function Test-ConfigSchema {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $true }
    try {
        $json = Get-Content $Path -Raw -Encoding UTF8
        $cfg = ConvertFrom-Json $json
        if ($null -eq $cfg -or $cfg -isnot [PSCustomObject]) { throw 'root must be a JSON object' }
        foreach ($name in @('wallet_address', 'daemon_url')) {
            $prop = $cfg.PSObject.Properties[$name]
            if ($prop -and $null -ne $prop.Value -and $prop.Value -isnot [string]) {
                throw "$name must be a string"
            }
        }
        $threads = $cfg.PSObject.Properties['thread_count']
        if ($threads) {
            $value = 0
            if (-not [int]::TryParse([string]$threads.Value, [ref]$value) -or $value -lt 0 -or $value -gt 256 -or [double]$threads.Value -ne $value) {
                throw 'thread_count must be an integer from 0 to 256'
            }
        }
        $fee = $cfg.PSObject.Properties['dev_fee']
        if ($fee -and $null -ne $fee.Value -and $fee.Value -isnot [string] -and $fee.Value -isnot [int] -and $fee.Value -isnot [double]) {
            throw 'dev_fee must be a string or number'
        }
        return $true
    } catch {
        Write-Host "[x] Invalid config '$Path': $($_.Exception.Message)" -ForegroundColor Red
        Write-Host '    Expected wallet_address/daemon_url strings and thread_count as an integer from 0 to 256.' -ForegroundColor DarkYellow
        return $false
    }
}

function Read-Config {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try {
        $json = Get-Content $Path -Raw -Encoding UTF8
        $cfg = ConvertFrom-Json $json
        return $cfg
    } catch {
        Write-Host "[x] Failed to parse config '$Path': $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
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

# Default DERO daemon / stratum port applied when the user types a custom
# node without one (e.g. "my.node" -> "my.node:10100").
$DefaultDaemonPort = '10100'

# Accepts a custom node the user typed at the daemon prompt: optional
# http(s):// scheme, hostname / IPv4 / bracketed IPv6, an optional port
# (defaults to $DefaultDaemonPort), and an optional path. Returns the
# normalized URL, or $null when the input is not a usable node.
function Normalize-DaemonUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $null }
    $m = [regex]::Match($Url.Trim(), '^(https?://)?(\[[0-9a-fA-F:]+\]|[A-Za-z0-9._-]+)(:[0-9]+)?(/.*)?$')
    if (-not $m.Success) { return $null }
    $port = $m.Groups[3].Value
    if (-not $port) { $port = ":$DefaultDaemonPort" }
    return $m.Groups[1].Value + $m.Groups[2].Value + $port + $m.Groups[4].Value
}

function Test-DaemonUrl {
    param([string]$Url)
    return [bool](Normalize-DaemonUrl $Url)
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