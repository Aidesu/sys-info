# Module Performance : charge en direct (CPU, mémoire, disque, réseau), historique enregistré, seuils d'alerte,
# goulots d'étranglement, processus les plus gourmands dans le temps, mini-benchmark disque.
#
# Sources
#   Dans SysInfo : [SysInfo.Native.CpuSampler], [SysInfo.Native.PerfSampler] (Linux : /proc/meminfo, /proc/diskstats,
#                  /proc/net/dev, /proc/vmstat, /proc/pressure ; Windows : GlobalMemoryStatusEx, GetPerformanceInfo,
#                  compteurs PDH PhysicalDisk(_Total), Memory\Pages/sec, System\Processor Queue Length),
#                  [SysInfo.Native.ProcessSampler] et [SysInfo.Native.DiskBenchmark].
#   Seul dans pwsh : /proc lu en PowerShell (Linux) ou Get-Counter (Windows), sans processus ni benchmark.
#
# Historique : un point toutes les 30 s (moyennes de la fenêtre, plus les processus les plus gourmands), écrit dans
#   Windows : %LOCALAPPDATA%\SysInfo\history\performance-AAAA-MM-JJ.jsonl
#   Linux   : ~/.local/share/SysInfo/history/performance-AAAA-MM-JJ.jsonl
# conservé 7 jours. Il n'est enregistré que pendant que SysInfo tourne (la vue d'ensemble se rafraîchit en arrière-plan,
# même page masquée). Plusieurs processus SysInfo (fenêtre + serveur MCP) : le premier qui a 30 s de mesures écrit,
# les autres relisent le fichier. Seuils d'alerte : state/performance-alerts.json ; alertes : history/performance-alerts-AAAA-MM.jsonl.

$script:Fr = [cultureinfo]::GetCultureInfo('fr-FR')
$script:Nbsp = [char]0x00A0

$script:DataRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'SysInfo'
$script:HistoryDir = Join-Path $script:DataRoot 'history'
$script:RulesFile = Join-Path (Join-Path $script:DataRoot 'state') 'performance-alerts.json'
$script:PointSeconds = 30        # une moyenne toutes les 30 s
$script:RetentionDays = 7

$script:Cache = @{}
function Get-Cached([string]$Key, [int]$Seconds, [scriptblock]$Compute) {
    $entry = $script:Cache[$Key]
    if ($entry -and ((Get-Date) - $entry.At).TotalSeconds -lt $Seconds) { return $entry.Value }
    $value = & $Compute
    $script:Cache[$Key] = @{ At = Get-Date; Value = $value }
    $value
}

#region Outils

function Format-Unit([double]$Value, [string]$Unit, [string]$Format = '0.#') {
    '{0}{1}{2}' -f $Value.ToString($Format, $script:Fr), $script:Nbsp, $Unit
}

function Format-Bytes([double]$Bytes) {
    if ($Bytes -ge 1TB) { return Format-Unit ($Bytes / 1TB) 'TiB' '0.0' }
    if ($Bytes -ge 1GB) { return Format-Unit ($Bytes / 1GB) 'GiB' '0.0' }
    if ($Bytes -ge 1MB) { return Format-Unit ($Bytes / 1MB) 'MiB' '0' }
    Format-Unit ($Bytes / 1KB) 'KiB' '0'
}

function Format-Rate([double]$BytesPerSecond) { (Format-Bytes $BytesPerSecond) + '/s' }

function Format-Bits([double]$BitsPerSecond) {
    if ($BitsPerSecond -ge 1e9) { return Format-Unit ($BitsPerSecond / 1e9) 'Gbit/s' '0.#' }
    if ($BitsPerSecond -ge 1e6) { return Format-Unit ($BitsPerSecond / 1e6) 'Mbit/s' '0.#' }
    Format-Unit ($BitsPerSecond / 1e3) 'kbit/s' '0'
}

function Format-Time([datetime]$Date) {
    if ($Date.Date -eq (Get-Date).Date) { return $Date.ToString('HH:mm', $script:Fr) }
    $Date.ToString('ddd d HH:mm', $script:Fr)
}

function Format-Minutes([double]$Minutes) {
    if ($Minutes -lt 1) { return '< 1 min' }
    if ($Minutes -lt 60) { return Format-Unit $Minutes 'min' '0' }
    '{0}{1}h{2:00}' -f [Math]::Floor($Minutes / 60), $script:Nbsp, [Math]::Round($Minutes % 60)
}

function Round1($Value) { if ($null -eq $Value) { $null } else { [Math]::Round([double]$Value, 1) } }

function New-Finding([string]$Severity, [string]$Code, [string]$Message, [string]$Recommendation) {
    [PSCustomObject]@{ Severity = $Severity; Code = $Code; Message = $Message; Recommendation = $Recommendation }
}

function New-ActionResult([string]$Subtitle, [object[]]$Sections, [object[]]$Findings, [object[]]$Changes, [string]$Blocked, $Undo) {
    $result = [ordered]@{
        Subtitle = $Subtitle
        Sections = @($Sections | Where-Object { $_ })
        Findings = @($Findings | Where-Object { $_ })
        Changes  = @($Changes | Where-Object { $_ })
        Blocked  = $Blocked
    }
    if ($Undo) { $result.Undo = $Undo }
    [PSCustomObject]$result
}

function New-Change([string]$Target, [string]$Property, $Before, $After) {
    [PSCustomObject]@{ Target = $Target; Property = $Property; Before = $Before; After = $After }
}

function ConvertTo-Unix([datetime]$Date) { [DateTimeOffset]::new($Date.ToUniversalTime()).ToUnixTimeSeconds() }
function ConvertFrom-Unix([double]$Seconds) { [DateTimeOffset]::FromUnixTimeSeconds([long]$Seconds).LocalDateTime }

#endregion

#region Mesures en direct

$script:Cpu = if ('SysInfo.Native.CpuSampler' -as [type]) { [SysInfo.Native.CpuSampler]::new() } else { $null }
$script:Perf = if ('SysInfo.Native.PerfSampler' -as [type]) { [SysInfo.Native.PerfSampler]::new() } else { $null }
$script:Procs = [bool]('SysInfo.Native.ProcessSampler' -as [type])
$script:Prev = $null   # repli PowerShell : compteurs du relevé précédent
$script:ProcsAt = [datetime]::MinValue

# Un relevé : pourcentages, octets/s, ms ; $null = pas encore mesurable (premier relevé) ou indisponible.
function Get-LiveSample {
    $now = [DateTime]::UtcNow
    $s = [ordered]@{ At = $now; Cpu = $null; MemTotal = $null; MemAvailable = $null; Mem = $null; Swap = $null; Commit = $null
        DiskBusy = $null; DiskRead = $null; DiskWrite = $null; DiskLatency = $null; DiskQueue = $null
        NetRx = $null; NetTx = $null; Link = $null; Pages = $null; CpuQueue = $null
        PsiCpu = $null; PsiMem = $null; PsiMemFull = $null; PsiIo = $null; PsiIoFull = $null; Groups = $null }

    if ($script:Perf) {
        $s.Cpu = $script:Cpu.Sample().Total
        $p = $script:Perf.Sample()
        $m = $p.Memory
        $s.MemTotal = $m.Total; $s.MemAvailable = $m.Available
        if ($p.Memory.Total -gt 0) { $s.Mem = [Math]::Round(100 * (1 - $m.Available / $m.Total), 1) }
        if ($m.SwapTotal -gt 0) { $s.Swap = [Math]::Round(100 * (1 - $m.SwapFree / $m.SwapTotal), 1) }
        if ($m.CommitLimit -gt 0) { $s.Commit = [Math]::Round(100 * $m.Committed / $m.CommitLimit, 1) }
        $s.DiskBusy = $p.DiskBusy; $s.DiskRead = $p.DiskRead; $s.DiskWrite = $p.DiskWrite
        $s.DiskLatency = $p.DiskLatencyMs; $s.DiskQueue = $p.DiskQueue
        $s.NetRx = $p.NetReceive; $s.NetTx = $p.NetSend; $s.Link = $p.LinkSpeed
        $s.Pages = $p.PagesPerSecond; $s.CpuQueue = $p.CpuQueue
        if ($p.Pressure) {
            $s.PsiCpu = $p.Pressure.Cpu; $s.PsiMem = $p.Pressure.MemorySome; $s.PsiMemFull = $p.Pressure.MemoryFull
            $s.PsiIo = $p.Pressure.IoSome; $s.PsiIoFull = $p.Pressure.IoFull
        }
        # Processus toutes les 5 s seulement (~5 ms le relevé), partagé avec le module Système.
        if ($script:Procs -and ($now - $script:ProcsAt).TotalSeconds -ge 5) {
            $s.Groups = [SysInfo.Native.ProcessSample]::Heaviest([SysInfo.Native.ProcessSampler]::Shared(1500), 12, 6)
            $script:ProcsAt = $now
        }
        return [PSCustomObject]$s
    }

    if ($IsWindows) {
        $c = (Get-Counter -Counter '\Processor(_Total)\% Processor Time', '\Memory\% Committed Bytes In Use', '\Memory\Available Bytes',
            '\PhysicalDisk(_Total)\% Idle Time', '\PhysicalDisk(_Total)\Disk Read Bytes/sec', '\PhysicalDisk(_Total)\Disk Write Bytes/sec',
            '\PhysicalDisk(_Total)\Avg. Disk sec/Transfer' -ErrorAction SilentlyContinue).CounterSamples
        $v = @{}; foreach ($x in $c) { $v[($x.Path -split '\\')[-1]] = $x.CookedValue }
        $os = Get-CimInstance Win32_OperatingSystem
        $s.Cpu = Round1 $v['% processor time']; $s.Commit = Round1 $v['% committed bytes in use']
        $s.MemTotal = [double]$os.TotalVisibleMemorySize * 1KB; $s.MemAvailable = [double]$v['available bytes']
        $s.Mem = [Math]::Round(100 * (1 - $s.MemAvailable / $s.MemTotal), 1)
        $s.DiskBusy = Round1 (100 - $v['% idle time']); $s.DiskRead = $v['disk read bytes/sec']; $s.DiskWrite = $v['disk write bytes/sec']
        $s.DiskLatency = [Math]::Round(1000 * $v['avg. disk sec/transfer'], 2)
        return [PSCustomObject]$s
    }

    # Linux sans l'application : /proc en PowerShell (CPU, mémoire, débit disque) ; le reste attend SysInfo.
    $stat = (Get-Content /proc/stat -TotalCount 1) -split '\s+' | Select-Object -Skip 1 -First 8 | ForEach-Object { [double]$_ }
    $total = ($stat | Measure-Object -Sum).Sum; $idle = $stat[3] + $stat[4]
    $mem = @{}; foreach ($line in Get-Content /proc/meminfo) { if ($line -match '^(\w+):\s+(\d+)') { $mem[$Matches[1]] = [double]$Matches[2] * 1KB } }
    $s.MemTotal = $mem.MemTotal; $s.MemAvailable = $mem.MemAvailable
    $s.Mem = [Math]::Round(100 * (1 - $mem.MemAvailable / $mem.MemTotal), 1)
    if ($mem.SwapTotal -gt 0) { $s.Swap = [Math]::Round(100 * (1 - $mem.SwapFree / $mem.SwapTotal), 1) }
    if ($script:Prev -and $total -gt $script:Prev.Total) {
        $s.Cpu = [Math]::Round(100 * (1 - ($idle - $script:Prev.Idle) / ($total - $script:Prev.Total)), 1)
    }
    $script:Prev = @{ Total = $total; Idle = $idle }
    [PSCustomObject]$s
}

