$script:UnicodeBox = @{
    TopLeft = '╔'; TopRight = '╗'; BotLeft = '╚'; BotRight = '╝'
    LTee = '╠'; RTee = '╣'; Horiz = '═'; Vert = '║'
    Bullet = '●'; Cross = '✗'; Check = '✓'; Arrow = '▶'; Prompt = '❯'
    TblTL = '┌'; TblTR = '┐'; TblBL = '└'; TblBR = '┘'
    TblLT = '├'; TblRT = '┤'; TblTT = '┬'; TblBT = '┴'; TblCross = '┼'
    TblH = '─'; TblV = '│'
}
$script:AsciiBox = @{
    TopLeft = '+'; TopRight = '+'; BotLeft = '+'; BotRight = '+'
    LTee = '+'; RTee = '+'; Horiz = '='; Vert = '|'
    Bullet = '*'; Cross = 'X'; Check = 'OK'; Arrow = '>'; Prompt = '>'
    TblTL = '+'; TblTR = '+'; TblBL = '+'; TblBR = '+'
    TblLT = '+'; TblRT = '+'; TblTT = '+'; TblBT = '+'; TblCross = '+'
    TblH = '-'; TblV = '|'
}

function Get-BoxChars {
    if (Test-IsUnicodeTerminal) { return $script:UnicodeBox } else { return $script:AsciiBox }
}

function Format-UiValue {
    param([string]$Value, [int]$MaxLength)
    if ($MaxLength -lt 4) { return '' }
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    if ($Value.Length -le $MaxLength) { return $Value }
    return $Value.Substring(0, $MaxLength - 1) + '…'
}

function Write-Banner {
    $b = Get-BoxChars
    $title = 'deromine'
    $subtitle = 'cross-platform DERO miner launcher'
    $width = [Math]::Min((Get-TerminalWidth), 100)
    $inner = [Math]::Max(30, $width - 2)
    $titlePad = $inner - $title.Length - 6
    $subtitlePad = $inner - $subtitle.Length - 6
    if ($titlePad -lt 0) { $titlePad = 0 }
    if ($subtitlePad -lt 0) { $subtitlePad = 0 }
    $topLine = $b.TopLeft + ($b.Horiz * $inner) + $b.TopRight
    $titleRow = $b.Vert + '  ' + $title + (' ' * $titlePad) + '  ' + $b.Vert
    $subtitleRow = $b.Vert + '  ' + $subtitle + (' ' * $subtitlePad) + '  ' + $b.Vert
    $botLine = $b.BotLeft + ($b.Horiz * $inner) + $b.BotRight
    Write-Host ''
    Write-Host $topLine -ForegroundColor Magenta
    Write-Host $titleRow -ForegroundColor White
    Write-Host $subtitleRow -ForegroundColor DarkGray
    Write-Host $botLine -ForegroundColor Magenta
    Write-Host '  [ MENU ]  list  ·  benchmark  ·  help  ·  quit' -ForegroundColor DarkGray
    Write-Host ''
}

function Write-ConfigStatus {
    param(
        [string]$Daemon = 'not set',
        [string]$Wallet = '',
        [int]$Threads = 0,
        [string]$DevFee = ''
    )
    $devFeeText = if ($DevFee) { ", dev fee $DevFee%" } else { '' }
    $bits = @("$Daemon", "threads $Threads$devFeeText")
    if ($Wallet) {
        $mask = if ($Wallet.Length -ge 10) { "$($Wallet.Substring(0,8))…$($Wallet.Substring($Wallet.Length-6))" } else { $Wallet }
        $bits = @("daemon $Daemon", "threads $Threads$devFeeText", "wallet $mask")
    }
    $b = Get-BoxChars
    $lineWidth = [Math]::Max(20, [Math]::Min(76, (Get-TerminalWidth) - 4))
    $line = $b.TblH * $lineWidth
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host '  CONFIGURATION' -ForegroundColor DarkCyan
    foreach ($bit in $bits) {
        Write-Host ("  $($b.Bullet) $bit") -ForegroundColor DarkGray
    }
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host ''
}

