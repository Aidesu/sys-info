# Module Rapports : score de santé par domaine, diagnostic global (tous les constats de tous les modules), instantanés
# de l'état de la machine et comparaison avant / après, historique (score, constats, espace libre, température),
# exports (HTML, Markdown, JSON, CSV), rapport client (HTML imprimable, logo Justware), anonymisation.
#
# Sources : les autres modules, par [SysInfo.Host.ModuleHost] (mêmes données que leurs pages et que le MCP, lectures
# seulement) ; seul dans pwsh, le module importe les autres lui-même. Journal d'audit (actions faites, rapport client).
# Fichiers : instantanés dans ~/.local/share/SysInfo/snapshots (Windows : %LOCALAPPDATA%\SysInfo\snapshots),
# historique dans …/history/reports-AAAA-MM.jsonl, exports dans Documents/SysInfo/Exports (jamais écrasés).
# Logo du rapport client : Documents/SysInfo/logo.png (ou .svg, .jpg) s'il existe.

$script:Fr = [cultureinfo]::GetCultureInfo('fr-FR')
$script:Nbsp = [char]0x00A0
$script:SelfId = 'reports'
$script:Aggregators = @('reports', 'diagnose', 'inventory')
$script:ModulesRoot = Split-Path $PSScriptRoot
$script:DataRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'SysInfo'
$script:SnapshotDir = Join-Path $script:DataRoot 'snapshots'
$script:HistoryDir = Join-Path $script:DataRoot 'history'

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

function Format-Date($Date) {
    if (-not $Date) { return '—' }
    ([datetime]$Date).ToString('ddd d MMM yyyy HH:mm', $script:Fr)
}

function New-Finding([string]$Severity, [string]$Code, [string]$Message, [string]$Recommendation) {
    [PSCustomObject]@{ Severity = $Severity; Code = $Code; Message = $Message; Recommendation = $Recommendation }
}

function New-Change([string]$Target, [string]$Property, $Before, $After) {
    [PSCustomObject]@{ Target = $Target; Property = $Property; Before = $Before; After = $After }
}

# Propriété d'un objet renvoyé par un module (PSCustomObject ou hashtable).
function Get-Prop($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $Object.$Name
}

function Get-ExportDir { Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'SysInfo/Exports' }

#endregion

#region Accès aux autres modules

# Dans SysInfo : le pont de l'application (mêmes runspaces que les pages). Seul dans pwsh : import des modules.
function Get-Bridge { $t = 'SysInfo.Host.ModuleHost' -as [type]; if ($t -and $t::IsAvailable) { $t } else { $null } }

# Modules compatibles avec ce système : id → dossier, titre, ordre, fonctions.
function Get-Manifests {
    Get-Cached 'manifests' 3600 {
        $os = if ($IsWindows) { 'windows' } else { 'linux' }
        $map = [ordered]@{}
        foreach ($dir in Get-ChildItem -LiteralPath $script:ModulesRoot -Directory | Sort-Object Name) {
            $file = Join-Path $dir.FullName 'module.json'
            if (-not (Test-Path -LiteralPath $file)) { continue }
            $m = try { Get-Content -LiteralPath $file -Raw | ConvertFrom-Json } catch { continue }
            if (@($m.platforms) -notcontains $os) { continue }
            $map[$m.id] = [PSCustomObject]@{ Id = $m.id; Title = $m.title; Order = [int]$m.order; Dir = $dir.FullName; Name = $dir.Name; Manifest = $m }
        }
        $map
    }
}

$script:Imported = @{}
function Invoke-SIModule([string]$Module, [string]$Function, [hashtable]$Parameters = @{}, [int]$TimeoutSeconds = 60, [int]$MaxAgeSeconds = 0) {
    $bridge = Get-Bridge
    if ($bridge) { return $bridge::Invoke($script:SelfId, $Module, $Function, $Parameters, $TimeoutSeconds, $MaxAgeSeconds) }
    $info = (Get-Manifests)[$Module]
    if (-not $info) { throw "Module inconnu ou indisponible sur ce système : $Module." }
    $command = 'Get-ModuleData'
    if ($Function) {
        $fn = @($info.Manifest.functions) | Where-Object name -eq $Function | Select-Object -First 1
        if (-not $fn) { throw "Fonction inconnue : $($Module)_$Function." }
        if ($fn.level -ne 'L') { throw "$($Module)_$Function n'est pas une lecture." }
        $command = $fn.command
    }
    $mod = $script:Imported[$Module]
    if (-not $mod) {
        $mod = Import-Module (Join-Path $info.Dir "$($info.Name).psm1") -PassThru -Force -Prefix "Rpt$($info.Name)" -DisableNameChecking -ErrorAction Stop
        $script:Imported[$Module] = $mod
    }
    & $mod { param($c, $p) & $c @p } $command $Parameters
}

# Plusieurs appels (en parallèle dans SysInfo) : @{ Module; Function; Parameters } → @{ Module; Function; Data; Error; DurationMs }.
function Invoke-SIModules([object[]]$Requests, [int]$TimeoutSeconds = 60, [int]$MaxAgeSeconds = 0) {
    $bridge = Get-Bridge
    if ($bridge) { return @($bridge::InvokeMany($script:SelfId, $Requests, $TimeoutSeconds, $MaxAgeSeconds)) }
    foreach ($r in $Requests) {
        $start = Get-Date
        $result = @{ Module = $r.Module; Function = $r.Function; Data = $null; Error = $null }
        try { $result.Data = Invoke-SIModule $r.Module $r.Function ($r.Parameters ?? @{}) $TimeoutSeconds $MaxAgeSeconds } catch { $result.Error = $_.Exception.Message }
        $result.DurationMs = [Math]::Round(((Get-Date) - $start).TotalMilliseconds)
        $result
    }
}

# Vue d'ensemble de tous les modules (hors modules d'agrégation) ; $Fresh : relevé neuf, sinon celui des pages.
function Get-AllOverviews([switch]$Fresh) {
    $ids = @((Get-Manifests).Values | Where-Object { $_.Id -notin $script:Aggregators } | Sort-Object Order | ForEach-Object Id)
    $results = Invoke-SIModules @($ids | ForEach-Object { @{ Module = $_; Function = $null } }) 120 $(if ($Fresh) { 1 } else { 0 })
    $manifests = Get-Manifests
    foreach ($r in $results) {
        $data = Get-Prop $r 'Data'
        [PSCustomObject]@{
            Id = Get-Prop $r 'Module'; Title = $manifests[(Get-Prop $r 'Module')].Title; Error = Get-Prop $r 'Error'; DurationMs = Get-Prop $r 'DurationMs'
            Subtitle = Get-Prop $data 'Subtitle'; Sections = @(Get-Prop $data 'Sections'); Findings = @(Get-Prop $data 'Findings' | Where-Object { $_ })
        }
    }
}

#endregion

#region Score de santé

# Domaines du score : modules qui y comptent.
$script:Domains = [ordered]@{
    'Sécurité'                  = @('security', 'domain', 'tasks')
    'Stockage et sauvegarde'    = @('storage', 'backup', 'maintenance')
    'Performance'               = @('performance', 'sensors', 'system', 'boot')
    'Stabilité'                 = @('events', 'services', 'hardware', 'printing', 'virtualization')
    'Réseau'                    = @('network')
    'Logiciels et mises à jour' = @('software')
}
$script:Penalty = @{ critical = 20; warning = 8; info = 2 }

