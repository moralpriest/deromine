function Get-GitlabRepoId {
    param([string]$Repo)
    return ($Repo -replace '/', '%2F')
}

function Get-GitlabLatestRelease {
    param([string]$Repo)
    $url = "https://gitlab.com/api/v4/projects/$(Get-GitlabRepoId $Repo)/releases/permalink/latest"
    try {
        $resp = Invoke-RestMethod -Uri $url -Headers @{ 'Accept' = 'application/json' } -TimeoutSec 30
        $links = @()
        if ($resp.assets -and $resp.assets.links) {
            foreach ($l in $resp.assets.links) {
                $links += [PSCustomObject]@{
                    name                = [string]$l.name
                    browser_download_url = [string]$l.direct_asset_url
                    size                = [long]0
                }
            }
        }
        return [PSCustomObject]@{
            Tag    = [string]$resp.tag_name
            Assets = $links
        }
    } catch {
        Write-Host "[x] GitLab API failed for $Repo : $_" -ForegroundColor Red
        return $null
    }
}

function Get-GitlabBranchRelease {
    param([string]$Repo, [string]$Branch, [string]$ReleasePath)
    $id = Get-GitlabRepoId $Repo
    $base = "https://gitlab.com/api/v4/projects/$id/repository/tree"
    try {
        $tree = Invoke-RestMethod -Uri "$base`?path=$ReleasePath&ref=$Branch&per_page=100" -TimeoutSec 30
        $dirs = @($tree | Where-Object { $_.type -eq 'tree' -and $_.name -match '^v?\d+(\.\d+)+$' })
        if ($dirs.Count -eq 0) {
            Write-Host "[x] No version dirs under $ReleasePath in $Repo" -ForegroundColor Red
            return $null
        }
        $version = $dirs |
            ForEach-Object { $_.name } |
            Sort-Object -Descending { [version](($_ -replace '^v', '') -split '-')[0] } |
            Select-Object -First 1
        $files = Invoke-RestMethod -Uri "$base`?path=$ReleasePath/$version&ref=$Branch&per_page=100" -TimeoutSec 30
        $assets = @()
        foreach ($f in $files) {
            if ($f.type -eq 'blob') {
                $assets += [PSCustomObject]@{
                    name                 = [string]$f.name
                    browser_download_url = "https://gitlab.com/$Repo/-/raw/$Branch/$($f.path)"
                    size                 = [long]0
                }
            }
        }
        return [PSCustomObject]@{
            Tag    = $version
            Assets = $assets
        }
    } catch {
        Write-Host "[x] GitLab branch API failed for $Repo : $_" -ForegroundColor Red
        return $null
    }
}

function Get-GithubLatestRelease {
    param([string]$Repo)
    $url = "https://api.github.com/repos/$Repo/releases/latest"
    try {
        $resp = Invoke-WebRequest -Uri $url -Headers @{ 'Accept' = 'application/vnd.github.v3+json' } -UseBasicParsing -TimeoutSec 30
        $json = $resp.Content | ConvertFrom-Json
        return [PSCustomObject]@{
            Tag       = [string]$json.tag_name
            Assets    = $json.assets
            Url       = [string]$json.html_url
        }
    } catch {
        Write-Host "[x] GitHub API failed for $Repo : $_" -ForegroundColor Red
        return $null
    }
}

function Get-ReleaseAssetByPattern {
    param([array]$Assets, [string]$Pattern)
    $re = '^' + [System.Text.RegularExpressions.Regex]::Escape($Pattern).Replace('\*', '.*').Replace('\?', '.') + '$'
    foreach ($a in $Assets) {
        $name = [string]$a.name
        if ($name -match $re) {
            return [PSCustomObject]@{
                Name = $name
                Url  = [string]$a.browser_download_url
                Size = [long]$a.size
            }
        }
    }
    return $null
}

function Resolve-DownloadAsset {
    param([string]$Repo, [string]$RepoHost, [string]$Branch, [string]$ReleasePath, [string]$Os, [string]$Arch, [string]$Pattern)
    switch ($RepoHost) {
        'gitlab-release' { $release = Get-GitlabLatestRelease -Repo $Repo }
        'gitlab-branch'  { $release = Get-GitlabBranchRelease -Repo $Repo -Branch $Branch -ReleasePath $ReleasePath }
        default          { $release = Get-GithubLatestRelease -Repo $Repo }
    }
    if (-not $release) { return $null }
    $asset = Get-ReleaseAssetByPattern -Assets $release.Assets -Pattern $Pattern
    if ($asset) {
        Write-Host "  Tag:   $($release.Tag)" -ForegroundColor DarkCyan
        Write-Host "  Asset: $($asset.Name)" -ForegroundColor DarkCyan
        return [PSCustomObject]@{
            Tag  = $release.Tag
            Name = $asset.Name
            Url  = $asset.Url
            Size = $asset.Size
        }
    }
    $patternList = ($release.Assets | ForEach-Object { "  $_" }) -join "`n"
    Write-Host "[x] No asset matched pattern '$Pattern' for $Repo" -ForegroundColor Red
    Write-Host "  Available assets:" -ForegroundColor DarkYellow
    $release.Assets | ForEach-Object { Write-Host "  $($_.name)" -ForegroundColor DarkYellow }
    return $null
}