function Show-Help {
    Write-Banner
    Write-Host 'Usage: deromine [options]' -ForegroundColor White
    Write-Host ''
    Write-Host 'Flag values accept both --flag=value and --flag value' -ForegroundColor Gray
    Write-Host '(e.g. --threads=28 or --threads 28).' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  --version              Show version and exit' -ForegroundColor Gray
    Write-Host '  --reconfigure          Re-run setup: ask for wallet, node, threads again' -ForegroundColor Gray
    Write-Host '  --update               Check for a new release now (bypasses the tag cache)' -ForegroundColor Gray
    Write-Host '  --check-catalog        Audit catalog asset patterns against the latest releases' -ForegroundColor Gray
    Write-Host '  --miner=<id>           Miner id, or "list" to show the catalog table' -ForegroundColor Gray
    Write-Host '  --wallet=<addr>        DERO wallet address' -ForegroundColor Gray
    Write-Host '  --daemon-url=<url>     Node/pool host:port (scheme optional)' -ForegroundColor Gray
    Write-Host '  --threads=<n>          CPU threads' -ForegroundColor Gray
    Write-Host '  --dev-fee=<pct>        Dev fee % for miners that support it (e.g. TNN)' -ForegroundColor Gray
    Write-Host '  --auto-restart         Restart miner on crash' -ForegroundColor Gray
    Write-Host '  --max-restart=<n>      Max restarts (default 5)' -ForegroundColor Gray
    Write-Host '  --delay=<sec>          Restart delay in seconds (default 10)' -ForegroundColor Gray
    Write-Host '  --dry-run              Resolve release and print command, do not launch' -ForegroundColor Gray
    Write-Host '  --benchmark            Benchmark approved miners (closed-source miners skipped)' -ForegroundColor Gray
    Write-Host '  --include-closed-source Include closed/partially closed miners (explicit opt-in)' -ForegroundColor Yellow
    Write-Host '  --yes                  Confirm an opt-in benchmark non-interactively' -ForegroundColor Yellow
    Write-Host '  --bench-time=<sec>     Benchmark seconds per miner (default 30)' -ForegroundColor Gray
    Write-Host '  --output-dir=<dir>     Where binaries are stored (default ./bin)' -ForegroundColor Gray
    Write-Host '  --config=<path>        Config file (default ./config.json)' -ForegroundColor Gray
    Write-Host '  -h | --help | /?       Show this help' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Examples:' -ForegroundColor White
    Write-Host '  deromine' -ForegroundColor Gray
    Write-Host '  deromine --miner=list' -ForegroundColor Gray
    Write-Host '  deromine --miner c --threads 28' -ForegroundColor Gray
    Write-Host '  deromine --miner=tnn --dev-fee=1' -ForegroundColor Gray
    Write-Host '  deromine --miner=c --dry-run' -ForegroundColor Gray
    Write-Host ''
    exit 0
}

