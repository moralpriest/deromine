$ErrorActionPreference = 'Stop'

$script:DeromineVersion = '1.1.1'

# ── Load helpers (dot-source .ps1, not .psm1, to avoid scope/export issues) ──
$projectDir = $PSScriptRoot
$libDir    = Join-Path $projectDir 'lib'
foreach ($f in Get-ChildItem $libDir -Filter '*.ps1' | Sort-Object Name) {
    . $f.FullName
}

# ── Validate shared data before any mode can use it ──
# Keep malformed catalog/config failures at the boundary so users get one
# actionable message instead of a later property-access stack trace.

# ── Defaults ──
$daemonUrl       = 'http://node.derofoundation.org:10100'
$defaultWalletAddress = 'deroi1qyqztaxp2cqdhtve0k0v4dv0cmkpvhs8xukkwhgr5eep9u8urxzqqqdpvf892qgwq7h23'
$daemonFlag      = $false
$walletAddress   = ''
$minerType       = $null
$threadCount     = 0
$autoRestart     = $false
$maxRestart      = 5
$restartDelay    = 10
$dryRun          = $false
$reconfigure     = $false
$benchmark       = $false
$benchTime       = 30
$includeClosedSource = $false
$assumeYes       = $false
$addExclusion    = $false
$devFee          = ''
$outputDir       = Join-Path $projectDir 'bin'
$configPath      = Join-Path $projectDir 'config.json'
$minersJsonPath  = Join-Path $projectDir 'miners.json'

# ── Parameter parsing ──
# `pwsh -File` tokenizes the raw command line and splits `--daemon=http://host:port`
# into `--daemon=http` + `//host:port` (and `host:port` into `host` + `port`).
# Reassemble the fragments so daemon URLs survive the native-arg boundary.
function Join-DaemonValue {
    param([array]$Params, [int]$Index)
    $val = ($Params[$Index] -split '=')[1]
    if ($Index + 1 -lt $Params.Count) {
        $next = [string]$Params[$Index + 1]
        if ($next -like '//*') { return $val + ':' + $next }
        if ($next -match '^\d+$') { return $val + ':' + $next }
    }
    return $val
}

# Accept values both as --flag=value and --flag value: normalize the space
# form into --flag=value so the `=*` switch cases below handle both styles
# identically. `pwsh -File` delivers a space-separated value as one intact
# token; daemon URLs then fall through to Join-DaemonValue, which reassembles
# any Windows-style splits (--daemon=host + port).
function ConvertTo-NormalizedCliArgs {
    param([string[]]$RawArgs)
    $valueFlags = @('--daemon', '--daemon-url', '--wallet', '--wallet-address', '--miner', '--miner-type', '--threads', '--thread-count', '--max-restart', '--delay', '--bench-time', '--dev-fee', '--output-dir', '--config')
    $normalized = [string[]]@()
    for ($n = 0; $n -lt $RawArgs.Count; $n++) {
        $p = [string]$RawArgs[$n]
        if ($valueFlags -contains $p) {
            if ($n + 1 -ge $RawArgs.Count) {
                Write-Host "Missing value for $p" -ForegroundColor Red
                exit 1
            }
            $normalized += "$p=$($RawArgs[$n + 1])"
            $n++
        } else {
            $normalized += $p
        }
    }
    # The comma wraps the array so a single-element result is NOT unrolled to
    # a scalar string (which would make $params[0] index the first character).
    return ,$normalized
}
# end: ConvertTo-NormalizedCliArgs

