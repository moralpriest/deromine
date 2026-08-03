function Get-PwshPlatform {
    $os = 'linux'
    $arch = 'amd64'

    # OS detection. $IsLinux/$IsMacOS/$IsWindows exist only in PowerShell 7+.
    # Windows PowerShell 5.1 has no PSVersionTable.Platform, so fall back to
    # $env:OS (Windows sets Windows_NT) and [Environment]::OSVersion.
    if ($IsLinux) { $os = 'linux' }
    elseif ($IsMacOS) { $os = 'macos' }
    elseif ($IsWindows) { $os = 'windows' }
    else {
        $p = $PSVersionTable.Platform
        if ($p -and $p -eq 'Win32NT') { $os = 'windows' }
        elseif ($p -and $p -eq 'Unix')  { $os = 'linux' }
        elseif ($p -and $p -eq 'Darwin') { $os = 'macos' }
        elseif ($env:OS -eq 'Windows_NT') { $os = 'windows' }
        else {
            $dotNet = [System.Environment]::OSVersion.Platform
            if ($dotNet -eq [System.PlatformID]::Win32NT) { $os = 'windows' }
            elseif ($dotNet -eq [System.PlatformID]::MacOSX) { $os = 'macos' }
            elseif ($dotNet -eq [System.PlatformID]::Unix) { $os = 'linux' }
        }
    }

    # Arch detection. On Windows, PROCESSOR_ARCHITECTURE (or
    # PROCESSOR_ARCHITEW6432 for 32-bit PowerShell on 64-bit Windows) reports
    # the architecture directly - no external commands needed. On macOS/Linux
    # we ask the kernel: Apple Silicon 'uname -m' reports arm64; Intel Macs
    # report x86_64; ARM Linux reports aarch64/armv7l.
    $procArch = $env:PROCESSOR_ARCHITECTURE
    if ($procArch -eq 'x86' -and $env:PROCESSOR_ARCHITEW6432) { $procArch = $env:PROCESSOR_ARCHITEW6432 }
    if (-not $procArch) { $procArch = $env:PROCESSOR_ARCHITEW6432 }
    if ($procArch -match 'ARM64|arm64|aarch64') { $arch = 'aarch64' }
    elseif ($procArch -match 'AMD64|amd64|x86_64|x64') { $arch = 'amd64' }
    elseif ($procArch -match 'ARM|arm') { $arch = 'arm' }
    elseif ($os -ne 'windows' -and (Get-Command uname -ErrorAction SilentlyContinue)) {
        # No PROCESSOR_ARCHITECTURE (Linux/macOS) - ask the kernel. Guarded by
        # Get-Command so a missing uname (e.g. bare Windows PowerShell) can
        # never crash the launcher.
        $unameArch = (& uname -m 2>$null) -as [string]
        if ($unameArch -match 'aarch64|arm64') { $arch = 'aarch64' }
        elseif ($unameArch -match '^armv7') { $arch = 'arm' }
        elseif ($unameArch -match '^armv8') { $arch = 'aarch64' }
    }
    return [PSCustomObject]@{ os = $os; arch = $arch }
}

