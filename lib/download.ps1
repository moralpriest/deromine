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