# Score 0–100 par domaine : 100 − points des constats (critique 20, attention 8, info 2, les infos comptent 10 au plus).
function Get-HealthScores($Overviews) {
    $scores = foreach ($domain in $script:Domains.Keys) {
        $found = @($Overviews | Where-Object { $_.Id -in $script:Domains[$domain] } | ForEach-Object { $_.Findings })
        $sev = @{ critical = 0; warning = 0; info = 0 }
        foreach ($f in $found) { $s = "$(Get-Prop $f 'Severity')".ToLower(); if ($sev.ContainsKey($s)) { $sev[$s]++ } }
        $lost = $sev.critical * 20 + $sev.warning * 8 + [Math]::Min(10, $sev.info * 2)
        $worst = $found | Sort-Object { @{ critical = 0; warning = 1; info = 2 }["$(Get-Prop $_ 'Severity')".ToLower()] } | Select-Object -First 1
        $modules = @($Overviews | Where-Object { $_.Id -in $script:Domains[$domain] })
        if (-not $modules.Count) { continue }
        [PSCustomObject]@{ Domain = $domain; Score = [Math]::Max(0, 100 - $lost); Critical = $sev.critical; Warning = $sev.warning; Info = $sev.info; Worst = $(if ($worst) { Get-Prop $worst 'Message' } else { $null }) }
    }
    $list = @($scores)
    [PSCustomObject]@{ Domains = $list; Global = if ($list.Count) { [Math]::Round(($list | Measure-Object Score -Average).Average) } else { $null } }
}

function Get-ScoreLabel([double]$Score) { if ($Score -ge 80) { 'bon' } elseif ($Score -ge 60) { 'moyen' } else { 'mauvais' } }

# Tous les constats, les plus graves d'abord : Severity, Module, Code, Message, Recommendation.
function Get-AllFindings($Overviews) {
    $order = @{ critical = 0; warning = 1; info = 2 }
    $all = foreach ($o in $Overviews) {
        foreach ($f in $o.Findings) {
            [PSCustomObject]@{ Severity = "$(Get-Prop $f 'Severity')".ToLower(); Module = $o.Title; ModuleId = $o.Id; Code = Get-Prop $f 'Code'; Message = Get-Prop $f 'Message'; Recommendation = Get-Prop $f 'Recommendation' }
        }
    }
    @($all | Sort-Object { $order[$_.Severity] }, Module, Code)
}

$script:SeverityText = @{ critical = 'Critique'; warning = 'Attention'; info = 'Info' }

#endregion

#region Historique

# Valeurs suivies dans le temps, lues dans les vues d'ensemble : espace libre du volume le plus plein (Stockage,
# section Usage), température du processeur (Capteurs, Metric « Températures »).
function Get-TrackedValues($Overviews) {
    $free = $null; $temp = $null
    $storage = $Overviews | Where-Object Id -eq 'storage' | Select-Object -First 1
    foreach ($s in @($storage.Sections | Where-Object { (Get-Prop $_ 'Type') -eq 'Usage' } | Select-Object -First 1)) {
        foreach ($i in @(Get-Prop $s 'Items')) {
            $v = Get-Prop $i 'Value'; $m = Get-Prop $i 'Max'
            if ($m -gt 0) { $pct = 100 * (1 - [double]$v / [double]$m); if ($null -eq $free -or $pct -lt $free) { $free = [Math]::Round($pct, 1) } }
        }
    }
    $sensors = $Overviews | Where-Object Id -eq 'sensors' | Select-Object -First 1
    $metric = @($sensors.Sections | Where-Object { (Get-Prop $_ 'Type') -eq 'Metric' -and (Get-Prop $_ 'Unit') -eq '°C' }) | Select-Object -First 1
    if ($metric) { $temp = Get-Prop $metric 'Value' }
    [PSCustomObject]@{ FreePct = $free; CpuTemp = $temp }
}

# Un point par heure au plus : scores, nombre de constats, espace libre, température.
function Add-HistoryPoint($Scores, $Findings, $Tracked) {
    $file = Join-Path $script:HistoryDir ('reports-{0:yyyy-MM}.jsonl' -f (Get-Date))
    $last = Get-Cached 'lastPoint' 3600 { if (Test-Path -LiteralPath $file) { try { ([System.IO.File]::ReadLines($file) | Select-Object -Last 1 | ConvertFrom-Json).t } catch { 0 } } else { 0 } }
    $now = [DateTimeOffset]::Now.ToUnixTimeSeconds()
    if ($now - [long]$last -lt 3500) { return }
    $point = [ordered]@{ t = $now; score = $Scores.Global; critical = @($Findings | Where-Object Severity -eq 'critical').Count; warning = @($Findings | Where-Object Severity -eq 'warning').Count
        free = $Tracked.FreePct; temp = $Tracked.CpuTemp; domains = [ordered]@{} }
    foreach ($d in $Scores.Domains) { $point.domains[$d.Domain] = $d.Score }
    try {
        [void][System.IO.Directory]::CreateDirectory($script:HistoryDir)
        [System.IO.File]::AppendAllText($file, ($point | ConvertTo-Json -Compress -Depth 4) + "`n")
        $script:Cache['lastPoint'] = @{ At = Get-Date; Value = $now }
    }
    catch { }
}

function Read-History([int]$Days) {
    $since = [DateTimeOffset]::Now.AddDays(-$Days).ToUnixTimeSeconds()
    $points = foreach ($m in 0..([Math]::Ceiling($Days / 28) + 1)) {
        $file = Join-Path $script:HistoryDir ('reports-{0:yyyy-MM}.jsonl' -f (Get-Date).AddMonths(-$m))
        if (Test-Path -LiteralPath $file) { foreach ($line in [System.IO.File]::ReadAllLines($file)) { try { $line | ConvertFrom-Json } catch { } } }
    }
    @($points | Where-Object { $_.t -ge $since } | Sort-Object t -Unique)
}

#endregion

#region Vue d'ensemble