$params = ConvertTo-NormalizedCliArgs $args
for ($i = 0; $i -lt $params.Count; $i++) {
    if ($params[$i] -eq '-h' -or $params[$i] -eq '--help' -or $params[$i] -eq 'help' -or $params[$i] -eq '/?') {
        Show-Help
    }
    if ($params[$i] -eq '--version' -or $params[$i] -eq '-v') {
        Write-Host "deromine $script:DeromineVersion"
        exit 0
    }
    switch -Wildcard ($params[$i]) {
        '--reconfigure'       { $reconfigure     = $true }
        '--add-exclusion'     { $addExclusion    = $true }
        '--daemon=*'          { $daemonUrl      = Join-DaemonValue $params $i; $daemonFlag = $true }
        '--wallet=*'          { $walletAddress   = ($params[$i] -split '=')[1] }
        '--miner=*'           { $minerType       = ($params[$i] -split '=')[1] }
        '--threads=*'         { $threadCount     = [int]($params[$i] -split '=')[1] }
        '--auto-restart'      { $autoRestart     = $true }
        '--max-restart=*'     { $maxRestart      = [int]($params[$i] -split '=')[1] }
        '--delay=*'           { $restartDelay    = [int]($params[$i] -split '=')[1] }
        '--dry-run'           { $dryRun          = $true }
        '--benchmark'         { $benchmark       = $true }
        '--include-closed-source' { $includeClosedSource = $true }
        '--yes'                { $assumeYes       = $true }
        '--bench-time=*'      { $benchTime       = [int]($params[$i] -split '=')[1] }
        '--dev-fee=*'         { $devFee          = ($params[$i] -split '=')[1] }
        '--output-dir=*'      { $outputDir       = ($params[$i] -split '=')[1] }
        '--config=*'          { $configPath      = ($params[$i] -split '=')[1] }
        '--daemon-url=*'      { $daemonUrl       = Join-DaemonValue $params $i; $daemonFlag = $true }
        '--wallet-address=*'  { $walletAddress   = ($params[$i] -split '=')[1] }
        '--miner-type=*'      { $minerType       = ($params[$i] -split '=')[1] }
        '--thread-count=*'    { $threadCount     = [int]($params[$i] -split '=')[1] }
        default {
            if ($params[$i] -match '^-') {
                Write-Host "Unknown parameter: $($params[$i])" -ForegroundColor Red
                exit 1
            }
        }
    }
}

# ── Startup validation ──
if (-not (Test-CatalogSchema $minersJsonPath)) { exit 1 }
if (-not (Test-ConfigSchema $configPath)) { exit 1 }

# ── Dev fee override: --dev-fee flag wins over config.json ──
$devFeeOverride = $devFee
if (-not $devFeeOverride) {
    $cfgEarly = Read-Config $configPath
    if ($cfgEarly) {
        $dfProp = $cfgEarly.PSObject.Properties['dev_fee']
        if ($dfProp -and $dfProp.Value) { $devFeeOverride = [string]$dfProp.Value }
    }
}

# ── Reconfigure: re-run the setup prompts from scratch ──
# Moves the current config aside (to config.bak, the default-wallet source the
# prompts already read) and deletes it, so wallet/daemon/threads are all asked
# again instead of being reused from disk.
if ($reconfigure) {
    $bakPath = Join-Path $projectDir 'config.bak'
    if (Test-Path $configPath) {
        Copy-Item $configPath $bakPath -Force
        Remove-Item $configPath -Force
        Write-Success "Previous config backed up to $bakPath; starting fresh setup"
    } else {
        Write-Host "No existing config to reset; starting fresh setup" -ForegroundColor DarkYellow
    }
}

# ── List mode ──
if ($minerType -and $minerType -eq 'list') {
    $catalog = Read-Catalog $minersJsonPath
    if (-not $catalog) { exit 1 }
    $platform = Get-PwshPlatform
    Write-Banner
    Write-Host "Available miners on $($platform.os)/$($platform.arch):" -ForegroundColor DarkCyan
    $null = Write-MinerTable $catalog.miners $platform -BinDir $outputDir -DevFee $devFeeOverride -AsList
    exit 0
}

# ── Resolve miner (interactive or --miner flag) ──
$platform = Get-PwshPlatform

