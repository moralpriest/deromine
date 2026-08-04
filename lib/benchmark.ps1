function Get-BenchmarkPolicy {
    param([object]$Miner)
    $policy = 'opt-in'
    if ($Miner.PSObject.Properties['benchmark_policy'] -and $Miner.benchmark_policy) {
        $policy = ([string]$Miner.benchmark_policy).ToLowerInvariant()
    }
    if ($policy -notin @('default', 'opt-in', 'disabled')) { return 'opt-in' }
    return $policy
}

function Get-SupportedMiners {
    param([object]$Catalog, [object]$Platform, [string]$BinDir = '', [switch]$IncludeClosedSource)

    $rows = @()
    if (-not $Catalog -or -not $Catalog.miners) { return $rows }
    foreach ($m in $Catalog.miners) {
        if (-not (Get-MinerAsset $m $Platform.os $Platform.arch)) { continue }
        if (-not (Test-MinerHardwareSupported $m)) { continue }
        $policy = Get-BenchmarkPolicy $m
        if ($policy -eq 'disabled') { continue }
        if ($policy -eq 'opt-in' -and -not $IncludeClosedSource) { continue }
        # Hide miners that can't actually run on this host: self-test-gated
        # GPU miners are listed only once a launch proved they work here.
        if ($BinDir -and -not (Test-MinerListable -Miner $m -BinDir $BinDir)) { continue }
        $rows += $m
    }
    return $rows
}

function ConvertFrom-HashToken {
    param([string]$Token)
    $m = [regex]::Match($Token, '(\d+(\.\d+)?)\s*([kKmM]?)\s*H/s')
    if (-not $m.Success) { return $null }
    $num = [double]$m.Groups[1].Value
    $mult = 1.0
    switch ($m.Groups[3].Value) {
        'k' { $mult = 1000.0 }
        'K' { $mult = 1000.0 }
        'm' { $mult = 1000000.0 }
        'M' { $mult = 1000000.0 }
    }
    return $num * $mult
}

function Get-LastHashrate {
    param([string]$Text)
    $ms = [regex]::Matches($Text, '\d+(\.\d+)? ?[kKmM]? ?H/s(?![/])')
    if ($ms.Count -eq 0) { return $null }
    return ConvertFrom-HashToken $ms[$ms.Count - 1].Value
}

function Get-DeroheHashrate {
    param([string]$Text)
    $ms = [regex]::Matches($Text, 'MINING @ \d+(\.\d+)? ?[kKmM]? ?H/s')
    if ($ms.Count -eq 0) { return $null }
    return ConvertFrom-HashToken $ms[$ms.Count - 1].Value
}

function Invoke-BenchmarkProcess {
    param([string]$BinaryPath, [string[]]$Arguments, [int]$TimeoutSec)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $BinaryPath
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($a in $Arguments) { [void]$psi.ArgumentList.Add($a) }
    try {
        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        if (-not $p.Start()) { return '' }
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill() } catch {}
            $p.WaitForExit()
        }
        $stdout = $outTask.GetAwaiter().GetResult()
        $stderr = $errTask.GetAwaiter().GetResult()
        return "$stdout`n$stderr"
    } catch {
        return ''
    }
}