function Get-ModuleData {
    $sections = [System.Collections.Generic.List[object]]::new()
    $findings = [System.Collections.Generic.List[object]]::new()

    $overviews = @(Get-AllOverviews)
    $all = Get-AllFindings $overviews
    $scores = Get-HealthScores $overviews
    $tracked = Get-TrackedValues $overviews
    Add-HistoryPoint $scores $all $tracked

    # Score et historique (30 jours)
    $history = Read-History 30
    $metric = [ordered]@{ Title = 'Score de santé'; Type = 'Metric'; Icon = 'checkmark_circle'; Value = $scores.Global; Unit = '/ 100'; Max = 100; Label = 'Score global'
        Detail = '{0} · {1} critique(s), {2} attention' -f (Get-ScoreLabel $scores.Global), @($all | Where-Object Severity -eq 'critical').Count, @($all | Where-Object Severity -eq 'warning').Count }
    if ($history.Count -ge 2) {
        $metric.History = [PSCustomObject]@{ Window = 30 * 86400; Points = @($history | ForEach-Object { , @($_.t, $_.score, $_.free) }) }
        $metric.Secondary = [PSCustomObject]@{ Label = 'Espace libre (volume le plus plein, %)'; Value = $tracked.FreePct }
    }
    $sections.Add([PSCustomObject]$metric)
    $sections.Add([PSCustomObject]@{ Title = 'Score par domaine'; Type = 'Table'; Icon = 'pulse'; Columns = @('Domaine', 'Score', 'Appréciation', 'Critiques', 'Attention', 'Infos', 'Problème principal')
            Rows = @($scores.Domains | ForEach-Object { , @($_.Domain, $_.Score, (Get-ScoreLabel $_.Score), $_.Critical, $_.Warning, $_.Info, $_.Worst) }) })

    $serious = @($all | Where-Object Severity -in 'critical', 'warning')
    $sections.Add([PSCustomObject]@{ Title = 'Constats les plus graves'; Type = 'Table'; Icon = 'warning'; Columns = @('Gravité', 'Module', 'Constat', 'Code')
            Rows = @($serious | Select-Object -First 30 | ForEach-Object { , @($script:SeverityText[$_.Severity], $_.Module, $_.Message, $_.Code) }) })

    if ($scores.Global -lt 40) { $findings.Add((New-Finding 'critical' 'RPT-SCORE-LOW' "Score de santé très bas : $($scores.Global) / 100." 'Traiter d''abord les constats critiques (tableau ci-dessus, reports_run_diagnostic).')) }
    elseif ($scores.Global -lt 60) { $findings.Add((New-Finding 'warning' 'RPT-SCORE-LOW' "Score de santé bas : $($scores.Global) / 100." 'Traiter les constats critiques et « Attention » (tableau ci-dessus).')) }
    foreach ($o in $overviews | Where-Object Error) { $findings.Add((New-Finding 'info' 'RPT-MODULE-ERROR' "Le module $($o.Title) n'a pas répondu : $($o.Error)" $null)) }

    # Instantanés et exports
    $snaps = @(Get-Snapshots)
    $items = [ordered]@{ 'Instantanés' = $snaps.Count; 'Dernier instantané' = if ($snaps.Count) { '{0}{1}' -f (Format-Date $snaps[0].Created), $(if ($snaps[0].Label) { " · $($snaps[0].Label)" }) } else { 'aucun' }
        'Dossier des instantanés' = $script:SnapshotDir; 'Dossier des exports' = Get-ExportDir; 'Historique' = '{0} point(s) sur 30 jours (un par heure au plus, pendant que SysInfo tourne)' -f $history.Count }
    if ($null -ne $tracked.CpuTemp) { $items['Température du processeur'] = Format-Unit $tracked.CpuTemp '°C' '0' }
    $sections.Add([PSCustomObject]@{ Title = 'Instantanés et exports'; Type = 'KeyValue'; Icon = 'arrow_download'; Items = $items })

    [PSCustomObject]@{
        Subtitle = 'score {0} / 100 ({1}) · {2} constat(s) critique(s), {3} attention · {4} module(s)' -f $scores.Global, (Get-ScoreLabel $scores.Global), @($all | Where-Object Severity -eq 'critical').Count, @($all | Where-Object Severity -eq 'warning').Count, $overviews.Count
        Sections = $sections.ToArray(); Findings = $findings.ToArray()
    }
}

#endregion

#region Instantanés

function Get-Snapshots {
    if (-not (Test-Path -LiteralPath $script:SnapshotDir)) { return @() }
    $list = foreach ($f in Get-ChildItem -LiteralPath $script:SnapshotDir -Filter 'snapshot-*.json.gz' -File) {
        if ($f.Name -notmatch '^snapshot-(\d{8}-\d{6})(?:-(.+))?\.json\.gz$') { continue }
        [PSCustomObject]@{ Id = $Matches[1]; Label = if ($Matches[2]) { $Matches[2] -replace '_', ' ' } else { $null }; Created = [datetime]::ParseExact($Matches[1], 'yyyyMMdd-HHmmss', $null); Path = $f.FullName; Size = $f.Length }
    }
    @($list | Sort-Object Created -Descending)
}

function Save-Json([string]$Path, $Object) {
    $json = $Object | ConvertTo-Json -Depth 12 -Compress
    $stream = [System.IO.File]::Create($Path)
    try { $gz = [System.IO.Compression.GZipStream]::new($stream, [System.IO.Compression.CompressionLevel]::Optimal); $w = [System.IO.StreamWriter]::new($gz); $w.Write($json); $w.Dispose() } finally { $stream.Dispose() }
}

function Read-Snapshot([string]$Path) {
    $stream = [System.IO.File]::OpenRead($Path)
    try { $gz = [System.IO.Compression.GZipStream]::new($stream, [System.IO.Compression.CompressionMode]::Decompress); $r = [System.IO.StreamReader]::new($gz); $r.ReadToEnd() | ConvertFrom-Json } finally { $stream.Dispose() }
}

# État à enregistrer : pour chaque module, sous-titre, sections (sans historiques de graphiques) et constats.
function ConvertTo-SnapshotState($Overviews) {
    $modules = [ordered]@{}
    foreach ($o in $Overviews | Where-Object { -not $_.Error }) {
        $sections = foreach ($s in $o.Sections) {
            $type = Get-Prop $s 'Type'
            $entry = [ordered]@{ Title = Get-Prop $s 'Title'; Type = $type }
            switch ($type) {
                'KeyValue' { $items = Get-Prop $s 'Items'; $entry.Items = [ordered]@{}; if ($items -is [System.Collections.IDictionary]) { foreach ($k in $items.Keys) { $entry.Items["$k"] = "$($items[$k])" } } else { foreach ($p in $items.PSObject.Properties) { $entry.Items[$p.Name] = "$($p.Value)" } } }
                'Table' { $entry.Columns = @(Get-Prop $s 'Columns'); $rows = @(Get-Prop $s 'Rows'); if ($rows.Count -and $rows[0] -isnot [array] -and $rows[0] -isnot [System.Collections.IList]) { $rows = , $rows }; $entry.Rows = @($rows | ForEach-Object { , @($_ | ForEach-Object { if ($null -eq $_) { $null } else { "$_" } }) }) }
                'Metric' { $entry.Value = Get-Prop $s 'Value'; $entry.Unit = Get-Prop $s 'Unit' }
                'Usage' { $entry.Items = @(@(Get-Prop $s 'Items') | ForEach-Object { [ordered]@{ Label = Get-Prop $_ 'Label'; Value = Get-Prop $_ 'Value'; Max = Get-Prop $_ 'Max'; Unit = Get-Prop $_ 'Unit' } }) }
            }
            $entry
        }
        $modules[$o.Id] = [ordered]@{ Title = $o.Title; Subtitle = $o.Subtitle; Sections = @($sections)
            Findings = @($o.Findings | ForEach-Object { [ordered]@{ Severity = "$(Get-Prop $_ 'Severity')".ToLower(); Code = Get-Prop $_ 'Code'; Message = Get-Prop $_ 'Message'; Recommendation = Get-Prop $_ 'Recommendation' } }) }
    }
    $modules
}

# reports_create_snapshot : enregistre l'état de la machine (toutes les vues d'ensemble) pour le comparer plus tard.
function New-SISnapshot {
    param([string]$Label)
    $Label = ($Label -replace '[^\w\s-]', '' -replace '\s+', '_').Trim('_')
    if ($Label.Length -gt 40) { $Label = $Label.Substring(0, 40) }
    Write-Information 'Relevé de tous les modules…'
    $overviews = @(Get-AllOverviews -Fresh)
    $scores = Get-HealthScores $overviews
    $state = [ordered]@{ Version = 1; Created = (Get-Date).ToString('o'); Label = $Label; Host = [Environment]::MachineName; User = [Environment]::UserName
        Os = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription; Score = $scores.Global; Modules = ConvertTo-SnapshotState $overviews }
    [void][System.IO.Directory]::CreateDirectory($script:SnapshotDir)
    $id = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $path = Join-Path $script:SnapshotDir ("snapshot-$id" + $(if ($Label) { "-$Label" } else { '' }) + '.json.gz')
    Save-Json $path $state
    $failed = @($overviews | Where-Object Error)
    [PSCustomObject]@{
        Subtitle = "Instantané $id enregistré ($($overviews.Count - $failed.Count) modules, score $($scores.Global) / 100)"
        Sections = @([PSCustomObject]@{ Title = 'Instantané'; Type = 'KeyValue'; Icon = 'arrow_download'; Items = [ordered]@{ 'Id' = $id; 'Libellé' = $Label ?? '—'; 'Fichier' = $path; 'Taille' = Format-Unit ((Get-Item -LiteralPath $path).Length / 1KB) 'Kio' '0'; 'Modules' = $overviews.Count - $failed.Count; 'Score' = $scores.Global } })
        Findings = @($failed | ForEach-Object { New-Finding 'info' 'RPT-MODULE-ERROR' "Le module $($_.Title) n'a pas répondu : $($_.Error)" $null })
    }
}