function Save-WebFile {
    param([string]$Url, [string]$OutPath)
    try {
        $dir = Split-Path -Parent $OutPath
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Invoke-WebRequest -Uri $Url -OutFile $OutPath -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
        return $true
    } catch {
        Write-Host "[x] Download failed: $_" -ForegroundColor Red
        return $false
    }
}

function Invoke-Extract {
    param([string]$ArchivePath, [string]$OutDir)
    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    if ($ArchivePath -match '\.zip$') {
        Expand-Archive -Path $ArchivePath -DestinationPath $OutDir -Force -ErrorAction Stop
    } elseif ($ArchivePath -match '\.tar\.gz$|\.tgz$') {
        if (Get-Command tar -ErrorAction SilentlyContinue) {
            tar -xzf $ArchivePath -C $OutDir 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "[x] tar extraction failed with code $LASTEXITCODE" -ForegroundColor Red
                throw "tar failed"
            }
        } else {
            Write-Host "[x] tar not found. Manual extraction required." -ForegroundColor Red
            throw "tar not found"
        }
    } elseif ($ArchivePath -match '\.tar$') {
        if (Get-Command tar -ErrorAction SilentlyContinue) {
            tar -xf $ArchivePath -C $OutDir 2>&1 | Out-Null
        } else {
            Write-Host "[x] tar not found" -ForegroundColor Red
            throw "tar not found"
        }
    } else {
        Write-Host "[x] Unknown archive type: $ArchivePath" -ForegroundColor Red
        throw "unknown archive type"
    }
}