function Write-MinerTable {
    param([array]$Miners, [object]$Platform, [string]$BinDir = '', [string]$DevFee = '', [switch]$AsList)
    $b = Get-BoxChars
    Write-Host ("  MINERS  ·  $($Platform.os)/$($Platform.arch)") -ForegroundColor DarkCyan
    $rows = @()
    foreach ($m in $Miners) {
        $asset = Get-MinerAsset $m $Platform.os $Platform.arch
        if (-not $asset) { continue }
        if (-not (Test-MinerHardwareSupported $m)) { continue }
        # Hide miners that can't actually run on this host: self-test-gated
        # GPU miners (go-gpu) are listed only once a launch proved they work
        # here; other miners are hidden after one confirmed startup failure.
        if ($BinDir -and -not (Test-MinerListable -Miner $m -BinDir $BinDir)) { continue }
        $rows += $m
    }

    if ($rows.Count -eq 0) {
        Write-Host "No miners available on this host" -ForegroundColor Red
        return @()
    }

    $numW = 3
    $nameW = 0
    $binW = 0
    $typeW = 0
    $riskW = 0
    $feeW = 0
    foreach ($m in $rows) {
        $nl = ([string]$m.name).Length
        $bl = (Get-MinerBinaryName $m $Platform.os $Platform.arch).Length
        $tl = (Get-MinerType $m).Length
        $rl = ([string]$m.risk_note).Length
        $flRaw = [string]$m.fee
        if ($DevFee -and $m.PSObject.Properties['flags'] -and $m.flags.PSObject.Properties['dev_fee']) { $flRaw = "$DevFee%" }
        $fl = $flRaw.Length
        if ([string]::IsNullOrEmpty([string]$m.fee)) { $fl = 3 }
        if ($nl -gt $nameW) { $nameW = $nl }
        if ($bl -gt $binW) { $binW = $bl }
        if ($tl -gt $typeW) { $typeW = $tl }
        if ($rl -gt $riskW) { $riskW = $rl }
        if ($fl -gt $feeW) { $feeW = $fl }
    }
    if ($nameW -lt 10) { $nameW = 10 }
    if ($binW -lt 12) { $binW = 12 }
    if ($typeW -lt 4) { $typeW = 4 }
    if ($riskW -lt 12) { $riskW = 12 }
    if ($feeW -lt 5) { $feeW = 5 }
    $statusW = 10

    $topBorder = $b.TblTL + ($b.TblH * ($numW + 2)) + $b.TblTT + ($b.TblH * ($nameW + 2)) + $b.TblTT + ($b.TblH * ($binW + 2)) + $b.TblTT + ($b.TblH * ($typeW + 2)) + $b.TblTT + ($b.TblH * ($statusW + 2)) + $b.TblTT + ($b.TblH * ($riskW + 2)) + $b.TblTT + ($b.TblH * ($feeW + 2)) + $b.TblTR
    $headerSep = $b.TblLT + ($b.TblH * ($numW + 2)) + $b.TblCross + ($b.TblH * ($nameW + 2)) + $b.TblCross + ($b.TblH * ($binW + 2)) + $b.TblCross + ($b.TblH * ($typeW + 2)) + $b.TblCross + ($b.TblH * ($statusW + 2)) + $b.TblCross + ($b.TblH * ($riskW + 2)) + $b.TblCross + ($b.TblH * ($feeW + 2)) + $b.TblRT
    $botBorder = $b.TblBL + ($b.TblH * ($numW + 2)) + $b.TblBT + ($b.TblH * ($nameW + 2)) + $b.TblBT + ($b.TblH * ($binW + 2)) + $b.TblBT + ($b.TblH * ($typeW + 2)) + $b.TblBT + ($b.TblH * ($statusW + 2)) + $b.TblBT + ($b.TblH * ($riskW + 2)) + $b.TblBT + ($b.TblH * ($feeW + 2)) + $b.TblBR

    $header = $b.TblV + ' ' + '  #'.PadRight($numW) + ' ' + $b.TblV + ' ' + 'Miner'.PadRight($nameW) + ' ' + $b.TblV + ' ' + 'Binary'.PadRight($binW) + ' ' + $b.TblV + ' ' + 'Type'.PadRight($typeW) + ' ' + $b.TblV + ' ' + 'Status'.PadRight($statusW) + ' ' + $b.TblV + ' ' + 'Risk'.PadRight($riskW) + ' ' + $b.TblV + ' ' + 'Fee'.PadRight($feeW) + ' ' + $b.TblV

    Write-Host $topBorder -ForegroundColor DarkCyan
    Write-Host $header -ForegroundColor DarkCyan
    Write-Host $headerSep -ForegroundColor DarkCyan

    $idx = 0
    foreach ($m in $rows) {
        $idx++
        $numCell = "$idx".PadLeft($numW)
        $nameCell = ([string]$m.name).PadRight($nameW)
        $binCell = ([string](Get-MinerBinaryName $m $Platform.os $Platform.arch)).PadRight($binW)
        $typeCell = (Get-MinerType $m).PadRight($typeW)
        $statusCell = "$($b.Bullet) FETCH".PadRight($statusW)
        $statusColor = 'Yellow'
        if ($BinDir) {
            $localBinary = Join-Path (Join-Path $BinDir $m.id) (Get-MinerBinaryName $m $Platform.os $Platform.arch)
            if (Test-Path $localBinary) { $statusCell = "$($b.Check) READY".PadRight($statusW); $statusColor = 'Green' }
        }
        $riskNote = [string]$m.risk_note
        if ([string]::IsNullOrEmpty($riskNote)) { $riskNote = 'Unknown' }
        $riskCell = $riskNote.PadRight($riskW)
        $riskColor = switch ([string]$m.risk) {
            'high'   { 'Red' }
            'medium' { 'Yellow' }
            default  { 'Green' }
        }
        # "Closed source" is always red regardless of the coarse risk level
        # (matches the README legend; e.g. astrox is 'medium' but ships no
        # source code, so it must not look as safe as 'Closed DLLs').
        if ($riskNote -eq 'Closed source') { $riskColor = 'Red' }
        $feeValue = [string]$m.fee
        if ([string]::IsNullOrEmpty($feeValue)) { $feeValue = '0%' }
        if ($DevFee -and $m.PSObject.Properties['flags'] -and $m.flags.PSObject.Properties['dev_fee']) { $feeValue = "$DevFee%" }
        $feeCell = $feeValue.PadRight($feeW)
        $feeColor = 'Magenta'
        $feeNum = 0.0
        if ([double]::TryParse($feeValue.TrimEnd('%'), [ref]$feeNum)) {
            if ($feeNum -le 0) { $feeColor = 'Green' }
            elseif ($feeNum -le 2.5) { $feeColor = 'Yellow' }
            else { $feeColor = 'Red' }
        }

        Write-Host $b.TblV -ForegroundColor DarkCyan -NoNewline
        Write-Host (' ' + $numCell) -ForegroundColor Yellow -NoNewline
        Write-Host (' ' + $b.TblV + ' ') -ForegroundColor DarkCyan -NoNewline
        Write-Host $nameCell -ForegroundColor White -NoNewline
        Write-Host (' ' + $b.TblV + ' ') -ForegroundColor DarkCyan -NoNewline
        Write-Host $binCell -ForegroundColor DarkGray -NoNewline
        Write-Host (' ' + $b.TblV + ' ') -ForegroundColor DarkCyan -NoNewline
        Write-Host $typeCell -ForegroundColor Blue -NoNewline
        Write-Host (' ' + $b.TblV + ' ') -ForegroundColor DarkCyan -NoNewline
        Write-Host $statusCell -ForegroundColor $statusColor -NoNewline
        Write-Host (' ' + $b.TblV + ' ') -ForegroundColor DarkCyan -NoNewline
        Write-Host $riskCell -ForegroundColor $riskColor -NoNewline
        Write-Host (' ' + $b.TblV + ' ') -ForegroundColor DarkCyan -NoNewline
        Write-Host $feeCell -ForegroundColor $feeColor -NoNewline
        Write-Host (' ' + $b.TblV) -ForegroundColor DarkCyan
    }

    Write-Host $botBorder -ForegroundColor DarkCyan
    Write-Host ''
    return $rows
}