# reports_list_snapshots : instantanés enregistrés.
function Get-SISnapshots {
    $snaps = @(Get-Snapshots)
    [PSCustomObject]@{
        Subtitle = '{0} instantané(s)' -f $snaps.Count
        Sections = @([PSCustomObject]@{ Title = 'Instantanés'; Type = 'Table'; Icon = 'arrow_download'; Columns = @('Id', 'Date', 'Libellé', 'Taille (Kio)'); Rows = @($snaps | ForEach-Object { , @($_.Id, (Format-Date $_.Created), $_.Label, [Math]::Round($_.Size / 1KB)) }) })
        Findings = @()
    }
}

function Resolve-Snapshot([string]$Ref) {
    $snaps = @(Get-Snapshots)
    if (-not $snaps.Count) { throw 'Aucun instantané : en créer un avec reports_create_snapshot.' }
    if (-not $Ref -or $Ref -eq 'latest') { return $snaps[0] }
    if ($Ref -eq 'previous') { if ($snaps.Count -lt 2) { throw 'Un seul instantané enregistré.' }; return $snaps[1] }
    $s = $snaps | Where-Object { $_.Id -eq $Ref -or $_.Label -eq $Ref -or $_.Label -eq ($Ref -replace '_', ' ') } | Select-Object -First 1
    if (-not $s) { throw "Instantané introuvable : $Ref (reports_list_snapshots pour la liste)." }
    $s
}

# Modules dont les valeurs changent sans cesse (charge, débits, processus) : pas comparés ligne à ligne.
$script:Volatile = @('system', 'performance', 'sensors', 'network', 'audit')

# Différences entre deux états : constats apparus / disparus, valeurs modifiées, lignes ajoutées / retirées.
function Compare-States($Before, $After) {
    $beforeModules = $Before.Modules; $afterModules = $After.Modules
    $ids = @(@($beforeModules.PSObject.Properties.Name) + @(if ($afterModules -is [System.Collections.IDictionary]) { $afterModules.Keys } else { $afterModules.PSObject.Properties.Name }) | Sort-Object -Unique)
    $get = { param($set, $id) if ($set -is [System.Collections.IDictionary]) { $set[$id] } else { $set.$id } }
    $newFindings = [System.Collections.Generic.List[object]]::new(); $resolved = [System.Collections.Generic.List[object]]::new()
    $values = [System.Collections.Generic.List[object]]::new(); $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($id in $ids) {
        $b = & $get $beforeModules $id; $a = & $get $afterModules $id
        $title = (Get-Prop $a 'Title') ?? (Get-Prop $b 'Title') ?? $id
        $key = { param($f) "$(Get-Prop $f 'Code')|$(Get-Prop $f 'Message')" }
        $bf = @{}; foreach ($f in @(Get-Prop $b 'Findings')) { if ($f) { $bf[(& $key $f)] = $f } }
        $af = @{}; foreach ($f in @(Get-Prop $a 'Findings')) { if ($f) { $af[(& $key $f)] = $f } }
        # Même code, message différent (« 94 % » → « 95 % ») : pas un nouveau constat ; on compare donc par code d'abord.
        $bCodes = @($bf.Values | ForEach-Object { Get-Prop $_ 'Code' }); $aCodes = @($af.Values | ForEach-Object { Get-Prop $_ 'Code' })
        foreach ($k in $af.Keys) { if (-not $bf.ContainsKey($k) -and ($bCodes -notcontains (Get-Prop $af[$k] 'Code') -or $id -notin $script:Volatile)) { $f = $af[$k]; $newFindings.Add([PSCustomObject]@{ Module = $title; Severity = Get-Prop $f 'Severity'; Code = Get-Prop $f 'Code'; Message = Get-Prop $f 'Message'; Recommendation = Get-Prop $f 'Recommendation' }) } }
        foreach ($k in $bf.Keys) { if (-not $af.ContainsKey($k) -and ($aCodes -notcontains (Get-Prop $bf[$k] 'Code') -or $id -notin $script:Volatile)) { $f = $bf[$k]; $resolved.Add([PSCustomObject]@{ Module = $title; Severity = Get-Prop $f 'Severity'; Code = Get-Prop $f 'Code'; Message = Get-Prop $f 'Message' }) } }
        if ($id -in $script:Volatile -or -not $a -or -not $b) { continue }
        $bs = @{}; foreach ($s in @(Get-Prop $b 'Sections')) { $bs["$(Get-Prop $s 'Type')|$(Get-Prop $s 'Title')"] = $s }
        foreach ($s in @(Get-Prop $a 'Sections')) {
            $type = Get-Prop $s 'Type'; $stitle = Get-Prop $s 'Title'
            $old = $bs["$type|$stitle"]
            if (-not $old) { continue }
            if ($type -eq 'KeyValue') {
                $ai = Get-Prop $s 'Items'; $bi = Get-Prop $old 'Items'
                $names = if ($ai -is [System.Collections.IDictionary]) { @($ai.Keys) } else { @($ai.PSObject.Properties.Name) }
                foreach ($k in $names) {
                    $av = "$(Get-Prop $ai $k)"; $bv = "$(Get-Prop $bi $k)"
                    # Valeurs qui ne sont que des durées ou des dates relatives : ignorées.
                    if ($av -ne $bv -and $k -notmatch '(?i)depuis|uptime|en marche|dernier|derni[eè]re|prochaine|relevé|heure') { $values.Add([PSCustomObject]@{ Module = $title; Section = $stitle; Key = $k; Before = $bv; After = $av }) }
                }
            }
            elseif ($type -eq 'Table') {
                # Tableaux dont la 1re colonne est une date (prochaines exécutions, journaux) : leur contenu tourne, ignorés.
                # Tableaux numérotés (« Ordre », « Rang ») ou propres au processus qui lit (PATH) : pas comparables non plus.
                if ("$(@(Get-Prop $s 'Columns')[0])" -match '(?i)date|heure|début|prochaine|dernière|envoyé|ordre|rang|^n°$|^#$' -or $stitle -eq 'PATH') { continue }
                # Clé d'une ligne : 1re colonne, ou les deux premières quand la 1re se répète (« systemd | dnf-makecache »).
                $firstOnly = { param($t) $k = @(@(Get-Prop $t 'Rows') | ForEach-Object { "$(@($_)[0])" }); $k.Count -eq @($k | Select-Object -Unique).Count }
                $two = -not ((& $firstOnly $s) -and (& $firstOnly $old))
                $toKeys = { param($t) @(@(Get-Prop $t 'Rows') | ForEach-Object { $r = @($_); if ($two -and $r.Count -gt 1) { "$($r[0]) · $($r[1])" } else { "$($r[0])" } }) }
                $ak = & $toKeys $s; $bk = & $toKeys $old
                if ($ak.Count -gt 3000) { continue }
                $added = @($ak | Where-Object { $_ -notin $bk } | Select-Object -Unique); $removed = @($bk | Where-Object { $_ -notin $ak } | Select-Object -Unique)
                if ($added.Count -or $removed.Count) {
                    $rows.Add([PSCustomObject]@{ Module = $title; Table = $stitle; Before = $bk.Count; After = $ak.Count
                            Added = (($added | Select-Object -First 8) -join ', ') + $(if ($added.Count -gt 8) { " … (+$($added.Count - 8))" } else { '' })
                            Removed = (($removed | Select-Object -First 8) -join ', ') + $(if ($removed.Count -gt 8) { " … (+$($removed.Count - 8))" } else { '' }) })
                }
            }
        }
    }
    [PSCustomObject]@{ New = $newFindings; Resolved = $resolved; Values = $values; Rows = $rows }
}