function Get-MinerBinaryPath {
    param(
        [object]$Miner,
        [string]$BinDir,
        [string]$PlatformOs,
        [string]$PlatformArch,
        [switch]$IncludeClosedSource
    )
    if ((Get-BenchmarkPolicy $Miner) -eq 'opt-in' -and -not $IncludeClosedSource) { return $null }
    $minerDir = Join-Path $BinDir $Miner.id
    New-Item -ItemType Directory -Path $minerDir -Force | Out-Null
    $binaryName = Get-MinerBinaryName $Miner $PlatformOs $PlatformArch
    $binaryPath = Join-Path $minerDir $binaryName
    $archiveBinary = Get-MinerArchiveBinaryName $Miner $PlatformOs $PlatformArch
    $asset = Get-MinerAsset $Miner $PlatformOs $PlatformArch
    if (-not $asset) { return $null }
    $pattern = [string]$asset.pattern
    $repoHost = [string]$Miner.host
    if (-not $repoHost) { $repoHost = 'github' }
    $branch = [string]$Miner.branch
    $releasePath = [string]$Miner.release_path
    # Resolve always (needed for the version-aware cache check).
    $resolved = Resolve-DownloadAsset -Repo $Miner.repo -RepoHost $repoHost -Branch $branch -ReleasePath $releasePath -Os $PlatformOs -Arch $PlatformArch -Pattern $pattern
    if (-not $resolved) { return $null }

    $needFetch = -not (Test-Path $binaryPath)
    if (-not $needFetch) {
        $needFetch = -not (Test-CachedBinaryUsable $binaryPath $resolved.Tag $PlatformOs)
    }
    if ($needFetch) {
        if (Test-Path $binaryPath) {
            Write-Host "  [re-fetch] $($Miner.name): cached binary stale or corrupt" -ForegroundColor DarkGray
            Remove-Item $binaryPath -Force -ErrorAction SilentlyContinue
            Remove-Item "$binaryPath.tag" -Force -ErrorAction SilentlyContinue
        }
        Write-Host "  [fetch] $($Miner.name) ($($resolved.Tag))" -ForegroundColor DarkGray
        $archivePath = Join-Path $minerDir $resolved.Name
        $ok = Save-WebFile $resolved.Url $archivePath
        if (-not $ok) { return $null }
        Invoke-Extract $archivePath $minerDir
        Remove-Item $archivePath -Force -ErrorAction SilentlyContinue

        if (-not (Test-Path $binaryPath)) {
            $found = Get-ChildItem -Path $minerDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $archiveBinary } | Select-Object -First 1
            if ($found) {
                if ($found.DirectoryName -ne $minerDir) {
                    # Copy the whole nested dir — Windows releases ship DLLs
                    # next to the exe, and a lone exe cannot start without them.
                    Move-LiftedFiles -SourceDir $found.DirectoryName -DestDir $minerDir -ArchiveBinary $archiveBinary -CanonicalBinary $binaryName
                }
            }
        }
        if (Test-Path $binaryPath) {
            if ($PlatformOs -ne 'windows') {
                try { & chmod +x $binaryPath 2>$null } catch {}
            } else {
                try { Unblock-File -Path $binaryPath -ErrorAction SilentlyContinue } catch {}
            }
            if (-not (Test-BinaryIntegrity $binaryPath $PlatformOs)) {
                Write-Host "  [x] $($Miner.name): extracted binary failed integrity check" -ForegroundColor Red
                Write-Host "      Incomplete/corrupt download. Remove-Item '$minerDir' -Recurse -Force and retry." -ForegroundColor DarkYellow
                Remove-Item $binaryPath -Force -ErrorAction SilentlyContinue
                Remove-Item "$binaryPath.tag" -Force -ErrorAction SilentlyContinue
                return $null
            }
            # Record the release tag so future runs can detect a stale cache.
            try { Set-Content -LiteralPath "$binaryPath.tag" -Value $resolved.Tag -NoNewline -ErrorAction SilentlyContinue } catch {}
            return $binaryPath
        }
        # Reached only right after a fresh fetch + lift. On Windows a missing
        # exe at this point is almost always Defender quarantine (false
        # positive on closed-source miners), not a bad archive.
        if ($PlatformOs -eq 'windows') {
            Write-Host "  [x] $($Miner.name): binary missing after extraction - Windows Defender likely quarantined it (a false positive for closed-source miners)." -ForegroundColor Red
            Write-Host "      Restore it in Windows Security > Protection history, or add an exclusion for '$minerDir'." -ForegroundColor DarkYellow
        } else {
            Write-Host "  [x] $($Miner.name): binary not found after extraction" -ForegroundColor Red
        }
        return $null
    }
    return $binaryPath
}

function Get-TnnHashrate {
    param([string]$Text)
    $m = [regex]::Match($Text, 'threads @ (\d+(\.\d+)?)')
    if (-not $m.Success) { return $null }
    return [math]::Round([double]$m.Groups[1].Value * 1000, 2)
}