function Test-CommandAvailable {
    param([string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-HasNvidiaGpu {
    try {
        $null = & nvidia-smi -L 2>$null
        if ($LASTEXITCODE -eq 0) { return $true }
    } catch {}
    # nvidia-smi may be missing even with a driver installed (unusual). Fall
    # back to enumerating the actual adapters so NVIDIA miners (cuda, astronv)
    # are shown only when an NVIDIA GPU is really present on this host.
    try {
        $adapters = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue
        foreach ($a in $adapters) {
            if ([string]$a.Name -match 'NVIDIA|GeForce|Quadro|RTX|Tesla|NVS') { return $true }
        }
    } catch {}
    return $false
}

# A Vulkan-capable GPU driver is present if any ICD JSON is registered under
# the Khronos Vulkan runtime key. Vulkan does NOT require an NVIDIA card -
# Intel/AMD integrated GPUs with a working Vulkan driver qualify - but a
# machine with no registered ICD (older iGPU drivers, WARP-only renderers,
# VMs) cannot run Vulkan miners like go-gpu and must not be listed.
function Test-WindowsVulkanDriver {
    param([string]$RegKey = 'HKLM:\SOFTWARE\Khronos\Vulkan\Drivers')
    try {
        $drv = Get-ItemProperty -Path $RegKey -ErrorAction SilentlyContinue
        if ($drv) {
            foreach ($prop in $drv.PSObject.Properties) {
                if ($prop.Name -like '*.json') { return $true }
            }
        }
    } catch {}
    return $false
}

function Test-HasVulkanGpu {
    $platform = Get-PwshPlatform
    switch ($platform.os) {
        'linux' {
            try {
                $null = & vulkaninfo --summary 2>$null
                if ($LASTEXITCODE -eq 0) { return $true }
            } catch {}
            if (Test-Path '/dev/dri') {
                return (Get-ChildItem '/dev/dri' -Filter 'card*' -ErrorAction SilentlyContinue).Count -gt 0
            }
            return $false
        }
        'macos'   { return $true }
        'windows' {
            if (Get-Command vulkaninfo -ErrorAction SilentlyContinue) {
                try {
                    $null = & vulkaninfo --summary 2>$null
                    if ($LASTEXITCODE -eq 0) { return $true }
                } catch {}
            }
            return (Test-WindowsVulkanDriver)
        }
        default   { return $false }
    }
}

function Test-IsTermux {
    # Termux (Android) is detected the same way as in install.sh/install.ps1:
    # $PREFIX is set by Termux and $PREFIX/bin is its always-on-PATH dir.
    # Requiring 'com.termux' in the path avoids false positives when an
    # unrelated PREFIX (e.g. Autotools) is exported on desktop Linux.
    return [bool]($env:PREFIX -and ($env:PREFIX -match 'com\.termux') -and (Test-Path (Join-Path $env:PREFIX 'bin')))
}

function Test-MinerHardwareSupported {
    param([object]$Miner)
    # Platform exclusions from the catalog (e.g. glibc-only miners on
    # Termux/Android: derohe's arm64 release fails its ELF self-check).
    # NOTE: keep this in separate statements - an inline chain like
    # 'Test-IsTermux -and $Miner.PSObject.Properties["x"] -and (...)'
    # mis-parses in PowerShell (evaluates truthy) and would hide miners.
    $excludedOnTermux = $false
    if (Test-IsTermux) {
        $excludedOnTermux = @($Miner.unsupported) -contains 'termux'
    }
    if ($excludedOnTermux) { return $false }
    if (-not $Miner.PSObject.Properties['requires']) { return $true }
    foreach ($req in $Miner.requires) {
        switch ($req) {
            'nvidia-gpu' { if (-not (Test-HasNvidiaGpu)) { return $false } }
            'vulkan-gpu' { if (-not (Test-HasVulkanGpu)) { return $false } }
            default {
                Write-Host "[!] Unknown hardware requirement: $req" -ForegroundColor DarkYellow
            }
        }
    }
    return $true
}

function Test-IsUnicodeTerminal {
    try {
        $codePage = [Console]::OutputEncoding.CodePage
        if ($codePage -eq 65001) { return $true }
        if ($OutputEncoding.EncodingName -match 'UTF') { return $true }
        return $false
    } catch { return $false }
}

function Get-TerminalWidth {
    try {
        $w = [Console]::WindowWidth
        if ($w -and $w -ge 80) { return $w }
    } catch {}
    return 80
}

function Test-TlsEndpoint {
    param([string]$Address, [int]$Port, [int]$TimeoutMs = 800)
    $curlCmd = $null
    if (Get-Command curl.exe -ErrorAction SilentlyContinue)      { $curlCmd = 'curl.exe' }
    elseif (Get-Command curl -ErrorAction SilentlyContinue -CommandType Application) { $curlCmd = 'curl' }
    if ($curlCmd) {
        & $curlCmd -sk --connect-timeout 0.5 --max-time 1.2 "https://${Address}:${Port}/" 2>$null | Out-Null
        return $LASTEXITCODE -eq 0
    }
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $connect = $tcp.BeginConnect($Address, $Port, $null, $null)
        if (-not $connect.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $tcp.EndConnect($connect)
        $stream = $tcp.GetStream()
        $callback = [System.Net.Security.RemoteCertificateValidationCallback]{ param($s, $c, $ch, $e) $true }
        $ssl = New-Object System.Net.Security.SslStream($stream, $false, $callback)
        $auth = $ssl.BeginAuthenticateAsClient($Address)
        if (-not $auth.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $ssl.EndAuthenticateAsClient($auth)
        return $ssl.IsAuthenticated
    } catch { return $false }
    finally { if ($tcp) { $tcp.Close() } }
}

# Only TLS GETWORK mining ports can serve dirtybird miners.
function Test-IsMiningUrl {
    param([string]$Url)
    $port = ($Url -split ':')[-1] -replace '[/\s].*', ''
    return $port -in @('10100', '40400')
}

function Test-LocalDaemonUrl {
    param([int]$TimeoutMs = 800)
    # Miners can ONLY connect via TLS to the GETWORK mining port
    # (mainnet 10100, testnet 40400). Plain-HTTP RPC ports (10102/40402/
    # 19999) are never valid miner endpoints, so they are not probed.
    foreach ($port in @(10100, 40400)) {
        if (Test-TlsEndpoint -Address '127.0.0.1' -Port $port -TimeoutMs $TimeoutMs) {
            return "http://127.0.0.1:$port"
        }
    }
    return $null
}