# reports_compare : compare un instantané à un autre, ou à l'état actuel (avant / après intervention).
function Compare-SISnapshots {
    param([string]$From = 'latest', [string]$To = 'now')
    $fromSnap = Resolve-Snapshot $From
    $before = Read-Snapshot $fromSnap.Path
    if (-not $To -or $To -eq 'now') {
        $overviews = @(Get-AllOverviews -Fresh)
        $after = [PSCustomObject]@{ Created = (Get-Date).ToString('o'); Score = (Get-HealthScores $overviews).Global; Modules = ConvertTo-SnapshotState $overviews }
        $toLabel = 'maintenant'
    }
    else { $toSnap = Resolve-Snapshot $To; $after = Read-Snapshot $toSnap.Path; $toLabel = "$($toSnap.Id)$(if ($toSnap.Label) { " ($($toSnap.Label))" })" }
    $diff = Compare-States $before $after
    $sev = { param($s) $script:SeverityText["$s"] ?? "$s" }
    $findings = @()
    foreach ($f in $diff.New | Where-Object Severity -in 'critical', 'warning') { $findings += New-Finding 'warning' 'RPT-NEW-FINDING' "Nouveau depuis l'instantané : $($f.Message) ($($f.Module), $($f.Code))." $null }
    [PSCustomObject]@{
        Subtitle = 'Du {0}{1} à {2} : score {3} → {4} · {5} nouveau(x) constat(s), {6} résolu(s), {7} valeur(s) modifiée(s)' -f $fromSnap.Id, $(if ($fromSnap.Label) { " ($($fromSnap.Label))" }), $toLabel, $before.Score, $after.Score, $diff.New.Count, $diff.Resolved.Count, $diff.Values.Count
        Sections = @(
            [PSCustomObject]@{ Title = 'Score de santé'; Type = 'KeyValue'; Icon = 'checkmark_circle'; Items = [ordered]@{ 'Avant' = "$($before.Score) / 100 ($(Format-Date $before.Created))"; 'Après' = "$($after.Score) / 100 ($(Format-Date $after.Created))" } }
            [PSCustomObject]@{ Title = 'Constats résolus'; Type = 'Table'; Icon = 'checkmark_circle'; Columns = @('Module', 'Gravité', 'Constat', 'Code'); Rows = @($diff.Resolved | ForEach-Object { , @($_.Module, (& $sev $_.Severity), $_.Message, $_.Code) }) }
            [PSCustomObject]@{ Title = 'Nouveaux constats'; Type = 'Table'; Icon = 'warning'; Columns = @('Module', 'Gravité', 'Constat', 'Code'); Rows = @($diff.New | ForEach-Object { , @($_.Module, (& $sev $_.Severity), $_.Message, $_.Code) }) }
            [PSCustomObject]@{ Title = 'Valeurs modifiées'; Type = 'Table'; Icon = 'arrow_swap'; Columns = @('Module', 'Section', 'Élément', 'Avant', 'Après'); Rows = @($diff.Values | ForEach-Object { , @($_.Module, $_.Section, $_.Key, $_.Before, $_.After) }) }
            [PSCustomObject]@{ Title = 'Listes modifiées'; Type = 'Table'; Icon = 'apps_list'; Columns = @('Module', 'Liste', 'Avant', 'Après', 'Ajoutés', 'Retirés'); Rows = @($diff.Rows | ForEach-Object { , @($_.Module, $_.Table, $_.Before, $_.After, $_.Added, $_.Removed) }) }
        )
        Findings = $findings
    }
}

#endregion

#region Diagnostic global

# reports_run_diagnostic : relève tous les modules et renvoie tous leurs constats, les plus graves d'abord.
function Invoke-SIDiagnostic {
    param([ValidateSet('all', 'critical', 'warning')][string]$MinSeverity = 'all')
    Write-Information 'Relevé de tous les modules…'
    $overviews = @(Get-AllOverviews -Fresh)
    $all = Get-AllFindings $overviews
    if ($MinSeverity -eq 'critical') { $all = @($all | Where-Object Severity -eq 'critical') } elseif ($MinSeverity -eq 'warning') { $all = @($all | Where-Object Severity -in 'critical', 'warning') }
    $scores = Get-HealthScores $overviews
    [PSCustomObject]@{
        Subtitle = 'score {0} / 100 · {1} constat(s) sur {2} module(s)' -f $scores.Global, $all.Count, $overviews.Count
        Sections = @(
            [PSCustomObject]@{ Title = 'Score par domaine'; Type = 'Table'; Icon = 'pulse'; Columns = @('Domaine', 'Score', 'Critiques', 'Attention', 'Infos'); Rows = @($scores.Domains | ForEach-Object { , @($_.Domain, $_.Score, $_.Critical, $_.Warning, $_.Info) }) }
            [PSCustomObject]@{ Title = 'Constats'; Type = 'Table'; Icon = 'warning'; Columns = @('Gravité', 'Module', 'Constat', 'Recommandation', 'Code'); Rows = @($all | ForEach-Object { , @($script:SeverityText[$_.Severity], $_.Module, $_.Message, $_.Recommendation, $_.Code) }) }
            [PSCustomObject]@{ Title = 'Modules relevés'; Type = 'Table'; Icon = 'apps_list'; Columns = @('Module', 'Résumé', 'Durée (ms)', 'Erreur'); Rows = @($overviews | ForEach-Object { , @($_.Title, $_.Subtitle, $_.DurationMs, $_.Error) }) }
        )
        # Les constats de chaque module, tels quels : l'IA les agrège par code.
        Findings = @($all | ForEach-Object { New-Finding $_.Severity $_.Code "$($_.Module) : $($_.Message)" $_.Recommendation })
    }
}

#endregion

#region Exports et rapport client

# Anonymisation d'un texte : noms (utilisateur, machine, domaine), n° de série, adresses IP et MAC, e-mails.
function Protect-Text([string]$Text) {
    if (-not $Text) { return $Text }
    $values = @([Environment]::UserName, [Environment]::MachineName, [Environment]::UserDomainName) + @(Get-Cached 'serials' 3600 { Get-Serials })
    foreach ($v in $values | Where-Object { $_ -and $_.Length -ge 3 } | Sort-Object Length -Descending -Unique) {
        $Text = [regex]::Replace($Text, [regex]::Escape($v), '[masqué]', 'IgnoreCase')
    }
    $Text = [regex]::Replace($Text, '\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b', 'xx:xx:xx:xx:xx:xx')
    $Text = [regex]::Replace($Text, '\b(?!127\.0\.0\.1\b)(?!0\.0\.0\.0\b)(?:\d{1,3}\.){3}\d{1,3}\b', 'x.x.x.x')
    $Text = [regex]::Replace($Text, '(?i)\b(?:[0-9a-f]{1,4}:){2,7}[0-9a-f]{1,4}\b', 'xxxx::x')
    [regex]::Replace($Text, '[\w.+-]+@[\w-]+\.[\w.-]+', '[e-mail masqué]')
}