# Move a nested extraction dir's contents up to the miner cache dir so the
# canonical binary keeps its dependencies (Windows releases ship DLLs next to
# the exe, e.g. libstdc++-6.dll — a lone exe cannot start without them). The
# exe is renamed to the canonical cache name; the nested dir is removed.
function Move-LiftedFiles {
    param(
        [string]$SourceDir,
        [string]$DestDir,
        [string]$ArchiveBinary,
        [string]$CanonicalBinary
    )
    foreach ($file in (Get-ChildItem -Path $SourceDir -File -ErrorAction SilentlyContinue)) {
        $dest = Join-Path $DestDir $file.Name
        if ($file.Name -eq $ArchiveBinary) { $dest = Join-Path $DestDir $CanonicalBinary }
        Copy-Item $file.FullName $dest -Force
    }
    Remove-Item $SourceDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ── Launch-failure memory + proven-on-host ──
# A miner that can't run on this host (missing DLLs, broken GPU driver, broken
# arm64 build) used to be listed forever and fail on every attempt. deromine
# now remembers per-miner launch outcomes in `bin/<id>/`:
#   .fails — fast nonzero exits (within 10s), ONE confirmed failure hides it.
#   .ok    — a launch that PROVED the miner can run here (exit 0, or it ran
#            long enough to get past startup, or the user stopped it with
#            Ctrl+C). Miners marked `startup_gate` in the catalog (e.g. go-gpu
#            with its self-test that refuses broken GPUs) are only LISTED once
#            .ok exists — a registered-but-broken driver can pass every static
#            probe yet still refuse to mine, so the only reliable proof is a
#            real successful launch on this host.
# `--miner=<id>` still force-runs a hidden miner.

# Thresholds: an exit within 10s is a startup failure (a working miner runs
# for hours); ONE confirmed failure hides the miner.
$script:FastFailSecs  = 10
$script:FailsToHide    = 1

function Get-MinerFailsPath {
    param([string]$BinDir, [string]$MinerId)
    return (Join-Path (Join-Path $BinDir $MinerId) '.fails')
}

function Get-MinerOkPath {
    param([string]$BinDir, [string]$MinerId)
    return (Join-Path (Join-Path $BinDir $MinerId) '.ok')
}

# Record the outcome of a miner launch. Successful runs, slow exits, and
# Ctrl+C clear the failure memory AND write the .ok proven marker; fast
# nonzero exits increment the failure counter and clear .ok.
function Mark-MinerLaunchOutcome {
    param([string]$BinDir, [string]$MinerId, [int]$ExitCode, [int]$ElapsedSec)
    $minerDir = Join-Path $BinDir $MinerId
    if (-not (Test-Path $minerDir)) { return }
    $failsPath = Get-MinerFailsPath $BinDir $MinerId
    $okPath = Get-MinerOkPath $BinDir $MinerId
    # Ctrl+C surfaces as 130 or the NTSTATUS 0xC000013A (3221225786 unsigned /
    # -1073741510 signed, which is what PowerShell reports on Windows).
    if ($ExitCode -eq 0 -or $ElapsedSec -ge $script:FastFailSecs -or $ExitCode -in @(130, 3221225786, -1073741510)) {
        Remove-Item $failsPath -Force -ErrorAction SilentlyContinue
        try { Set-Content -LiteralPath $okPath -Value '1' -NoNewline -ErrorAction Stop } catch {}
        return
    }
    Remove-Item $okPath -Force -ErrorAction SilentlyContinue
    $count = 0
    if (Test-Path $failsPath) {
        $count = [int]((Get-Content -LiteralPath $failsPath -Raw -ErrorAction SilentlyContinue) -as [int])
    }
    $count++
    if ($count -gt 9) { $count = 9 }
    try { Set-Content -LiteralPath $failsPath -Value "$count" -NoNewline -ErrorAction Stop } catch {}
}

function Test-MinerFailsOnHost {
    param([string]$BinDir, [string]$MinerId)
    $failsPath = Get-MinerFailsPath $BinDir $MinerId
    if (-not (Test-Path $failsPath)) { return $false }
    $count = [int]((Get-Content -LiteralPath $failsPath -Raw -ErrorAction SilentlyContinue) -as [int])
    return $count -ge $script:FailsToHide
}

function Test-MinerProvenOnHost {
    param([string]$BinDir, [string]$MinerId)
    return (Test-Path (Get-MinerOkPath $BinDir $MinerId))
}

# A miner is listed only when it can actually run on this host:
#   startup_gate miners (go-gpu): listed ONLY once .ok proves a real launch
#     succeeded here — static probes can't see a registered-but-broken driver.
#   other miners: hidden after ONE confirmed fast startup failure.
function Test-MinerListable {
    param([object]$Miner, [string]$BinDir)
    if (-not $BinDir) { return $true }
    $isGated = $Miner.PSObject.Properties['startup_gate'] -and $Miner.startup_gate
    if ($isGated) {
        return (Test-MinerProvenOnHost -BinDir $BinDir -MinerId $Miner.id)
    }
    return -not (Test-MinerFailsOnHost -BinDir $BinDir -MinerId $Miner.id)
}

# A miner binary must be a complete, platform-valid executable. This catches
# truncated/interrupted extractions that used to be cached forever — a corrupt
# binary can still run far enough to print its usage screen instead of mining.
function Test-BinaryIntegrityOnce {
    param([string]$Path, [string]$Os)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $fi = Get-Item -LiteralPath $Path
        # Valid stripped miners can be smaller than 200 KB (Dirtybird C++ is
        # about 178 KB), so use a conservative 64 KiB floor and rely on the
        # platform executable magic below for the format check.
        if ($fi.Length -lt 65536) { return $false }
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $buf = New-Object byte[] 4
            $read = $fs.Read($buf, 0, 4)
            if ($read -lt 4) { return $false }
            if ($Os -eq 'windows') {
                # MZ
                return ($buf[0] -eq 0x4D -and $buf[1] -eq 0x5A)
            }
            if ($Os -eq 'macos') {
                # Mach-O: MH_MAGIC_64 / fat / MH_MAGIC variants
                return (($buf[0] -eq 0xCF -and $buf[1] -eq 0xFA -and $buf[2] -eq 0xED -and $buf[3] -eq 0xFE) -or
                        ($buf[0] -eq 0xCA -and $buf[1] -eq 0xFE -and $buf[2] -eq 0xBA -and $buf[3] -eq 0xBE) -or
                        ($buf[0] -eq 0xFE -and $buf[1] -eq 0xED -and $buf[2] -eq 0xFA -and $buf[3] -eq 0xCE) -or
                        ($buf[0] -eq 0xFE -and $buf[1] -eq 0xED -and $buf[2] -eq 0xFA -and $buf[3] -eq 0xCF))
            }
            # ELF (\x7fELF)
            return ($buf[0] -eq 0x7F -and $buf[1] -eq 0x45 -and $buf[2] -eq 0x4C -and $buf[3] -eq 0x46)
        } finally {
            $fs.Dispose()
        }
    } catch {
        return $false
    }
}