#endregion

#region Historique (points de 30 s)

$script:Points = [System.Collections.Generic.List[object]]::new()   # 24 dernières heures, du plus ancien au plus récent
$script:FileName = $null      # fichier du jour déjà lu…
$script:FileOffset = 0        # … jusqu'à cet octet
$script:Window = $null        # fenêtre de 30 s en cours d'accumulation
$script:PointsVersion = 0     # change à chaque nouveau point (sections d'historique en cache)
$script:WriteError = $null
$script:IsWriter = $false     # ce processus écrit l'historique (il journalise aussi les alertes)

function Get-HistoryFile([datetime]$Day) { Join-Path $script:HistoryDir ('performance-{0:yyyy-MM-dd}.jsonl' -f $Day) }

# Lignes JSON → points (objets). Une ligne abîmée (écriture interrompue) est ignorée.
function ConvertFrom-PointLines([string[]]$Lines) {
    $valid = @($Lines | Where-Object { $_ -and $_.StartsWith('{') -and $_.EndsWith('}') })
    if ($valid.Count -eq 0) { return @() }
    try { return @(('[' + ($valid -join ',') + ']') | ConvertFrom-Json) }
    catch { return @($valid | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } }) }
}

# Lit les points d'une période dans les fichiers (fonctions ciblées, autre runspace).
function Read-HistoryPoints([datetime]$Since) {
    $points = foreach ($day in 0..([Math]::Ceiling(((Get-Date) - $Since).TotalDays))) {
        $file = Get-HistoryFile (Get-Date).Date.AddDays(-$day)
        if (Test-Path -LiteralPath $file) { ConvertFrom-PointLines ([System.IO.File]::ReadAllLines($file)) }
    }
    $from = ConvertTo-Unix $Since
    @($points | Where-Object { $_.t -ge $from } | Sort-Object t)
}

# Relit la fin du fichier du jour (points écrits par un autre processus SysInfo, ou au démarrage : les 24 dernières heures).
function Sync-History {
    $today = Get-HistoryFile (Get-Date).Date
    if ($null -eq $script:FileName) {
        $script:FileName = $today
        foreach ($p in Read-HistoryPoints (Get-Date).AddHours(-24)) { $script:Points.Add($p) }
        $script:FileOffset = if (Test-Path -LiteralPath $today) { (Get-Item -LiteralPath $today).Length } else { 0 }
        $script:PointsVersion++
    }
    elseif ($script:FileName -ne $today) { $script:FileName = $today; $script:FileOffset = 0 }

    if (-not (Test-Path -LiteralPath $today)) { return }
    $length = (Get-Item -LiteralPath $today).Length
    if ($length -le $script:FileOffset) { return }
    $stream = [System.IO.FileStream]::new($today, 'Open', 'Read', 'ReadWrite')
    try {
        [void]$stream.Seek($script:FileOffset, 'Begin')
        $text = [System.IO.StreamReader]::new($stream).ReadToEnd()
    }
    finally { $stream.Dispose() }
    $script:FileOffset = $length
    $new = ConvertFrom-PointLines ($text -split "`n")
    foreach ($p in $new) { $script:Points.Add($p) }
    if ($new.Count -gt 0) { $script:PointsVersion++ }
    Remove-OldPoints
}

function Remove-OldPoints {
    $limit = ConvertTo-Unix (Get-Date).AddHours(-24)
    $old = 0
    while ($old -lt $script:Points.Count -and $script:Points[$old].t -lt $limit) { $old++ }
    if ($old -gt 0) { $script:Points.RemoveRange(0, $old) }
}

# Ajoute un relevé à la fenêtre en cours ; toutes les 30 s, en fait un point (moyennes) et l'écrit.
function Add-ToWindow($Sample) {
    $w = $script:Window
    # Fenêtre périmée (fenêtre réduite, pause, appel MCP isolé) : on repart de zéro.
    if ($w -and ($Sample.At - $w.Last).TotalSeconds -gt 20) { $w = $null }
    if (-not $w) {
        $w = @{ Start = $Sample.At; Last = $Sample.At; N = 0; Sums = @{}; Counts = @{}; Max = @{}; Procs = @{}; ProcSamples = 0 }
        $script:Window = $w
    }
    $w.Last = $Sample.At
    $w.N++
    foreach ($key in 'Cpu', 'Mem', 'Swap', 'Commit', 'DiskBusy', 'DiskRead', 'DiskWrite', 'DiskLatency', 'DiskQueue', 'NetRx', 'NetTx', 'Pages', 'CpuQueue', 'PsiCpu', 'PsiMem', 'PsiMemFull', 'PsiIo', 'PsiIoFull') {
        $v = $Sample.$key
        if ($null -eq $v) { continue }
        $w.Sums[$key] = $w.Sums[$key] + [double]$v
        $w.Counts[$key] = $w.Counts[$key] + 1
        if ($null -eq $w.Max[$key] -or $v -gt $w.Max[$key]) { $w.Max[$key] = [double]$v }
    }
    if ($Sample.Link) { $w.Link = $Sample.Link }
    if ($Sample.Groups) {
        $w.ProcSamples++
        # Les 12 plus gourmands en CPU et les 6 plus gros en mémoire de ce relevé (Heaviest).
        foreach ($g in $Sample.Groups) {
            $e = $w.Procs[$g.Name]
            if (-not $e) { $e = @{ Cpu = 0.0; CpuMax = 0.0; Mem = 0.0; N = 0 }; $w.Procs[$g.Name] = $e }
            $e.Cpu += $g.Cpu; $e.Mem += $g.Memory; $e.N++
            if ($g.Cpu -gt $e.CpuMax) { $e.CpuMax = $g.Cpu }
        }
    }

    $span = ($w.Last - $w.Start).TotalSeconds
    if ($span -lt $script:PointSeconds - 1) { return }
    $script:Window = $null
    if ($w.N -lt 3) { return }

    Sync-History
    $last = if ($script:Points.Count) { $script:Points[$script:Points.Count - 1].t } else { 0 }
    $t = ConvertTo-Unix ([DateTime]::SpecifyKind($w.Last, 'Utc'))
    if ($t - $last -lt 25) { $script:IsWriter = $false; return }   # un autre processus SysInfo vient d'écrire ce point

    $avg = { param($k) if ($w.Counts[$k]) { [Math]::Round($w.Sums[$k] / $w.Counts[$k], 2) } else { $null } }
    $point = [ordered]@{ t = $t; cpu = & $avg 'Cpu'; cpuMax = $w.Max['Cpu']; mem = & $avg 'Mem'; swap = & $avg 'Swap'; commit = & $avg 'Commit'
        disk = & $avg 'DiskBusy'; diskMax = $w.Max['DiskBusy']; rd = & $avg 'DiskRead'; wr = & $avg 'DiskWrite'; lat = & $avg 'DiskLatency'
        rx = & $avg 'NetRx'; tx = & $avg 'NetTx'; link = $w.Link; pages = & $avg 'Pages'
        psiCpu = & $avg 'PsiCpu'; psiMem = & $avg 'PsiMem'; psiIo = & $avg 'PsiIo' }
    if ($w.Link -and ($null -ne $point.rx)) { $point.net = [Math]::Round(800 * [Math]::Max($point.rx, $point.tx) / $w.Link, 2) }
    # Processus : moyenne sur la fenêtre (absent d'un relevé = 0 %), les 5 premiers en CPU et les 3 premiers en mémoire.
    $procs = foreach ($name in $w.Procs.Keys) {
        $e = $w.Procs[$name]
        [PSCustomObject]@{ Name = $name; Cpu = [Math]::Round($e.Cpu / $w.ProcSamples, 1); CpuMax = $e.CpuMax; Mem = [Math]::Round($e.Mem / $e.N / 1MB) }
    }
    if ($procs) {
        $top = @($procs | Sort-Object Cpu -Descending | Select-Object -First 5) + @($procs | Sort-Object Mem -Descending | Select-Object -First 3)
        $point.top = @($top | Sort-Object Name -Unique | ForEach-Object { , @($_.Name, $_.Cpu, $_.CpuMax, $_.Mem) })
    }

    $line = $point | ConvertTo-Json -Compress -Depth 4
    try {
        [void][System.IO.Directory]::CreateDirectory($script:HistoryDir)
        [System.IO.File]::AppendAllText($script:FileName, $line + "`n")
        $script:FileOffset = (Get-Item -LiteralPath $script:FileName).Length
        $script:WriteError = $null
        $script:IsWriter = $true
        Remove-ExpiredFiles
    }
    catch { $script:WriteError = $_.Exception.Message }
    $script:Points.Add(($line | ConvertFrom-Json))
    $script:PointsVersion++
    Remove-OldPoints
}

