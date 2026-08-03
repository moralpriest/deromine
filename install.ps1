# install.ps1 - unified one-line installer for deromine (all OSes)
#
#   Windows (built-in PowerShell 5.1 or 7):
#     irm https://raw.githubusercontent.com/moralpriest/deromine/main/install.ps1 | iex
#
#   Linux / macOS / Termux (PowerShell 7 required):
#     pwsh -c "irm https://raw.githubusercontent.com/moralpriest/deromine/main/install.ps1 | iex"
#
# One script installs everywhere: it clones deromine into ~/.local/share/deromine
# (Windows: %USERPROFILE%\.local\share\deromine), places the launcher in
# ~/.local/bin (deromine on Unix, deromine.cmd on Windows), and puts it on PATH
# (user registry on Windows, shell rc for bash/zsh/fish on Unix, and $PREFIX/bin
# on Termux - the one directory always on PATH there). Git is used when
# available; otherwise the source zip is downloaded, so git is not required.
# Idempotent: re-running pulls the latest version.
#
# Optional switches (normally unnecessary):
#   -RepoUrl <url>   Repo to install (also accepts a local path for testing)
#   -Branch <name>   Branch to install (default: main)
#   -InstallDir <p>  Install location (default: ~/.local/share/deromine)
#   -BinDir <p>      Where the launcher is placed (default: ~/.local/bin)
#   -NoPathEdit      Do not modify PATH (for testing)
param(
    [string]$RepoUrl = 'https://github.com/moralpriest/deromine',
    [string]$Branch = 'main',
    [string]$InstallDir = '',
    [string]$BinDir = '',
    [switch]$NoPathEdit
)

$ErrorActionPreference = 'Stop'
# Never let a non-zero native exit code (git) become a terminating error,
# even if the caller enabled PS 7.3+'s $PSNativeCommandUseErrorActionPreference.
# Harmless on Windows PowerShell 5.1.
$PSNativeCommandUseErrorActionPreference = $false

# $IsWindows exists on PowerShell 7; Windows PowerShell 5.1 is Windows-only and
# leaves it undefined, so fall back to the OS env var there.
$IsWin = if ($IsWindows) { $true } elseif ($env:OS -eq 'Windows_NT') { $true } else { $false }