function Get-Serials {
    if ($IsWindows) { return @((Get-CimInstance Win32_BIOS).SerialNumber, (Get-CimInstance Win32_BaseBoard).SerialNumber) | Where-Object { $_ } }
    foreach ($f in 'product_serial', 'board_serial', 'chassis_serial', 'product_uuid') { try { [System.IO.File]::ReadAllText("/sys/class/dmi/id/$f").Trim() } catch { } }
}

function ConvertTo-Html([string]$Text) { [System.Net.WebUtility]::HtmlEncode("$Text") }

# Rendu HTML d'une section (KeyValue, Table limitée à 100 lignes, Metric, Usage).
function ConvertTo-HtmlSection($Section) {
    $type = Get-Prop $Section 'Type'; $title = ConvertTo-Html (Get-Prop $Section 'Title')
    switch ($type) {
        'KeyValue' {
            $items = Get-Prop $Section 'Items'
            $names = if ($items -is [System.Collections.IDictionary]) { @($items.Keys) } else { @($items.PSObject.Properties.Name) }
            "<h4>$title</h4><table class='kv'>" + (($names | ForEach-Object { "<tr><th>$(ConvertTo-Html $_)</th><td>$(ConvertTo-Html (Get-Prop $items $_))</td></tr>" }) -join '') + '</table>'
        }
        'Table' {
            $rows = @(Get-Prop $Section 'Rows'); if ($rows.Count -and $rows[0] -isnot [array] -and $rows[0] -isnot [System.Collections.IList]) { $rows = , $rows }
            $more = if ($rows.Count -gt 100) { "<p class='muted'>… $($rows.Count - 100) autres lignes</p>" } else { '' }
            "<h4>$title</h4><table><tr>" + ((@(Get-Prop $Section 'Columns') | ForEach-Object { "<th>$(ConvertTo-Html $_)</th>" }) -join '') + '</tr>' +
            (($rows | Select-Object -First 100 | ForEach-Object { '<tr>' + ((@($_) | ForEach-Object { "<td>$(ConvertTo-Html $_)</td>" }) -join '') + '</tr>' }) -join '') + "</table>$more"
        }
        'Metric' { "<p><b>$title</b> : $(ConvertTo-Html (Get-Prop $Section 'Value')) $(ConvertTo-Html (Get-Prop $Section 'Unit'))$(if (Get-Prop $Section 'Detail') { ' · ' + (ConvertTo-Html (Get-Prop $Section 'Detail')) })</p>" }
        'Usage' { "<h4>$title</h4><table>" + ((@(Get-Prop $Section 'Items') | ForEach-Object { "<tr><th>$(ConvertTo-Html (Get-Prop $_ 'Label'))</th><td>$(ConvertTo-Html (Get-Prop $_ 'Value')) / $(ConvertTo-Html (Get-Prop $_ 'Max')) $(ConvertTo-Html (Get-Prop $_ 'Unit'))</td><td>$(ConvertTo-Html (Get-Prop $_ 'Text'))</td></tr>" }) -join '') + '</table>' }
        default { '' }
    }
}