# Fichiers d'historique de plus de 7 jours (une fois par heure).
function Remove-ExpiredFiles {
    [void](Get-Cached 'cleanup' 3600 {
        $limit = (Get-Date).Date.AddDays(-$script:RetentionDays)
        Get-ChildItem -LiteralPath $script:HistoryDir -Filter 'performance-*.jsonl' -File -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Name -match '^performance-(\d{4}-\d{2}-\d{2})\.jsonl$' -and [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', $null) -lt $limit) {
                Remove-Item -LiteralPath $_.FullName -ErrorAction SilentlyContinue
            }
            elseif ($_.Name -match '^performance-alerts-(\d{4}-\d{2})\.jsonl$' -and [datetime]::ParseExact($Matches[1], 'yyyy-MM', $null) -lt (Get-Date).AddMonths(-3)) {
                Remove-Item -LiteralPath $_.FullName -ErrorAction SilentlyContinue
            }
        }
        $true
    })
}

# Points regroupés par intervalles réguliers sur une période : moyenne par intervalle, $null s'il n'y a aucun point
# (SysInfo fermé : un trou dans la courbe). $Property : champ du point, multiplié par $Scale ; un champ …Max donne le maximum.
function Get-Buckets($Points, [datetime]$Since, [int]$BucketSeconds, [string]$Property, [double]$Scale = 1) {
    $from = ConvertTo-Unix $Since
    $count = [Math]::Ceiling(((ConvertTo-Unix (Get-Date)) - $from) / $BucketSeconds)
    $sums = [double[]]::new($count); $n = [int[]]::new($count)
    $peak = $Property.EndsWith('Max')   # pics : maximum de l'intervalle, pas la moyenne
    foreach ($p in $Points) {
        $i = [int][Math]::Floor(($p.t - $from) / $BucketSeconds)
        if ($i -lt 0 -or $i -ge $count) { continue }
        $v = $p.$Property
        if ($null -eq $v) { continue }
        if ($peak) { if ($v -gt $sums[$i]) { $sums[$i] = $v }; $n[$i] = 1 } else { $sums[$i] += $v; $n[$i]++ }
    }
    for ($i = 0; $i -lt $count; $i++) {
        [PSCustomObject]@{ T = $from + ($i + 1) * $BucketSeconds; V = if ($n[$i]) { [Math]::Round($sums[$i] / $n[$i] * $Scale, 2) } else { $null } }
    }
}

# Section Metric d'historique : une ou deux séries regroupées par intervalles (contrat §4.3, History).
# Une série = @('libellé', 'champ', échelle).
function New-HistoryMetric([string]$Title, [string]$Icon, $Points, [datetime]$Since, [int]$BucketSeconds, [string]$Unit, $Max,
    [object[]]$Series, [object[]]$Series2, [string]$Detail) {
    $first = @(Get-Buckets $Points $Since $BucketSeconds $Series[1] ($Series[2] ?? 1))
    $second = if ($Series2) { @(Get-Buckets $Points $Since $BucketSeconds $Series2[1] ($Series2[2] ?? 1)) } else { $null }
    $rows = for ($i = 0; $i -lt $first.Count; $i++) {
        if ($second) { , @($first[$i].T, $first[$i].V, $second[$i].V) } else { , @($first[$i].T, $first[$i].V) }
    }
    $lastValue = ($first | Where-Object { $null -ne $_.V } | Select-Object -Last 1).V
    $section = [ordered]@{
        Title = $Title; Type = 'Metric'; Icon = $Icon; Unit = $Unit; Label = $Series[0]; Value = $lastValue
        History = [PSCustomObject]@{ Window = [Math]::Round(((Get-Date) - $Since).TotalSeconds); Points = @($rows) }
    }
    if ($null -ne $Max) { $section.Max = $Max }
    if ($Detail) { $section.Detail = $Detail }
    if ($second) { $section.Secondary = [PSCustomObject]@{ Label = $Series2[0]; Value = ($second | Where-Object { $null -ne $_.V } | Select-Object -Last 1).V } }
    [PSCustomObject]$section
}

$script:ToMbit = 8 / 1e6
$script:ToMiB = 1 / 1MB

# Processus les plus gourmands sur une période, d'après les points (5 premiers en CPU et 3 en mémoire de chaque point).
function Get-TopConsumers($Points) {
    $stats = @{}
    $total = 0
    foreach ($p in $Points) {
        if (-not $p.top) { continue }
        $total++
        foreach ($e in $p.top) {
            $s = $stats[$e[0]]
            if (-not $s) { $s = @{ Cpu = 0.0; CpuMax = 0.0; Mem = 0.0; MemMax = 0.0; N = 0 }; $stats[$e[0]] = $s }
            $s.Cpu += $e[1]; $s.Mem += $e[3]; $s.N++
            if ($e[2] -gt $s.CpuMax) { $s.CpuMax = $e[2] }
            if ($e[3] -gt $s.MemMax) { $s.MemMax = $e[3] }
        }
    }
    foreach ($name in $stats.Keys) {
        $s = $stats[$name]
        [PSCustomObject]@{
            Name = $name
            Cpu = [Math]::Round($s.Cpu / [Math]::Max(1, $total), 1)      # moyenne sur toute la période
            CpuMax = [Math]::Round($s.CpuMax, 1)
            Mem = [Math]::Round($s.Mem / $s.N)
            MemMax = $s.MemMax
            Minutes = $s.N * $script:PointSeconds / 60
        }
    }
}

#endregion

#region Seuils d'alerte

# Mesures surveillables : libellé, unité, borne max du seuil, sens (Below : alerte sous le seuil), lecture dans un point.
$script:Metrics = [ordered]@{
    cpu         = @{ Label = 'Processeur'; Unit = '%'; Max = 100; Value = { param($p) $p.cpu } }
    memory      = @{ Label = 'Mémoire'; Unit = '%'; Max = 100; Value = { param($p) $p.mem } }
    swap        = @{ Label = "Swap / fichier d'échange"; Unit = '%'; Max = 100; Value = { param($p) $p.swap } }
    commit      = @{ Label = 'Mémoire engagée'; Unit = '%'; Max = 200; Value = { param($p) $p.commit } }
    disk        = @{ Label = 'Activité disque'; Unit = '%'; Max = 100; Value = { param($p) $p.disk } }
    diskLatency = @{ Label = 'Latence disque'; Unit = 'ms'; Max = 10000; Value = { param($p) $p.lat } }
    network     = @{ Label = 'Réseau (part du lien)'; Unit = '%'; Max = 100; Value = { param($p) $p.net } }
    diskFree    = @{ Label = 'Espace libre (volume le plus plein)'; Unit = '%'; Max = 100; Below = $true; Value = $null }
}

$script:DefaultRules = [ordered]@{
    cpu         = @{ threshold = 90; minutes = 5; severity = 'warning'; enabled = $true }
    memory      = @{ threshold = 90; minutes = 5; severity = 'warning'; enabled = $true }
    swap        = @{ threshold = 80; minutes = 10; severity = 'warning'; enabled = $false }
    commit      = @{ threshold = 90; minutes = 5; severity = 'warning'; enabled = $true }
    disk        = @{ threshold = 90; minutes = 5; severity = 'warning'; enabled = $true }
    diskLatency = @{ threshold = 50; minutes = 5; severity = 'warning'; enabled = $false }
    network     = @{ threshold = 80; minutes = 5; severity = 'warning'; enabled = $false }
    diskFree    = @{ threshold = 10; minutes = 0; severity = 'warning'; enabled = $true }
}

# Seuils : valeurs par défaut, remplacées par celles du fichier (relu quand il change).
function Get-Rules {
    $stamp = if (Test-Path -LiteralPath $script:RulesFile) { (Get-Item -LiteralPath $script:RulesFile).LastWriteTimeUtc } else { $null }
    if ($script:RulesCache -and $script:RulesStamp -eq $stamp) { return $script:RulesCache }
    $saved = if ($stamp) { try { Get-Content -LiteralPath $script:RulesFile -Raw | ConvertFrom-Json -AsHashtable } catch { @{} } } else { @{} }
    $rules = [ordered]@{}
    foreach ($key in $script:DefaultRules.Keys) {
        $rule = @{} + $script:DefaultRules[$key]
        if ($saved[$key]) { foreach ($k in 'threshold', 'minutes', 'severity', 'enabled') { if ($saved[$key].ContainsKey($k)) { $rule[$k] = $saved[$key][$k] } } }
        $rules[$key] = $rule
    }
    $script:RulesCache = $rules; $script:RulesStamp = $stamp
    $rules
}

