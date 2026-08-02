function Read-Config {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try {
        $json = Get-Content $Path -Raw -Encoding UTF8
        $cfg = ConvertFrom-Json $json
        return $cfg
    } catch { return $null }
}

function Write-Config {
    param([string]$Path, [object]$Config)
    if ($Config -is [hashtable]) {
        $json = $Config | ConvertTo-Json -Depth 4
    } elseif ($Config -is [PSCustomObject]) {
        $json = $Config | ConvertTo-Json -Depth 4
    } else {
        Write-Host "[x] Unknown config type: $($Config.GetType())" -ForegroundColor Red
        return
    }
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
}

function Test-WalletAddress {
    param([string]$Address)
    return $Address -match '^[13d][a-zA-Z0-9]{50,120}$'
}

function Read-WalletAddress {
    param([string]$Default = '')
    Write-Host ''
    while ($true) {
        if ($Default) {
            $prompt = "Your DERO wallet address (default: $Default, leave empty to use it)"
        } else {
            $prompt = 'Your DERO wallet address (dero1... or deto1... leave empty to cancel)'
        }
        $addr = Read-Host $prompt
        if (-not $addr -and $Default) { return $Default }
        if (-not $addr) {
            Write-Host '[x] No address entered, exiting' -ForegroundColor Red
            return $null
        }
        if (Test-WalletAddress $addr) { return $addr }
        Write-Host '[x] Invalid DERO address. Must start with dero1 or deto1 (50-120 chars).' -ForegroundColor Red
        Write-Host '    Example: dero1qy8qmf45w3hccaev2fqz3jpxt3k5xz3w5f3u9qetnd5c6y5zqt5zhqzwx8cvd' -ForegroundColor DarkYellow
    }
}

function Read-ThreadCount {
    Write-Host ''
    $cpuCount = [Environment]::ProcessorCount
    if (-not $cpuCount -or $cpuCount -lt 2) { $cpuCount = 2 }
    $defaultCount = $cpuCount - 1
    while ($true) {
        $raw = Read-Host "Thread count (default: $defaultCount, leave empty for default)"
        if (-not $raw) { return $defaultCount }
        $n = 0
        if ([int]::TryParse($raw, [ref]$n) -and $n -gt 0 -and $n -le 256) { return $n }
        Write-Host '[x] Enter a number between 1 and 256' -ForegroundColor Red
    }
}

function Save-ConfigValue {
    param([string]$Path, [string]$Key, [object]$Value)
    $cfg = Read-Config $Path
    if (-not $cfg) { $cfg = [PSCustomObject]@{} }
    $cfg | Add-Member -NotePropertyName $Key -NotePropertyValue $Value -Force
    Write-Config $Path $cfg
}