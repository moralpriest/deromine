function Get-SupportedMiners {
    param([object]$Catalog, [object]$Platform)
    $rows = @()
    if (-not $Catalog -or -not $Catalog.miners) { return $rows }
    foreach ($m in $Catalog.miners) {
        if (-not (Get-MinerAsset $m $Platform.os $Platform.arch)) { continue }
        if (-not (Test-MinerHardwareSupported $m)) { continue }
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
    param([object]$Miner, [string]$BinDir, [string]$PlatformOs, [string]$PlatformArch)
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
                    Copy-Item $found.FullName $binaryPath -Force
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
                Remove-Item $binaryPath -Force -ErrorAction SilentlyContinue
                Remove-Item "$binaryPath.tag" -Force -ErrorAction SilentlyContinue
                return $null
            }
            # Record the release tag so future runs can detect a stale cache.
            try { Set-Content -LiteralPath "$binaryPath.tag" -Value $resolved.Tag -NoNewline -ErrorAction SilentlyContinue } catch {}
            return $binaryPath
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
        [string]$Wallet
    )
    $id = [string]$Miner.id
    if ($Miner.PSObject.Properties['benchmark'] -and $Miner.benchmark -eq $false) {
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
        [string]$BinDir
    )
    # ── Benchmark history (compare against last run) ──
    $benchCache = Join-Path $BinDir '.benchmarks.json'
    $prev = @{}
    if (Test-Path $benchCache) {
        try { $prev = (Get-Content $benchCache -Raw | ConvertFrom-Json) -as [hashtable] } catch { $prev = @{} }
        if (-not $prev) { $prev = @{} }
    }
    $supported = @(Get-SupportedMiners -Catalog $Catalog -Platform $Platform)
    if ($supported.Count -eq 0) {
        Write-Host "[x] No miners available to benchmark on this host" -ForegroundColor Red
        exit 1
    }
    Write-Banner
    Write-Host "Benchmarking $($supported.Count) miners (~${BenchTime}s each, ${Threads} threads)..." -ForegroundColor DarkCyan

    $rows = @()
    foreach ($m in $supported) {
        $binaryPath = Get-MinerBinaryPath -Miner $m -BinDir $BinDir -PlatformOs $Platform.os -PlatformArch $Platform.arch
        if (-not $binaryPath) {
            Write-Host "  $($m.name): binary unavailable" -ForegroundColor Red
            Start-Sleep -Seconds 1
            continue
        }
        $row = Invoke-MinerBenchmark -Miner $m -BinaryPath $binaryPath -BenchTime $BenchTime -Threads $Threads -Daemon $Daemon -Wallet $Wallet
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