# Volume local le plus plein (relu toutes les 60 s) : % libre, nom.
function Get-FullestVolume {
    Get-Cached 'volumes' 60 {
        $seen = @{}
        $drives = foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
            try {
                if ($d.DriveType -ne 'Fixed' -or -not $d.IsReady -or $d.TotalSize -lt 1GB) { continue }
                if ($d.Name -match '^/(snap|var/lib/snapd|run|sys|proc|dev|boot/efi)(/|$)' -or $d.DriveFormat -in 'squashfs', 'tmpfs', 'overlay') { continue }
                $key = '{0}/{1}' -f $d.TotalSize, $d.AvailableFreeSpace
                if ($seen[$key]) { continue }   # même système de fichiers monté plusieurs fois (sous-volumes Btrfs)
                $seen[$key] = $true
                [PSCustomObject]@{ Name = $d.Name; Free = 100 * $d.AvailableFreeSpace / $d.TotalSize; FreeBytes = $d.AvailableFreeSpace }
            }
            catch { }
        }
        $drives | Sort-Object Free | Select-Object -First 1
    }
}

# État de chaque seuil : valeur moyenne sur sa durée (d'après les points), active ou non.
function Get-RuleStates($Points) {
    $rules = Get-Rules
    $now = ConvertTo-Unix (Get-Date)
    foreach ($key in $rules.Keys) {
        $rule = $rules[$key]; $metric = $script:Metrics[$key]
        $value = $null; $covered = $false
        if ($key -eq 'diskFree') {
            $volume = Get-FullestVolume
            if ($volume) { $value = [Math]::Round($volume.Free, 1); $covered = $true }
        }
        else {
            $minutes = [Math]::Max(1, $rule.minutes)
            # Points récents seulement, en partant de la fin (la liste couvre 24 h).
            $values = [System.Collections.Generic.List[double]]::new()
            for ($i = $Points.Count - 1; $i -ge 0 -and $Points[$i].t -gt $now - $minutes * 60; $i--) {
                $v = & $metric.Value $Points[$i]
                if ($null -ne $v) { $values.Add($v) }
            }
            # Il faut des mesures sur au moins 80 % de la durée (SysInfo vient de démarrer : pas encore d'alerte).
            $covered = $values.Count -ge [Math]::Max(1, [Math]::Floor($minutes * 60 / $script:PointSeconds * 0.8))
            if ($values.Count) { $value = [Math]::Round([System.Linq.Enumerable]::Average($values), 1) }
        }
        $active = $rule.enabled -and $covered -and $null -ne $value -and $(if ($metric.Below) { $value -le $rule.threshold } else { $value -ge $rule.threshold })
        [PSCustomObject]@{ Key = $key; Label = $metric.Label; Unit = $metric.Unit; Below = [bool]$metric.Below; Rule = $rule; Value = $value; Covered = $covered; Active = $active
            Available = $null -ne $value -or $key -notin 'commit', 'swap', 'network' }
    }
}

function Get-AlertFile { Join-Path $script:HistoryDir ('performance-alerts-{0:yyyy-MM}.jsonl' -f (Get-Date)) }

# Début et fin des alertes, journalisés par le processus qui écrit l'historique.
$script:ActiveAlerts = $null
function Update-AlertLog($States) {
    if (-not $script:IsWriter) { return }
    if ($null -eq $script:ActiveAlerts) {
        # Au démarrage : alertes restées ouvertes dans le journal (SysInfo fermé pendant l'alerte) = toujours en cours.
        $script:ActiveAlerts = @{}
        foreach ($e in Read-AlertEvents 2) { if ($e.state -eq 'start') { $script:ActiveAlerts[$e.metric] = @{ Peak = $e.value } } else { $script:ActiveAlerts.Remove($e.metric) } }
    }
    $lines = foreach ($s in $States) {
        $open = $script:ActiveAlerts[$s.Key]
        if ($s.Active -and -not $open) {
            $script:ActiveAlerts[$s.Key] = @{ Peak = $s.Value }
            [ordered]@{ t = ConvertTo-Unix (Get-Date); metric = $s.Key; state = 'start'; value = $s.Value; threshold = $s.Rule.threshold; minutes = $s.Rule.minutes; severity = $s.Rule.severity } | ConvertTo-Json -Compress
        }
        # Fin : seuil désactivé, ou valeur revenue en deçà (même sur une durée encore incomplète : seuil modifié).
        elseif ($open -and -not $s.Active -and (-not $s.Rule.enabled -or $null -ne $s.Value)) {
            $script:ActiveAlerts.Remove($s.Key)
            [ordered]@{ t = ConvertTo-Unix (Get-Date); metric = $s.Key; state = 'end'; value = $open.Peak } | ConvertTo-Json -Compress
        }
        elseif ($open -and $null -ne $s.Value) {
            if ($(if ($s.Below) { $s.Value -lt $open.Peak } else { $s.Value -gt $open.Peak })) { $open.Peak = $s.Value }
        }
    }
    if ($lines) {
        try { [System.IO.File]::AppendAllText((Get-AlertFile), (($lines -join "`n") + "`n")) } catch { }
        $script:Cache.Remove('alertEvents')
    }
}

function Read-AlertEvents([int]$Days) {
    $since = ConvertTo-Unix (Get-Date).AddDays(-$Days)
    $files = foreach ($m in 0..([Math]::Ceiling($Days / 28) + 1)) { Join-Path $script:HistoryDir ('performance-alerts-{0:yyyy-MM}.jsonl' -f (Get-Date).AddMonths(-$m)) }
    $events = foreach ($f in ($files | Sort-Object -Unique)) { if (Test-Path -LiteralPath $f) { ConvertFrom-PointLines ([System.IO.File]::ReadAllLines($f)) } }
    @($events | Where-Object { $_.t -ge $since } | Sort-Object t)
}

# Événements → alertes (début, fin, pic), les plus récentes d'abord.
function Get-AlertHistory([int]$Days) {
    $open = @{}
    $alerts = foreach ($e in Read-AlertEvents $Days) {
        if ($e.state -eq 'start') { $open[$e.metric] = $e; continue }
        $start = $open[$e.metric]
        if (-not $start) { continue }
        $open.Remove($e.metric)
        [PSCustomObject]@{ Metric = $e.metric; Start = ConvertFrom-Unix $start.t; End = ConvertFrom-Unix $e.t; Peak = $e.value; Threshold = $start.threshold; Severity = $start.severity }
    }
    $current = foreach ($start in $open.Values) {
        [PSCustomObject]@{ Metric = $start.metric; Start = ConvertFrom-Unix $start.t; End = $null; Peak = $start.value; Threshold = $start.threshold; Severity = $start.severity }
    }
    @(@($alerts) + @($current) | Sort-Object Start -Descending)
}

function Get-AlertTable($Alerts, [string]$Title) {
    $rows = foreach ($a in $Alerts) {
        $m = $script:Metrics[$a.Metric]
        $duration = if ($a.End) { Format-Minutes ($a.End - $a.Start).TotalMinutes } else { 'en cours' }
        , @((Format-Time $a.Start), $duration, $m.Label, $(if ($null -ne $a.Peak) { [double]$a.Peak } else { $null }), $m.Unit, "$($a.Threshold)", $(if ($a.Severity -eq 'critical') { 'Critique' } else { 'Attention' }))
    }
    [PSCustomObject]@{ Title = $Title; Type = 'Table'; Icon = 'warning'; Columns = @('Début', 'Durée', 'Mesure', 'Pic', 'Unité', 'Seuil', 'Gravité'); Rows = @($rows) }
}

function Get-RuleTable($States) {
    $rows = foreach ($s in $States) {
        $r = $s.Rule
        $state = if (-not $r.enabled) { 'Désactivé' } elseif ($s.Active) { 'En alerte' } elseif ($null -eq $s.Value -and $s.Key -in 'commit', 'swap', 'network') { 'Sans objet' } elseif (-not $s.Covered) { 'Mesures insuffisantes' } else { 'Normal' }
        $threshold = '{0} {1}' -f $(if ($s.Below) { '≤' } else { '≥' }), (Format-Unit $r.threshold $s.Unit '0.#')
        , @($s.Key, $s.Label, $threshold, $(if ($s.Key -eq 'diskFree') { 'immédiat' } else { Format-Minutes $r.minutes }), $(if ($r.severity -eq 'critical') { 'Critique' } else { 'Attention' }), $s.Value, $state)
    }
    [PSCustomObject]@{ Title = "Seuils d'alerte"; Type = 'Table'; Icon = 'settings'; Columns = @('Clé', 'Mesure', 'Seuil', 'Pendant', 'Gravité', 'Actuel (moyenne)', 'État'); Rows = @($rows) }
}