# AV real-time protection (Windows Defender) can briefly LOCK a freshly
# extracted exe while it scans it, making the read fail even though the file
# is fine. Retry a few times to ride out the scan; only give up if the file
# still fails every attempt (adds at most ~600ms, and only on the failure
# path).
function Test-BinaryIntegrity {
    param([string]$Path, [string]$Os, [int]$Retries = 3, [int]$RetryDelayMs = 500)
    $attempt = 0
    while ($attempt -lt $Retries) {
        if (Test-BinaryIntegrityOnce -Path $Path -Os $Os) { return $true }
        $attempt++
        if ($attempt -lt $Retries) { Start-Sleep -Milliseconds $RetryDelayMs }
    }
    return $false
}

# A freshly-extracted binary that FAILED the integrity check needs an
# actionable explanation, not a dead-end error. On Windows the upstream
# release is valid (verified per-release), so a damaged or missing file is
# almost always Windows Defender (or another AV) interfering: quarantining
# the exe (file missing), truncating it during extraction, or briefly locking
# it while scanning. Report what was actually observed so the diagnosis is
# data-driven, not a coin flip.
function Get-IntegrityFailureHint {
    param([string]$Path, [string]$Os, [string]$MinerDir)
    if ($Os -ne 'windows') {
        return @"
The download was incomplete or corrupt (e.g. an interrupted download).
Remove the stale cache and retry:
  Remove-Item '$MinerDir' -Recurse -Force
Then run deromine again.
"@
    }
    $state = 'file is missing'
    $locked = $false
    $sizeNum = -1
    if (Test-Path -LiteralPath $Path) {
        $sizeText = 'size unknown'
        try {
            $sizeNum = [int](Get-Item -LiteralPath $Path).Length
            $sizeText = "$sizeNum bytes"
        } catch {}
        $magic = 'unreadable'
        try {
            $fs = [System.IO.File]::OpenRead($Path)
            try {
                $b = New-Object byte[] 4
                if ($fs.Read($b, 0, 4) -eq 4) {
                    $magic = '0x{0:X2}{1:X2}{2:X2}{3:X2}' -f $b[0], $b[1], $b[2], $b[3]
                } else {
                    $magic = 'shorter than 4 bytes'
                }
            } finally { $fs.Dispose() }
        } catch {
            $magic = 'locked or unreadable'
            $locked = $true
        }
        $state = "file exists, $sizeText, first 4 bytes $magic"
    }
    if ($locked) {
        # The file cannot be opened for reading — Windows Security (or another
        # AV/process) is holding it. Only claim "correct full size" when the
        # size was actually verified as plausible; otherwise stick to the
        # Observed line, which already shows the truth.
        $sizeClause = if ($sizeNum -ge 65536) { ' meets the minimum size check but' } else { '' }
        return @"
Observed: $state - an AV/process is holding the file open

The file$sizeClause is LOCKED - Windows Security (or another AV) is actively
holding it (scan or quarantine in progress) and will keep locking every fresh
download until told not to. Re-running alone will NOT fix this.

Fix (do this FIRST, then re-run deromine):
  1. Windows Security > Virus & threat protection > Protection history
     > find the deroluna detection > Actions > Allow / Restore
  2. Windows Security > Virus & threat protection > Manage settings
     > Exclusions > Add a folder > '$MinerDir'
  3. Run deromine again - it re-downloads the miner.
"@
    }
    return @"
Observed: $state

Windows Defender (or another AV) frequently interferes with closed-source
miners (e.g. deroluna) - the upstream release is valid, so a damaged or
missing file here almost always means AV interference (quarantine, truncation
during extraction, or a scan lock).

Fix:
  1. Windows Security > Virus & threat protection > Manage settings
     > Exclusions > Add a folder > '$MinerDir'
  2. Windows Security > Virus & threat protection > Protection history
     > restore the deroluna detection if listed
  3. Run deromine again - it re-downloads the miner.

If it still fails with the exclusion in place, the download itself was
corrupt: Remove-Item '$MinerDir' -Recurse -Force, then run deromine again.
"@
}

# A cached binary is usable only if it exists, its recorded release tag matches
# the currently-resolved latest tag, and it passes the integrity check.
function Test-CachedBinaryUsable {
    param([string]$BinaryPath, [string]$ResolvedTag, [string]$Os)
    if (-not (Test-Path -LiteralPath $BinaryPath)) { return $false }
    $tagPath = "$BinaryPath.tag"
    if (-not (Test-Path -LiteralPath $tagPath)) { return $false }
    try {
        $cachedTag = (Get-Content -LiteralPath $tagPath -Raw -ErrorAction Stop).Trim()
    } catch {
        return $false
    }
    if ($cachedTag -ne $ResolvedTag) { return $false }
    return (Test-BinaryIntegrity $BinaryPath $Os)
}