# ── Add a Windows Defender exclusion for the binaries folder (Windows only) ──
if ($addExclusion) {
    if ($platform.os -ne 'windows') {
        Write-Host "[x] --add-exclusion only works on Windows" -ForegroundColor Red
        exit 1
    }
    if (Test-DefenderExclusion $outputDir) {
        Write-Success "Already excluded from Defender: $outputDir"
        exit 0
    }
    if (Add-DefenderExclusion $outputDir) {
        Write-Success "Defender exclusion added: $outputDir"
        exit 0
    }
    Write-Host "[x] Exclusion not added (UAC cancelled or no admin rights)." -ForegroundColor Red
    Write-Host "    Add it manually: Windows Security > Virus & threat protection > Manage settings > Exclusions > Add a folder > '$outputDir'" -ForegroundColor DarkYellow
    exit 1
}

# ── Benchmark mode ──
if ($benchmark) {
    $catalog = Read-Catalog $minersJsonPath
    if (-not $catalog) { exit 1 }
    if ($benchTime -lt 1) { $benchTime = 30 }
    $cfg = Read-Config $configPath
    if (-not $cfg) { $cfg = [PSCustomObject]@{} }
    if (-not $walletAddress -and $cfg.PSObject.Properties['wallet_address'] -and $cfg.wallet_address) { $walletAddress = [string]$cfg.wallet_address }
    if (-not $walletAddress) { $walletAddress = $defaultWalletAddress }
    if (-not $daemonFlag) {
        if ($cfg.PSObject.Properties['daemon_url'] -and $cfg.daemon_url) { $daemonUrl = [string]$cfg.daemon_url }
        else { $daemonUrl = 'http://127.0.0.1:10100' }
    }
    $liveDaemon = $daemonUrl -replace '^https?://', ''
    $benchThreads = $threadCount
    if ($benchThreads -le 0 -and $cfg.PSObject.Properties['thread_count'] -and $cfg.thread_count) { $benchThreads = [int]$cfg.thread_count }
    if ($benchThreads -le 0) {
        $cpus = [Environment]::ProcessorCount
        if (-not $cpus -or $cpus -lt 2) { $cpus = 2 }
        $benchThreads = $cpus - 1
    }
    if ($benchThreads -lt 1) { $benchThreads = 1 }
    Start-MinerBenchmark -Catalog $catalog -Platform $platform -BenchTime $benchTime -Threads $benchThreads -Daemon $liveDaemon -Wallet $walletAddress -BinDir $outputDir -IncludeClosedSource:$includeClosedSource -AssumeYes:$assumeYes
    exit 0
}