function Get-AlertFindings($States) {
    foreach ($s in $States | Where-Object Active) {
        $r = $s.Rule
        $code = 'PERF-ALERT-' + ($s.Key -creplace '([a-z])([A-Z])', '$1-$2').ToUpperInvariant()
        $message = if ($s.Key -eq 'diskFree') {
            '{0} : {1} libres seulement (seuil {2})' -f (Get-FullestVolume).Name, (Format-Unit $s.Value '%' '0.#'), (Format-Unit $r.threshold '%' '0')
        } else {
            '{0} à {1} en moyenne sur {2} (seuil {3})' -f $s.Label, (Format-Unit $s.Value $s.Unit '0.#'), (Format-Minutes $r.minutes), (Format-Unit $r.threshold $s.Unit '0.#')
        }
        $advice = switch ($s.Key) {
            'cpu' { 'Voir les processus les plus gourmands (tableau ci-dessous, system_get_processes).' }
            { $_ -in 'memory', 'commit', 'swap' } { 'Fermer les applications inutiles ou ajouter de la mémoire ; voir les processus les plus gros en mémoire.' }
            { $_ -in 'disk', 'diskLatency' } { "Chercher le processus qui lit ou écrit le plus (system_get_processes, tri io) ; un disque dur lent ou usé se voit dans l'onglet Stockage." }
            'network' { 'Un transfert sature la connexion : voir les connexions actives (onglet Réseau).' }
            'diskFree' { "Libérer de l'espace (maintenance_cleanup, storage_analyze_space)." }
        }
        New-Finding $r.severity $code $message $advice
    }
}

#endregion

#region Goulots d'étranglement

# Diagnostic sur la fenêtre en cours (moyennes des dernières secondes) : ce qui limite la machine maintenant.
function Get-Bottlenecks($Avg) {
    $cores = [Environment]::ProcessorCount
    $rows = [System.Collections.Generic.List[object]]::new()
    $found = [System.Collections.Generic.List[string]]::new()

    $cpuPressure = if ($null -ne $Avg.PsiCpu) { 'PSI {0}' -f (Format-Unit $Avg.PsiCpu '%' '0.#') } elseif ($null -ne $Avg.CpuQueue) { 'file {0} threads' -f [Math]::Round($Avg.CpuQueue) } else { '—' }
    $cpuBusy = $Avg.Cpu -ge 90 -or $Avg.PsiCpu -ge 40 -or ($null -ne $Avg.CpuQueue -and $Avg.CpuQueue -ge 2 * $cores)
    $rows.Add(@('Processeur', $(if ($null -ne $Avg.Cpu) { Format-Unit $Avg.Cpu '%' '0' } else { '—' }), $cpuPressure, $(if ($cpuBusy) { 'Saturé : des tâches attendent le processeur' } else { 'OK' })))
    if ($cpuBusy) { $found.Add('cpu') }

    $memPressure = @()
    if ($null -ne $Avg.PsiMem) { $memPressure += 'PSI {0}' -f (Format-Unit $Avg.PsiMem '%' '0.#') }
    if ($null -ne $Avg.Pages) { $memPressure += $(if ($IsWindows) { '{0} pages/s' } else { 'swap {0} pages/s' }) -f [Math]::Round($Avg.Pages) }
    $memBusy = $Avg.Mem -ge 92 -or $Avg.PsiMem -ge 10 -or $Avg.PsiMemFull -ge 5 -or $Avg.Commit -ge 95 -or (-not $IsWindows -and $Avg.Pages -ge 1000)
    $rows.Add(@('Mémoire', $(if ($null -ne $Avg.Mem) { Format-Unit $Avg.Mem '%' '0' } else { '—' }), $(if ($memPressure) { $memPressure -join ' · ' } else { '—' }), $(if ($memBusy) { 'Sous pression : le système libère ou échange de la mémoire' } else { 'OK' })))
    if ($memBusy) { $found.Add('memory') }

    $diskPressure = @()
    if ($null -ne $Avg.PsiIo) { $diskPressure += 'PSI {0}' -f (Format-Unit $Avg.PsiIo '%' '0.#') }
    if ($null -ne $Avg.DiskLatency) { $diskPressure += 'latence {0}' -f (Format-Unit $Avg.DiskLatency 'ms' '0.#') }
    if ($null -ne $Avg.DiskQueue) { $diskPressure += 'file {0}' -f $Avg.DiskQueue.ToString('0.#', $script:Fr) }
    $diskBusy = ($Avg.DiskBusy -ge 90 -and ($Avg.DiskLatency -ge 20 -or $Avg.DiskQueue -ge 2 -or $Avg.PsiIoFull -ge 10)) -or $Avg.PsiIoFull -ge 25
    $rows.Add(@('Disque', $(if ($null -ne $Avg.DiskBusy) { Format-Unit $Avg.DiskBusy '%' '0' } else { '—' }), $(if ($diskPressure) { $diskPressure -join ' · ' } else { '—' }), $(if ($diskBusy) { 'Saturé : les lectures et écritures attendent' } else { 'OK' })))
    if ($diskBusy) { $found.Add('disk') }

    $netShare = if ($Avg.Link -and $null -ne $Avg.NetRx) { 800 * [Math]::Max($Avg.NetRx, $Avg.NetTx) / $Avg.Link } else { $null }
    $netBusy = $netShare -ge 85
    $rows.Add(@('Réseau', $(if ($null -ne $netShare) { '{0} du lien' -f (Format-Unit $netShare '%' '0') } else { '—' }), $(if ($Avg.Link) { 'lien {0}' -f (Format-Bits $Avg.Link) } else { '—' }), $(if ($netBusy) { 'Saturé : la connexion est à son maximum' } else { 'OK' })))
    if ($netBusy) { $found.Add('network') }

    [PSCustomObject]@{ Rows = $rows; Found = $found }
}

#endregion

#region Vue d'ensemble

$script:HistorySections = $null; $script:HistoryVersion = -1; $script:HistoryAt = [datetime]::MinValue
$script:States = @(); $script:StatesVersion = -1; $script:StatesAt = [datetime]::MinValue; $script:RuleTable = $null
$script:Info = $null; $script:InfoVersion = -1

# Moyennes de la fenêtre en cours (ou du dernier relevé si elle vient de commencer).
function Get-WindowAverages($Sample) {
    $w = $script:Window
    $avg = @{}
    foreach ($key in 'Cpu', 'Mem', 'Swap', 'Commit', 'DiskBusy', 'DiskLatency', 'DiskQueue', 'NetRx', 'NetTx', 'Pages', 'CpuQueue', 'PsiCpu', 'PsiMem', 'PsiMemFull', 'PsiIo', 'PsiIoFull') {
        $avg[$key] = if ($w -and $w.Counts[$key]) { $w.Sums[$key] / $w.Counts[$key] } else { $Sample.$key }
    }
    $avg.Link = $Sample.Link
    [PSCustomObject]$avg
}