$script:Css = @'
body{font-family:"Segoe UI",Cantarell,Arial,sans-serif;color:#1d1d1f;margin:32px auto;max-width:980px;padding:0 16px;line-height:1.45}
h1{font-size:24px;margin:0}h2{font-size:18px;margin:28px 0 8px;border-bottom:1px solid #ddd;padding-bottom:4px}h3{font-size:15px;margin:20px 0 6px}h4{font-size:13px;margin:14px 0 4px;color:#444}
table{border-collapse:collapse;width:100%;font-size:12px;margin:4px 0 10px}th,td{border:1px solid #e2e2e2;padding:4px 6px;text-align:left;vertical-align:top}th{background:#f5f5f7;font-weight:600}
table.kv th{width:32%}.muted{color:#777;font-size:12px}.sev-critical{color:#b3261e;font-weight:600}.sev-warning{color:#9a6700;font-weight:600}.sev-info{color:#555}
.head{display:flex;justify-content:space-between;align-items:center;gap:24px;border-bottom:2px solid #1d1d1f;padding-bottom:12px}.logo{max-height:64px;max-width:240px}.brand{font-size:22px;font-weight:700;letter-spacing:.5px}
.score{font-size:32px;font-weight:700}@media print{body{margin:0}h2{page-break-after:avoid}table{page-break-inside:auto}tr{page-break-inside:avoid}}
'@

function Get-FindingsHtml($Findings) {
    if (-not @($Findings).Count) { return "<p class='muted'>Aucun constat.</p>" }
    '<table><tr><th>Gravité</th><th>Module</th><th>Constat</th><th>Recommandation</th></tr>' + ((@($Findings) | ForEach-Object {
                "<tr><td class='sev-$($_.Severity)'>$($script:SeverityText[$_.Severity])</td><td>$(ConvertTo-Html $_.Module)</td><td>$(ConvertTo-Html $_.Message)<br><span class='muted'>$(ConvertTo-Html $_.Code)</span></td><td>$(ConvertTo-Html $_.Recommendation)</td></tr>" }) -join '') + '</table>'
}

# Nom de fichier libre dans le dossier des exports.
function Get-ExportPath([string]$Base, [string]$Extension) {
    $dir = Get-ExportDir
    $name = '{0}-{1}-{2:yyyyMMdd-HHmmss}' -f $Base, ([Environment]::MachineName -replace '[^\w.-]', '_'), (Get-Date)
    $path = Join-Path $dir "$name.$Extension"
    $i = 2
    while (Test-Path -LiteralPath $path) { $path = Join-Path $dir "$name-$i.$Extension"; $i++ }
    $path
}

# reports_export : exporte l'état de la machine (vues d'ensemble et constats) en HTML, Markdown, JSON ou CSV.
function Export-SIReport {
    param(
        [ValidateSet('html', 'markdown', 'json', 'csv')][string]$Format = 'html',
        [string]$Modules,
        [bool]$Anonymize = $false,
        [switch]$DryRun
    )
    $blocked = $null
    $overviews = @(Get-AllOverviews)
    if ($Modules) {
        $wanted = @($Modules -split '[,;\s]+' | Where-Object { $_ })
        $unknown = @($wanted | Where-Object { $_ -notin $overviews.Id })
        if ($unknown) { $blocked = "Module(s) inconnu(s) : $($unknown -join ', '). Modules : $($overviews.Id -join ', ')." }
        $overviews = @($overviews | Where-Object Id -in $wanted)
    }
    $ext = @{ html = 'html'; markdown = 'md'; json = 'json'; csv = 'csv' }[$Format]
    $path = Get-ExportPath 'sysinfo-rapport' $ext
    $all = Get-AllFindings $overviews
    $scores = Get-HealthScores $overviews
    $items = [ordered]@{ 'Fichier' = $path; 'Format' = $Format; 'Modules' = $overviews.Count; 'Constats' = $all.Count; 'Anonymisé' = if ($Anonymize) { 'oui (noms, n° de série, adresses IP et MAC, e-mails)' } else { 'non' } }
    if ($Format -eq 'csv') { $items['Contenu'] = 'les constats (une ligne par constat)' }
    $section = [PSCustomObject]@{ Title = 'Export'; Type = 'KeyValue'; Icon = 'arrow_download'; Items = $items }
    $findings = @()
    if (-not $Anonymize) { $findings += New-Finding 'info' 'RPT-EXPORT-PRIVATE' 'Le fichier contient des informations sur cette machine (nom, comptes, adresses, logiciels) : l''anonymiser avant de le partager.' $null }
    $change = New-Change $path 'Fichier' 'absent' "rapport $Format créé"
    if ($DryRun -or $blocked) { return [PSCustomObject]@{ Subtitle = "Rapport $Format : $path"; Sections = @($section); Findings = $findings; Changes = @($change); Blocked = $blocked } }

    $now = Get-Date
    $content = switch ($Format) {
        'json' {
            [ordered]@{ created = $now.ToString('o'); host = [Environment]::MachineName; score = $scores.Global; domains = @($scores.Domains | ForEach-Object { [ordered]@{ domain = $_.Domain; score = $_.Score } })
                findings = @($all | ForEach-Object { [ordered]@{ severity = $_.Severity; module = $_.ModuleId; code = $_.Code; message = $_.Message; recommendation = $_.Recommendation } })
                modules = ConvertTo-SnapshotState $overviews } | ConvertTo-Json -Depth 12
        }
        'csv' { ($all | ForEach-Object { [PSCustomObject]@{ Gravite = $script:SeverityText[$_.Severity]; Module = $_.Module; Code = $_.Code; Constat = $_.Message; Recommandation = $_.Recommendation } } | ConvertTo-Csv -NoTypeInformation -Delimiter ';') -join "`r`n" }
        'markdown' {
            $md = [System.Text.StringBuilder]::new()
            [void]$md.AppendLine("# Rapport SysInfo — $([Environment]::MachineName)`n")
            [void]$md.AppendLine("$($now.ToString('dddd d MMMM yyyy HH:mm', $script:Fr)) · score de santé **$($scores.Global) / 100** ($(Get-ScoreLabel $scores.Global))`n")
            [void]$md.AppendLine("## Score par domaine`n`n| Domaine | Score | Critiques | Attention |`n|---|---|---|---|")
            foreach ($d in $scores.Domains) { [void]$md.AppendLine("| $($d.Domain) | $($d.Score) | $($d.Critical) | $($d.Warning) |") }
            [void]$md.AppendLine("`n## Constats`n`n| Gravité | Module | Constat | Recommandation |`n|---|---|---|---|")
            foreach ($f in $all) { [void]$md.AppendLine("| $($script:SeverityText[$f.Severity]) | $($f.Module) | $($f.Message -replace '\|', '/') | $("$($f.Recommendation)" -replace '\|', '/') |") }
            foreach ($o in $overviews | Where-Object { -not $_.Error }) {
                [void]$md.AppendLine("`n## $($o.Title)`n`n$($o.Subtitle)`n")
                foreach ($s in $o.Sections | Where-Object { (Get-Prop $_ 'Type') -eq 'KeyValue' }) {
                    $it = Get-Prop $s 'Items'; $names = if ($it -is [System.Collections.IDictionary]) { @($it.Keys) } else { @($it.PSObject.Properties.Name) }
                    [void]$md.AppendLine("### $(Get-Prop $s 'Title')`n")
                    foreach ($k in $names) { [void]$md.AppendLine("- **$k** : $(Get-Prop $it $k)") }
                    [void]$md.AppendLine()
                }
            }
            $md.ToString()
        }
        default {
            $body = [System.Text.StringBuilder]::new()
            [void]$body.Append("<div class='head'><div><h1>Rapport SysInfo — $(ConvertTo-Html ([Environment]::MachineName))</h1><p class='muted'>$($now.ToString('dddd d MMMM yyyy HH:mm', $script:Fr)) · $(ConvertTo-Html ([System.Runtime.InteropServices.RuntimeInformation]::OSDescription))</p></div><div class='score'>$($scores.Global)<span class='muted'> / 100</span></div></div>")
            [void]$body.Append('<h2>Score par domaine</h2><table><tr><th>Domaine</th><th>Score</th><th>Critiques</th><th>Attention</th><th>Problème principal</th></tr>' + (($scores.Domains | ForEach-Object { "<tr><td>$(ConvertTo-Html $_.Domain)</td><td>$($_.Score)</td><td>$($_.Critical)</td><td>$($_.Warning)</td><td>$(ConvertTo-Html $_.Worst)</td></tr>" }) -join '') + '</table>')
            [void]$body.Append('<h2>Constats</h2>' + (Get-FindingsHtml $all))
            foreach ($o in $overviews | Where-Object { -not $_.Error }) {
                [void]$body.Append("<h2>$(ConvertTo-Html $o.Title)</h2><p class='muted'>$(ConvertTo-Html $o.Subtitle)</p>")
                foreach ($s in $o.Sections) { [void]$body.Append((ConvertTo-HtmlSection $s)) }
            }
            "<!doctype html><html lang='fr'><head><meta charset='utf-8'><title>Rapport SysInfo</title><style>$script:Css</style></head><body>$body<p class='muted'>Généré par SysInfo.</p></body></html>"
        }
    }
    if ($Anonymize) { $content = Protect-Text $content }
    [void][System.IO.Directory]::CreateDirectory((Split-Path $path))
    [System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($Format -eq 'csv'))
    $items['Taille'] = Format-Unit ((Get-Item -LiteralPath $path).Length / 1KB) 'Kio' '0'
    [PSCustomObject]@{ Subtitle = "Rapport $Format créé : $path"; Sections = @($section); Findings = $findings; Changes = @(New-Change $path 'Fichier' 'absent' "rapport $Format créé"); Blocked = $null }
}

# Actions faites (journal d'audit) : actions A et C exécutées et réussies depuis $Since.
function Get-AuditActions([datetime]$Since) {
    $dir = Join-Path $script:DataRoot 'audit'
    $files = @(0..([Math]::Ceiling(((Get-Date) - $Since).TotalDays / 28) + 1) | ForEach-Object { Join-Path $dir ('audit-{0:yyyy-MM}.jsonl' -f (Get-Date).AddMonths(-$_)) } | Sort-Object -Unique)
    $entries = foreach ($f in $files) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        foreach ($line in [System.IO.File]::ReadLines($f)) {
            if ($line -notmatch '"dryRun":false' -or $line -notmatch '"level":"[AC]"') { continue }
            try { $e = $line | ConvertFrom-Json } catch { continue }
            if ([datetime]$e.time -lt $Since -or $e.status -notin 'ok', 'warning', 'critical') { continue }
            $e
        }
    }
    @($entries | Sort-Object time)
}

function Get-Logo {
    $dir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'SysInfo'
    foreach ($ext in 'svg', 'png', 'jpg', 'jpeg') {
        $file = Join-Path $dir "logo.$ext"
        if (Test-Path -LiteralPath $file) {
            $mime = @{ svg = 'image/svg+xml'; png = 'image/png'; jpg = 'image/jpeg'; jpeg = 'image/jpeg' }[$ext]
            return [PSCustomObject]@{ Path = $file; Uri = "data:$mime;base64,$([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($file)))" }
        }
    }
    $null
}

# reports_client_report : rapport d'intervention pour le client (HTML imprimable) : état, constats, actions faites
# (journal d'audit), recommandations, comparaison avec un instantané pris avant l'intervention.
function New-SIClientReport {
    param(
        [string]$Client,
        [string]$Technician,
        [ValidateRange(1, 720)][int]$SinceHours = 24,
        [string]$Before,
        [string]$Notes,
        [bool]$Anonymize = $false,
        [switch]$DryRun
    )
    $blocked = $null
    $snap = $null
    if ($Before) { try { $snap = Resolve-Snapshot $Before } catch { $blocked = $_.Exception.Message } }
    $since = (Get-Date).AddHours(-$SinceHours)
    $actions = @(Get-AuditActions $since)
    $logo = Get-Logo
    $path = Get-ExportPath 'rapport-intervention' 'html'
    $items = [ordered]@{ 'Fichier' = $path; 'Client' = $Client ?? '—'; 'Technicien' = $Technician ?? '—'; 'Période' = 'depuis le ' + (Format-Date $since)
        'Actions faites (journal d''audit)' = $actions.Count; 'Avant / après' = if ($snap) { "instantané $($snap.Id)$(if ($snap.Label) { " ($($snap.Label))" })" } else { 'non (donner before pour comparer)' }
        'Logo' = if ($logo) { $logo.Path } else { 'Justware (texte) : déposer Documents/SysInfo/logo.png pour le logo' }; 'Anonymisé' = if ($Anonymize) { 'oui' } else { 'non' } }
    $section = [PSCustomObject]@{ Title = 'Rapport client'; Type = 'KeyValue'; Icon = 'arrow_download'; Items = $items }
    $change = New-Change $path 'Fichier' 'absent' 'rapport d''intervention HTML créé'
    if ($DryRun -or $blocked) { return [PSCustomObject]@{ Subtitle = "Rapport d'intervention : $path"; Sections = @($section); Findings = @(); Changes = @($change); Blocked = $blocked } }

    Write-Information 'Relevé de tous les modules…'
    $overviews = @(Get-AllOverviews -Fresh)
    $all = Get-AllFindings $overviews
    $scores = Get-HealthScores $overviews
    $diff = $null
    if ($snap) {
        $beforeState = Read-Snapshot $snap.Path
        $diff = Compare-States $beforeState ([PSCustomObject]@{ Modules = ConvertTo-SnapshotState $overviews })
    }
    $inventory = try { Invoke-SIModule 'inventory' $null @{} 60 } catch { $null }
    $card = @(Get-Prop $inventory 'Sections') | Where-Object { (Get-Prop $_ 'Title') -eq 'Fiche machine' } | Select-Object -First 1

    $now = Get-Date
    $b = [System.Text.StringBuilder]::new()
    $brand = if ($logo) { "<img class='logo' src='$($logo.Uri)' alt='Justware'>" } else { "<div class='brand'>JUSTWARE</div>" }
    [void]$b.Append("<div class='head'>$brand<div style='text-align:right'><h1>Rapport d'intervention</h1><p class='muted'>$($now.ToString('dddd d MMMM yyyy', $script:Fr))</p></div></div>")
    [void]$b.Append('<h2>Intervention</h2><table class=''kv''>')
    foreach ($kv in @(@('Client', $Client), @('Technicien', $Technician), @('Machine', [Environment]::MachineName), @('Période', "du $(Format-Date $since) au $(Format-Date $now)"), @('Score de santé', "$($scores.Global) / 100 ($(Get-ScoreLabel $scores.Global))$(if ($snap) { ' · avant : ' + (Read-Snapshot $snap.Path).Score + ' / 100' })"))) {
        if ($kv[1]) { [void]$b.Append("<tr><th>$($kv[0])</th><td>$(ConvertTo-Html $kv[1])</td></tr>") }
    }
    [void]$b.Append('</table>')
    if ($card) { [void]$b.Append('<h3>Machine</h3>' + (ConvertTo-HtmlSection $card)) }
    if ($Notes) { [void]$b.Append("<h2>Notes du technicien</h2><p>$((ConvertTo-Html $Notes) -replace "`n", '<br>')</p>") }

    [void]$b.Append('<h2>Actions réalisées</h2>')
    if ($actions.Count) {
        [void]$b.Append('<table><tr><th>Date</th><th>Action</th><th>Modifications</th><th>Résultat</th></tr>')
        foreach ($a in $actions) {
            $changes = @($a.changes | ForEach-Object { '{0} : {1} → {2}' -f $_.target, $_.before, $_.after }) -join ' ; '
            $result = @{ ok = 'réussie'; warning = 'réussie avec avertissement'; critical = 'réussie, à surveiller' }["$($a.status)"]
            [void]$b.Append("<tr><td>$(Format-Date $a.time)</td><td>$(ConvertTo-Html $a.tool)</td><td>$(ConvertTo-Html $changes)</td><td>$result</td></tr>")
        }
        [void]$b.Append('</table>')
    }
    else { [void]$b.Append("<p class='muted'>Aucune action enregistrée par SysInfo sur la période.</p>") }

    if ($diff) {
        [void]$b.Append('<h2>Avant / après</h2>')
        [void]$b.Append('<h3>Problèmes résolus</h3>' + (Get-FindingsHtml @($diff.Resolved | ForEach-Object { [PSCustomObject]@{ Severity = $_.Severity; Module = $_.Module; Message = $_.Message; Code = $_.Code; Recommendation = $null } })))
        [void]$b.Append('<h3>Nouveaux constats</h3>' + (Get-FindingsHtml @($diff.New)))
        if ($diff.Rows.Count) { [void]$b.Append('<h3>Listes modifiées</h3><table><tr><th>Module</th><th>Liste</th><th>Ajoutés</th><th>Retirés</th></tr>' + (($diff.Rows | ForEach-Object { "<tr><td>$(ConvertTo-Html $_.Module)</td><td>$(ConvertTo-Html $_.Table)</td><td>$(ConvertTo-Html $_.Added)</td><td>$(ConvertTo-Html $_.Removed)</td></tr>" }) -join '') + '</table>') }
    }

    $remaining = @($all | Where-Object Severity -in 'critical', 'warning')
    [void]$b.Append('<h2>Points à surveiller et recommandations</h2>' + (Get-FindingsHtml $remaining))
    [void]$b.Append('<h2>État par domaine</h2><table><tr><th>Domaine</th><th>Score</th><th>Appréciation</th></tr>' + (($scores.Domains | ForEach-Object { "<tr><td>$(ConvertTo-Html $_.Domain)</td><td>$($_.Score)</td><td>$(Get-ScoreLabel $_.Score)</td></tr>" }) -join '') + '</table>')
    [void]$b.Append("<p class='muted'>Rapport généré par SysInfo le $($now.ToString('d MMMM yyyy HH:mm', $script:Fr)). Pour l'enregistrer en PDF : Imprimer › Enregistrer au format PDF.</p>")

    $html = "<!doctype html><html lang='fr'><head><meta charset='utf-8'><title>Rapport d'intervention</title><style>$script:Css</style></head><body>$b</body></html>"
    if ($Anonymize) { $html = Protect-Text $html }
    [void][System.IO.Directory]::CreateDirectory((Split-Path $path))
    [System.IO.File]::WriteAllText($path, $html)
    $items['Taille'] = Format-Unit ((Get-Item -LiteralPath $path).Length / 1KB) 'Kio' '0'
    $findings = @()
    if (-not $actions.Count) { $findings += New-Finding 'info' 'RPT-NO-ACTIONS' "Aucune action SysInfo dans les $SinceHours dernières heures : la partie « Actions réalisées » est vide (les actions faites hors SysInfo n'y figurent pas)." 'Ajouter les notes du technicien (notes).' }
    if (-not $Anonymize) { $findings += New-Finding 'info' 'RPT-EXPORT-PRIVATE' 'Le rapport contient le nom de la machine et des informations sur sa configuration.' $null }
    [PSCustomObject]@{ Subtitle = "Rapport d'intervention créé : $path"; Sections = @($section); Findings = $findings; Changes = @(New-Change $path 'Fichier' 'absent' 'rapport d''intervention HTML créé'); Blocked = $null }
}

#endregion

Export-ModuleMember -Function Get-ModuleData, Invoke-SIDiagnostic, New-SISnapshot, Get-SISnapshots, Compare-SISnapshots, Export-SIReport, New-SIClientReport