# ── Interactive: action menu + miner select ──
if (-not $minerType -or $minerType -eq 'interactive') {
    $catalog = Read-Catalog $minersJsonPath
    if (-not $catalog) { exit 1 }

    Write-Banner
    $sCfg = Read-Config $configPath
    $sDaemon = $daemonUrl
    if (-not $daemonFlag -and $sCfg) {
        if ($sCfg.PSObject.Properties['daemon_url'] -and $sCfg.daemon_url) { $sDaemon = [string]$sCfg.daemon_url }
    }
    $sDaemon = $sDaemon -replace '^https?://', ''
    $sWallet = ''
    if ($walletAddress) { $sWallet = $walletAddress }
    elseif ($sCfg -and $sCfg.PSObject.Properties['wallet_address'] -and $sCfg.wallet_address) { $sWallet = [string]$sCfg.wallet_address }
    $sThreads = $threadCount
    if ($sThreads -le 0 -and $sCfg -and $sCfg.PSObject.Properties['thread_count'] -and $sCfg.thread_count) { $sThreads = [int]$sCfg.thread_count }
    Write-ConfigStatus -Daemon $sDaemon -Wallet $sWallet -Threads $sThreads
    Write-Host "Select a miner (or an action):" -ForegroundColor DarkCyan
    $shownMiners = Write-MinerTable $catalog.miners $platform -BinDir $outputDir -DevFee $devFeeOverride
    if ($shownMiners.Count -eq 0) { exit 1 }
    $maxChoice = $shownMiners.Count
    Write-Host (("  0/l/b/h/q → " + "list  ·  " + "benchmark  ·  " + "help  ·  quit")) -ForegroundColor DarkGray
    $choice = Read-Host "Number (1-$maxChoice), or action [l/b/h/q]"
    switch ($choice) {
        { $choice -match '^(l|L|list)$' }   { & $PSCommandPath --miner=list; exit 0 }
        { $choice -match '^(b|B|bench|benchmark)$' } {
            $benchArgs = @('--benchmark')
            if ($includeClosedSource) { $benchArgs += '--include-closed-source' }
            if ($assumeYes) { $benchArgs += '--yes' }
            & $PSCommandPath @benchArgs
            exit 0
        }
        { $choice -match '^(h|H|help)$' }   { Show-Help }
        { $choice -match '^(q|quit|x|exit)$' } { Write-Host 'bye' -ForegroundColor DarkGray; exit 0 }
        { $choice -match '^\d+$' } {
            $choiceIdx = [int]$choice - 1
            if ($choiceIdx -lt 0 -or $choiceIdx -ge $shownMiners.Count) {
                Write-Error "Invalid choice '$choice'"
                exit 1
            }
            $miner = $shownMiners[$choiceIdx]
        }
        default {
            Write-Error "Invalid choice '$choice'"
            exit 1
        }
    }
}
else {
    $catalog = Read-Catalog $minersJsonPath
    if (-not $catalog) { exit 1 }
    $miner = Get-MinerByMinerId $catalog $minerType
    if (-not $miner) {
        Write-Error "Miner '$minerType' not found in catalog"
        exit 1
    }
    # Refuse BEFORE any resolve/download (an unsupported miner must never be
    # fetched, even when force-run with --miner=<id>).
    if (-not (Test-MinerHardwareSupported $miner)) {
        $why = if (Test-IsTermux) { 'Termux/Android' } else { 'this host' }
        Write-Error "Miner '$minerType' is not supported on $why; nothing was downloaded"
        exit 1
    }
}

# ── Resolve binary name & catalog asset entry (has the glob pattern) ──
$binaryName = Get-MinerBinaryName $miner $platform.os $platform.arch
$archiveBinary = Get-MinerArchiveBinaryName $miner $platform.os $platform.arch
if (-not $binaryName) {
    Write-Error "No binary name for $($miner.id) on $($platform.os)/$($platform.arch)"
    exit 1
}

$assetEntry = Get-MinerAsset $miner $platform.os $platform.arch
if (-not $assetEntry) {
    Write-Error "No asset for $($miner.id) on $($platform.os)/$($platform.arch)"
    exit 1
}
$assetPattern = [string]$assetEntry.pattern

# ── Resolve config from disk or prompt ──
$config = Read-Config $configPath
if (-not $config) {
    $config = @{}
}

# ── Default wallet (from config.bak, shown in prompt when no wallet saved) ──
$defaultWallet = $defaultWalletAddress
$bakPath = Join-Path $projectDir 'config.bak'
if (Test-Path $bakPath) {
    $bak = Read-Config $bakPath
    if ($bak -and $bak.wallet_address) { $defaultWallet = [string]$bak.wallet_address }
}

# ── Wallet ──
if ($walletAddress) {
    if ($config -is [System.Management.Automation.PSCustomObject]) {
        $config | Add-Member -NotePropertyName wallet_address -NotePropertyValue $walletAddress -Force
    } else {
        $config.wallet_address = $walletAddress
    }
}
$hasWallet = ($config -is [System.Management.Automation.PSCustomObject] -and $config.PSObject.Properties['wallet_address'] -and $config.wallet_address) -or
             ($config -is [hashtable] -and $config.wallet_address)
if (-not $hasWallet) {
    $walletAddress = Read-WalletAddress -Default $defaultWallet
    if (-not $walletAddress) { exit 1 }
    if ($config -is [System.Management.Automation.PSCustomObject]) {
        $config | Add-Member -NotePropertyName wallet_address -NotePropertyValue $walletAddress -Force
    } else {
        $config.wallet_address = $walletAddress
    }
}
$effectiveWallet = if ($config -is [System.Management.Automation.PSCustomObject]) { $config.wallet_address } else { $config.wallet_address }