function Get-ModuleData {
    $sections = [System.Collections.Generic.List[object]]::new()
    $findings = [System.Collections.Generic.List[object]]::new()
    $errors = [ordered]@{}
    function Invoke-Block([string]$Name, [scriptblock]$Block) {
        try { & $Block } catch { $errors[$Name] = $_.Exception.Message; $null }
    }

    $sample = Get-LiveSample
    if ($null -eq $sample.Cpu) {
        # Premier appel : un second relevé 250 ms plus tard donne les pourcentages.
        Start-Sleep -Milliseconds 250
        $sample = Get-LiveSample
    }
    [void](Invoke-Block 'Historique' { Sync-History })
    [void](Invoke-Block 'Historique' { Add-ToWindow $sample })
    $avg = Get-WindowAverages $sample

    # Charge en direct
    $memText = if ($sample.MemTotal) { '{0} utilisés sur {1}' -f (Format-Bytes ($sample.MemTotal - $sample.MemAvailable)), (Format-Bytes $sample.MemTotal) } else { $null }
    if ($null -ne $sample.Swap) { $memText += ' · swap {0}' -f (Format-Unit $sample.Swap '%' '0') }
    if ($null -ne $sample.Commit) { $memText += ' · engagée {0}' -f (Format-Unit $sample.Commit '%' '0') }
    $cpuText = '{0} threads' -f [Environment]::ProcessorCount
    if ($null -ne $sample.PsiCpu) { $cpuText += ' · attente {0}' -f (Format-Unit $sample.PsiCpu '%' '0.#') }
    elseif ($null -ne $sample.CpuQueue) { $cpuText += ' · file {0}' -f [Math]::Round($sample.CpuQueue) }
    $diskText = @()
    if ($null -ne $sample.DiskLatency) { $diskText += 'latence {0}' -f (Format-Unit $sample.DiskLatency 'ms' '0.##') }
    if ($null -ne $sample.DiskQueue) { $diskText += "file d'attente {0}" -f $sample.DiskQueue.ToString('0.##', $script:Fr) }

    $sections.Add([PSCustomObject]@{ Title = 'Processeur'; Type = 'Metric'; Icon = 'developer_board'; Value = $sample.Cpu; Unit = '%'; Max = 100; Warning = 75; Critical = 90; Detail = $cpuText })
    $sections.Add([PSCustomObject]@{ Title = 'Mémoire'; Type = 'Metric'; Icon = 'ram'; Value = $sample.Mem; Unit = '%'; Max = 100; Warning = 80; Critical = 92; Detail = $memText })
    $sections.Add([PSCustomObject]@{ Title = 'Activité disque'; Type = 'Metric'; Icon = 'hard_drive'; Value = $sample.DiskBusy; Unit = '%'; Max = 100; Warning = 80; Critical = 95; Detail = $(if ($diskText) { $diskText -join ' · ' } else { 'disque le plus occupé' }) })
    $sections.Add([PSCustomObject]@{
            Title = 'Débit disque'; Type = 'Metric'; Icon = 'arrow_swap'; Unit = 'MiB/s'; Label = 'Lecture'
            Value = if ($null -ne $sample.DiskRead) { [Math]::Round($sample.DiskRead / 1MB, 2) } else { $null }
            Secondary = [PSCustomObject]@{ Label = 'Écriture'; Value = if ($null -ne $sample.DiskWrite) { [Math]::Round($sample.DiskWrite / 1MB, 2) } else { $null } }
            Detail = 'Tous les disques physiques'
        })
    $sections.Add([PSCustomObject]@{
            Title = 'Réseau'; Type = 'Metric'; Icon = 'globe'; Unit = 'Mbit/s'; Label = 'Réception'
            Value = if ($null -ne $sample.NetRx) { [Math]::Round($sample.NetRx * 8 / 1e6, 2) } else { $null }
            Secondary = [PSCustomObject]@{ Label = 'Émission'; Value = if ($null -ne $sample.NetTx) { [Math]::Round($sample.NetTx * 8 / 1e6, 2) } else { $null } }
            Detail = if ($sample.Link) { 'Interfaces physiques · lien {0}' -f (Format-Bits $sample.Link) } else { 'Interfaces physiques' }
        })

    # Goulots d'étranglement (moyennes des dernières secondes)
    $bottlenecks = Get-Bottlenecks $avg
    $sections.Add([PSCustomObject]@{ Title = "Goulots d'étranglement"; Type = 'Table'; Icon = 'pulse'; Columns = @('Ressource', 'Utilisation', 'Attente', 'Diagnostic'); Rows = @($bottlenecks.Rows) })

    # Seuils d'alerte (d'après les points de l'historique) : réévalués à chaque nouveau point ou toutes les 30 s.
    if ($script:StatesVersion -ne $script:PointsVersion -or ((Get-Date) - $script:StatesAt).TotalSeconds -ge 30) {
        $script:States = @(Invoke-Block 'Alertes' { Get-RuleStates $script:Points })
        [void](Invoke-Block 'Alertes' { Update-AlertLog $script:States })
        $script:StatesVersion = $script:PointsVersion; $script:StatesAt = Get-Date
        $script:RuleTable = Get-RuleTable $script:States
    }
    $states = $script:States
    foreach ($f in Get-AlertFindings $states) { $findings.Add($f) }
    $alerting = @($states | Where-Object Active | ForEach-Object Key)
    $messages = @{
        cpu = 'Le processeur est saturé : des tâches attendent pour s''exécuter.'
        memory = 'La mémoire est sous pression : le système libère des caches ou utilise le swap, tout ralentit.'
        disk = 'Le disque est saturé : les lectures et écritures attendent.'
        network = 'La connexion réseau est utilisée au maximum de son débit.'
    }
    foreach ($key in $bottlenecks.Found) {
        if ($key -in $alerting -or ($key -eq 'memory' -and ($alerting -contains 'commit' -or $alerting -contains 'swap'))) { continue }
        $findings.Add((New-Finding 'warning' ('PERF-BOTTLENECK-' + $key.ToUpperInvariant()) $messages[$key] 'Voir les processus les plus gourmands ci-dessous et dans system_get_processes.'))
    }

    # Historique : sections recalculées au plus toutes les 5 min, quand des points sont arrivés (~100 ms pour 24 h).
    if (-not $script:HistorySections -or ($script:HistoryVersion -ne $script:PointsVersion -and ((Get-Date) - $script:HistoryAt).TotalSeconds -ge 300)) {
        $script:HistoryAt = Get-Date
        $script:HistorySections = Invoke-Block 'Historique' {
            $since = (Get-Date).AddHours(-24)
            $bucket = 900
            $list = [System.Collections.Generic.List[object]]::new()
            $list.Add((New-HistoryMetric 'Processeur et mémoire · 24 h' 'timer' $script:Points $since $bucket '%' 100 @('Processeur', 'cpu') @('Mémoire', 'mem') 'Moyennes par quart d''heure'))
            $list.Add((New-HistoryMetric 'Activité disque · 24 h' 'hard_drive' $script:Points $since $bucket '%' 100 @('Activité', 'disk') $null 'Moyennes par quart d''heure, disque le plus occupé'))
            $list.Add((New-HistoryMetric 'Réseau · 24 h' 'globe' $script:Points $since $bucket 'Mbit/s' $null @('Réception', 'rx', $script:ToMbit) @('Émission', 'tx', $script:ToMbit) 'Moyennes par quart d''heure'))

            $hour = ConvertTo-Unix (Get-Date).AddHours(-1)
            $recent = @($script:Points | Where-Object { $_.t -ge $hour })
            $top = @(Get-TopConsumers $recent | Sort-Object Cpu -Descending | Select-Object -First 15)
            $list.Add([PSCustomObject]@{
                    Title = 'Processus les plus gourmands · 1 h'; Type = 'Table'; Icon = 'apps_list'
                    Columns = @('Processus', 'CPU moyen %', 'CPU max %', 'Mémoire moyenne (MiB)', 'Mémoire max (MiB)', 'Présence (min)')
                    Rows = @($top | ForEach-Object { , @($_.Name, $_.Cpu, $_.CpuMax, $_.Mem, $_.MemMax, [Math]::Round($_.Minutes, 1)) })
                })
            $list
        }
        $script:HistoryVersion = $script:PointsVersion
    }
    foreach ($s in @($script:HistorySections)) { if ($s) { $sections.Add($s) } }

    $sections.Add($script:RuleTable)
    $recentAlerts = Get-Cached 'alertEvents' 60 { @(Get-AlertHistory 7) }
    if ($recentAlerts.Count) { $sections.Add((Get-AlertTable ($recentAlerts | Select-Object -First 50) 'Alertes des 7 derniers jours')) }

    # État de l'historique (à chaque nouveau point)
    if ($script:InfoVersion -ne $script:PointsVersion) { $script:InfoVersion = $script:PointsVersion; $script:Info = Invoke-Block 'Historique' {
        $since = (Get-Date).AddHours(-24)
        $count = @($script:Points | Where-Object { $_.t -ge (ConvertTo-Unix $since) }).Count
        $coverage = 100 * $count * $script:PointSeconds / 86400
        $files = @(Get-ChildItem -LiteralPath $script:HistoryDir -Filter 'performance-*.jsonl' -File -ErrorAction SilentlyContinue)
        $first = $files | Where-Object Name -match '^performance-\d{4}-\d{2}-\d{2}\.jsonl$' | Sort-Object Name | Select-Object -First 1
        [ordered]@{
            'Enregistrement' = "1 point toutes les $($script:PointSeconds) s (moyennes), conservé $($script:RetentionDays) jours, pendant que SysInfo tourne"
            'Ce processus' = if ($script:IsWriter) { 'enregistre' } elseif ($script:Points.Count) { "relit l'historique (un autre processus SysInfo enregistre)" } else { 'en attente des premières mesures' }
            'Plus ancien jour' = if ($first) { [datetime]::ParseExact($first.Name.Substring(12, 10), 'yyyy-MM-dd', $null).ToString('dddd d MMMM', $script:Fr) } else { '—' }
            'Couverture des 24 h' = Format-Unit ([Math]::Min(100, $coverage)) '%' '0'
            'Taille' = Format-Bytes (($files | Measure-Object Length -Sum).Sum)
            'Dossier' = $script:HistoryDir
        }
    } }
    $info = if ($script:Info) { [ordered]@{} + $script:Info } else { $null }
    if ($script:WriteError) { $info['Erreur'] = $script:WriteError; $findings.Add((New-Finding 'info' 'PERF-HISTORY-WRITE' "L'historique n'a pas pu être écrit : $($script:WriteError)" $null)) }
    if ($info) { $sections.Add([PSCustomObject]@{ Title = 'Historique'; Type = 'KeyValue'; Icon = 'info'; Items = $info }) }

    if ($errors.Count) { $sections.Add([PSCustomObject]@{ Title = 'Erreurs de collecte'; Type = 'KeyValue'; Icon = 'error_circle'; Items = $errors }) }

    $busy = @($bottlenecks.Found | ForEach-Object { @{ cpu = 'processeur'; memory = 'mémoire'; disk = 'disque'; network = 'réseau' }[$_] })
    $parts = @()
    if ($null -ne $sample.Cpu) { $parts += 'CPU {0}' -f (Format-Unit $sample.Cpu '%' '0') }
    if ($null -ne $sample.Mem) { $parts += 'mémoire {0}' -f (Format-Unit $sample.Mem '%' '0') }
    if ($null -ne $sample.DiskBusy) { $parts += 'disque {0}' -f (Format-Unit $sample.DiskBusy '%' '0') }
    $parts += if ($busy) { 'goulot : ' + ($busy -join ', ') } else { 'aucun goulot' }

    [PSCustomObject]@{ Subtitle = $parts -join ' · '; Sections = $sections.ToArray(); Findings = $findings.ToArray() }
}

#endregion

#region Fonctions ciblées

$script:Periods = @{ '1h' = @{ Hours = 1; Bucket = 60; Label = '1 h' }; '6h' = @{ Hours = 6; Bucket = 300; Label = '6 h' }
    '24h' = @{ Hours = 24; Bucket = 900; Label = '24 h' }; '7d' = @{ Hours = 168; Bucket = 7200; Label = '7 jours' } }

