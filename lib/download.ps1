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

# A miner binary must be a complete, platform-valid executable. This catches
# truncated/interrupted extractions that used to be cached forever — a corrupt
# binary can still run far enough to print its usage screen instead of mining.
function Test-BinaryIntegrity {
    param([string]$Path, [string]$Os)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $fi = Get-Item -LiteralPath $Path
        if ($fi.Length -lt 200000) { return $false }
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