# ── Daemon: --daemon flag > live localhost > saved config > prompt ──
$hasSavedDaemon = ($config -is [System.Management.Automation.PSCustomObject] -and $config.PSObject.Properties['daemon_url'] -and $config.daemon_url) -or
                  ($config -is [hashtable] -and $config.daemon_url)

if ($daemonFlag) {
    $effectiveDaemon = $daemonUrl
} else {
    $localDaemon = Test-LocalDaemonUrl
    if ($localDaemon) {
        Write-Success "Local DERO daemon detected: $localDaemon"
        $effectiveDaemon = $localDaemon
    } elseif ($hasSavedDaemon) {
        $savedDaemon = if ($config -is [System.Management.Automation.PSCustomObject]) { $config.daemon_url } else { $config.daemon_url }
        if (Test-IsMiningUrl $savedDaemon) {
            $effectiveDaemon = $savedDaemon
        } else {
            Write-Host "Stale saved daemon ($savedDaemon) is not a mining port; ignoring." -ForegroundColor DarkYellow
            $effectiveDaemon = Read-DaemonEndpoint $catalog.daemons
            if (-not $effectiveDaemon) { exit 0 }
        }
    } else {
        $effectiveDaemon = Read-DaemonEndpoint $catalog.daemons
        if (-not $effectiveDaemon) { exit 0 }
    }
}

if ($config -is [System.Management.Automation.PSCustomObject]) {
    $config | Add-Member -NotePropertyName daemon_url -NotePropertyValue $effectiveDaemon -Force
} else {
    $config.daemon_url = $effectiveDaemon
}

# ── Dev fee (from --dev-fee or config.json; only used by miners with a dev_fee flag) ──
if (-not $devFee) {
    if ($config -is [System.Management.Automation.PSCustomObject] -and $config.PSObject.Properties['dev_fee'] -and $config.dev_fee) {
        $devFee = [string]$config.dev_fee
    }
}

# ── Thread count ──
$hasThreads = ($config -is [System.Management.Automation.PSCustomObject] -and $config.PSObject.Properties['thread_count'] -and $config.thread_count) -or
              ($config -is [hashtable] -and $config.thread_count)
if (-not $hasThreads) {
    if ($threadCount -gt 0) {
        $tc = $threadCount
    } else {
        $tc = Read-ThreadCount
    }
    if ($config -is [System.Management.Automation.PSCustomObject]) {
        $config | Add-Member -NotePropertyName thread_count -NotePropertyValue $tc -Force
    } else {
        $config.thread_count = $tc
    }
}
$effectiveThreads = if ($config -is [System.Management.Automation.PSCustomObject]) { $config.thread_count } else { $config.thread_count }

# ── Save config ──
$dir = Split-Path -Parent $configPath
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
Write-Config $configPath $config

# ── Resolve real download URL from GitHub/GitLab (runtime) ──
$repoHost = [string]$miner.host
if (-not $repoHost) { $repoHost = 'github' }
$repoBranch = [string]$miner.branch
$repoReleasePath = [string]$miner.release_path
Write-Host "`nResolving latest release for $($miner.repo)..." -ForegroundColor Cyan
$resolved = Resolve-DownloadAsset -Repo $miner.repo -RepoHost $repoHost -Branch $repoBranch -ReleasePath $repoReleasePath -Os $platform.os -Arch $platform.arch -Pattern $assetPattern
if (-not $resolved) { exit 1 }

$archiveName = $resolved.Name
$downloadUrl = $resolved.Url