function Invoke-MinerBenchmark {
    param(
        [object]$Miner,
        [string]$BinaryPath,
        [int]$BenchTime,
        [int]$Threads,
        [string]$Daemon,
        [string]$Wallet,
        [switch]$IncludeClosedSource
    )
    $id = [string]$Miner.id
    $policy = Get-BenchmarkPolicy $Miner
    if ($policy -eq 'opt-in' -and -not $IncludeClosedSource) {
        Write-Host "  [skip] $($Miner.name): closed/partially closed miner requires --include-closed-source" -ForegroundColor DarkGray
        return $null
    }
    if ($policy -eq 'disabled') {
        Write-Host "  [skip] $($Miner.name): benchmark disabled in catalog" -ForegroundColor DarkGray
        return $null
    }
    Write-Host "  $($Miner.name): " -ForegroundColor White -NoNewline
    $out = ''
    switch ($id) {
        'tnn'     { $out = Invoke-BenchmarkProcess $BinaryPath @("--DERO", "--daemon-address", $Daemon, "--wallet", $Wallet, "--threads", "$Threads", "--mine-time", "$BenchTime", "--no-gpu") ($BenchTime + 15) }
        'go'      { $out = Invoke-BenchmarkProcess $BinaryPath @("--sustained", "--secs", "$BenchTime", "-t", "$Threads") ($BenchTime + 20) }
        'zig'     { $out = Invoke-BenchmarkProcess $BinaryPath @("--bench") 20 }
        'rust'    { $out = Invoke-BenchmarkProcess $BinaryPath @("--sustained", "-t", "$Threads") ($BenchTime + 20) }
        'go-gpu'  { $out = Invoke-BenchmarkProcess $BinaryPath @("-benchpipe", "8000", "-batch", "400") 45 }
        'c'       { $out = Invoke-BenchmarkProcess $BinaryPath @("-d", $Daemon, "-w", $Wallet, "-t", "$Threads") ($BenchTime + 10) }
        'deroluna' { $out = Invoke-BenchmarkProcess $BinaryPath @("-d", $Daemon, "-w", $Wallet, "-t", "$Threads") ($BenchTime + 10) }
        'derohe' {
            if (Get-Command script -ErrorAction SilentlyContinue) {
                $cmd = "$BinaryPath --wallet-address $Wallet --daemon-rpc-address $Daemon --mining-threads $Threads"
                $out = (& timeout ($BenchTime + 30) script -qec $cmd /dev/null 2>&1 | Out-String)
            } else {
                Write-Host "no pty (script) for derohe" -ForegroundColor Red
                return $null
            }
        }
        default {
            Write-Host "no benchmark method" -ForegroundColor Red
            return $null
        }
    }
    $raw = $null
    if ($id -eq 'derohe') { $raw = Get-DeroheHashrate $out }
    elseif ($id -eq 'tnn') { $raw = Get-TnnHashrate $out }
    else { $raw = Get-LastHashrate $out }
    if (-not $raw) {
        Write-Host "no hashrate reported" -ForegroundColor Red
        $clean = [regex]::Replace([string]$out, "\x1b\[[0-9;]*m", '')
        $lines = @($clean -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 3)
        if ($lines.Count -gt 0) {
            Write-Host ("  output tail: {0}" -f ($lines -join ' | ')) -ForegroundColor DarkGray
        }
        return $null
    }
    $feeText = [string]$Miner.fee
    $feeNum = 0.0
    if ($feeText -match '^(\d+(\.\d+)?)%') { $feeNum = [double]$Matches[1] }
    $eff = [math]::Round($raw * (1 - $feeNum / 100), 2)
    Write-Host ("{0} H/s (fee {1}, effective {2})" -f $raw, $feeText, $eff) -ForegroundColor Green
    return [PSCustomObject]@{ Id = $id; Eff = $eff; Raw = $raw; Fee = $feeText; Name = [string]$Miner.name }
}

