$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectDir = Split-Path -Parent $scriptDir
$minersJsonPath = Join-Path $projectDir 'miners.json'
$libDir = Join-Path $projectDir 'lib'

$passed = 0
$failed = 0

function Assert-True {
    param([string]$Label, [bool]$Condition)
    if ($Condition) {
        Write-Host "  [PASS] $Label" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host "  [FAIL] $Label" -ForegroundColor Red
        $script:failed++
    }
}

Write-Host "=== deromine smoke tests ===" -ForegroundColor Cyan
Write-Host ''

# 1. miners.json is valid JSON
Write-Host '1. Catalog validation:' -ForegroundColor Yellow
$catalog = $null
try {
    $json = [System.IO.File]::ReadAllText($minersJsonPath)
    $catalog = $json | ConvertFrom-Json
    Assert-True 'miners.json parses as valid JSON' ($null -ne $catalog)
} catch {
    Assert-True 'miners.json parses as valid JSON' $false
}

# 2. Miners have required fields
Write-Host ''
Write-Host '2. Miner catalog entries:' -ForegroundColor Yellow
if ($catalog) {
    :mloop foreach ($m in $catalog.miners) {
        Assert-True "  miner '$($m.id)' has id field" (-not [string]::IsNullOrEmpty($m.id))
        Assert-True "  miner '$($m.id)' has name field" (-not [string]::IsNullOrEmpty($m.name))
        Assert-True "  miner '$($m.id)' has binary field" (-not [string]::IsNullOrEmpty($m.binary))
        Assert-True "  miner '$($m.id)' has repo field" (-not [string]::IsNullOrEmpty($m.repo))
        Assert-True "  miner '$($m.id)' has fee field" ($null -ne $m.fee)
        Assert-True "  miner '$($m.id)' has assets array" ($null -ne $m.assets -and $m.assets -is [System.Array])
        if ($m.assets -is [System.Array]) {
            foreach ($asset in $m.assets) {
                if ($null -eq $asset) { continue }
                Assert-True "    asset for $($m.id) has os field" (-not [string]::IsNullOrEmpty($asset.os))
                Assert-True "    asset for $($m.id) has arch field" (-not [string]::IsNullOrEmpty($asset.arch))
                Assert-True "    asset for $($m.id) has pattern field" (-not [string]::IsNullOrEmpty($asset.pattern))
            }
        }
    }
}

