# Module Audit & Traçabilité : journal des appels (fenêtre et MCP) et des actions, avec leur confirmation, leurs
# changements et leur annulation.
#
# Source : le journal JSONL écrit par SysInfo (Services/AuditLog.cs), un fichier par mois :
#   Windows : %LOCALAPPDATA%\SysInfo\audit\audit-AAAA-MM.jsonl
#   Linux   : ~/.local/share/SysInfo/audit/audit-AAAA-MM.jsonl
# Le journal est celui du compte qui lance SysInfo (root a le sien quand SysInfo tourne avec sudo).
# Le rafraîchissement automatique des pages n'y figure pas.

$script:Fr = [cultureinfo]::GetCultureInfo('fr-FR')
$script:Directory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'SysInfo/audit'

$script:Cache = @{}
function Get-Cached([string]$Key, [int]$Seconds, [scriptblock]$Compute) {
    $entry = $script:Cache[$Key]
    if ($entry -and ((Get-Date) - $entry.At).TotalSeconds -lt $Seconds) { return $entry.Value }
    $value = & $Compute
    $script:Cache[$Key] = @{ At = Get-Date; Value = $value }
    $value
}

#region Lecture du journal

function Format-Date($Date) { if ($Date) { ([datetime]$Date).ToString('dd/MM/yyyy HH:mm:ss', $script:Fr) } else { $null } }

function New-Finding([string]$Severity, [string]$Code, [string]$Message, [string]$Recommendation) {
    [PSCustomObject]@{ Severity = $Severity; Code = $Code; Message = $Message; Recommendation = $Recommendation }
}

$script:Confirmations = @{ 'not-required' = '—'; confirmed = 'confirmée'; declined = 'refusée'; timeout = 'sans réponse'; unavailable = 'impossible' }
$script:Statuses = @{ ok = 'OK'; warning = 'attention'; critical = 'critique'; error = 'erreur'; blocked = 'bloquée'; declined = 'refusée'; cancelled = 'arrêtée'; running = 'en cours' }

# Entrées des $Days derniers jours, les plus récentes d'abord (fichiers du mois courant et des précédents).
# Mise en cache par date de modification des fichiers.
function Read-Audit([int]$Days) {
    if (-not (Test-Path -LiteralPath $script:Directory)) { return @() }
    $since = (Get-Date).AddDays(-$Days).ToUniversalTime()
    $files = @(Get-ChildItem -LiteralPath $script:Directory -Filter 'audit-*.jsonl' -File | Where-Object { $_.LastWriteTimeUtc -ge $since } | Sort-Object Name)
    $stamp = ($files | ForEach-Object { "$($_.Name):$($_.Length)" }) -join '|'
    Get-Cached "audit|$Days|$stamp" 3600 {
        $entries = [System.Collections.Generic.List[object]]::new()
        foreach ($f in $files) {
            # Lecture partagée : SysInfo peut écrire en même temps.
            $stream = [System.IO.FileStream]::new($f.FullName, 'Open', 'Read', 'ReadWrite')
            try {
                $reader = [System.IO.StreamReader]::new($stream)
                while ($null -ne ($line = $reader.ReadLine())) {
                    if (-not $line.Trim()) { continue }
                    $e = try { $line | ConvertFrom-Json -DateKind Utc } catch { $null }
                    if ($e -and [datetime]$e.time -ge $since) { $entries.Add($e) }
                }
            }
            finally { $stream.Dispose() }
        }
        $entries.Reverse()
        , $entries.ToArray()
    }
}

function Format-Origin($Entry) { if ($Entry.origin -eq 'mcp') { 'MCP' + $(if ($Entry.client) { " · $($Entry.client)" }) } else { 'Fenêtre' } }