function Start-MinerBenchmark {
    param(
        [object]$Catalog,
        [object]$Platform,
        [int]$BenchTime,
        [int]$Threads,
        [string]$Daemon,
        [string]$Wallet,
        [string]$BinDir,
        [switch]$IncludeClosedSource,
        [switch]$AssumeYes
    )
    # ── Benchmark history (compare against last run) ──
    $benchCache = Join-Path $BinDir '.benchmarks.json'
    $prev = @{}
    if (Test-Path $benchCache) {
        try { $prev = (Get-Content $benchCache -Raw | ConvertFrom-Json) -as [hashtable] } catch { $prev = @{} }
        if (-not $prev) { $prev = @{} }
    }
    $optInMiners = @($Catalog.miners | Where-Object {
        (Get-BenchmarkPolicy $_) -eq 'opt-in' -and
        (Get-MinerAsset $_ $Platform.os $Platform.arch) -and
        (Test-MinerHardwareSupported $_) -and
        (Test-MinerListable -Miner $_ -BinDir $BinDir)
    })
    if ($IncludeClosedSource -and $optInMiners.Count -gt 0) {
        Write-Host ''
        Write-Host 'WARNING: this will download and execute closed-source or partially closed-source miners.' -ForegroundColor Yellow
        Write-Host ('Affected miners: ' + (($optInMiners | ForEach-Object { $_.name }) -join ', ')) -ForegroundColor Yellow
        if (-not $AssumeYes) {
            if ([Console]::IsInputRedirected) {
                Write-Host 'Non-interactive input detected; rerun with --yes only after reviewing the risk.' -ForegroundColor Red
                exit 1
            }
            $answer = Read-Host 'Continue with these miners? [y/N]'
            if ($answer -notmatch '^(y|yes)$') {
                Write-Host 'Benchmark cancelled; no opt-in miners were run.' -ForegroundColor DarkYellow
                exit 0
            }
        } else {
            Write-Host 'Non-interactive confirmation supplied with --yes.' -ForegroundColor DarkYellow
        }
    }
    $supported = @(Get-SupportedMiners -Catalog $Catalog -Platform $Platform -BinDir $BinDir -IncludeClosedSource:$IncludeClosedSource)
    if ($supported.Count -eq 0) {
        Write-Host "[x] No miners available to benchmark on this host" -ForegroundColor Red
        exit 1
    }
    Write-Banner
    if (-not $IncludeClosedSource -and $optInMiners.Count -gt 0) {
        Write-Host ('Skipped untrusted miners: ' + (($optInMiners | ForEach-Object { $_.name }) -join ', ')) -ForegroundColor DarkYellow
        Write-Host 'Use --include-closed-source to opt in; add --yes for non-interactive confirmation.' -ForegroundColor DarkYellow
    }
    Write-Host "Benchmarking $($supported.Count) miners (~${BenchTime}s each, ${Threads} threads)..." -ForegroundColor DarkCyan

    $rows = @()
    foreach ($m in $supported) {
        $binaryPath = Get-MinerBinaryPath -Miner $m -BinDir $BinDir -PlatformOs $Platform.os -PlatformArch $Platform.arch -IncludeClosedSource:$IncludeClosedSource
        if (-not $binaryPath) {
            Write-Host "  $($m.name): binary unavailable" -ForegroundColor Red
            Start-Sleep -Seconds 1
            continue
        }
        $row = Invoke-MinerBenchmark -Miner $m -BinaryPath $binaryPath -BenchTime $BenchTime -Threads $Threads -Daemon $Daemon -Wallet $Wallet -IncludeClosedSource:$IncludeClosedSource
        if ($row) { $rows += $row }
        Start-Sleep -Seconds 3
    }

    Write-Host ''
    if ($rows.Count -eq 0) {
        Write-Host "[x] No benchmark results collected" -ForegroundColor Red
        exit 1
    }
    $sorted = @($rows | Sort-Object { [double]$_.Eff } -Descending)
    Write-Host ("{0,-4} {1,-30} {2,12} {3,8} {4,14} {5,10}" -f '#', 'Miner', 'H/s', 'Fee', 'Eff. H/s', 'Δ vs last')
    for ($i = 0; $i -lt $sorted.Count; $i++) {
        $row = $sorted[$i]
        $deltaStr = ''
        if ($prev.ContainsKey($row.Id)) {
            $lastEff = [double]$prev[$row.Id]
            $d = [math]::Round($row.Eff - $lastEff, 1)
            $deltaStr = '{0:+0.0;-0.0;0.0}' -f $d
        } else {
            $deltaStr = '—'
        }
        Write-Host ("{0,-4} {1,-30} {2,12} {3,8} {4,14} {5,10}" -f ($i + 1), $row.Name, $row.Raw, $row.Fee, $row.Eff, $deltaStr)
    }
    Write-Host ''
    $winner = $sorted[0]
    Write-Host ("{0}Best miner: {1} (effective {2} H/s, raw {3} H/s)" -f ([char]0x2713 + ' '), $winner.Name, $winner.Eff, $winner.Raw) -ForegroundColor Green

    # 🔁 Save results for next run
    if (-not (Test-Path $BinDir)) { New-Item -ItemType Directory -Path $BinDir -Force | Out-Null }
    $new = @{}
    foreach ($r in $rows) { $new[$r.Id] = $r.Eff }
    $new | ConvertTo-Json | Out-File -FilePath $benchCache -Encoding utf8
    Write-Host "[*] Saved benchmark cache: $benchCache" -ForegroundColor DarkGray
    exit 0
}