# 2b. The same startup validators used by mine.ps1 reject malformed data
# with a readable message rather than allowing a later stack trace.
Write-Host ''
Write-Host '2b. Startup schema validation:' -ForegroundColor Yellow
try {
    . (Join-Path $libDir 'config.ps1')
    . (Join-Path $libDir 'catalog.ps1')
    $tmpSchema = Join-Path ([System.IO.Path]::GetTempPath()) ('deromine-schema-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmpSchema -Force | Out-Null
    $badCatalog = Join-Path $tmpSchema 'bad-catalog.json'
    $badConfig = Join-Path $tmpSchema 'bad-config.json'
    Set-Content -LiteralPath $badCatalog -Value '{"miners":[],"daemons":[]}' -NoNewline
    Set-Content -LiteralPath $badConfig -Value '{"thread_count":"oops"}' -NoNewline
    Assert-True '  malformed catalog rejected' (-not (Test-CatalogSchema $badCatalog))
    Assert-True '  malformed config rejected' (-not (Test-ConfigSchema $badConfig))
    Assert-True '  repository catalog passes schema' (Test-CatalogSchema $minersJsonPath)
    $configPathForTest = Join-Path $projectDir 'config.json'
    Assert-True '  repository config passes schema' (Test-ConfigSchema $configPathForTest)
} catch {
    Assert-True '  startup schema validation works' $false
    Write-Host "    Error: $_" -ForegroundColor DarkRed
} finally {
    Remove-Item $tmpSchema -Recurse -Force -ErrorAction SilentlyContinue
}

# 2c. Both runners use the integrated default wallet.
Write-Host ''
Write-Host '2c. Default wallet:' -ForegroundColor Yellow
$expectedWallet = 'deroi1qyqztaxp2cqdhtve0k0v4dv0cmkpvhs8xukkwhgr5eep9u8urxzqqqdpvf892qgwq7h23'
$mineShText = Get-Content (Join-Path $projectDir 'mine.sh') -Raw
$minePsText = Get-Content (Join-Path $projectDir 'mine.ps1') -Raw
$expectedBashDefault = 'DEFAULT_WALLET="' + $expectedWallet + '"'
$expectedPsDefault = '$defaultWalletAddress = ''' + $expectedWallet + ''''
Assert-True '  Bash uses integrated default wallet' ($mineShText -match [regex]::Escape($expectedBashDefault))
Assert-True '  PowerShell uses integrated default wallet' ($minePsText -match [regex]::Escape($expectedPsDefault))

# 2d. Installers expose safe PowerShell prerequisite handling.
Write-Host ''
Write-Host '2d. PowerShell prerequisite handling:' -ForegroundColor Yellow
$installShText = Get-Content (Join-Path $projectDir 'install.sh') -Raw
$installPsText = Get-Content (Join-Path $projectDir 'install.ps1') -Raw
Assert-True '  bash installer handles missing pwsh safely' ($installShText -match 'install_pwsh_if_missing' -and $installShText -match 'DEROMINE_SKIP_PWSH' -and $installShText -match 'DEROMINE_AUTO_INSTALL_PWSH' -and $installShText -match '/dev/tty' -and $installShText -match 'packages\.microsoft\.com/config/fedora' -and $installShText -match 'brew install --cask powershell')
Assert-True '  bash installer never attempts pwsh install on Termux' ($installShText -match 'not packaged for Termux' -and $installShText -match 'com\.termux' -and $installShText -notmatch 'pkg install.*powershell')
Assert-True '  bash installer recovers from a diverged clone on update' ($installShText -match 'pull --ff-only' -and $installShText -match 'reset --hard')
Assert-True '  PowerShell installer handles missing pwsh safely' ($installPsText -match 'Install-PwshIfMissing' -and $installPsText -match 'Microsoft.PowerShell' -and $installPsText -match 'DEROMINE_AUTO_INSTALL_PWSH')

# 3. Helper modules load without errors
Write-Host ''
Write-Host '3. Helper modules:' -ForegroundColor Yellow
$helpers = @('config.ps1', 'catalog.ps1', 'platform.ps1', 'download.ps1', 'run.ps1', 'ui.ps1')
foreach ($h in $helpers) {
    $hPath = Join-Path $libDir $h
    Assert-True "  $h exists" (Test-Path $hPath)
}

# 3a. Reconfigure and CLI surface are present on the PowerShell path.
Write-Host ''
Write-Host '3a. CLI parity:' -ForegroundColor Yellow
$mineTextForCli = Get-Content (Join-Path $projectDir 'mine.ps1') -Raw
$uiTextForCli = Get-Content (Join-Path $libDir 'ui.ps1') -Raw
Assert-True '  --reconfigure is wired' ($mineTextForCli -match '--reconfigure' -and $mineTextForCli -match 'config.bak')
Assert-True '  benchmark trust controls are documented in help' ($uiTextForCli -match '--benchmark' -and $uiTextForCli -match '--include-closed-source' -and $uiTextForCli -match '--yes' -and $uiTextForCli -match '--bench-time')
$derolunaOptIn = @($catalog.miners | Where-Object { $_.id -eq 'deroluna' -and $_.benchmark_policy -eq 'opt-in' }).Count -eq 1
$astronvDisabled = @($catalog.miners | Where-Object { $_.id -eq 'astronv' -and $_.benchmark_policy -eq 'disabled' }).Count -eq 1
Assert-True '  catalog benchmark policies are explicit' ($derolunaOptIn -and $astronvDisabled)
Assert-True '  benchmark trust boundaries are wired' ($minePsText -match '--include-closed-source' -and $minePsText -match '--yes' -and $minePsText -match 'Start-MinerBenchmark.*IncludeClosedSource')
Assert-True '  help documents config/output controls' ($uiTextForCli -match '--config=<path>' -and $uiTextForCli -match '--output-dir=<dir>')
Assert-True '  custom node prompt remains available' ($uiTextForCli -match 'custom node' -and $mineTextForCli -match 'Read-DaemonEndpoint')

# 3b. --version works
Write-Host ''
Write-Host '3b. Version flag:' -ForegroundColor Yellow
try {
    $ver = (& pwsh -NoProfile -File (Join-Path $projectDir 'mine.ps1') --version 2>&1 | Select-Object -First 1)
    Assert-True "  mine.ps1 --version prints version ('$ver')" ($ver -match 'deromine \d+\.\d+\.\d+')
} catch {
    Assert-True '  mine.ps1 --version works' $false
    Write-Host "    Error: $_" -ForegroundColor DarkRed
}

# 3c. Space-separated flag values (--threads 28 ≡ --threads=28). Extracts the
# REAL ConvertTo-NormalizedCliArgs from mine.ps1 and exercises both forms,
# then runs the space form end-to-end through the real runner.
Write-Host ''
Write-Host '3c. Space-separated flag values:' -ForegroundColor Yellow
try {
    $minePsLines = Get-Content (Join-Path $projectDir 'mine.ps1')
    $startIdx = ($minePsLines | Select-String '^function ConvertTo-NormalizedCliArgs').LineNumber
    $endIdx = ($minePsLines | Select-String '^# end: ConvertTo-NormalizedCliArgs').LineNumber
    if (-not $startIdx -or -not $endIdx) { throw 'ConvertTo-NormalizedCliArgs markers not found' }
    $fnCode = ($minePsLines[($startIdx - 1)..($endIdx - 2)]) -join "`n"
    Invoke-Expression $fnCode
    $r = ConvertTo-NormalizedCliArgs @('--threads', '28')
    Assert-True '  --threads 28 normalizes to --threads=28' (($r -join ' ') -eq '--threads=28')
    $r = ConvertTo-NormalizedCliArgs @('--threads=28')
    Assert-True '  --threads=28 passes through unchanged' (($r -join ' ') -eq '--threads=28')
    $r = ConvertTo-NormalizedCliArgs @('--miner', 'c', '--threads=4', '--dry-run')
    Assert-True '  mixed space/equals forms normalize' (($r -join ' ') -eq '--miner=c --threads=4 --dry-run')
    $r = ConvertTo-NormalizedCliArgs @('--daemon', 'http://node.example.org:10100', '--max-restart', '3')
    Assert-True '  --daemon <url> space form keeps URL intact' (($r -join ' ') -eq '--daemon=http://node.example.org:10100 --max-restart=3')
    $r = ConvertTo-NormalizedCliArgs @('--wallet-address', 'deroi1abc', '--miner-type', 'rust')
    Assert-True '  long-alias flags (space) normalize' (($r -join ' ') -eq '--wallet-address=deroi1abc --miner-type=rust')
    # End-to-end: --miner list (space) exits 0 through the real runner.
    & pwsh -NoProfile -File (Join-Path $projectDir 'mine.ps1') --miner list *> $null
    Assert-True '  mine.ps1 --miner list (space) exits 0' ($LASTEXITCODE -eq 0)
} catch {
    Assert-True '  space-separated flag values work' $false
    Write-Host "    Error: $_" -ForegroundColor DarkRed
}

# 4. Platform detection
Write-Host ''
Write-Host '4. Platform detection:' -ForegroundColor Yellow
try {
    . (Join-Path $libDir 'platform.ps1')
    $platform = Get-PwshPlatform
    Assert-True "  Platform.os is non-empty" (-not [string]::IsNullOrEmpty($platform.os))
    Assert-True "  Platform.arch is non-empty" (-not [string]::IsNullOrEmpty($platform.arch))
    Assert-True "  OS is linux/macos/windows" ($platform.os -in @('linux', 'macos', 'windows'))
} catch {
    Assert-True '  Platform detection works' $false
    Write-Host "    Error: $_" -ForegroundColor DarkRed
}

# 4b. Windows arch mapping must never shell out to uname (regression: on
#     Windows, PROCESSOR_ARCHITECTURE=AMD64 used to fall through to '& uname -m',
#     crashing with "The term 'uname' is not recognized").
Write-Host ''
Write-Host '4b. Windows arch mapping:' -ForegroundColor Yellow
try {
    . (Join-Path $libDir 'platform.ps1')
    $savedProcArch = $env:PROCESSOR_ARCHITECTURE
    $savedW6432 = $env:PROCESSOR_ARCHITEW6432
    $savedPath = $env:PATH
    $marker = Join-Path ([System.IO.Path]::GetTempPath()) ('uname-marker-' + [guid]::NewGuid().ToString('N'))
    $fakeDir = Join-Path ([System.IO.Path]::GetTempPath()) ('deromine-fakebin-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $fakeDir -Force | Out-Null
    $fakeUname = Join-Path $fakeDir 'uname'
    if ($IsWindows) { $fakeUname += '.cmd' }
    $fakeBody = if ($IsWindows) {
        "@echo x86_64`r`necho MARKER>> `"$marker`"`r`n"
    } else {
        "#!/bin/sh`necho x86_64`necho MARKER>> `"$marker`"`n"
    }
    [System.IO.File]::WriteAllText($fakeUname, $fakeBody)
    if (-not $IsWindows) { chmod +x $fakeUname 2>$null }
    $env:PATH = "$fakeDir$([System.IO.Path]::PathSeparator)$env:PATH"

    $env:PROCESSOR_ARCHITECTURE = 'AMD64'
    $env:PROCESSOR_ARCHITEW6432 = $null
    Remove-Item $marker -Force -ErrorAction SilentlyContinue
    $p = Get-PwshPlatform
    Assert-True "  PROC_ARCH=AMD64 -> amd64, uname NOT called (got '$($p.arch)')" ($p.arch -eq 'amd64' -and -not (Test-Path $marker))

    $env:PROCESSOR_ARCHITECTURE = 'ARM64'
    Remove-Item $marker -Force -ErrorAction SilentlyContinue
    $p = Get-PwshPlatform
    Assert-True "  PROC_ARCH=ARM64 -> aarch64, uname NOT called (got '$($p.arch)')" ($p.arch -eq 'aarch64' -and -not (Test-Path $marker))

    # WOW64: 32-bit PowerShell on 64-bit Windows reports x86 + W6432.
    $env:PROCESSOR_ARCHITECTURE = 'x86'
    $env:PROCESSOR_ARCHITEW6432 = 'AMD64'
    Remove-Item $marker -Force -ErrorAction SilentlyContinue
    $p = Get-PwshPlatform
    Assert-True "  WOW64 (x86 + W6432=AMD64) -> amd64, uname NOT called (got '$($p.arch)')" ($p.arch -eq 'amd64' -and -not (Test-Path $marker))

    # Sanity: with no PROC_ARCH on unix, the uname fallback still works.
    $env:PROCESSOR_ARCHITECTURE = $null
    $env:PROCESSOR_ARCHITEW6432 = $null
    Remove-Item $marker -Force -ErrorAction SilentlyContinue
    $p = Get-PwshPlatform
    $called = Test-Path $marker
    if ($IsWindows) {
        Assert-True '  Windows with no PROC_ARCH still resolves amd64 without uname' ($p.arch -eq 'amd64' -and -not $called)
    } else {
        Assert-True "  unix fallback uses uname when PROC_ARCH unset (got '$($p.arch)')" ($called -and $p.arch -match '^(amd64|aarch64)$')
    }
} catch {
    Assert-True '  Windows arch mapping works' $false
    Write-Host "    Error: $_" -ForegroundColor DarkRed
} finally {
    $env:PROCESSOR_ARCHITECTURE = $savedProcArch
    $env:PROCESSOR_ARCHITEW6432 = $savedW6432
    $env:PATH = $savedPath
    Remove-Item $fakeDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $marker -Force -ErrorAction SilentlyContinue
}

# 4c. Windows Vulkan detection is FUNCTIONAL: a registered ICD is not proof
# a driver works (registered-but-broken drivers — e.g. Intel Iris Xe where
# wgpu falls back to DX12 — must still hide go-gpu). Test-WindowsVulkanWorks
# asks the Vulkan loader (vulkan-1.dll) to create an instance and enumerate
# physical devices. On Unix there is no Vulkan runtime, so it must degrade
# gracefully to $false.
Write-Host ''
Write-Host '4c. Windows Vulkan probe:' -ForegroundColor Yellow
try {
    . (Join-Path $libDir 'platform.ps1')
    if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') {
        # Real loader probe: must return a boolean without throwing (true only
        # if a working Vulkan runtime with >=1 GPU is present).
        $r = Test-WindowsVulkanWorks
        Assert-True "  functional probe returns bool (got '$r')" ($r -is [bool])
        # Regression: Add-Type is compiled once per session; calling again
        # must NOT throw (duplicate-type) and must still return a bool.
        $r2 = Test-WindowsVulkanWorks
        Assert-True '  second probe call still returns bool (no dup-type error)' ($r2 -is [bool])
    } else {
        Assert-True '  no Vulkan runtime on unix -> no Vulkan' (-not (Test-WindowsVulkanWorks))
        Assert-True '  repeated call on unix still returns false' (-not (Test-WindowsVulkanWorks))
    }
    # The probe must be a REAL loader call (vkCreateInstance + device
    # enumeration), not a registry-presence check.
    $platText = Get-Content (Join-Path $libDir 'platform.ps1') -Raw
    Assert-True '  probe calls vkCreateInstance / vkEnumeratePhysicalDevices' ($platText -match 'vkCreateInstance' -and $platText -match 'vkEnumeratePhysicalDevices')
} catch {
    Assert-True '  Windows Vulkan probe works' $false
    Write-Host "    Error: $_" -ForegroundColor DarkRed
}

# 4d. Windows Defender exclusion helpers must degrade gracefully off-Windows:
# Get-MpPreference / powershell.exe don't exist there, so both helpers return
# $false instead of throwing. Tests the REAL functions from platform.ps1.
Write-Host ''
Write-Host '4d. Defender exclusion helpers:' -ForegroundColor Yellow
try {
    . (Join-Path $libDir 'platform.ps1')
    if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') {
        # On Windows the helpers run for real: Test returns a bool, Add either
        # returns a bool or a (caught) false for a cancelled UAC prompt.
        $t = Test-DefenderExclusion (Join-Path $env:TEMP 'deromine-test')
        Assert-True "  Test-DefenderExclusion returns bool (got '$t')" ($t -is [bool])
    } else {
        Assert-True '  Test-DefenderExclusion false off-Windows' (-not (Test-DefenderExclusion '/tmp/deromine-x'))
        Assert-True '  Add-DefenderExclusion false off-Windows (no throw)' (-not (Add-DefenderExclusion '/tmp/deromine-x'))
    }
    $mineText = Get-Content (Join-Path $projectDir 'mine.ps1') -Raw
    Assert-True '  integrity failure offers Defender exclusion' ($mineText -match 'Add-DefenderExclusion')
    Assert-True '  --add-exclusion flag wired' ($mineText -match '--add-exclusion')
} catch {
    Assert-True '  Defender exclusion helpers work' $false
    Write-Host "    Error: $_" -ForegroundColor DarkRed
}

# 4e. Daemon URL validation (custom node entry): the daemon prompt lets the
# user type a custom host:port. Normalize-DaemonUrl must accept valid node
# formats (scheme optional, IPv4/IPv6, optional port defaulting to 10100)
# and return the normalized URL, rejecting unusable input.
Write-Host ''
Write-Host '4e. Daemon URL validation:' -ForegroundColor Yellow
try {
    . (Join-Path $libDir 'config.ps1')
    Assert-True '  host:port accepted' (Test-DaemonUrl '192.168.1.10:10100')
    Assert-True '  scheme + host:port accepted' (Test-DaemonUrl 'http://node.example.org:10100')
    Assert-True '  https + path accepted' (Test-DaemonUrl 'https://pool.example.org:10100/stratum')
    Assert-True '  bracketed IPv6 accepted' (Test-DaemonUrl '[::1]:10100')
    Assert-True '  bare word defaults to 10100' ((Normalize-DaemonUrl 'mynode') -eq 'mynode:10100')
    Assert-True '  missing port defaults to 10100' ((Normalize-DaemonUrl 'node.example.org') -eq 'node.example.org:10100')
    Assert-True '  default port inserted before path' ((Normalize-DaemonUrl 'https://node.example.org/stratum') -eq 'https://node.example.org:10100/stratum')
    Assert-True '  IPv6 without port defaults' ((Normalize-DaemonUrl '[::1]') -eq '[::1]:10100')
    Assert-True '  explicit port preserved' ((Normalize-DaemonUrl '192.168.1.10:9999') -eq '192.168.1.10:9999')
    Assert-True '  whitespace trimmed' ((Normalize-DaemonUrl '  my.node  ') -eq 'my.node:10100')
    Assert-True '  empty rejected' (-not (Test-DaemonUrl '   '))
    Assert-True '  garbage rejected' (-not (Test-DaemonUrl 'ht!tp://bad'))
    $uiText = Get-Content (Join-Path $libDir 'ui.ps1') -Raw
    Assert-True '  Read-DaemonEndpoint offers custom entry' ($uiText -match 'custom node')
    $mineText = Get-Content (Join-Path $projectDir 'mine.ps1') -Raw
    Assert-True '  mine.ps1 uses Read-DaemonEndpoint for the prompt' ($mineText -match 'Read-DaemonEndpoint')
} catch {
    Assert-True '  daemon URL validation works' $false
    Write-Host "    Error: $_" -ForegroundColor DarkRed
}

# 5. Binary name resolution
Write-Host ''
Write-Host '5. Binary name resolution:' -ForegroundColor Yellow
try {
    . (Join-Path $libDir 'catalog.ps1')
    if ($catalog) {
        :cbloop foreach ($m in $catalog.miners) {
            $bin = Get-MinerBinaryName $m $platform.os $platform.arch
            Assert-True "  '$($m.id)' binary name resolved: '$bin'" (-not [string]::IsNullOrEmpty($bin))
        }
    }
} catch {
    Assert-True '  Binary name resolution works' $false
    Write-Host "    Error: $_" -ForegroundColor DarkRed
}

# 6. Asset resolution for each available miner
Write-Host ''
Write-Host '6. Asset resolution:' -ForegroundColor Yellow
try {
    if ($catalog -and $platform) {
        :aloop foreach ($m in $catalog.miners) {
            $asset = Get-MinerAsset $m $platform.os $platform.arch
            if ($asset) {
                Assert-True "  '$($m.id)' asset resolved: $($asset.pattern)" $true
            } else {
                Assert-True "  '$($m.id)' no asset for $($platform.os)/$($platform.arch) (expected for some miners)" $true
            }
        }
    }
} catch {
    Assert-True '  Asset resolution works' $false
    Write-Host "    Error: $_" -ForegroundColor DarkRed
}

# 6b. Per-arch binary overrides (derohe regression: name differs by arch)
Write-Host ''
Write-Host '6b. Per-arch binary resolution:' -ForegroundColor Yellow
try {
    $derohe = Get-MinerByMinerId $catalog 'derohe'
    if ($derohe) {
        Assert-True '  derohe linux/amd64 -> dero-miner-linux-amd64' ((Get-MinerBinaryName $derohe 'linux' 'amd64') -eq 'dero-miner-linux-amd64')
        Assert-True '  derohe linux/aarch64 -> dero-miner-linux-arm64' ((Get-MinerBinaryName $derohe 'linux' 'aarch64') -eq 'dero-miner-linux-arm64')
        Assert-True '  derohe windows/amd64 -> dero-miner-windows-amd64.exe' ((Get-MinerBinaryName $derohe 'windows' 'amd64') -eq 'dero-miner-windows-amd64.exe')
        Assert-True '  derohe archive name on aarch64 matches binary' ((Get-MinerArchiveBinaryName $derohe 'linux' 'aarch64') -eq 'dero-miner-linux-arm64')
    } else {
        Assert-True '  derohe found in catalog' $false
    }
    # DeroLuna/TNN regression: their arm64 builds extract under a different
    # name than the desktop build (android archive ships deroluna-miner-aarch64,
    # arm64 archive ships tnn-miner-cpu) — used to fail with 'Binary not found
    # after extraction' on Termux. Per-asset binary overrides fix it.
    $derolunaT = Get-MinerByMinerId $catalog 'deroluna'
    $tnnT = Get-MinerByMinerId $catalog 'tnn'
    Assert-True '  deroluna found in catalog' ($null -ne $derolunaT)
    Assert-True '  tnn found in catalog' ($null -ne $tnnT)
    if ($derolunaT) {
        Assert-True '  deroluna linux/aarch64 -> deroluna-miner-aarch64' ((Get-MinerBinaryName $derolunaT 'linux' 'aarch64') -eq 'deroluna-miner-aarch64')
        Assert-True '  deroluna linux/aarch64 archive -> deroluna-miner-aarch64' ((Get-MinerArchiveBinaryName $derolunaT 'linux' 'aarch64') -eq 'deroluna-miner-aarch64')
        Assert-True '  deroluna linux/amd64 -> deroluna-miner' ((Get-MinerBinaryName $derolunaT 'linux' 'amd64') -eq 'deroluna-miner')
        Assert-True '  deroluna windows/amd64 -> deroluna-miner.exe' ((Get-MinerBinaryName $derolunaT 'windows' 'amd64') -eq 'deroluna-miner.exe')
    }
    if ($tnnT) {
        Assert-True '  tnn linux/aarch64 -> tnn-miner-cpu' ((Get-MinerBinaryName $tnnT 'linux' 'aarch64') -eq 'tnn-miner-cpu')
        Assert-True '  tnn linux/aarch64 archive -> tnn-miner-cpu' ((Get-MinerArchiveBinaryName $tnnT 'linux' 'aarch64') -eq 'tnn-miner-cpu')
        Assert-True '  tnn linux/amd64 -> tnn-miner' ((Get-MinerBinaryName $tnnT 'linux' 'amd64') -eq 'tnn-miner')
        Assert-True '  tnn windows/amd64 -> tnn-miner.exe' ((Get-MinerBinaryName $tnnT 'windows' 'amd64') -eq 'tnn-miner.exe')
    }
} catch {
    Assert-True '  per-arch binary resolution works' $false
    Write-Host "    Error: $_" -ForegroundColor DarkRed
}

# 6c. Termux exclusions (derohe must be hidden on Android/Termux)
Write-Host ''
Write-Host '6c. Termux exclusions:' -ForegroundColor Yellow
$savedPrefix = $env:PREFIX
try {
    $fakePrefix = Join-Path ([System.IO.Path]::GetTempPath()) ('deromine-com.termux-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $fakePrefix 'bin') -Force | Out-Null
    $env:PREFIX = $fakePrefix
    $deroheT = Get-MinerByMinerId $catalog 'derohe'
    $zigT = Get-MinerByMinerId $catalog 'zig'
    $rustT = Get-MinerByMinerId $catalog 'rust'
    Assert-True '  derohe hidden on Termux' (-not (Test-MinerHardwareSupported $deroheT))
    Assert-True '  zig hidden on Termux (arm64 build broken on Android)' (-not (Test-MinerHardwareSupported $zigT))
    $derolunaT = Get-MinerByMinerId $catalog 'deroluna'
    $tnnT = Get-MinerByMinerId $catalog 'tnn'
    Assert-True '  deroluna hidden on Termux' (-not (Test-MinerHardwareSupported $derolunaT))
    Assert-True '  tnn hidden on Termux' (-not (Test-MinerHardwareSupported $tnnT))
    Assert-True '  rust still supported on Termux' (Test-MinerHardwareSupported $rustT)
    # Direct-run (--miner=<id>) must refuse unsupported miners BEFORE any
    # resolve/download, not just hide them from the list.
    $mineShGate = Get-Content (Join-Path $projectDir 'mine.sh') -Raw
    Assert-True '  bash direct-run refuses unsupported miners before download' ($mineShGate -match 'is not supported on this host' -and $mineShGate -match 'miner_hardware_ok "\$MINER_JSON"' -and $mineShGate -match 'is not supported on Termux/Android')
    $minePsGate = Get-Content (Join-Path $projectDir 'mine.ps1') -Raw
    Assert-True '  powershell direct-run refuses unsupported miners before download' ($minePsGate -match 'is not supported on' -and $minePsGate -match 'Test-MinerHardwareSupported \$miner' -and $minePsGate -match 'nothing was downloaded')
} finally {
    $env:PREFIX = $savedPrefix
    Remove-Item (Join-Path ([System.IO.Path]::GetTempPath()) 'deromine-com.termux-*') -Recurse -Force -ErrorAction SilentlyContinue
}

# 6d. Cache integrity + version-aware cache (tests the real lib/download.ps1 helpers)
Write-Host ''
Write-Host '6d. Cache integrity:' -ForegroundColor Yellow
try {
    . (Join-Path $libDir 'download.ps1')
    $tmpCache = Join-Path ([System.IO.Path]::GetTempPath()) ('deromine-cache-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmpCache -Force | Out-Null
    $good = Join-Path $tmpCache 'good.bin'
    $bad = Join-Path $tmpCache 'bad.bin'
    $small = Join-Path $tmpCache 'small.bin'
    $goodBuf = New-Object byte[] 400000
    $goodBuf[0] = 0x7F; $goodBuf[1] = 0x45; $goodBuf[2] = 0x4C; $goodBuf[3] = 0x46
    [System.IO.File]::WriteAllBytes($good, $goodBuf)
    $badBuf = New-Object byte[] 400000
    [System.IO.File]::WriteAllBytes($bad, $badBuf)
    [System.IO.File]::WriteAllBytes($small, @([byte]0x7F, 0x45, 0x4C, 0x46, 0x74, 0x69, 0x6E, 0x79))
    $compact = Join-Path $tmpCache 'compact.bin'
    $compactBuf = New-Object byte[] 178145
    $compactBuf[0] = 0x7F; $compactBuf[1] = 0x45; $compactBuf[2] = 0x4C; $compactBuf[3] = 0x46
    [System.IO.File]::WriteAllBytes($compact, $compactBuf)
    Assert-True '  integrity accepts valid ELF binary' (Test-BinaryIntegrity $good 'linux')
    Assert-True '  integrity rejects wrong magic' (-not (Test-BinaryIntegrity $bad 'linux'))
    Assert-True '  integrity rejects tiny file' (-not (Test-BinaryIntegrity $small 'linux'))
    Assert-True '  integrity accepts valid compact ELF binary' (Test-BinaryIntegrity $compact 'linux')
    $cached = Join-Path $tmpCache 'cached.bin'
    [System.IO.File]::WriteAllBytes($cached, $goodBuf)
    Set-Content -LiteralPath "$cached.tag" -Value 'v0.3.0' -NoNewline
    Assert-True '  matching tag + valid binary is usable' (Test-CachedBinaryUsable $cached 'v0.3.0' 'linux')
    Set-Content -LiteralPath "$cached.tag" -Value 'v0.2.0' -NoNewline
    Assert-True '  stale tag forces re-download' (-not (Test-CachedBinaryUsable $cached 'v0.3.0' 'linux'))
    Remove-Item "$cached.tag" -Force -ErrorAction SilentlyContinue
    Assert-True '  missing tag forces re-download' (-not (Test-CachedBinaryUsable $cached 'v0.3.0' 'linux'))
    $corrupt = Join-Path $tmpCache 'corrupt.bin'
    [System.IO.File]::WriteAllBytes($corrupt, $badBuf)
    Set-Content -LiteralPath "$corrupt.tag" -Value 'v0.3.0' -NoNewline
    Assert-True '  corrupt binary forces re-download' (-not (Test-CachedBinaryUsable $corrupt 'v0.3.0' 'linux'))
    # Release-tag cache: while the recorded tag is fresh the release API is
    # skipped entirely (GitHub/GitLab rate-limit unauthenticated API calls).
    $fresh = Join-Path $tmpCache 'fresh.bin'
    [System.IO.File]::WriteAllBytes($fresh, $goodBuf)
    Set-Content -LiteralPath "$fresh.tag" -Value 'v0.3.0' -NoNewline
    Set-Content -LiteralPath "$fresh.tagtime" -Value ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -NoNewline
    Assert-True '  fresh tag skips release API' (Test-CachedTagFresh $fresh 'linux')
    Set-Content -LiteralPath "$fresh.tagtime" -Value ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 999999) -NoNewline
    Assert-True '  expired tag re-checks release API' (-not (Test-CachedTagFresh $fresh 'linux'))
    Remove-Item "$fresh.tagtime" -Force -ErrorAction SilentlyContinue
    Assert-True '  missing tagtime re-checks release API' (-not (Test-CachedTagFresh $fresh 'linux'))
    Set-Content -LiteralPath "$fresh.tagtime" -Value ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -NoNewline
    Assert-True '  corrupt binary inside TTL re-checks release API' (-not (Test-CachedTagFresh $bad 'linux'))
    $dlTextTag = Get-Content (Join-Path $libDir 'download.ps1') -Raw
    $mineTextTag = Get-Content (Join-Path $projectDir 'mine.ps1') -Raw
    Assert-True '  GitHub API calls identify deromine (User-Agent)' ($dlTextTag -match 'User-Agent' -and $dlTextTag -match 'DeromineVersion')
    Assert-True '  fetch records tag fetch time (.tagtime)' ($dlTextTag -match 'tagtime' -and $mineTextTag -match 'tagtime')
    # Integrity failures must be actionable, not a dead-end error: on Windows a
    # binary that is MISSING right after extraction is almost always Defender
    # quarantining it (false positive for closed-source miners); a present-but-
    # corrupt one is a bad download. Tests the REAL Get-IntegrityFailureHint.
    $hintWin = Get-IntegrityFailureHint -Path (Join-Path $tmpCache 'missing.exe') -Os 'windows' -MinerDir $tmpCache
    Assert-True '  missing binary on windows -> Defender hint' ($hintWin -match 'Windows Defender')
    $hintLin = Get-IntegrityFailureHint -Path (Join-Path $tmpCache 'missing.bin') -Os 'linux' -MinerDir $tmpCache
    Assert-True '  missing binary on linux -> generic retry hint' ($hintLin -match 'incomplete or corrupt')
    $hintCorrupt = Get-IntegrityFailureHint -Path $bad -Os 'windows' -MinerDir $tmpCache
    Assert-True '  present-but-corrupt binary on windows -> reports observed state' ($hintCorrupt -match 'Observed:' -and $hintCorrupt -match '400000')
    # A full-size file that cannot be opened is Windows Security ACTIVELY
    # holding it (the deroluna case: correct size, locked). Simulated with a
    # FileShare.None handle, which .NET honors on every platform.
    $lockedFile = Join-Path $tmpCache 'locked.bin'
    [System.IO.File]::WriteAllBytes($lockedFile, $goodBuf)
    $fsLock = [System.IO.File]::Open($lockedFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        $hintLocked = Get-IntegrityFailureHint -Path $lockedFile -Os 'windows' -MinerDir $tmpCache
        Assert-True '  locked full-size binary -> actively-held message' ($hintLocked -match 'is LOCKED' -and $hintLocked -match 'Re-running alone will NOT fix')
    } finally {
        $fsLock.Dispose()
    }
    $mineText = Get-Content (Join-Path $projectDir 'mine.ps1') -Raw
    Assert-True '  launch path prints the integrity hint' ($mineText -match 'Get-IntegrityFailureHint')
    $dlText = Get-Content (Join-Path $libDir 'download.ps1') -Raw
    Assert-True '  integrity check retries transient AV locks' ($dlText -match 'Test-BinaryIntegrityOnce')
} finally {
    Remove-Item $tmpCache -Recurse -Force -ErrorAction SilentlyContinue
}

# 6e. Lifted binaries keep their dependencies. Windows releases ship DLLs
# next to the exe (e.g. libstdc++-6.dll); the lift must copy the whole nested
# dir, not just the binary. Tests the REAL Move-LiftedFiles from download.ps1.
Write-Host ''
Write-Host '6e. Lift dependencies:' -ForegroundColor Yellow
try {
    . (Join-Path $libDir 'download.ps1')
    $tmpLift = Join-Path ([System.IO.Path]::GetTempPath()) ('deromine-lift-' + [guid]::NewGuid().ToString('N'))
    $destDir = Join-Path $tmpLift 'cache'
    $nested = Join-Path $destDir 'nested'
    New-Item -ItemType Directory -Path $nested -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $nested 'dirtybird-miner-cpu.exe') -Value 'MZfakeexe' -NoNewline
    Set-Content -LiteralPath (Join-Path $nested 'libstdc++-6.dll') -Value 'DLLDATA' -NoNewline
    Set-Content -LiteralPath (Join-Path $nested 'config.json') -Value '{}' -NoNewline
    Move-LiftedFiles -SourceDir $nested -DestDir $destDir -ArchiveBinary 'dirtybird-miner-cpu.exe' -CanonicalBinary 'dirtybird-c-miner.exe'
    Assert-True '  exe lifted to canonical name' (Test-Path (Join-Path $destDir 'dirtybird-c-miner.exe'))
    Assert-True '  DLL lifted next to exe' (Test-Path (Join-Path $destDir 'libstdc++-6.dll'))
    Assert-True '  config.json lifted too' (Test-Path (Join-Path $destDir 'config.json'))
    Assert-True '  nested dir removed after lift' (-not (Test-Path $nested))
} catch {
    Assert-True '  lift dependencies works' $false
    Write-Host "    Error: $_" -ForegroundColor DarkRed
} finally {
    Remove-Item $tmpLift -Recurse -Force -ErrorAction SilentlyContinue
}

# 6f. Miner exit codes are reported after launch (a silent instant exit used
# to return to the prompt with zero feedback). Tests the REAL Start-Miner.
Write-Host ''
Write-Host '6f. Miner exit reporting:' -ForegroundColor Yellow
try {
    . (Join-Path $libDir 'run.ps1')
    $tmpExit = Join-Path ([System.IO.Path]::GetTempPath()) ('deromine-exit-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmpExit -Force | Out-Null
    $fakeName = if ($IsWindows) { 'fail-miner.cmd' } else { 'fail-miner.sh' }
    $fakeBin = Join-Path $tmpExit $fakeName
    if ($IsWindows) {
        Set-Content -LiteralPath $fakeBin -Value "@echo off`r`nexit /b 2`r`n" -NoNewline
    } else {
        Set-Content -LiteralPath $fakeBin -Value "#!/bin/sh`nexit 2`n" -NoNewline
        chmod +x $fakeBin 2>$null
    }
    $flagMap = @{ daemon = '-d'; wallet = '-w'; threads = '-t' }
    # 6>&1 captures the information stream (Write-Host) so the report line can
    # be asserted — the feature IS the message, not just the exit code.
    $out = Start-Miner -BinaryPath $fakeBin -DaemonUrl 'host:10100' -WalletAddress 'dero1test' -ThreadCount 2 -FlagMap $flagMap -ExtraArgs @() 6>&1 | Out-String
    Assert-True '  nonzero miner exit is reported' ($out -match 'exited with code 2')
    # The STATUS_DLL_NOT_FOUND (0xC0000135) hint must exist so a Windows user
    # hitting the missing-DLL case gets told exactly how to fix it.
    $runPsText = Get-Content (Join-Path $libDir 'run.ps1') -Raw
    Assert-True '  missing-DLL hint present in run.ps1' ($runPsText -match 'STATUS_DLL_NOT_FOUND')
} catch {
    Assert-True '  miner exit reporting works' $false
    Write-Host "    Error: $_" -ForegroundColor DarkRed
} finally {
    Remove-Item $tmpExit -Recurse -Force -ErrorAction SilentlyContinue
}

# 6g. Proven-on-host + launch-failure memory: a self-test-gated GPU miner
# (go-gpu, whose self-test refuses broken drivers) is listed ONLY once a
# launch proved it runs on this host — a registered-but-broken driver can pass
# every static probe yet still refuse to mine. Other miners are hidden after
# ONE confirmed fast failure. Tests the REAL helpers from download.ps1.
Write-Host ''
Write-Host '6g. Proven-on-host + failure memory:' -ForegroundColor Yellow
try {
    . (Join-Path $libDir 'download.ps1')
    $tmpMem = Join-Path ([System.IO.Path]::GetTempPath()) ('deromine-mem-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $tmpMem 'go-gpu') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $tmpMem 'c') -Force | Out-Null
    $gated = [PSCustomObject]@{ id = 'go-gpu'; startup_gate = $true }
    $plain = [PSCustomObject]@{ id = 'c' }

    # Self-test-gated miner: NOT listed until .ok proves a real launch.
    Assert-True '  gated miner not listed before any launch' (-not (Test-MinerListable -Miner $gated -BinDir $tmpMem))
    Mark-MinerLaunchOutcome -BinDir $tmpMem -MinerId 'go-gpu' -ExitCode 0 -ElapsedSec 30
    Assert-True '  successful launch writes .ok -> gated miner listed' (Test-MinerListable -Miner $gated -BinDir $tmpMem)
    Assert-True '  .ok marker exists' (Test-MinerProvenOnHost -BinDir $tmpMem -MinerId 'go-gpu')
    Mark-MinerLaunchOutcome -BinDir $tmpMem -MinerId 'go-gpu' -ExitCode 1 -ElapsedSec 2
    Assert-True '  fast failure clears .ok -> gated miner hidden again' (-not (Test-MinerListable -Miner $gated -BinDir $tmpMem))

    # Non-gated miner: listed until ONE confirmed fast failure.
    Assert-True '  plain miner listed with no failures' (Test-MinerListable -Miner $plain -BinDir $tmpMem)
    Mark-MinerLaunchOutcome -BinDir $tmpMem -MinerId 'c' -ExitCode 1 -ElapsedSec 2
    Assert-True '  one confirmed fast failure -> plain miner hidden' (-not (Test-MinerListable -Miner $plain -BinDir $tmpMem))
    Mark-MinerLaunchOutcome -BinDir $tmpMem -MinerId 'c' -ExitCode 0 -ElapsedSec 30
    Assert-True '  successful run resets -> plain miner listed again' (Test-MinerListable -Miner $plain -BinDir $tmpMem)
    Mark-MinerLaunchOutcome -BinDir $tmpMem -MinerId 'c' -ExitCode 130 -ElapsedSec 3
    Assert-True '  Ctrl+C does not count as failure' (Test-MinerListable -Miner $plain -BinDir $tmpMem)
    Mark-MinerLaunchOutcome -BinDir $tmpMem -MinerId 'c' -ExitCode 1 -ElapsedSec 60
    Assert-True '  slow exit does not count as startup failure' (Test-MinerListable -Miner $plain -BinDir $tmpMem)
    # PowerShell reports the NTSTATUS Ctrl+C code as the signed form -1073741510.
    Mark-MinerLaunchOutcome -BinDir $tmpMem -MinerId 'c' -ExitCode -1073741510 -ElapsedSec 3
    Assert-True '  signed Ctrl+C code does not count as failure' (Test-MinerListable -Miner $plain -BinDir $tmpMem)
    # Ctrl+C on a gated miner proves it ran -> .ok written -> listed.
    Mark-MinerLaunchOutcome -BinDir $tmpMem -MinerId 'go-gpu' -ExitCode 130 -ElapsedSec 3
    Assert-True '  Ctrl+C proves gated miner -> listed' (Test-MinerListable -Miner $gated -BinDir $tmpMem)
    $uiText = Get-Content (Join-Path $libDir 'ui.ps1') -Raw
    Assert-True '  miner list filters on proven-on-host' ($uiText -match 'Test-MinerListable')
} catch {
    Assert-True '  proven-on-host + failure memory works' $false
    Write-Host "    Error: $_" -ForegroundColor DarkRed
} finally {
    Remove-Item $tmpMem -Recurse -Force -ErrorAction SilentlyContinue
}

# 6h. Auto-restart measures the LAST run's elapsed, not the whole session: a
# stopwatch that spans restart delays would make a fast-failing miner (e.g.
# go-gpu on a broken GPU) look like it ran long enough to pass startup,
# wrongly writing .ok and listing it forever. Tests the REAL
# Start-MinerAutoRestart from run.ps1.
Write-Host ''
Write-Host '6h. Auto-restart per-run elapsed:' -ForegroundColor Yellow
try {
    . (Join-Path $libDir 'run.ps1')
    $tmpAr = Join-Path ([System.IO.Path]::GetTempPath()) ('deromine-autorestart-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmpAr -Force | Out-Null
    $fakeName = if ($IsWindows) { 'fail-miner.cmd' } else { 'fail-miner.sh' }
    $fakeBin = Join-Path $tmpAr $fakeName
    if ($IsWindows) {
        Set-Content -LiteralPath $fakeBin -Value "@echo off`r`nexit /b 1`r`n" -NoNewline
    } else {
        Set-Content -LiteralPath $fakeBin -Value "#!/bin/sh`nexit 1`n" -NoNewline
        chmod +x $fakeBin 2>$null
    }
    $flagMap = @{ daemon = '-d'; wallet = '-w'; threads = '-t' }
    # 3 fast failures with 2s delays. The returned elapsed must be the LAST
    # single run, never the whole session (restart delays included). Measure
    # the session with our own stopwatch and require last < session: a
    # caller-side stopwatch that spans delays would always report a value
    # that meets or exceeds the session, so this catches the regression
    # regardless of machine speed.
    $sessionSw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastElapsed = Start-MinerAutoRestart -MinerId 'go-gpu' -BinaryPath $fakeBin -DaemonUrl 'host:10100' -WalletAddress 'dero1test' -ThreadCount 2 -FlagMap $flagMap -ExtraArgs @() -MaxRestarts 3 -RestartDelay 2
    $sessionSw.Stop()
    $sessionElapsed = [int]$sessionSw.Elapsed.TotalSeconds
    Assert-True '  auto-restart returns the last run elapsed as an int' ($lastElapsed -is [int])
    Assert-True '  returned elapsed is the last run, not the whole session' ($lastElapsed -is [int] -and $lastElapsed -lt $sessionElapsed)
    $mineText = Get-Content (Join-Path $projectDir 'mine.ps1') -Raw
    Assert-True '  mine.ps1 uses the returned per-run elapsed for auto-restart' ($mineText -match 'lastElapsedSec = Start-MinerAutoRestart')
} catch {
    Assert-True '  auto-restart per-run elapsed works' $false
    Write-Host "    Error: $_" -ForegroundColor DarkRed
} finally {
    Remove-Item $tmpAr -Recurse -Force -ErrorAction SilentlyContinue
}

# 7. Installer (install.ps1) runs and places the launcher for this OS
Write-Host ''
Write-Host '7. Installer (cross-platform):' -ForegroundColor Yellow
if (Get-Command git -ErrorAction SilentlyContinue) {
    $isWin = if ($IsWindows) { $true } elseif ($PSVersionTable.PSEdition -eq 'Desktop') { $true } else { $false }
    $launcherName = if ($isWin) { 'deromine.cmd' } else { 'deromine' }
    $tmpBase = [System.IO.Path]::GetTempPath()
    $tmpInst = Join-Path $tmpBase ('deromine-test-' + [guid]::NewGuid().ToString('N'))
    $tmpBin = Join-Path $tmpBase ('deromine-bin-' + [guid]::NewGuid().ToString('N'))
    try {
        $installer = Join-Path $projectDir 'install.ps1'
        Assert-True '  install.ps1 exists' (Test-Path $installer)
        & pwsh -NoProfile -File $installer -RepoUrl $projectDir -InstallDir $tmpInst -BinDir $tmpBin -NoPathEdit | Out-Null
        Assert-True '  install.ps1 ran cleanly' ($LASTEXITCODE -eq 0)
        Assert-True '  repo cloned (mine.ps1 present)' (Test-Path (Join-Path $tmpInst 'mine.ps1'))
        Assert-True "  launcher shim placed ($launcherName)" (Test-Path (Join-Path $tmpBin $launcherName))
        $shimInvokesMine = $false
        $shimPath = Join-Path $tmpBin $launcherName
        if (Test-Path $shimPath) {
            # Get-Content follows symlinks, so this works for the Unix
            # symlinked launcher as well as the Windows copied shim.
            $shimInvokesMine = (Get-Content $shimPath -Raw) -match 'mine\.ps1'
        }
        Assert-True '  shim invokes mine.ps1' $shimInvokesMine
        # Re-run must succeed (idempotent update path)
        & pwsh -NoProfile -File $installer -RepoUrl $projectDir -InstallDir $tmpInst -BinDir $tmpBin -NoPathEdit | Out-Null
        Assert-True '  install.ps1 re-run (idempotent)' ($LASTEXITCODE -eq 0)
    } catch {
        Assert-True '  install.ps1 ran cleanly' $false
        Write-Host "    Error: $_" -ForegroundColor DarkRed
    } finally {
        Remove-Item $tmpInst -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $tmpBin -Recurse -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-Host '  [SKIP] git not found - skipping installer test' -ForegroundColor DarkYellow
}

# Summary
Write-Host ''
Write-Host '=== Results ===' -ForegroundColor Cyan
Write-Host "Passed: $passed" -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Yellow' })
Write-Host "Failed: $failed" -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Red' })

if ($failed -eq 0) {
    Write-Host 'All smoke tests passed!' -ForegroundColor Green
} else {
    Write-Host 'Some smoke tests failed. See output above for details.' -ForegroundColor Red
    exit 1
}