function Write-DaemonTable {
    param([array]$Daemons)
    $b = Get-BoxChars
    if ($Daemons.Count -eq 0) {
        Write-Host "No daemons available" -ForegroundColor Red
        return @()
    }

    $numW = 3
    $nameW = 0
    $urlW = 0
    foreach ($d in $Daemons) {
        $nl = ([string]$d.name).Length
        $ul = ([string]$d.url).Length
        if ($nl -gt $nameW) { $nameW = $nl }
        if ($ul -gt $urlW) { $urlW = $ul }
    }
    if ($nameW -lt 10) { $nameW = 10 }
    if ($urlW -lt 20) { $urlW = 20 }

    $topBorder = $b.TblTL + ($b.TblH * ($numW + 2)) + $b.TblTT + ($b.TblH * ($nameW + 2)) + $b.TblTT + ($b.TblH * ($urlW + 2)) + $b.TblTR
    $headerSep = $b.TblLT + ($b.TblH * ($numW + 2)) + $b.TblCross + ($b.TblH * ($nameW + 2)) + $b.TblCross + ($b.TblH * ($urlW + 2)) + $b.TblRT
    $botBorder = $b.TblBL + ($b.TblH * ($numW + 2)) + $b.TblBT + ($b.TblH * ($nameW + 2)) + $b.TblBT + ($b.TblH * ($urlW + 2)) + $b.TblBR

    $header = $b.TblV + ' ' + '  #'.PadRight($numW) + ' ' + $b.TblV + ' ' + 'Name'.PadRight($nameW) + ' ' + $b.TblV + ' ' + 'URL'.PadRight($urlW) + ' ' + $b.TblV

    Write-Host $topBorder -ForegroundColor DarkCyan
    Write-Host $header -ForegroundColor DarkCyan
    Write-Host $headerSep -ForegroundColor DarkCyan

    $idx = 0
    foreach ($d in $Daemons) {
        $idx++
        $numCell = "$idx".PadLeft($numW)
        $nameCell = ([string]$d.name).PadRight($nameW)
        $urlCell = ([string]$d.url).PadRight($urlW)
        Write-Host $b.TblV -ForegroundColor DarkCyan -NoNewline
        Write-Host (' ' + $numCell) -ForegroundColor Yellow -NoNewline
        Write-Host (' ' + $b.TblV + ' ') -ForegroundColor DarkCyan -NoNewline
        Write-Host $nameCell -ForegroundColor White -NoNewline
        Write-Host (' ' + $b.TblV + ' ') -ForegroundColor DarkCyan -NoNewline
        Write-Host $urlCell -ForegroundColor DarkGray -NoNewline
        Write-Host (' ' + $b.TblV) -ForegroundColor DarkCyan
    }

    Write-Host $botBorder -ForegroundColor DarkCyan
    Write-Host ''
    return $Daemons
}

