# install.ps1 - one-line installer for deromine (Windows)
#
#   From PowerShell:
#     irm https://raw.githubusercontent.com/moralpriest/deromine/main/install.ps1 | iex
#
#   From cmd:
#     powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/moralpriest/deromine/main/install.ps1 | iex"
#
# Clones deromine into %USERPROFILE%\.local\share\deromine, copies the
# deromine.cmd launcher into %USERPROFILE%\.local\bin, and adds that folder
# to your user PATH so 'deromine' works from any new cmd/PowerShell window.
# Git is used when available; otherwise the source zip is downloaded, so
# git is not required. Idempotent: re-running pulls the latest version.
#
# Optional switches (normally unnecessary):
#   -RepoUrl <url>   Repo to install (also accepts a local path for testing)
#   -Branch <name>   Branch to install (default: main)
#   -InstallDir <p>  Install location (default: %USERPROFILE%\.local\share\deromine)
#   -BinDir <p>      Where deromine.cmd is placed (default: %USERPROFILE%\.local\bin)
#   -NoPathEdit      Do not modify the user PATH (for testing)
param(
    [string]$RepoUrl = 'https://github.com/moralpriest/deromine',
    [string]$Branch = 'main',
    [string]$InstallDir = (Join-Path $env:USERPROFILE '.local\share\deromine'),
    [string]$BinDir = (Join-Path $env:USERPROFILE '.local\bin'),
    [switch]$NoPathEdit
)

$ErrorActionPreference = 'Stop'
# Never let a non-zero native exit code (git) become a terminating error,
# even if the caller enabled PS 7.3+'s $PSNativeCommandUseErrorActionPreference.
# Harmless on Windows PowerShell 5.1.
$PSNativeCommandUseErrorActionPreference = $false

Write-Host ''
Write-Host '  deromine - Windows installer' -ForegroundColor White
Write-Host ''

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
New-Item -ItemType Directory -Path $BinDir -Force | Out-Null

# ---- Clone or update -------------------------------------------------
$installed = $false
if (Test-Path (Join-Path $InstallDir '.git')) {
    Write-Host '  [*] deromine already installed, updating...' -ForegroundColor Cyan
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        & $git.Source -C $InstallDir pull --ff-only origin $Branch
        if ($LASTEXITCODE -eq 0) { $installed = $true }
    }
} else {
    Write-Host "  [*] Installing deromine into $InstallDir ..." -ForegroundColor Cyan
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        & $git.Source clone --depth 1 --branch $Branch $RepoUrl $InstallDir
        if ($LASTEXITCODE -eq 0) { $installed = $true }
    }
}

if (-not $installed) {
    # Fallback: download the source zip from GitHub (no git needed).
    $ghPath = $RepoUrl
    if ($ghPath -match '^https://github.com/(.+?)(\.git)?$') { $ghPath = $matches[1] }
    if ($ghPath -notmatch '^[^/]+/[^/]+$') {
        Write-Host "  [x] Cannot install from '$RepoUrl' without git." -ForegroundColor Red
        exit 1
    }
    Write-Host '  [*] git not found or failed - downloading source zip...' -ForegroundColor Cyan
    $zipUrl = "https://codeload.github.com/$ghPath/zip/refs/heads/$Branch"
    $zipPath = Join-Path $env:TEMP "deromine-$Branch.zip"
    $extractDir = Join-Path $env:TEMP ('deromine-' + [guid]::NewGuid().ToString('N'))
    try {
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
        Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
        $top = Get-ChildItem $extractDir -Directory | Select-Object -First 1
        if ($top) {
            # Copy-Item -Recurse -Force merges into existing dirs; Move-Item
            # would nest (e.g. lib\lib) when re-installing over old files.
            Get-ChildItem $top.FullName -Force | Copy-Item -Destination $InstallDir -Recurse -Force
        } else {
            throw 'Source zip had no contents.'
        }
        $installed = $true
    } catch {
        Write-Host "  [x] Download failed: $_" -ForegroundColor Red
        exit 1
    } finally {
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---- Verify install --------------------------------------------------
if (-not (Test-Path (Join-Path $InstallDir 'mine.ps1'))) {
    Write-Host "  [x] Install incomplete: mine.ps1 not found in $InstallDir" -ForegroundColor Red
    exit 1
}

# ---- Launcher shim ---------------------------------------------------
$sourceLauncher = Join-Path $InstallDir 'deromine.cmd'
if (-not (Test-Path $sourceLauncher)) {
    Write-Host "  [x] Launcher not found at $sourceLauncher" -ForegroundColor Red
    exit 1
}
Copy-Item $sourceLauncher (Join-Path $BinDir 'deromine.cmd') -Force
Write-Host "  [*] Launcher copied to $BinDir\deromine.cmd" -ForegroundColor Cyan

# ---- PATH ------------------------------------------------------------
if (-not $NoPathEdit) {
    # Read/write the raw registry value (DoNotExpandEnvironmentNames +
    # ExpandString kind) so existing entries like %SystemRoot% keep their
    # variable references instead of being expanded to absolute paths.
    $regKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    if ($regKey) {
        $rawPath = [string]$regKey.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $onPath = $false
        $binKey = $BinDir.TrimEnd('\')
        foreach ($p in @($rawPath -split ';')) {
            if ($p.TrimEnd('\') -ieq $binKey) { $onPath = $true; break }
        }
        if (-not $onPath) {
            $newPath = if ($rawPath) { "$rawPath;$BinDir" } else { $BinDir }
            $regKey.SetValue('Path', $newPath, [Microsoft.Win32.RegistryValueKind]::ExpandString)
            Write-Host "  [*] Added $BinDir to your user PATH" -ForegroundColor Cyan
            # Make it available in this session immediately.
            $env:Path = "$BinDir;$env:Path"
        } else {
            Write-Host "  [*] $BinDir is already on your user PATH" -ForegroundColor Cyan
        }
        $regKey.Close()
    } else {
        Write-Host '  [x] Could not open the user Environment registry key to update PATH.' -ForegroundColor Red
        Write-Host "      Add $BinDir to your PATH manually." -ForegroundColor Gray
    }
}

# ---- Summary ---------------------------------------------------------
Write-Host ''
Write-Host '  Installed. Open a NEW cmd or PowerShell window, then:' -ForegroundColor White
Write-Host '    deromine                  # interactive menu' -ForegroundColor Gray
Write-Host '    deromine --miner=list     # show catalog' -ForegroundColor Gray
Write-Host ''
if (Get-Command pwsh -ErrorAction SilentlyContinue) {
    Write-Host '  PowerShell 7 found - full interactive UI enabled.' -ForegroundColor Gray
} else {
    Write-Host '  PowerShell 7 (pwsh) not found. Windows PowerShell 5.1 will' -ForegroundColor Gray
    Write-Host '  be used; install pwsh for the full interactive menu:' -ForegroundColor Gray
    Write-Host '    https://learn.microsoft.com/powershell/scripting/install/installing-powershell' -ForegroundColor DarkCyan
}
