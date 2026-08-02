function Start-Miner {
    param(
        [string]$BinaryPath,
        [string]$DaemonUrl,
        [string]$WalletAddress,
        [int]$ThreadCount,
        [hashtable]$FlagMap,
        [string[]]$ExtraArgs
    )
    $daemonAddr = $DaemonUrl -replace '^https?://', ''
    $argsList = @()
    if ($FlagMap.coin) { $argsList += $FlagMap.coin }
    if ($FlagMap.port) {
        $hostPart = $daemonAddr
        $portPart = ''
        if ($daemonAddr -match '^(.*):(\d+)$') { $hostPart = $Matches[1]; $portPart = $Matches[2] }
        $argsList += @($FlagMap.daemon, $hostPart, $FlagMap.port, $portPart)
    } else {
        $argsList += @($FlagMap.daemon, $daemonAddr)
    }
    $argsList += @($FlagMap.wallet, $WalletAddress)
    if ($FlagMap.threads) {
        $argsList += @($FlagMap.threads, [string]$ThreadCount)
    }
    if ($FlagMap.dev_fee -and $FlagMap.dev_fee_value) {
        $argsList += @($FlagMap.dev_fee, [string]$FlagMap.dev_fee_value)
    }
    if ($ExtraArgs) { $argsList += $ExtraArgs }
    & $BinaryPath @argsList
}

function Start-MinerAutoRestart {
    param(
        [string]$MinerId,
        [string]$BinaryPath,
        [string]$DaemonUrl,
        [string]$WalletAddress,
        [int]$ThreadCount,
        [hashtable]$FlagMap,
        [string[]]$ExtraArgs,
        [int]$MaxRestarts,
        [int]$RestartDelay,
        [string]$LogDir = ''
    )
    # Per-run log so restarts are diagnosable instead of a black box.
    $logFile = ''
    if ($LogDir) {
        try {
            if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
            $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
            $logFile = Join-Path $LogDir "$MinerId-$ts.log"
        } catch { $logFile = '' }
    }
    $restartCount = 0
    while ($restartCount -lt $MaxRestarts) {
        $stamp = Get-Date -Format 'HH:mm:ss'
        if ($logFile) {
            Add-Content $logFile "=== $stamp run $($restartCount + 1)/$MaxRestarts ($MinerId) ==="
        }
        try {
            $out = Start-Miner -BinaryPath $BinaryPath -DaemonUrl $DaemonUrl -WalletAddress $WalletAddress -ThreadCount $ThreadCount -FlagMap $FlagMap -ExtraArgs $ExtraArgs 2>&1
            if ($logFile -and $out) { $out | Out-File -FilePath $logFile -Append -Encoding utf8 }
        } catch {
            $errMsg = "Miner $MinerId crashed: $_"
            Write-Host "[!] $errMsg" -ForegroundColor Yellow
            if ($logFile) { Add-Content $logFile "ERROR: $errMsg" }
        }
        $restartCount++
        if ($restartCount -ge $MaxRestarts) {
            Write-Host "[!] Max restarts ($MaxRestarts) reached for $MinerId" -ForegroundColor Red
            if ($logFile) { Add-Content $logFile "Max restarts reached ($MaxRestarts)" }
            break
        }
        Write-Host "[*] Restarting $MinerId in ${RestartDelay}s (attempt $restartCount/$MaxRestarts)..." -ForegroundColor Cyan
        if ($logFile) { Add-Content $logFile "Restarting in ${RestartDelay}s (attempt $restartCount/$MaxRestarts)" }
        Start-Sleep -Seconds $RestartDelay
    }
    if ($logFile) { Write-Host "[*] Log: $logFile" -ForegroundColor DarkGray }
}