function Test-IsOnPath {
    param([string]$Dir)
    $sep = if ($IsWin) { ';' } else { ':' }
    $needle = $Dir.TrimEnd('\', '/')
    foreach ($p in ($env:PATH -split [regex]::Escape($sep))) {
        if ($p.TrimEnd('\', '/') -ieq $needle) { return $true }
    }
    return $false
}

if (-not $InstallDir) {
    if ($IsWin) {
        $InstallDir = Join-Path $env:USERPROFILE '.local\share\deromine'
    } else {
        $dataHome = if ($env:XDG_DATA_HOME) { $env:XDG_DATA_HOME } else { Join-Path $HOME '.local/share' }
        $InstallDir = Join-Path $dataHome 'deromine'
    }
}
if (-not $BinDir) {
    $BinDir = if ($IsWin) { Join-Path $env:USERPROFILE '.local\bin' } else { Join-Path $HOME '.local/bin' }
}

$isTermux = -not $IsWin -and $env:PREFIX -and (Test-Path (Join-Path $env:PREFIX 'bin'))

Write-Host ''
Write-Host '  deromine - installer' -ForegroundColor White
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
    $zipPath = Join-Path ([System.IO.Path]::GetTempPath()) "deromine-$Branch.zip"
    $extractDir = Join-Path ([System.IO.Path]::GetTempPath()) ('deromine-' + [guid]::NewGuid().ToString('N'))
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
if ($IsWin) {
    $sourceLauncher = Join-Path $InstallDir 'deromine.cmd'
} else {
    $sourceLauncher = Join-Path $InstallDir 'deromine'
}
$destLauncher = Join-Path $BinDir (Split-Path $sourceLauncher -Leaf)
if (-not (Test-Path $sourceLauncher)) {
    Write-Host "  [x] Launcher not found at $sourceLauncher" -ForegroundColor Red
    exit 1
}
if ($IsWin) {
    Copy-Item $sourceLauncher $destLauncher -Force
    Write-Host "  [*] Launcher copied to $destLauncher" -ForegroundColor Cyan
} else {
    # Prefer a symlink (like install.sh); fall back to a plain copy on
    # filesystems that don't support symlinks.
    Remove-Item $destLauncher -Force -ErrorAction SilentlyContinue
    try {
        New-Item -ItemType SymbolicLink -Path $destLauncher -Target $sourceLauncher -ErrorAction Stop | Out-Null
        Write-Host "  [*] Launcher linked to $destLauncher" -ForegroundColor Cyan
    } catch {
        Copy-Item $sourceLauncher $destLauncher -Force
        Write-Host "  [*] Launcher copied to $destLauncher (symlink not supported)" -ForegroundColor Cyan
    }
}

# ---- PATH ------------------------------------------------------------
if (-not $NoPathEdit) {
    if ($IsWin) {
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
    } elseif ($isTermux) {
        # $PREFIX/bin is the only dir always on PATH in Termux, and it's
        # user-writable - drop a launcher there so it works in ANY shell.
        $prefixLauncher = Join-Path $env:PREFIX 'bin/deromine'
        Remove-Item $prefixLauncher -Force -ErrorAction SilentlyContinue
        try {
            New-Item -ItemType SymbolicLink -Path $prefixLauncher -Target $sourceLauncher -ErrorAction Stop | Out-Null
        } catch {
            Copy-Item $sourceLauncher $prefixLauncher -Force
        }
        Write-Host "  [*] Linked deromine into $(Join-Path $env:PREFIX 'bin') - on PATH in every Termux shell" -ForegroundColor Cyan
    } elseif (-not (Test-IsOnPath $BinDir)) {
        # Non-Termux Unix: persist $BinDir on PATH for the user's shell.
        $shellName = if ($env:SHELL) { Split-Path $env:SHELL -Leaf } else { '' }
        $rc = $null
        switch ($shellName) {
            'fish' { $cfgHome = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }; $rc = Join-Path $cfgHome 'fish/config.fish' }
            'zsh'  { $rc = Join-Path $HOME '.zshrc'; if (-not (Test-Path $rc)) { $rc = Join-Path $HOME '.zshenv' } }
            'bash' { $rc = Join-Path $HOME '.bashrc'; if ($IsMacOS) { $rc = Join-Path $HOME '.bash_profile' } }
        }
        $marked = $rc -and (Test-Path $rc) -and [bool](Select-String -Path $rc -Pattern '# deromine' -Quiet -ErrorAction SilentlyContinue)
        if ($rc -and -not $marked) {
            New-Item -ItemType Directory -Path (Split-Path $rc) -Force | Out-Null
            if ($shellName -eq 'fish') {
                Add-Content -Path $rc -Value "`n# deromine`nfish_add_path `"$BinDir`""
            } else {
                Add-Content -Path $rc -Value "`n# deromine`nexport PATH=`"$BinDir`:`$PATH`""
            }
            Write-Host "  [*] Added $BinDir to your PATH in $rc" -ForegroundColor Cyan
        } elseif ($rc -and $marked) {
            Write-Host "  [*] $BinDir already added to your PATH in $rc" -ForegroundColor Cyan
        } else {
            Write-Host "  [*] Could not detect a shell config - add $BinDir to your PATH manually:" -ForegroundColor Gray
            Write-Host "        export PATH=`"$BinDir`:`$PATH`"" -ForegroundColor Gray
        }
    } else {
        Write-Host "  [*] $BinDir is already on your PATH" -ForegroundColor Cyan
    }
}

# ---- Summary ---------------------------------------------------------
$hasPwsh = [bool](Get-Command pwsh -ErrorAction SilentlyContinue)
Write-Host ''
Write-Host '  Installed. Open a NEW terminal window, then:' -ForegroundColor White
Write-Host '    deromine                  # interactive menu' -ForegroundColor Gray
Write-Host '    deromine --miner=list     # show catalog' -ForegroundColor Gray
Write-Host ''
if ($hasPwsh) {
    Write-Host '  PowerShell 7 found - full interactive UI enabled.' -ForegroundColor Gray
} else {
    Write-Host '  PowerShell 7 (pwsh) not found.' -ForegroundColor Gray
    if ($IsWin) {
        Write-Host '  Windows PowerShell 5.1 will be used; install pwsh for the full' -ForegroundColor Gray
        Write-Host '  interactive menu:' -ForegroundColor Gray
    } else {
        Write-Host '  The bash fallback still works, but for the full interactive' -ForegroundColor Gray
        Write-Host '  menu install PowerShell 7 first:' -ForegroundColor Gray
    }
    Write-Host '    https://learn.microsoft.com/powershell/scripting/install/installing-powershell' -ForegroundColor DarkCyan
}