function Get-Stats($Points, [string]$Property, [double]$Scale = 1) {
    $values = [System.Collections.Generic.List[double]]::new()
    $max = [double]::MinValue; $maxAt = 0
    foreach ($p in $Points) {
        $v = $p.$Property
        if ($null -eq $v) { continue }
        $v = [double]$v * $Scale
        $values.Add($v)
        if ($v -gt $max) { $max = $v; $maxAt = $p.t }
    }
    if (-not $values.Count) { return $null }
    $average = [System.Linq.Enumerable]::Average($values)
    $values.Sort()
    [PSCustomObject]@{ Avg = $average; P95 = $values[[int][Math]::Floor(($values.Count - 1) * 0.95)]; Max = $max; MaxAt = ConvertFrom-Unix $maxAt; Count = $values.Count }
}

# performance_get_history : historique enregistré sur une période, regroupé par intervalles, avec statistiques.
function Get-SIPerformanceHistory {
    param(
        [ValidateSet('1h', '6h', '24h', '7d')][string]$Period = '24h',
        [ValidateSet('all', 'cpu', 'memory', 'disk', 'network')][string]$Metric = 'all'
    )
    $p = $script:Periods[$Period]
    $since = (Get-Date).AddHours(-$p.Hours)
    $points = Read-HistoryPoints $since
    $label = $p.Label
    $per = switch ($p.Bucket) { 60 { 'par minute' } 300 { 'par 5 min' } 900 { "par quart d'heure" } default { 'par 2 h' } }
    $sections = [System.Collections.Generic.List[object]]::new()
    if ($Metric -in 'all', 'cpu') { $sections.Add((New-HistoryMetric "Processeur · $label" 'developer_board' $points $since $p.Bucket '%' 100 @('Moyenne', 'cpu') @('Pic', 'cpuMax') "Moyennes $per")) }
    if ($Metric -in 'all', 'memory') { $sections.Add((New-HistoryMetric "Mémoire · $label" 'ram' $points $since $p.Bucket '%' 100 @('Mémoire', 'mem') @('Swap', 'swap') "Moyennes $per")) }
    if ($Metric -in 'all', 'disk') {
        $sections.Add((New-HistoryMetric "Activité disque · $label" 'hard_drive' $points $since $p.Bucket '%' 100 @('Activité', 'disk') $null "Moyennes $per"))
        $sections.Add((New-HistoryMetric "Débit disque · $label" 'arrow_swap' $points $since $p.Bucket 'MiB/s' $null @('Lecture', 'rd', $script:ToMiB) @('Écriture', 'wr', $script:ToMiB) "Moyennes $per"))
    }
    if ($Metric -in 'all', 'network') { $sections.Add((New-HistoryMetric "Réseau · $label" 'globe' $points $since $p.Bucket 'Mbit/s' $null @('Réception', 'rx', $script:ToMbit) @('Émission', 'tx', $script:ToMbit) "Moyennes $per")) }

    $measures = [ordered]@{
        cpu = @(, @('Processeur', '%', 'cpu'))
        memory = @(@('Mémoire', '%', 'mem'), @('Swap', '%', 'swap'), @('Mémoire engagée', '%', 'commit'))
        disk = @(@('Activité disque', '%', 'disk'), @('Latence disque', 'ms', 'lat'), @('Lecture disque', 'MiB/s', 'rd', $script:ToMiB), @('Écriture disque', 'MiB/s', 'wr', $script:ToMiB))
        network = @(@('Réception', 'Mbit/s', 'rx', $script:ToMbit), @('Émission', 'Mbit/s', 'tx', $script:ToMbit))
    }
    $rows = foreach ($key in $measures.Keys) {
        if ($Metric -ne 'all' -and $Metric -ne $key) { continue }
        foreach ($m in $measures[$key]) {
            $s = Get-Stats $points $m[2] ($m[3] ?? 1)
            if ($s) { , @($m[0], $m[1], [Math]::Round($s.Avg, 2), [Math]::Round($s.P95, 2), [Math]::Round($s.Max, 2), (Format-Time $s.MaxAt)) }
        }
    }
    $sections.Add([PSCustomObject]@{ Title = 'Statistiques'; Type = 'Table'; Icon = 'pulse'; Columns = @('Mesure', 'Unité', 'Moyenne', '95e centile', 'Maximum', 'Heure du maximum'); Rows = @($rows) })

    $coverage = [Math]::Min(100, 100 * $points.Count * $script:PointSeconds / ($p.Hours * 3600))
    $findings = @()
    if ($points.Count -eq 0) { $findings += New-Finding 'info' 'PERF-HISTORY-EMPTY' "Aucune mesure enregistrée sur $label : l'historique n'est enregistré que pendant que SysInfo est ouvert." $null }
    elseif ($coverage -lt 50) { $findings += New-Finding 'info' 'PERF-HISTORY-PARTIAL' ("Mesures sur {0} de la période seulement (SysInfo fermé le reste du temps) : les trous de la courbe sont sans mesure." -f (Format-Unit $coverage '%' '0')) $null }
    [PSCustomObject]@{ Subtitle = '{0} points sur {1} · couverture {2}' -f $points.Count, $label, (Format-Unit $coverage '%' '0'); Sections = $sections.ToArray(); Findings = $findings }
}

# performance_get_top_consumers : processus qui ont le plus consommé sur une période (d'après l'historique).
function Get-SIPerformanceTopConsumers {
    param(
        [ValidateSet('1h', '6h', '24h', '7d')][string]$Period = '24h',
        [ValidateRange(1, 100)][int]$Top = 15,
        [ValidateSet('cpu', 'memory')][string]$SortBy = 'cpu'
    )
    $p = $script:Periods[$Period]
    $points = Read-HistoryPoints (Get-Date).AddHours(-$p.Hours)
    $all = @(Get-TopConsumers $points)
    $sorted = if ($SortBy -eq 'memory') { $all | Sort-Object Mem -Descending } else { $all | Sort-Object Cpu -Descending }
    $rows = @($sorted | Select-Object -First $Top | ForEach-Object { , @($_.Name, $_.Cpu, $_.CpuMax, $_.Mem, $_.MemMax, [Math]::Round($_.Minutes, 1)) })
    $findings = @()
    if (-not $points.Count) { $findings += New-Finding 'info' 'PERF-HISTORY-EMPTY' "Aucune mesure enregistrée sur $($p.Label) : l'historique n'est enregistré que pendant que SysInfo est ouvert." $null }
    $heavy = $all | Where-Object { $_.Cpu -ge 25 } | Sort-Object Cpu -Descending | Select-Object -First 3
    foreach ($h in $heavy) {
        $findings += New-Finding 'warning' 'PERF-PROCESS-HEAVY' ('{0} a utilisé {1} du processeur en moyenne sur {2} (pics à {3}).' -f $h.Name, (Format-Unit $h.Cpu '%' '0'), $p.Label, (Format-Unit $h.CpuMax '%' '0')) 'Vérifier si ce programme doit tourner en permanence (system_get_processes, software_list).'
    }
    [PSCustomObject]@{
        Subtitle = '{0} processus sur {1} · {2} points' -f $all.Count, $p.Label, $points.Count
        Sections = @(
            [PSCustomObject]@{ Title = "Processus les plus gourmands · $($p.Label)"; Type = 'Table'; Icon = 'apps_list'
                Columns = @('Processus', 'CPU moyen %', 'CPU max %', 'Mémoire moyenne (MiB)', 'Mémoire max (MiB)', 'Présence (min)'); Rows = $rows }
            [PSCustomObject]@{ Title = 'Méthode'; Type = 'KeyValue'; Icon = 'info'; Items = [ordered]@{
                    'Relevé' = "Toutes les $($script:PointSeconds) s : les 5 processus les plus gourmands en CPU et les 3 plus gros en mémoire (regroupés par nom)"
                    'CPU moyen' = 'Part de toute la machine, moyenne sur la période mesurée (absent du relevé = 0 %)'
                    'Présence' = 'Temps pendant lequel le processus était parmi les plus gourmands' } }
        )
        Findings = $findings
    }
}

# performance_get_alerts : seuils, alertes en cours et alertes passées.
function Get-SIPerformanceAlerts {
    param([ValidateRange(1, 90)][int]$Days = 7)
    $points = Read-HistoryPoints (Get-Date).AddHours(-24)
    $states = @(Get-RuleStates $points)
    $alerts = @(Get-AlertHistory $Days)
    $findings = @(Get-AlertFindings $states)
    [PSCustomObject]@{
        Subtitle = '{0} alerte(s) en cours · {1} sur {2} jours' -f @($states | Where-Object Active).Count, $alerts.Count, $Days
        Sections = @((Get-RuleTable $states), (Get-AlertTable $alerts "Alertes des $Days derniers jours"))
        Findings = $findings
    }
}

