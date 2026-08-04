function Test-CatalogSchema {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        Write-Host "[x] Catalog not found: $Path" -ForegroundColor Red
        return $false
    }
    try {
        $json = Get-Content $Path -Raw -Encoding UTF8
        $catalog = ConvertFrom-Json $json
        if ($null -eq $catalog -or $catalog -isnot [PSCustomObject]) { throw 'root must be a JSON object' }
        if ($null -eq $catalog.miners -or @($catalog.miners).Count -eq 0) { throw 'miners must be a non-empty array' }
        if ($null -eq $catalog.daemons -or @($catalog.daemons).Count -eq 0) { throw 'daemons must be a non-empty array' }
        $ids = @{}
        foreach ($m in @($catalog.miners)) {
            foreach ($field in @('id', 'name', 'binary', 'repo', 'fee')) {
                if (-not $m.PSObject.Properties[$field] -or [string]::IsNullOrWhiteSpace([string]$m.$field)) { throw "miner is missing '$field'" }
            }
            if ($ids.ContainsKey([string]$m.id)) { throw "duplicate miner id '$($m.id)'" }
            $ids[[string]$m.id] = $true
            if ($m.PSObject.Properties['benchmark_policy']) {
                $policy = ([string]$m.benchmark_policy).ToLowerInvariant()
                if ($policy -notin @('default', 'opt-in', 'disabled')) { throw "miner '$($m.id)' has invalid benchmark_policy '$policy'" }
            }
            if ($null -eq $m.assets -or @($m.assets).Count -eq 0) { throw "miner '$($m.id)' must have assets" }
            foreach ($a in @($m.assets)) {
                foreach ($field in @('os', 'arch', 'pattern')) {
                    if (-not $a.PSObject.Properties[$field] -or [string]::IsNullOrWhiteSpace([string]$a.$field)) { throw "miner '$($m.id)' asset is missing '$field'" }
                }
            }
        }
        foreach ($d in @($catalog.daemons)) {
            if (-not $d.PSObject.Properties['name'] -or [string]::IsNullOrWhiteSpace([string]$d.name) -or
                -not $d.PSObject.Properties['url'] -or [string]::IsNullOrWhiteSpace([string]$d.url)) { throw 'daemon entries require name and url' }
        }
        return $true
    } catch {
        Write-Host "[x] Invalid catalog '$Path': $($_.Exception.Message)" -ForegroundColor Red
        Write-Host '    Expected non-empty miners[] and daemons[] with required fields.' -ForegroundColor DarkYellow
        return $false
    }
}

function Read-Catalog {
    param([string]$Path)
    if (-not (Test-CatalogSchema $Path)) { return $null }
    try {
        $json = Get-Content $Path -Raw -Encoding UTF8
        return ConvertFrom-Json $json
    } catch {
        Write-Host "[x] Failed to parse catalog '$Path': $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

function Get-MinerByMinerId {
    param([object]$Catalog, [string]$MinerId)
    foreach ($m in $Catalog.miners) {
        if ($m.id -eq $MinerId) { return $m }
    }
    return $null
}

function Get-MinerBinaryName {
    param([object]$Miner, [string]$Os = '', [string]$Arch = '')
    $name = $null
    # Per-asset override first (needed when a release names its binary per
    # OS/arch, e.g. derohe's dero-miner-linux-arm64 on aarch64). Prefer the
    # exact OS+arch asset, then fall back to any asset for this OS.
    if ($Os -and $Miner.PSObject.Properties['assets']) {
        $asset = $null
        foreach ($a in $Miner.assets) {
            if ([string]$a.os -eq $Os -and [string]$a.arch -eq $Arch) { $asset = $a; break }
        }
        if (-not $asset) {
            foreach ($a in $Miner.assets) {
                if ([string]$a.os -eq $Os) { $asset = $a; break }
            }
        }
        if ($asset -and $asset.PSObject.Properties['binary'] -and $asset.binary) { $name = [string]$asset.binary }
    }
    if (-not $name -and $Miner.binary) { $name = [string]$Miner.binary }
    if (-not $name) {
        $fallback = @{
            'c'         = 'dirtybird-c-miner'
            'rust'      = 'dirtybird-dero-miner'
            'go'        = 'dirtybird-go-miner'
            'zig'       = 'dirtybird-zig-miner'
            'cuda'      = 'dirtybird-openastronv_v3'
            'go-gpu'    = 'dirtybird-go-gpu-miner'
        }
        $name = $fallback[$Miner.id]
    }
    if ($Os -eq 'windows' -and $name -and -not $name.EndsWith('.exe')) { $name += '.exe' }
    return $name
}

function Get-MinerType {
    param([object]$Miner)
    if ($Miner.PSObject.Properties['type'] -and $Miner.type) { return ([string]$Miner.type).ToLower() }
    $fallback = @{
        'cuda'    = 'gpu'
        'go-gpu'  = 'gpu'
        'tnn'     = 'both'
    }
    $t = $fallback[$Miner.id]
    if (-not $t) { $t = 'cpu' }
    return $t
}

function Get-MinerArchiveBinaryName {
    param([object]$Miner, [string]$Os = '', [string]$Arch = '')
    $name = $null
    if ($Os -and $Miner.PSObject.Properties['assets']) {
        $asset = $null
        foreach ($a in $Miner.assets) {
            if ([string]$a.os -eq $Os -and [string]$a.arch -eq $Arch) { $asset = $a; break }
        }
        if (-not $asset) {
            foreach ($a in $Miner.assets) {
                if ([string]$a.os -eq $Os) { $asset = $a; break }
            }
        }
        if ($asset) {
            if ($asset.PSObject.Properties['binary_archive'] -and $asset.binary_archive) { $name = [string]$asset.binary_archive }
            elseif ($asset.PSObject.Properties['binary'] -and $asset.binary) { $name = [string]$asset.binary }
        }
    }
    if (-not $name -and $Miner.PSObject.Properties['binary_archive'] -and $Miner.binary_archive) { $name = [string]$Miner.binary_archive }
    if (-not $name) { $name = Get-MinerBinaryName $Miner $Os $Arch }
    if ($Os -eq 'windows' -and $name -and -not $name.EndsWith('.exe')) { $name += '.exe' }
    return $name
}

function Get-MinerCliArgs {
    param([object]$Miner)
    $noThreads = @('cuda', 'go-gpu').Contains([string]$Miner.id)
    $flags = @{
        daemon    = '-d'
        wallet    = '-w'
        threads   = if ($noThreads) { $null } else { '-t' }
        coin      = $null
        port      = $null
        cpu_off   = $null
        gpu_off   = $null
        dev_fee   = $null
    }
    if ($Miner.PSObject.Properties['flags']) {
        foreach ($f in $Miner.flags.PSObject.Properties) {
            $flags[$f.Name] = [string]$f.Value
        }
    }
    if ($flags['dev_fee'] -and $Miner.PSObject.Properties['fee']) {
        $flags['dev_fee_value'] = ([string]$Miner.fee).TrimEnd('%')
    }
    return $flags
}

function Get-MinerAsset {
    param([object]$Miner, [string]$Os, [string]$Arch)
    if ($Miner.PSObject.Properties['assets']) {
        foreach ($a in $Miner.assets) {
            $aOs   = [string]$a.os
            $aArch = [string]$a.arch
            if ($aOs -eq $Os -and $aArch -eq $Arch) { return $a }
        }
    }
    return $null
}