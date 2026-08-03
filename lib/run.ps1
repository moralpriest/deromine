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
    if ([string]::IsNullOrEmpty($WalletAddress)) {
        # Terminating error so Start-MinerAutoRestart's catch logs it as a
        # crash instead of silently writing a stray '1' and restarting.
        throw 'No wallet address to pass to the miner.'
    }
    Write-Host "[*] Command: $BinaryPath $($argsList -join ' ')" -ForegroundColor DarkGray
    & $BinaryPath @argsList
    # A miner that fails to start used to return to the prompt with zero
    # feedback (missing DLLs, corrupt binary, wrong flags). Always report how
    # the launch ended so a silent instant exit is never a black box. Ctrl+C
    # (130 / 0xC000013A = STATUS_CONTROL_C_EXIT; PowerShell reports the signed
    # form -1073741510 on Windows) is a normal stop, not a crash.
    if ($LASTEXITCODE -in @(130, 3221225786, -1073741510)) {
        Write-Host "[*] Miner stopped (interrupted)" -ForegroundColor DarkGray
    } elseif ($LASTEXITCODE -ne 0) {
        $code = $LASTEXITCODE
        Write-Host "[!] Miner exited with code $code" -ForegroundColor Yellow
        if ($code -eq -1073741515) {  # 0xC0000135 = STATUS_DLL_NOT_FOUND
            Write-Host "  A required DLL is missing next to the miner (stale cache from an older deromine)." -ForegroundColor DarkYellow
            Write-Host "  Fix: Remove-Item '$(Split-Path -Parent $BinaryPath)' -Recurse -Force, then run deromine again (it re-downloads the DLLs)." -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "[*] Miner stopped (exit code 0)" -ForegroundColor DarkGray
    }
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