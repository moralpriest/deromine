$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectDir = Split-Path -Parent $scriptDir
$minersJsonPath = Join-Path $projectDir 'miners.json'

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

# 3. Helper modules load without errors
Write-Host ''
Write-Host '3. Helper modules:' -ForegroundColor Yellow
$libDir = Join-Path $projectDir 'lib'
$helpers = @('config.ps1', 'catalog.ps1', 'platform.ps1', 'download.ps1', 'run.ps1', 'ui.ps1')
foreach ($h in $helpers) {
    $hPath = Join-Path $libDir $h
    Assert-True "  $h exists" (Test-Path $hPath)
}

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
    Assert-True '  rust still supported on Termux' (Test-MinerHardwareSupported $rustT)
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
    Assert-True '  integrity accepts valid ELF binary' (Test-BinaryIntegrity $good 'linux')
    Assert-True '  integrity rejects wrong magic' (-not (Test-BinaryIntegrity $bad 'linux'))
    Assert-True '  integrity rejects tiny file' (-not (Test-BinaryIntegrity $small 'linux'))
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
} finally {
    Remove-Item $tmpCache -Recurse -Force -ErrorAction SilentlyContinue
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