# Daemon endpoint prompt. Picks a number from the catalog table, lets the user
# type a custom node (host:port) with 'c', or quit with 'q'. Returns the URL
# string, or $null when the user quits.
function Read-DaemonEndpoint {
    param([array]$Daemons)
    $b = Get-BoxChars
    while ($true) {
        Write-PromptHeader 'Select a daemon endpoint:'
        $null = Write-DaemonTable $Daemons
        $choice = Read-Host "Choice (1-$($Daemons.Count)), $($b.Prompt) c for a custom node, q to quit"
        if ($choice -match '^(q|quit|x|exit)$') { return $null }
        if ($choice -match '^(c|custom)$') {
            $custom = Read-Host 'Custom node (host:port, e.g. 192.168.1.10:10100, port defaults to 10100)'
            $url = Normalize-DaemonUrl $custom
            if ($url) { return $url }
            Write-Host "[x] Invalid node. Use host:port (e.g. node.example.org:10100)." -ForegroundColor Red
            continue
        }
        $n = 0
        if ([int]::TryParse($choice, [ref]$n) -and $n -ge 1 -and $n -le $Daemons.Count) {
            return [string]$Daemons[$n - 1].url
        }
        Write-Host "[x] Invalid choice '$choice'" -ForegroundColor Red
    }
}

function Write-LaunchSummary {
    param([object]$Miner, [string]$Binary, [string]$Daemon, [string]$Wallet, [int]$Threads, [string]$DevFee = '')
    $b = Get-BoxChars
    $mask = if ($Wallet.Length -ge 14) { "$($Wallet.Substring(0,8))…$($Wallet.Substring($Wallet.Length-6))" } else { $Wallet }
    $rows = @(
        @{ Label = 'Miner';   Value = $Miner.name }
        @{ Label = 'Binary';  Value = $Binary }
        @{ Label = 'Daemon';  Value = $Daemon }
        @{ Label = 'Wallet';  Value = $mask }
        @{ Label = 'Threads'; Value = "$Threads" }
    )
    if ($DevFee) { $rows += @{ Label = 'Dev fee'; Value = "$DevFee%" } }
    $maxLabel = 0
    $maxValue = 0
    foreach ($r in $rows) {
        if ($r.Label.Length -gt $maxLabel) { $maxLabel = $r.Label.Length }
        if ($r.Value.Length -gt $maxValue) { $maxValue = $r.Value.Length }
    }
    $inner = [Math]::Max(30, $maxLabel + $maxValue + 7)
    $inner = [Math]::Min($inner, [Math]::Max(30, (Get-TerminalWidth) - 4))
    $valueWidth = [Math]::Max(4, $inner - $maxLabel - 5)
    foreach ($r in $rows) { $r.Value = Format-UiValue ([string]$r.Value) $valueWidth }
    $topLine = $b.TopLeft + ($b.Horiz * $inner) + $b.TopRight
    $botLine = $b.BotLeft + ($b.Horiz * $inner) + $b.BotRight
    Write-Host ''
    Write-Host ("$($b.TopLeft)$($b.Horiz * $inner)$($b.TopRight)") -ForegroundColor Green
    $titleSpace = [Math]::Max(0, $inner - 15)
    Write-Host ("$($b.Vert)  LAUNCH PLAN" + (' ' * $titleSpace) + $b.Vert) -ForegroundColor Green
    Write-Host ($b.LTee + ($b.Horiz * $inner) + $b.RTee) -ForegroundColor Green
    foreach ($r in $rows) {
        $label = ([string]$r.Label).PadRight($maxLabel)
        $value = ([string]$r.Value).PadRight($valueWidth)
        Write-Host $b.Vert -ForegroundColor Green -NoNewline
        Write-Host "  $label  " -ForegroundColor White -NoNewline
        Write-Host $value -ForegroundColor DarkGray -NoNewline
        Write-Host $b.Vert -ForegroundColor Green
    }
    Write-Host $botLine -ForegroundColor Green
    Write-Host ''
}

function Write-Error {
    param([string]$Message)
    $b = Get-BoxChars
    Write-Host "$($b.Cross) $Message" -ForegroundColor Red
}

function Write-Success {
    param([string]$Message)
    $b = Get-BoxChars
    Write-Host "$($b.Check) $Message" -ForegroundColor Green
}

function Write-PromptHeader {
    param([string]$Message)
    $b = Get-BoxChars
    $lineWidth = [Math]::Max(20, [Math]::Min(76, (Get-TerminalWidth) - 4))
    $line = $b.TblH * $lineWidth
    Write-Host "`n$line" -ForegroundColor DarkCyan
    Write-Host "$($b.Arrow) $Message" -ForegroundColor Cyan
    Write-Host $line -ForegroundColor DarkCyan
}