# performance_set_alert : modifie un seuil d'alerte (fichier state/performance-alerts.json de l'utilisateur).
function Set-SIPerformanceAlert {
    param(
        [Parameter(Mandatory)][ValidateSet('cpu', 'memory', 'swap', 'commit', 'disk', 'diskLatency', 'network', 'diskFree')][string]$Metric,
        [double]$Threshold = [double]::NaN,
        [ValidateRange(0, 1440)][int]$Minutes = -1,
        [ValidateSet('warning', 'critical')][string]$Severity,
        [Nullable[bool]]$Enabled,
        [switch]$DryRun
    )
    $rules = Get-Rules
    $before = @{} + $rules[$Metric]
    $after = @{} + $before
    $m = $script:Metrics[$Metric]
    $blocked = $null
    if (-not [double]::IsNaN($Threshold)) {
        if ($Threshold -le 0 -or $Threshold -gt $m.Max) { $blocked = "Seuil hors limites pour $($m.Label) : entre 0 et $($m.Max) $($m.Unit)." }
        $after.threshold = $Threshold
    }
    if ($Minutes -ge 0) { $after.minutes = $(if ($Metric -eq 'diskFree') { 0 } else { [Math]::Max(1, $Minutes) }) }
    if ($Severity) { $after.severity = $Severity }
    if ($null -ne $Enabled) { $after.enabled = [bool]$Enabled }

    $describe = { param($r) '{0} {1} pendant {2}, {3}, {4}' -f $(if ($m.Below) { '≤' } else { '≥' }), (Format-Unit $r.threshold $m.Unit '0.#'), (Format-Minutes $r.minutes), $(if ($r.severity -eq 'critical') { 'critique' } else { 'attention' }), $(if ($r.enabled) { 'actif' } else { 'désactivé' }) }
    $changes = foreach ($k in 'threshold', 'minutes', 'severity', 'enabled') {
        if ("$($before[$k])" -ne "$($after[$k])") { New-Change $m.Label @{ threshold = 'Seuil'; minutes = 'Durée (min)'; severity = 'Gravité'; enabled = 'Actif' }[$k] $before[$k] $after[$k] }
    }
    if (-not $blocked -and -not $changes) { $blocked = "Le seuil $($m.Label) est déjà réglé ainsi : $(& $describe $before)." }
    $section = [PSCustomObject]@{ Title = "Seuil : $($m.Label)"; Type = 'KeyValue'; Icon = 'settings'; Items = [ordered]@{ 'Actuel' = & $describe $before; 'Nouveau' = & $describe $after; 'Fichier' = $script:RulesFile } }
    $undo = @{ Function = 'set_alert'; Parameters = @{ metric = $Metric; threshold = [double]$before.threshold; minutes = [int]$before.minutes; severity = $before.severity; enabled = [bool]$before.enabled } }
    if ($DryRun -or $blocked) { return New-ActionResult "Seuil d'alerte $($m.Label) : $(& $describe $after)" @($section) @() @($changes) $blocked $null }

    $saved = if (Test-Path -LiteralPath $script:RulesFile) { try { Get-Content -LiteralPath $script:RulesFile -Raw | ConvertFrom-Json -AsHashtable } catch { @{} } } else { @{} }
    $saved[$Metric] = $after
    [void][System.IO.Directory]::CreateDirectory((Split-Path $script:RulesFile))
    $saved | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:RulesFile -Encoding utf8
    $script:RulesCache = $null
    New-ActionResult "Seuil d'alerte $($m.Label) : $(& $describe $after)" @($section) @() @($changes) $null $undo
}

# performance_benchmark_disk : écrit puis relit un fichier de test (séquentiel), puis lectures aléatoires de 4 KiB.
function Measure-SIDiskPerformance {
    param(
        [string]$Path,
        [ValidateRange(64, 8192)][int]$SizeMiB = 1024,
        [switch]$DryRun
    )
    if (-not $Path) { $Path = [Environment]::GetFolderPath('UserProfile') }
    $blocked = $null; $drive = $null
    $full = try { [System.IO.Path]::GetFullPath($Path) } catch { $null }
    if (-not $full -or -not (Test-Path -LiteralPath $full -PathType Container)) { $blocked = "Dossier introuvable : $Path." }
    else {
        $drive = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and $full.StartsWith($_.Name, [StringComparison]::OrdinalIgnoreCase) } | Sort-Object { $_.Name.Length } -Descending | Select-Object -First 1
    }
    $size = [long]$SizeMiB * 1MB
    if (-not $blocked -and -not ('SysInfo.Native.DiskBenchmark' -as [type])) { $blocked = "Le mini-benchmark n'est disponible que dans SysInfo (classe de l'application)." }
    if (-not $blocked -and $drive -and $drive.AvailableFreeSpace -lt $size + [Math]::Max(2GB, 0.05 * $drive.TotalSize)) {
        $blocked = 'Pas assez de place sur {0} : {1} libres pour un fichier de {2} (plus une marge).' -f $drive.Name, (Format-Bytes $drive.AvailableFreeSpace), (Format-Bytes $size)
    }
    $file = if ($full) { Join-Path $full ('.sysinfo-benchmark-{0}.tmp' -f [guid]::NewGuid().ToString('N').Substring(0, 8)) } else { $null }
    if (-not $blocked) {
        try { [System.IO.File]::WriteAllBytes("$file.probe", [byte[]]::new(1)); [System.IO.File]::Delete("$file.probe") }
        catch { $blocked = "Écriture impossible dans $full : $($_.Exception.Message)" }
    }

    $items = [ordered]@{ 'Dossier' = $full ?? $Path; 'Volume' = if ($drive) { '{0} ({1}, {2} libres)' -f $drive.Name, $drive.DriveFormat, (Format-Bytes $drive.AvailableFreeSpace) } else { '—' }; 'Fichier de test' = Format-Bytes $size; 'Lectures aléatoires' = '2 000 × 4 KiB' }
    $findings = @(
        New-Finding 'info' 'PERF-BENCH-WRITE' ("Le test écrit {0} sur le disque puis supprime le fichier : usure négligeable, mais le disque est très occupé pendant le test (résultats faussés si d'autres programmes l'utilisent)." -f (Format-Bytes $size)) $null
    )
    $change = New-Change ($file ?? $Path) 'Fichier de test' 'absent' ('{0} écrit puis supprimé' -f (Format-Bytes $size))
    if ($DryRun -or $blocked) { return New-ActionResult ('Mini-benchmark de {0} ({1})' -f ($drive.Name ?? $Path), (Format-Bytes $size)) @([PSCustomObject]@{ Title = 'Test'; Type = 'KeyValue'; Icon = 'hard_drive'; Items = $items }) $findings @($change) $blocked $null }

    Write-Information "Mini-benchmark : $file ($(Format-Bytes $size))"
    $bench = [SysInfo.Native.DiskBenchmark]::new($file, $size)
    try {
        while ($bench.WriteNext()) { Write-Progress -Activity 'Écriture séquentielle' -Status ('{0} %' -f [Math]::Round($bench.Percent)) -PercentComplete ([Math]::Round($bench.Percent / 3)) }
        Write-Information ('Écriture : {0}' -f (Format-Rate $bench.WriteBytesPerSecond))
        while ($bench.ReadNext()) { Write-Progress -Activity 'Lecture séquentielle' -Status ('{0} %' -f [Math]::Round($bench.Percent)) -PercentComplete ([Math]::Round(33 + $bench.Percent / 3)) }
        Write-Information ('Lecture : {0}' -f (Format-Rate $bench.ReadBytesPerSecond))
        while ($bench.RandomNext(100, 2000)) { Write-Progress -Activity 'Lectures aléatoires 4 KiB' -Status ('{0} %' -f [Math]::Round($bench.Percent)) -PercentComplete ([Math]::Round(66 + $bench.Percent / 3)) }
        Write-Progress -Activity 'Lectures aléatoires 4 KiB' -Completed
        $result = [PSCustomObject]@{ Write = $bench.WriteBytesPerSecond; Read = $bench.ReadBytesPerSecond; Avg = $bench.RandomAverageMs; P95 = $bench.RandomP95Ms; Iops = $bench.RandomIops }
    }
    finally { $bench.Dispose() }

    $items['Écriture séquentielle'] = Format-Rate $result.Write
    $items['Lecture séquentielle'] = Format-Rate $result.Read
    $items['Lecture aléatoire 4 KiB'] = '{0} en moyenne · {1} au 95e centile · {2} IOPS' -f (Format-Unit $result.Avg 'ms' '0.###'), (Format-Unit $result.P95 'ms' '0.###'), [Math]::Round($result.Iops).ToString('#,##0', $script:Fr)
    # Repères : SSD NVMe > 1 500 MiB/s et < 0,2 ms ; SSD SATA ~500 MiB/s ; disque dur 100–200 MiB/s et 5–15 ms.
    $kind = if ($result.Avg -lt 0.3 -and $result.Read -gt 1000MB) { 'SSD NVMe' } elseif ($result.Avg -lt 1) { 'SSD' } elseif ($result.Avg -lt 25) { 'disque dur' } else { 'support lent (USB, réseau ou disque en difficulté)' }
    $items['Profil'] = "comparable à un $kind"
    $after = @()
    if ($result.Read -lt 50MB -or $result.Avg -gt 30) {
        $after += New-Finding 'warning' 'PERF-DISK-SLOW' ('Disque lent : {0} en lecture, {1} par accès aléatoire.' -f (Format-Rate $result.Read), (Format-Unit $result.Avg 'ms' '0.#')) "Vérifier l'état SMART du disque (onglet Stockage) ; un disque dur ou un support USB est normalement lent."
    }
    $change = New-Change $file 'Fichier de test' 'absent' 'écrit, relu puis supprimé'
    New-ActionResult ('{0} : lecture {1}, écriture {2}' -f $drive.Name, (Format-Rate $result.Read), (Format-Rate $result.Write)) @([PSCustomObject]@{ Title = 'Résultats'; Type = 'KeyValue'; Icon = 'top_speed'; Items = $items }) $after @($change) $null $null
}

#endregion

Export-ModuleMember -Function Get-ModuleData, Get-SIPerformanceHistory, Get-SIPerformanceTopConsumers, Get-SIPerformanceAlerts, Set-SIPerformanceAlert, Measure-SIDiskPerformance