# ── Dry-run ──
if ($dryRun) {
    $daemonDisplay = $effectiveDaemon -replace '^https?://', ''
    Write-Host "`n--- DRY RUN ---" -ForegroundColor Yellow
    Write-Host "Miner:    $($miner.id) ($($miner.name))"
    Write-Host "Binary:   $binaryName"
    Write-Host "Tag:      $($resolved.Tag)"
    Write-Host "Asset:    $archiveName"
    Write-Host "URL:      $downloadUrl"
    Write-Host "Wallet:   $effectiveWallet"
    Write-Host "Daemon:   $daemonDisplay"
    Write-Host "Threads:  $effectiveThreads"
    Write-Host "Output:   $outputDir"
    $hasDevFeeFlag = $miner.PSObject.Properties['flags'] -and $miner.flags.PSObject.Properties['dev_fee']
    if ($hasDevFeeFlag -and $devFee) { Write-Host "Dev fee:  $devFee%" }
    exit 0
}

# ── Setup directories ──
$minerDir = Join-Path $outputDir $miner.id
if (-not (Test-Path $minerDir)) {
    New-Item -ItemType Directory -Path $minerDir -Force | Out-Null
}

# ── Download (version-aware cache: a stale or corrupt cached binary is
#    re-downloaded instead of being used forever) ──
$archivePath = Join-Path $minerDir $archiveName
$binaryPath = Join-Path $minerDir $binaryName
$needsDownload = -not (Test-Path $binaryPath)
if (-not $needsDownload) {
    $needsDownload = -not (Test-CachedBinaryUsable $binaryPath $resolved.Tag $platform.os)
}

if ($needsDownload) {
    if (Test-Path $binaryPath) {
        Write-Host "Cached binary is stale or corrupt; re-downloading..." -ForegroundColor DarkYellow
        Remove-Item $binaryPath -Force -ErrorAction SilentlyContinue
        Remove-Item "$binaryPath.tag" -Force -ErrorAction SilentlyContinue
    }
    Write-Host "Downloading $archiveName ($($resolved.Tag))..." -ForegroundColor Yellow
    $success = Save-WebFile $downloadUrl $archivePath
    if (-not $success) {
        Write-Error 'Download failed'
        exit 1
    }
    Write-Host "Extracting..." -ForegroundColor Yellow
    Invoke-Extract $archivePath $minerDir
    Remove-Item $archivePath -Force -ErrorAction SilentlyContinue
} else {
    Write-Success "Using cached binary: $binaryPath ($($resolved.Tag))"
}

# ── Resolve binary path (handle nested dirs) ──
if (-not (Test-Path $binaryPath)) {
    $found = Get-ChildItem -Path $minerDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $archiveBinary } | Select-Object -First 1
    if ($found) {
        $binaryPath = $found.FullName
        $binDir = Split-Path -Parent $binaryPath
        if ($binDir -ne $minerDir) {
            Write-Host "Lifting binary from $binDir to $minerDir" -ForegroundColor Yellow
            # Copy the whole nested dir — Windows releases ship DLLs next to
            # the exe, and a lone exe cannot start without them.
            Move-LiftedFiles -SourceDir $binDir -DestDir $minerDir -ArchiveBinary $archiveBinary -CanonicalBinary $binaryName
            $binaryPath = Join-Path $minerDir $binaryName
        }
    }
    else {
        Write-Error "Binary '$binaryName' not found after extraction in $minerDir"
        Write-Host "    Contents:" -ForegroundColor DarkYellow
        Get-ChildItem -Path $minerDir -Recurse -File | ForEach-Object { Write-Host "      $($_.FullName)" -ForegroundColor DarkYellow }
        exit 1
    }
}

if ($platform.os -ne 'windows') {
    try {
        chmod +x $binaryPath 2>$null
    } catch {
        Write-Host "(warning: chmod +x failed, binary may not be executable)" -ForegroundColor DarkYellow
    }
} else {
    # Downloaded/extracted files carry Mark-of-the-Web; clear it so Windows
    # does not block the miner on launch (SmartScreen / Defender).
    try { Unblock-File -Path $binaryPath -ErrorAction SilentlyContinue } catch {}
}