function Format-Parameters($Parameters) {
    if (-not $Parameters) { return '' }
    (@($Parameters.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', ')
}

function Format-Changes($Changes) {
    (@($Changes | Where-Object { $_ } | ForEach-Object { '{0} · {1} : {2} → {3}' -f $_.target, $_.property, $_.before, $_.after }) -join ' ; ')
}

function Test-Action($Entry) { $Entry.level -in 'A', 'C' }

#endregion

#region Vue d'ensemble

function Get-ModuleData {
    # Les lignes « running » (début d'une tâche longue) ne comptent pas : la ligne de fin suit.
    $entries = @(Read-Audit 30 | Where-Object status -ne 'running')
    $actions = @($entries | Where-Object { Test-Action $_ })
    $done = @($actions | Where-Object { -not $_.dryRun -and $_.confirmation -eq 'confirmed' })
    $sections = [System.Collections.Generic.List[object]]::new()
    $findings = [System.Collections.Generic.List[object]]::new()

    $files = @(Get-ChildItem -LiteralPath $script:Directory -Filter 'audit-*.jsonl' -File -ErrorAction SilentlyContinue)
    $sections.Add([PSCustomObject]@{
            Title = 'Journal (30 jours)'; Type = 'KeyValue'; Icon = 'timer'
            Items = [ordered]@{
                'Appels'                 = $entries.Count
                'Depuis la fenêtre'      = @($entries | Where-Object origin -eq 'ui').Count
                'Depuis un agent (MCP)'  = @($entries | Where-Object origin -eq 'mcp').Count
                'Actions exécutées'      = $done.Count
                'Aperçus'                = @($actions | Where-Object dryRun).Count
                'Actions refusées'       = @($actions | Where-Object { $_.confirmation -in 'declined', 'timeout' }).Count
                'Actions bloquées'       = @($actions | Where-Object status -eq 'blocked').Count
                'Erreurs'                = @($entries | Where-Object status -eq 'error').Count
                'Fichiers'               = ('{0} ({1})' -f $files.Count, $script:Directory)
            }
        })

    $rows = @($actions | Where-Object { -not $_.dryRun } | Select-Object -First 50 | ForEach-Object {
            , @((Format-Date ([datetime]$_.time).ToLocalTime()), (Format-Origin $_), $_.tool, $_.level, $script:Confirmations[$_.confirmation] ?? $_.confirmation,
                ($script:Statuses[$_.status] ?? $_.status), (Format-Parameters $_.parameters), (Format-Changes $_.changes), $(if ($_.undo) { $_.id } else { $null }))
        })
    $sections.Add([PSCustomObject]@{ Title = 'Actions'; Type = 'Table'; Icon = 'play'; Columns = @('Date', 'Origine', 'Outil', 'Niveau', 'Confirmation', 'Résultat', 'Paramètres', 'Modifications', 'Annulable (id)'); Rows = $rows })

    $top = @($entries | Group-Object tool | Sort-Object Count -Descending | Select-Object -First 10 | ForEach-Object { , @($_.Name, $_.Count) })
    if ($top) { $sections.Add([PSCustomObject]@{ Title = 'Outils les plus appelés'; Type = 'Table'; Icon = 'arrow_sort'; Columns = @('Outil', 'Appels'); Rows = $top }) }

    $errors = @($entries | Where-Object status -eq 'error' | Select-Object -First 10 | ForEach-Object { , @((Format-Date ([datetime]$_.time).ToLocalTime()), (Format-Origin $_), $_.tool, $_.error) })
    if ($errors) { $sections.Add([PSCustomObject]@{ Title = 'Dernières erreurs'; Type = 'Table'; Icon = 'error_circle'; Columns = @('Date', 'Origine', 'Outil', 'Erreur'); Rows = $errors }) }

    # Constats : actions faites par un agent dans les dernières 24 h, refus répétés (un agent qui insiste).
    $recent = @($done | Where-Object { $_.origin -eq 'mcp' -and [datetime]$_.time -gt (Get-Date).ToUniversalTime().AddHours(-24) })
    if ($recent.Count) { $findings.Add((New-Finding 'info' 'AUD-MCP-ACTIONS' "$($recent.Count) action(s) exécutée(s) à la demande d'un agent IA ces dernières 24 h." 'Voir la carte « Actions » ; celles marquées annulables peuvent être défaites avec audit_undo.')) }
    $declined = @($actions | Where-Object { $_.origin -eq 'mcp' -and $_.confirmation -eq 'declined' -and [datetime]$_.time -gt (Get-Date).ToUniversalTime().AddHours(-24) })
    if ($declined.Count -ge 3) { $findings.Add((New-Finding 'warning' 'AUD-MCP-DECLINED' "$($declined.Count) actions demandées par un agent IA refusées ces dernières 24 h." 'Si un agent insiste, désactiver ses actions dans Paramètres › Actions et audit.')) }

    $subtitle = '{0} appel(s) · {1} action(s) exécutée(s) sur 30 jours' -f $entries.Count, $done.Count
    [PSCustomObject]@{ Subtitle = $subtitle; Sections = $sections.ToArray(); Findings = $findings.ToArray() }
}

#endregion

#region Fonctions ciblées

# audit_get_log : entrées du journal filtrées (période, origine, actions seulement, outil, résultat).
function Get-SIAuditLog {
    param(
        [ValidateRange(1, 8760)][int]$SinceHours = 168,
        [ValidateSet('all', 'ui', 'mcp')][string]$Origin = 'all',
        [ValidateSet('all', 'actions', 'reads')][string]$Kind = 'all',
        [string]$Tool,
        [ValidateSet('all', 'ok', 'warning', 'critical', 'error', 'blocked', 'declined', 'cancelled', 'running')][string]$Status = 'all',
        [ValidateRange(1, 1000)][int]$Top = 100
    )
    $since = (Get-Date).ToUniversalTime().AddHours(-$SinceHours)
    $entries = @(Read-Audit ([Math]::Ceiling($SinceHours / 24) + 1) | Where-Object { [datetime]$_.time -ge $since })
    if ($Origin -ne 'all') { $entries = @($entries | Where-Object origin -eq $Origin) }
    if ($Kind -eq 'actions') { $entries = @($entries | Where-Object { Test-Action $_ }) } elseif ($Kind -eq 'reads') { $entries = @($entries | Where-Object { -not (Test-Action $_) }) }
    if ($Tool) { $entries = @($entries | Where-Object tool -like "*$Tool*") }
    if ($Status -ne 'all') { $entries = @($entries | Where-Object status -eq $Status) }
    $total = $entries.Count
    $rows = @($entries | Select-Object -First $Top | ForEach-Object {
            , @($_.id, (Format-Date ([datetime]$_.time).ToLocalTime()), (Format-Origin $_), $_.user, $_.tool, $_.level, $(if ($_.dryRun) { 'aperçu' } else { $null }),
                ($script:Confirmations[$_.confirmation] ?? $_.confirmation), ($script:Statuses[$_.status] ?? $_.status), [long]$_.durationMs,
                (Format-Parameters $_.parameters), (@($_.findings) -join ', '), (Format-Changes $_.changes), $_.restorePoint, $_.error)
        })
    $filters = @("$SinceHours h")
    if ($Origin -ne 'all') { $filters += "origine $Origin" }
    if ($Kind -ne 'all') { $filters += @{ actions = 'actions'; reads = 'lectures' }[$Kind] }
    if ($Tool) { $filters += "outil « $Tool »" }
    if ($Status -ne 'all') { $filters += "résultat $Status" }
    [PSCustomObject]@{
        Subtitle = '{0} entrée(s) · {1} affichée(s) · {2}' -f $total, $rows.Count, ($filters -join ' · ')
        Sections = @([PSCustomObject]@{
                Title = 'Journal'; Type = 'Table'; Icon = 'timer'
                Columns = @('Id', 'Date', 'Origine', 'Compte', 'Outil', 'Niveau', 'Aperçu', 'Confirmation', 'Résultat', 'Durée (ms)', 'Paramètres', 'Constats', 'Modifications', 'Point de restauration', 'Erreur')
                Rows = $rows
            })
        Findings = @()
    }
}

# Module de SysInfo d'après son id (dossier frère de celui-ci) : Manifest et chemin du .psm1.
function Find-SysInfoModule([string]$Id) {
    foreach ($dir in Get-ChildItem -LiteralPath (Split-Path $PSScriptRoot) -Directory) {
        $manifest = Join-Path $dir.FullName 'module.json'
        if (-not (Test-Path -LiteralPath $manifest)) { continue }
        $json = try { Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json } catch { $null }
        if ($json.id -eq $Id) { return @{ Manifest = $json; Script = Join-Path $dir.FullName "$($dir.Name).psm1" } }
    }
    $null
}

# audit_undo : défait une action du journal en lançant son « undo » (fonction du même module qui la renverse :
# redémarrer un service arrêté, réactiver un élément au démarrage, annuler un redémarrage planifié…). Seules les
# annulations de niveau A sont faites ici ; une annulation critique (C) se lance par son outil, avec point de
# restauration. L'aperçu est celui de la fonction d'annulation.
function Undo-SIAction {
    param(
        [Parameter(Mandatory)][string]$Id,
        [switch]$DryRun
    )
    $entry = @(Read-Audit 90) | Where-Object id -eq $Id | Select-Object -First 1
    $fail = { param($Reason) [PSCustomObject]@{ Subtitle = "Annulation de $Id"; Sections = @(); Findings = @(); Changes = @(); Blocked = $Reason } }
    if (-not $entry) { return & $fail "Aucune entrée « $Id » dans le journal des 90 derniers jours (voir audit_get_log)." }
    if (-not $entry.undo) { return & $fail "L'action $($entry.tool) du $(Format-Date ([datetime]$entry.time).ToLocalTime()) n'est pas annulable automatiquement." }
    if ($entry.dryRun -or $entry.confirmation -ne 'confirmed') { return & $fail 'Cette entrée n''a rien modifié (aperçu, refus ou blocage).' }
    $undone = @(Read-Audit 90) | Where-Object { $_.tool -eq 'audit_undo' -and -not $_.dryRun -and $_.parameters.id -eq $Id -and $_.status -in 'ok', 'warning' } | Select-Object -First 1
    if ($undone) { return & $fail "Déjà annulée le $(Format-Date ([datetime]$undone.time).ToLocalTime())." }

    $module = Find-SysInfoModule $entry.module
    $function = $module.Manifest.functions | Where-Object name -eq $entry.undo.function | Select-Object -First 1
    if (-not $function) { return & $fail "Fonction d'annulation $($entry.undo.tool) introuvable." }
    if ($function.level -ne 'A') { return & $fail "L'annulation passe par une action critique : lancer $($entry.undo.tool) avec $(Format-Parameters $entry.undo.parameters) (point de restauration et droits administrateur)." }

    $parameters = @{}
    foreach ($p in $entry.undo.parameters.PSObject.Properties) { $parameters[$p.Name] = $p.Value }
    if ($DryRun) { $parameters.DryRun = $true }
    # Module importé dans la portée de cette fonction seulement : ses noms ne masquent pas ceux de l'Audit.
    $target = Import-Module -Name $module.Script -PassThru -Force -Scope Local -DisableNameChecking
    try { $result = & $target { param($Command, $Arguments) & $Command @Arguments } $function.command $parameters }
    finally { Remove-Module -ModuleInfo $target -Force -ErrorAction SilentlyContinue }

    $context = [PSCustomObject]@{
        Title = 'Action annulée'; Type = 'KeyValue'; Icon = 'arrow_clockwise'
        Items = [ordered]@{ Id = $entry.id; Date = Format-Date ([datetime]$entry.time).ToLocalTime(); Origine = Format-Origin $entry; Outil = $entry.tool; Modifications = Format-Changes $entry.changes; Annulation = "$($entry.undo.tool) ($(Format-Parameters $entry.undo.parameters))" }
    }
    [PSCustomObject]@{
        Subtitle = "Annulation de $($entry.tool) : $($result.Subtitle)"
        Sections = @($context) + @($result.Sections)
        Findings = @($result.Findings)
        Changes  = @($result.Changes)
        Blocked  = $result.Blocked
    }
}

# audit_export_log : copie le journal d'une période dans Documents/SysInfo/Exports (JSON), sans l'écraser.
function Export-SIAuditLog {
    param(
        [ValidateRange(1, 8760)][int]$SinceHours = 720,
        [switch]$DryRun
    )
    $since = (Get-Date).ToUniversalTime().AddHours(-$SinceHours)
    $entries = @(Read-Audit ([Math]::Ceiling($SinceHours / 24) + 1) | Where-Object { [datetime]$_.time -ge $since })
    $docs = if ($IsWindows) { [Environment]::GetFolderPath('MyDocuments') } else { (& xdg-user-dir DOCUMENTS 2>$null) ?? (Join-Path $HOME 'Documents') }
    if (-not $docs -or -not (Test-Path -LiteralPath $docs)) { $docs = $HOME }
    $dir = Join-Path $docs 'SysInfo/Exports'
    $file = Join-Path $dir ('audit-{0}.json' -f $(if ($DryRun) { 'AAAAMMJJ-HHMMSS' } else { Get-Date -Format 'yyyyMMdd-HHmmss' }))
    $section = [PSCustomObject]@{ Title = 'Export'; Type = 'KeyValue'; Icon = 'arrow_download'; Items = [ordered]@{ Période = "$SinceHours dernières heures"; Entrées = $entries.Count; Fichier = $file } }
    $findings = @(New-Finding 'info' 'AUD-EXPORT-PRIVATE' 'Le journal contient des noms de comptes, de machines, de fichiers et de services : vérifier avant de le transmettre.' $null)
    $blocked = if ($entries.Count -eq 0) { 'Aucune entrée sur cette période.' } else { $null }
    $change = [PSCustomObject]@{ Target = $file; Property = 'Fichier'; Before = 'absent'; After = "$($entries.Count) entrée(s)" }
    if ($DryRun -or $blocked) { return [PSCustomObject]@{ Subtitle = "$($entries.Count) entrée(s) seront exportées"; Sections = @($section); Findings = $findings; Changes = @($change); Blocked = $blocked } }
    [void](New-Item -ItemType Directory -Path $dir -Force)
    $entries | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $file -Encoding utf8
    if ($IsLinux) { & chmod 600 $file 2>$null }
    [PSCustomObject]@{ Subtitle = "Journal exporté : $file"; Sections = @($section); Findings = $findings; Changes = @($change); Blocked = $null }
}

#endregion

Export-ModuleMember -Function Get-ModuleData, Get-SIAuditLog, Undo-SIAction, Export-SIAuditLog