if ($needsDownload) {
    if (-not (Test-BinaryIntegrity $binaryPath $platform.os)) {
        Write-Host "`n[x] Extracted binary '$binaryName' failed integrity check:" -ForegroundColor Red
        Write-Host (Get-IntegrityFailureHint -Path $binaryPath -Os $platform.os -MinerDir $minerDir) -ForegroundColor Yellow
        # On Windows this is almost always Defender interfering with the
        # freshly-extracted exe. Offer to add a folder exclusion (elevated)
        # and auto-retry — re-running alone just re-downloads into the lock.
        if ($platform.os -eq 'windows') {
            if (Test-DefenderExclusion $outputDir) {
                Write-Host "  '$outputDir' is already excluded from Defender. If it keeps failing, restore the detection in Windows Security > Protection history." -ForegroundColor DarkYellow
            } else {
                $answer = ''
                try { $answer = Read-Host "`nAdd a Windows Defender exclusion for '$outputDir' (fixes the lock/quarantine loop; a UAC prompt will appear)? [Y/n]" } catch { $answer = 'n' }
                if ($answer -match '^(y|yes)?$') {
                    if (Add-DefenderExclusion $outputDir) {
                        Write-Success "Defender exclusion added for '$outputDir'"
                        # Retry once with the exclusion in place — the miner
                        # downloads and launches in the same session.
                        Remove-Item $minerDir -Recurse -Force -ErrorAction SilentlyContinue
                        & $PSCommandPath --miner=$($miner.id) @($args)
                        exit $LASTEXITCODE
                    }
                    Write-Host "  Exclusion not added (cancelled or failed). Add it manually:" -ForegroundColor DarkYellow
                    Write-Host "    Windows Security > Virus & threat protection > Manage settings > Exclusions > Add a folder > '$outputDir'" -ForegroundColor DarkYellow
                }
            }
        }
        exit 1
    }
    # Record the release tag so future runs can detect a stale cache.
    try { Set-Content -LiteralPath "$binaryPath.tag" -Value $resolved.Tag -NoNewline -ErrorAction SilentlyContinue } catch {}
}

# ── Build command ──
$flagMap = Get-MinerCliArgs $miner
$showDevFee = ''
if ($flagMap.dev_fee -and $devFee) {
    $flagMap.dev_fee_value = $devFee
    $showDevFee = $devFee
}
$cmdArgs = @()

# ── Launch ──
$daemonDisplay = $effectiveDaemon -replace '^https?://', ''
Write-LaunchSummary -Miner $miner -Binary $binaryPath -Daemon $daemonDisplay -Wallet $effectiveWallet -Threads $effectiveThreads -DevFee $showDevFee

# ── Launch (foreground) ──
$lastElapsedSec = 0
if ($autoRestart) {
    # Start-MinerAutoRestart reports the LAST run's elapsed. A wrapper
    # stopwatch must NOT span the whole session: restart delays would make a
    # fast-failing miner look like it ran long enough to pass startup, and a
    # broken self-test-gated miner (go-gpu) would wrongly get marked
    # proven-on-host and listed forever.
    $lastElapsedSec = Start-MinerAutoRestart `
        -MinerId $miner.id `
        -BinaryPath $binaryPath `
        -DaemonUrl $effectiveDaemon `
        -WalletAddress $effectiveWallet `
        -ThreadCount $effectiveThreads `
        -FlagMap $flagMap `
        -ExtraArgs $cmdArgs `
        -MaxRestarts $maxRestart `
        -RestartDelay $restartDelay `
        -LogDir (Join-Path $outputDir 'logs')
} else {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Start-Miner -BinaryPath $binaryPath -DaemonUrl $effectiveDaemon -WalletAddress $effectiveWallet -ThreadCount $effectiveThreads -FlagMap $flagMap -ExtraArgs $cmdArgs
    $sw.Stop()
    $lastElapsedSec = [int]$sw.Elapsed.TotalSeconds
}
# Remember fast startup failures so a miner that can't run on this host is
# hidden from the list on future runs (--miner=<id> still force-runs it).
Mark-MinerLaunchOutcome -BinDir $outputDir -MinerId $miner.id -ExitCode $LASTEXITCODE -ElapsedSec $lastElapsedSec
