# Module Services : état, type de démarrage, compte, PID, binaire, anomalies, plantages, signaux de sécurité,
# dépendances, options de récupération, journaux d'un service.
#
# Sources
#   Windows : Win32_Service (état, démarrage, compte, PID, chemin, code de sortie), Get-Service (dépendances),
#             registre Services\<nom>\TriggerInfo (démarrage sur déclencheur), sc.exe qfailure (récupération),
#             journal System « Service Control Manager » (7000, 7009, 7011, 7023, 7024, 7031, 7034),
#             Get-AuthenticodeSignature (binaires hors du dossier Windows).
#   Linux   : systemctl (list-units et list-unit-files en JSON, show), journalctl (journal de systemd et de l'unité).
#
# La liste est relue à chaque rafraîchissement (états, PID) ; les types de démarrage (lents à lire sous Linux),
# l'historique de plantages et les signatures sont mis en cache.

$script:Fr = [cultureinfo]::GetCultureInfo('fr-FR')
$script:Days = 7

# Cache des données qui changent peu : recalculées au plus toutes les $Seconds secondes.
# Un échec n'est pas mis en cache (l'exception remonte à Invoke-Block).
$script:Cache = @{}
function Get-Cached([string]$Key, [int]$Seconds, [scriptblock]$Compute) {
    $entry = $script:Cache[$Key]
    if ($entry -and ((Get-Date) - $entry.At).TotalSeconds -lt $Seconds) { return $entry.Value }
    $value = & $Compute
    $script:Cache[$Key] = @{ At = Get-Date; Value = $value }
    $value
}

#region Outils

function Format-Date([datetime]$Date) { $Date.ToString('dd/MM/yyyy HH:mm', $script:Fr) }

function New-Finding([string]$Severity, [string]$Code, [string]$Message, [string]$Recommendation) {
    [PSCustomObject]@{ Severity = $Severity; Code = $Code; Message = $Message; Recommendation = $Recommendation }
}

$script:WinStates = @{ Running = 'En cours'; Stopped = 'Arrêté'; 'Start Pending' = 'Démarrage…'; 'Stop Pending' = 'Arrêt…'; Paused = 'En pause'; 'Pause Pending' = 'Mise en pause…'; 'Continue Pending' = 'Reprise…' }
$script:WinStarts = @{ Auto = 'Automatique'; Manual = 'Manuel'; Disabled = 'Désactivé'; Boot = 'Démarrage du noyau'; System = 'Système' }
$script:LinuxStates = @{ running = 'En cours'; exited = 'Terminé'; dead = 'Arrêté'; failed = 'Échec'; activating = 'Démarrage…'; deactivating = 'Arrêt…'; 'auto-restart' = 'Redémarrage…'; reloading = 'Rechargement…'; start = 'Démarrage…'; 'start-pre' = 'Démarrage…'; 'start-post' = 'Démarrage…'; stop = 'Arrêt…'; 'stop-sigterm' = 'Arrêt…'; condition = 'Condition non remplie' }
$script:LinuxStarts = @{ enabled = 'Activé'; 'enabled-runtime' = 'Activé (temporaire)'; disabled = 'Désactivé'; static = 'Statique'; masked = 'Masqué'; 'masked-runtime' = 'Masqué (temporaire)'; indirect = 'Indirect'; generated = 'Généré'; transient = 'Transitoire'; alias = 'Alias'; linked = 'Lié'; 'linked-runtime' = 'Lié (temporaire)' }

# Chemin de l'exécutable dans une ligne de commande Windows : entre guillemets, ou jusqu'au premier « .exe ».
function Get-BinaryPath([string]$CommandLine) {
    if (-not $CommandLine) { return $null }
    if ($CommandLine -match '^\s*"([^"]+)"') { return $Matches[1] }
    if ($CommandLine -match '^\s*(.+?\.exe)\b') { return $Matches[1] }
    ($CommandLine -split '\s+')[0]
}

#endregion

#region Liste des services

# Linux : systemctl show de toutes les unités en un appel ; blocs « clé=valeur » séparés par une ligne vide.
function Get-UnitProperties([string[]]$Units, [string[]]$Properties) {
    $map = @{}
    if ($Units.Count -eq 0) { return $map }
    $current = @{}
    foreach ($line in & systemctl show --no-pager -p ($Properties -join ',') -- @Units 2>$null) {
        if (-not $line) {
            if ($current.Id) { $map[$current.Id] = $current }
            $current = @{}
            continue
        }
        $i = $line.IndexOf('=')
        if ($i -gt 0) { $current[$line.Substring(0, $i)] = $line.Substring($i + 1) }
    }
    if ($current.Id) { $map[$current.Id] = $current }
    $map
}

# Type de démarrage de chaque fichier d'unité (systemctl list-unit-files : ~1 s, mis en cache).
function Get-UnitFileStates {
    $map = @{}
    $json = (& systemctl list-unit-files --type=service --output=json --no-pager 2>$null) -join ''
    if ($json) { foreach ($f in $json | ConvertFrom-Json) { $map[$f.unit_file] = $f.state } }
    $map
}

# Services normalisés : Name, Description, State, Running, Failed, StartType, Auto, Disabled, Account, Pid, Restarts,
# Binary, CommandLine, ExitCode, Trigger.
function Get-ServiceList {
    if ($IsWindows) {
        # État en direct par le gestionnaire de services (Get-Service, peu coûteux) ; le reste (compte, binaire, code
        # de sortie, PID) par WMI, relu toutes les 60 s : une requête Win32_Service coûte ~200 ms et charge WmiPrvSE.
        $cim = Get-Cached 'wincim' 60 { $map = @{}; foreach ($c in Get-CimInstance -ClassName Win32_Service) { $map[$c.Name] = $c }; $map }
        $live = @{}
        foreach ($svc in Get-Service -ErrorAction SilentlyContinue) { $live[$svc.Name] = "$($svc.Status)" }
        $script:ServiceSignature = (($live.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ';') + "|$($script:Cache['wincim'].At.Ticks)"
        return $cim.Values | ForEach-Object {
            $status = $live[$_.Name] ?? "$($_.State)"
            $_ | Add-Member -NotePropertyName LiveState -NotePropertyValue $(switch ($status) { 'Running' { 'Running' } 'Stopped' { 'Stopped' } 'StartPending' { 'Start Pending' } 'StopPending' { 'Stop Pending' } 'Paused' { 'Paused' } default { "$($_.State)" } }) -Force -PassThru
        } | ForEach-Object {
            $start = "$($_.StartMode)"
            $auto = $start -in 'Auto', 'Boot', 'System'
            $trigger = $auto -and $_.LiveState -ne 'Running' -and (Test-Path "HKLM:\SYSTEM\CurrentControlSet\Services\$($_.Name)\TriggerInfo")
            [PSCustomObject]@{
                Name = $_.Name; Description = $_.DisplayName; State = $script:WinStates[$_.LiveState] ?? $_.LiveState
                Running = $_.LiveState -eq 'Running'; Failed = $_.LiveState -eq 'Stopped' -and $auto -and $_.ExitCode -notin 0, 1077 -and -not $trigger
                StartType = ($script:WinStarts[$start] ?? $start) + $(if ($_.DelayedAutoStart) { ' (différé)' } elseif ($trigger) { ' (déclencheur)' } else { '' })
                Auto = $auto -and -not $trigger; Disabled = $start -eq 'Disabled'
                Account = $_.StartName; Pid = if ($_.ProcessId) { [int]$_.ProcessId } else { $null }; Restarts = $null
                Binary = Get-BinaryPath $_.PathName; CommandLine = $_.PathName; ExitCode = [int]$_.ExitCode; Trigger = $trigger; Type = $null
            }
        }
    }

    $json = (& systemctl list-units --type=service --all --output=json --no-pager 2>$null) -join ''
    if (-not $json) { throw 'systemctl indisponible (système sans systemd ?)' }
    $units = @($json | ConvertFrom-Json | Where-Object { $_.load -ne 'not-found' })
    $files = Get-Cached 'unitfiles' 300 { Get-UnitFileStates }
    # UnitFileState n'est pas demandé ici : systemctl show le calcule unité par unité (~0,4 s pour 200 unités) ;
    # list-unit-files, mis en cache, donne la même information.
    # systemctl show coûte ~0,5 s pour 200 unités (un appel D-Bus par unité) : relu toutes les 30 s ; l'état, lui,
    # vient de list-units à chaque rafraîchissement.
    $props = Get-Cached 'unitprops' 60 { Get-UnitProperties @($units.unit) @('Id', 'MainPID', 'User', 'ExecStart', 'NRestarts', 'Type', 'Result') }
    # Signature de l'état : si rien n'a bougé depuis l'appel précédent, Get-ModuleData réutilise son résultat.
    $script:ServiceSignature = "$($json.GetHashCode())|$($script:Cache['unitprops'].At.Ticks)|$($script:Cache['unitfiles'].At.Ticks)"
    foreach ($u in $units) {
        $p = $props[$u.unit] ?? @{}
        # Instance « getty@tty1.service » : type de démarrage de son modèle « getty@.service ».
        $fileState = $files[$u.unit] ?? $files[($u.unit -replace '@[^.]*\.', '@.')]
        $sub = $u.sub
        [PSCustomObject]@{
            Name = $u.unit -replace '\.service$', ''; Description = $u.description
            State = $script:LinuxStates[$sub] ?? $sub; Running = $sub -eq 'running'; Failed = $u.active -eq 'failed'
            StartType = $script:LinuxStarts[$fileState] ?? $fileState; Auto = $fileState -in 'enabled', 'enabled-runtime'
            Disabled = $fileState -in 'disabled', 'masked', 'masked-runtime'
            Account = if ($p.User) { $p.User } else { 'root' }
            Pid = if ($p.MainPID -and $p.MainPID -ne '0') { [int]$p.MainPID } else { $null }
            Restarts = if ($p.NRestarts) { [int]$p.NRestarts } else { 0 }
            Binary = if ($p.ExecStart -match 'path=(\S+)') { $Matches[1] } else { $null }
            CommandLine = if ($p.ExecStart -match 'argv\[\]=([^;]+)') { $Matches[1].Trim() } else { $null }
            ExitCode = $null; Trigger = $false; Type = $p.Type; Result = $p.Result
        }
    }
}

#endregion

#region Plantages et sécurité

# Plantages et échecs des 7 derniers jours.
# Windows : Service Control Manager 7031 / 7034 (arrêt inattendu), 7023 / 7024 (arrêt sur erreur), 7000 / 7009 / 7011
#           (échec ou délai de démarrage) ; nom affiché du service en premier paramètre.
# Linux   : messages de systemd « Failed with result », « code=dumped / killed », « Scheduled restart job ».
function Get-ServiceIncidents([int]$Days) {
    $since = (Get-Date).AddDays(-$Days)
    if ($IsWindows) {
        $kinds = @{ 7031 = 'Arrêt inattendu (redémarré)'; 7034 = 'Arrêt inattendu'; 7023 = 'Arrêt sur erreur'; 7024 = 'Arrêt sur erreur'; 7000 = 'Échec du démarrage'; 7009 = 'Délai de démarrage dépassé'; 7011 = 'Délai de réponse dépassé' }
        return Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager'; Id = @($kinds.Keys); StartTime = $since } -MaxEvents 500 -ErrorAction SilentlyContinue | ForEach-Object {
            [PSCustomObject]@{ Time = $_.TimeCreated; Service = "$($_.Properties[0].Value)"; Kind = $kinds[$_.Id]; Message = ($_.Message -split "`r?`n")[0] }
        }
    }
    $lines = & journalctl -t systemd -S "-${Days}d" -g 'Failed with result|code=dumped|code=killed|Scheduled restart job' -o json --output-fields=MESSAGE,__REALTIME_TIMESTAMP,_UID -q --no-pager 2>$null
    if (-not $lines) { return @() }
    foreach ($e in ('[' + (@($lines) -join ',') + ']') | ConvertFrom-Json) {
        # Gestionnaire du système seulement : les « systemd --user » des sessions (_UID ≠ 0) gèrent des applications.
        if ($null -ne $e._UID -and [string]$e._UID -ne '0') { continue }
        $message = [string]$e.MESSAGE
        if ($message -notmatch '^([^:\s]+\.service): (.*)$') { continue }
        $unit = $Matches[1]; $rest = $Matches[2]
        $kind = if ($rest -match 'code=dumped') { 'Plantage (core dump)' } elseif ($rest -match 'code=killed') { 'Tué par un signal' } elseif ($rest -match 'Scheduled restart') { 'Redémarrage automatique' } else { 'Échec' }
        [PSCustomObject]@{
            Time = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$e.__REALTIME_TIMESTAMP / 1000).LocalDateTime
            Service = $unit -replace '\.service$', ''; Kind = $kind; Message = $rest
        }
    }
}

# Windows : signaux de sécurité sur les binaires de services.
#   - chemin non entre guillemets contenant un espace (« C:\Program Files\X\svc.exe ») : un exécutable déposé en
#     « C:\Program.exe » serait lancé à la place ;
#   - binaire hors du dossier Windows non signé ou à la signature invalide.
$script:Signatures = @{}
function Get-ServiceSecuritySignals($Services) {
    if (-not $IsWindows) { return @() }
    foreach ($s in $Services) {
        $cmd = $s.CommandLine
        if (-not $cmd) { continue }
        if ($cmd -notmatch '^\s*"' -and $s.Binary -match '\s' -and $s.Binary -notlike "$env:WINDIR*") {
            [PSCustomObject]@{ Service = $s.Name; Signal = 'Chemin non entre guillemets'; Detail = $cmd; Code = 'SVC-UNQUOTED-PATH' }
        }
        $path = [Environment]::ExpandEnvironmentVariables($s.Binary)
        if ($path -like "$env:WINDIR*" -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        if (-not $script:Signatures.ContainsKey($path)) {
            $script:Signatures[$path] = try { "$((Get-AuthenticodeSignature -FilePath $path -ErrorAction Stop).Status)" } catch { $null }
        }
        $status = $script:Signatures[$path]
        if ($status -and $status -ne 'Valid') {
            [PSCustomObject]@{ Service = $s.Name; Signal = if ($status -eq 'NotSigned') { 'Binaire non signé' } else { "Signature invalide ($status)" }; Detail = $path; Code = 'SVC-UNSIGNED-BINARY' }
        }
    }
}

#endregion

function Get-ModuleData {
    $sections = [System.Collections.Generic.List[object]]::new()
    $findings = [System.Collections.Generic.List[object]]::new()
    $errors = [ordered]@{}
    function Invoke-Block([string]$Name, [scriptblock]$Block) {
        try { & $Block } catch { $errors[$Name] = $_.Exception.Message; $null }
    }
    function Add-Finding([string]$Severity, [string]$Code, [string]$Message, [string]$Recommendation) {
        $findings.Add((New-Finding $Severity $Code $Message $Recommendation))
    }

    $services = @(Invoke-Block 'Services' { Get-ServiceList } | Where-Object { $_ })
    $incidents = @(Invoke-Block 'Plantages' { Get-Cached 'incidents' 60 { Get-ServiceIncidents $script:Days } } | Where-Object { $_ })
    $signals = @(Invoke-Block 'Sécurité' { Get-Cached 'signals' 600 { Get-ServiceSecuritySignals $services } } | Where-Object { $_ })

    # Rien n'a changé (états, propriétés, incidents, signaux) : même résultat qu'à l'appel précédent, sans refaire
    # les ~250 lignes du tableau.
    $signature = "$($script:ServiceSignature)|$($script:Cache['incidents'].At.Ticks)|$($script:Cache['signals'].At.Ticks)|$($errors.Count)"
    if ($script:LastResult -and $signature -eq $script:LastSignature) { return $script:LastResult }

    $failed = @($services | Where-Object Failed)
    # Automatiques arrêtés sans échec : normal pour les services « oneshot » (Linux) ou arrêtés proprement (code 0).
    $autoStopped = @($services | Where-Object { $_.Auto -and -not $_.Running -and -not $_.Failed -and $_.Type -ne 'oneshot' -and $_.State -ne 'Terminé' })
    $looping = @($services | Where-Object { $_.Restarts -ge 3 })

    $summary = [ordered]@{
        'Services' = $services.Count
        'En cours' = @($services | Where-Object Running).Count
        'Arrêtés'  = @($services | Where-Object { -not $_.Running }).Count
        'Démarrage automatique' = @($services | Where-Object Auto).Count
        'Désactivés' = @($services | Where-Object Disabled).Count
        'En échec' = $failed.Count
    }
    if ($IsLinux) { $summary['Redémarrés en boucle (≥ 3)'] = $looping.Count }
    $summary["Incidents ($($script:Days) jours)"] = $incidents.Count
    $sections.Add([PSCustomObject]@{ Title = 'Résumé'; Type = 'KeyValue'; Icon = 'pulse'; Items = $summary })

    # Anomalies : en échec, automatiques arrêtés, redémarrages en boucle
    $anomalies = @()
    $anomalies += $failed | ForEach-Object { [PSCustomObject]@{ S = $_; Problem = $(if ($IsWindows) { "Automatique arrêté (code de sortie $($_.ExitCode))" } else { "En échec ($($_.Result))" }) } }
    $anomalies += $autoStopped | ForEach-Object { [PSCustomObject]@{ S = $_; Problem = 'Automatique mais arrêté' } }
    $anomalies += $looping | Where-Object { -not $_.Failed } | ForEach-Object { [PSCustomObject]@{ S = $_; Problem = "Redémarré $($_.Restarts) fois depuis le démarrage" } }
    if ($anomalies.Count -gt 0) {
        $rows = foreach ($a in $anomalies) { , @($a.S.Name, $a.S.Description, $a.Problem, $a.S.State, $a.S.StartType) }
        $sections.Add([PSCustomObject]@{
                Title = 'Anomalies'; Type = 'Table'; Icon = 'warning'
                Columns = @('Service', 'Description', 'Problème', 'État', 'Démarrage'); Rows = @($rows)
            })
    }
    foreach ($f in $failed) {
        Add-Finding 'warning' 'SVC-FAILED' ('{0} ({1}) : {2}' -f $f.Name, $f.Description, $(if ($IsWindows) { "service automatique arrêté avec le code $($f.ExitCode)" } else { "en échec ($($f.Result))" })) `
            $(if ($IsWindows) { 'Voir son détail (services_get_service) et ses événements ; le redémarrer ou corriger sa configuration.' } else { "Lire son journal : journalctl -u $($f.Name) (ou services_get_service)." })
    }
    if ($autoStopped.Count -gt 0) {
        Add-Finding 'info' 'SVC-AUTO-STOPPED' ('{0} service(s) automatique(s) arrêté(s) sans erreur : {1}' -f $autoStopped.Count, (($autoStopped | Select-Object -First 5).Name -join ', ')) `
            'Souvent normal (service qui s''arrête quand il n''a plus rien à faire) ; à vérifier si une fonction manque.'
    }
    foreach ($l in $looping) {
        Add-Finding 'warning' 'SVC-RESTART-LOOP' ('{0} a redémarré {1} fois depuis le démarrage' -f $l.Name, $l.Restarts) `
            'Il plante et systemd le relance : lire son journal pour trouver la cause.'
    }

    # Incidents des 7 derniers jours, regroupés par service
    if ($incidents.Count -gt 0) {
        $groups = @($incidents | Group-Object Service | Sort-Object Count -Descending)
        $rows = foreach ($g in $groups | Select-Object -First 50) {
            $last = $g.Group | Sort-Object Time -Descending | Select-Object -First 1
            , @($g.Name, $g.Count, (($g.Group.Kind | Select-Object -Unique) -join ', '), (Format-Date $last.Time), $last.Message)
        }
        $sections.Add([PSCustomObject]@{
                Title = "Plantages et échecs ($($script:Days) jours)"; Type = 'Table'; Icon = 'error_circle'
                Columns = @('Service', 'Nombre', 'Types', 'Dernier', 'Dernier message'); Rows = @($rows)
            })
        foreach ($g in $groups | Where-Object Count -ge 3 | Select-Object -First 10) {
            Add-Finding 'warning' 'SVC-CRASHING' ('{0} : {1} plantage(s) ou échec(s) en {2} jours' -f $g.Name, $g.Count, $script:Days) `
                'Service instable : lire son journal et vérifier sa configuration ou sa version.'
        }
    }

    # Signaux de sécurité (Windows)
    if ($signals.Count -gt 0) {
        $rows = foreach ($s in $signals) { , @($s.Service, $s.Signal, $s.Detail) }
        $sections.Add([PSCustomObject]@{ Title = 'Signaux de sécurité'; Type = 'Table'; Icon = 'shield_checkmark'; Columns = @('Service', 'Signal', 'Détail'); Rows = @($rows) })
        foreach ($s in $signals) {
            Add-Finding 'warning' $s.Code ('{0} : {1}' -f $s.Service, $s.Signal) $(if ($s.Code -eq 'SVC-UNQUOTED-PATH') {
                    'Mettre le chemin entre guillemets dans la configuration du service (ImagePath), sinon un programme placé plus haut dans le chemin peut être lancé à sa place.'
                } else { 'Vérifier l''éditeur de ce service : un binaire de service non signé hors de Windows est un point d''entrée classique de logiciel malveillant.' })
        }
    }

    # Liste complète : en cours d'abord, puis par nom
    if ($services.Count -gt 0) {
        $rows = foreach ($s in $services | Sort-Object { -not $_.Running }, Name) {
            $row = @($s.Name, $s.Description, $s.State, $s.StartType, $s.Account, $s.Pid)
            if ($IsLinux) { $row += $s.Restarts }
            $row += $s.Binary
            , $row
        }
        $columns = @('Service', 'Description', 'État', 'Démarrage', 'Compte', 'PID')
        if ($IsLinux) { $columns += 'Redémarrages' }
        $columns += 'Binaire'
        $sections.Add([PSCustomObject]@{ Title = 'Tous les services'; Type = 'Table'; Icon = 'apps_list'; Columns = $columns; Rows = @($rows) })
    }

    if ($errors.Count -gt 0) {
        $sections.Add([PSCustomObject]@{ Title = 'Erreurs du module'; Type = 'KeyValue'; Icon = 'error_circle'; Items = $errors })
    }

    $subtitle = '{0} services · {1} en cours · {2} en échec' -f $services.Count, $summary['En cours'], $failed.Count
    $script:LastSignature = $signature
    $script:LastResult = [PSCustomObject]@{ Subtitle = $subtitle; Sections = $sections.ToArray(); Findings = $findings.ToArray() }
    $script:LastResult
}

#region Fonctions ciblées (module.json › functions)

# services_list : liste filtrée.
function Get-SIServices {
    param(
        [ValidateSet('all', 'running', 'stopped', 'failed')][string]$State = 'all',
        [ValidateSet('all', 'auto', 'manual', 'disabled')][string]$StartType = 'all',
        [string]$Filter
    )
    $services = @(Get-ServiceList)
    $services = @($services | Where-Object {
            ($State -eq 'all' -or ($State -eq 'running' -and $_.Running) -or ($State -eq 'stopped' -and -not $_.Running) -or ($State -eq 'failed' -and $_.Failed)) -and
            ($StartType -eq 'all' -or ($StartType -eq 'auto' -and $_.Auto) -or ($StartType -eq 'disabled' -and $_.Disabled) -or ($StartType -eq 'manual' -and -not $_.Auto -and -not $_.Disabled)) -and
            (-not $Filter -or $_.Name -like "*$Filter*" -or $_.Description -like "*$Filter*")
        })
    $rows = foreach ($s in $services | Sort-Object Name) { , @($s.Name, $s.Description, $s.State, $s.StartType, $s.Account, $s.Pid, $s.Binary) }
    $filters = @()
    if ($State -ne 'all') { $filters += "état $State" }
    if ($StartType -ne 'all') { $filters += "démarrage $StartType" }
    if ($Filter) { $filters += "texte « $Filter »" }
    [PSCustomObject]@{
        Subtitle = '{0} service(s){1}' -f $services.Count, $(if ($filters) { ' · ' + ($filters -join ' · ') } else { '' })
        Sections = @([PSCustomObject]@{ Title = 'Services'; Type = 'Table'; Icon = 'apps_list'; Columns = @('Service', 'Description', 'État', 'Démarrage', 'Compte', 'PID', 'Binaire'); Rows = @($rows) })
        Findings = @()
    }
}

# Délai systemd en microsecondes (« 100ms », « 1min 30s » sont déjà lisibles via show ; *USec = nombre brut) → texte.
function Format-USec([string]$Value) {
    if ($Value -match '^\d+$') { $ms = [double]$Value / 1000; if ($ms -ge 1000) { return '{0} s' -f ($ms / 1000).ToString('0.#', $script:Fr) } else { return '{0} ms' -f $ms } }
    $Value
}

# services_get_service : propriétés, dépendances, récupération et journal d'un service.
function Get-SIServiceDetail {
    param(
        [Parameter(Mandatory)][string]$Name,
        [ValidateRange(0, 500)][int]$LogLines = 30
    )
    $sections = [System.Collections.Generic.List[object]]::new()
    $findings = @()

    if ($IsWindows) {
        $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if (-not $svc) { $svc = Get-Service -DisplayName $Name -ErrorAction SilentlyContinue | Select-Object -First 1 }
        if (-not $svc) { throw "Service introuvable : $Name" }
        $cim = Get-CimInstance -ClassName Win32_Service -Filter "Name='$($svc.Name -replace "'", "''")'"
        $info = Get-ServiceList | Where-Object Name -eq $svc.Name | Select-Object -First 1
        $items = [ordered]@{
            'Nom' = $svc.Name; 'Nom affiché' = $svc.DisplayName; 'Description' = $cim.Description
            'État' = $info.State; 'Démarrage' = $info.StartType; 'Compte' = $cim.StartName; 'PID' = $info.Pid
            'Ligne de commande' = $cim.PathName; 'Code de sortie' = $cim.ExitCode
        }
        $sections.Add([PSCustomObject]@{ Title = 'Propriétés'; Type = 'KeyValue'; Icon = 'info'; Items = $items })

        $needs = @($svc.ServicesDependedOn | ForEach-Object { , @('Dépend de', $_.Name, $_.DisplayName, ($script:WinStates["$($_.Status)"] ?? "$($_.Status)")) })
        $neededBy = @($svc.DependentServices | ForEach-Object { , @('Requis par', $_.Name, $_.DisplayName, ($script:WinStates["$($_.Status)"] ?? "$($_.Status)")) })
        $sections.Add([PSCustomObject]@{ Title = 'Dépendances'; Type = 'Table'; Icon = 'link'; Columns = @('Sens', 'Service', 'Nom affiché', 'État'); Rows = @($needs + $neededBy) })

        # sc.exe qfailure : libellés en anglais quelle que soit la langue de Windows.
        $recovery = [ordered]@{}
        foreach ($line in & sc.exe qfailure $svc.Name 2>$null) {
            if ($line -match '^\s*RESET_PERIOD[^:]*:\s*(\d+)') { $recovery['Remise à zéro du compteur'] = '{0} s' -f $Matches[1] }
            elseif ($line -match '(RESTART|RUN PROCESS|REBOOT)\s*--\s*Delay\s*=\s*(\d+)') {
                $action = @{ RESTART = 'Redémarrer le service'; 'RUN PROCESS' = 'Lancer un programme'; REBOOT = 'Redémarrer l''ordinateur' }[$Matches[1]]
                $recovery["Échec $($recovery.Count)"] = '{0} après {1} s' -f $action, ([int]$Matches[2] / 1000)
            }
        }
        if ($recovery.Count -eq 0) { $recovery['Actions'] = 'Aucune (le service reste arrêté s''il plante)' }
        $sections.Add([PSCustomObject]@{ Title = 'Récupération en cas d''échec'; Type = 'KeyValue'; Icon = 'arrow_clockwise'; Items = $recovery })

        if ($LogLines -gt 0) {
            $display = $svc.DisplayName
            $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager'; StartTime = (Get-Date).AddDays(-30) } -MaxEvents 3000 -ErrorAction SilentlyContinue |
                    Where-Object { $_.Message -like "*$display*" }) +
                @(Get-WinEvent -FilterHashtable @{ LogName = 'Application', 'System'; ProviderName = $svc.Name } -MaxEvents $LogLines -ErrorAction SilentlyContinue)
            $rows = foreach ($e in $events | Sort-Object TimeCreated -Descending | Select-Object -First $LogLines) {
                , @((Format-Date $e.TimeCreated), $e.LevelDisplayName, $e.ProviderName, $e.Id, (($e.Message -split "`r?`n")[0]))
            }
            $sections.Add([PSCustomObject]@{ Title = 'Événements'; Type = 'Table'; Icon = 'search'; Columns = @('Date', 'Niveau', 'Source', 'ID', 'Message'); Rows = @($rows) })
        }
        return [PSCustomObject]@{ Subtitle = '{0} · {1} · {2}' -f $svc.DisplayName, $info.State, $info.StartType; Sections = $sections.ToArray(); Findings = $findings }
    }

    $unit = if ($Name -match '\.(service|socket|timer)$') { $Name } else { "$Name.service" }
    $props = (Get-UnitProperties @($unit) @('Id', 'Description', 'LoadState', 'ActiveState', 'SubState', 'UnitFileState', 'UnitFilePreset', 'Result',
            'MainPID', 'User', 'Group', 'ExecStart', 'FragmentPath', 'ActiveEnterTimestamp', 'InactiveEnterTimestamp', 'NRestarts', 'Type',
            'Restart', 'RestartUSec', 'StartLimitBurst', 'StartLimitIntervalUSec', 'WatchdogUSec', 'TimeoutStartUSec', 'MemoryCurrent',
            'Requires', 'Wants', 'BindsTo', 'Requisite', 'RequiredBy', 'WantedBy', 'BoundBy', 'After', 'Before'))[$unit]
    if (-not $props -or $props.LoadState -eq 'not-found') { throw "Unité introuvable : $unit" }

    $items = [ordered]@{
        'Unité' = $props.Id; 'Description' = $props.Description
        'État' = '{0} ({1})' -f ($script:LinuxStates[$props.SubState] ?? $props.SubState), $props.ActiveState
        'Démarrage' = ($script:LinuxStarts[$props.UnitFileState] ?? $props.UnitFileState) + $(if ($props.UnitFilePreset) { " · préréglage $($props.UnitFilePreset)" } else { '' })
        'Dernier résultat' = $props.Result; 'Type' = $props.Type
        'Compte' = if ($props.User) { $props.User } else { 'root' }
        'PID principal' = if ($props.MainPID -ne '0') { $props.MainPID } else { $null }
        'Commande' = if ($props.ExecStart -match 'argv\[\]=([^;]+)') { $Matches[1].Trim() } else { $null }
        'Fichier d''unité' = $props.FragmentPath
        'Actif depuis' = $props.ActiveEnterTimestamp; 'Arrêté le' = $props.InactiveEnterTimestamp
        'Redémarrages' = $props.NRestarts
        'Mémoire' = if ($props.MemoryCurrent -match '^\d+$') { '{0} MiB' -f ([double]$props.MemoryCurrent / 1MB).ToString('0.#', $script:Fr) } else { $null }
    }
    foreach ($k in @($items.Keys)) { if (-not $items[$k] -or $items[$k] -eq '[not set]') { $items.Remove($k) } }
    $sections.Add([PSCustomObject]@{ Title = 'Propriétés'; Type = 'KeyValue'; Icon = 'info'; Items = $items })

    $deps = foreach ($pair in @(@('Requires', 'Dépend de (requis)'), @('BindsTo', 'Dépend de (lié)'), @('Requisite', 'Dépend de (prérequis)'), @('Wants', 'Dépend de (souhaité)'),
            @('RequiredBy', 'Requis par'), @('BoundBy', 'Lié à'), @('WantedBy', 'Souhaité par'))) {
        foreach ($d in ($props[$pair[0]] -split '\s+' | Where-Object { $_ })) { , @($pair[1], $d) }
    }
    $sections.Add([PSCustomObject]@{ Title = 'Dépendances'; Type = 'Table'; Icon = 'link'; Columns = @('Relation', 'Unité'); Rows = @($deps) })

    $recovery = [ordered]@{
        'Redémarrage automatique' = @{ no = 'Non'; always = 'Toujours'; 'on-failure' = 'En cas d''échec'; 'on-abnormal' = 'En cas d''arrêt anormal'; 'on-abort' = 'En cas de plantage'; 'on-success' = 'En cas de succès'; 'on-watchdog' = 'Si le chien de garde expire' }[$props.Restart] ?? $props.Restart
        'Délai avant redémarrage' = Format-USec $props.RestartUSec
        'Limite de démarrages' = '{0} en {1}' -f $props.StartLimitBurst, (Format-USec $props.StartLimitIntervalUSec)
        'Délai de démarrage' = Format-USec $props.TimeoutStartUSec
    }
    if ($props.WatchdogUSec -and $props.WatchdogUSec -ne '0') { $recovery['Chien de garde'] = Format-USec $props.WatchdogUSec }
    $sections.Add([PSCustomObject]@{ Title = 'Récupération en cas d''échec'; Type = 'KeyValue'; Icon = 'arrow_clockwise'; Items = $recovery })

    if ($LogLines -gt 0) {
        $lines = & journalctl -u $unit -n $LogLines -r -o json --output-fields=MESSAGE,PRIORITY,__REALTIME_TIMESTAMP -q --no-pager 2>$null
        $levels = @{ '0' = 'Critique'; '1' = 'Critique'; '2' = 'Critique'; '3' = 'Erreur'; '4' = 'Avertissement' }
        $rows = if ($lines) {
            foreach ($e in ('[' + (@($lines) -join ',') + ']') | ConvertFrom-Json) {
                $message = if ($e.MESSAGE -is [array]) { [System.Text.Encoding]::UTF8.GetString([byte[]]$e.MESSAGE) } else { [string]$e.MESSAGE }
                , @((Format-Date ([DateTimeOffset]::FromUnixTimeMilliseconds([long]$e.__REALTIME_TIMESTAMP / 1000).LocalDateTime)), ($levels[[string]$e.PRIORITY] ?? 'Information'), $message)
            }
        } else { @() }
        $sections.Add([PSCustomObject]@{ Title = 'Journal'; Type = 'Table'; Icon = 'search'; Columns = @('Date', 'Niveau', 'Message'); Rows = @($rows) })
    }
    if ($props.ActiveState -eq 'failed') {
        $findings += New-Finding 'warning' 'SVC-FAILED' ('{0} est en échec ({1})' -f $props.Id, $props.Result) 'Les dernières lignes du journal donnent la cause.'
    }
    [PSCustomObject]@{
        Subtitle = '{0} · {1} · {2}' -f $props.Id, $items['État'], $items['Démarrage']
        Sections = $sections.ToArray(); Findings = $findings
    }
}

#endregion

#region Actions (niveau A : aperçu -DryRun, confirmation dans SysInfo, journal d'audit)

# Résultat d'une action : Changes = ce qui a changé (ou changerait) ; Blocked = pourquoi elle est impossible.
function New-ActionResult([string]$Subtitle, [object[]]$Sections, [object[]]$Findings, [object[]]$Changes, [string]$Blocked) {
    [PSCustomObject]@{
        Subtitle = $Subtitle
        Sections = @($Sections | Where-Object { $_ })
        Findings = @($Findings | Where-Object { $_ })
        Changes  = @($Changes | Where-Object { $_ })
        Blocked  = $Blocked
    }
}

# Services que SysInfo n'arrête ni ne redémarre jamais : le système, la session graphique ou la connexion au
# bureau tomberaient. Les démarrer reste possible.
$script:ProtectedServices = @(
    'RpcSs', 'RpcEptMapper', 'DcomLaunch', 'LSM', 'SamSs', 'BrokerInfrastructure', 'Power', 'PlugPlay', 'ProfSvc',
    'CoreMessagingRegistrar', 'SystemEventsBroker', 'gpsvc', 'EventLog', 'Winmgmt', 'WinDefend', 'mpssvc', 'TermService',
    'dbus', 'dbus-broker', 'systemd-journald', 'systemd-logind', 'systemd-udevd', 'polkit', 'display-manager', 'gdm',
    'sddm', 'lightdm', 'auditd', 'user@0'
)

# État d'un service : Name, Description, State (libellé), Active (en cours), Pid, StartType, Exists, plus de quoi
# décider (Windows : objet ServiceController ; Linux : propriétés systemctl show).
function Get-ServiceState([string]$Name) {
    if ($IsWindows) {
        $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if (-not $svc) { $svc = Get-Service -DisplayName $Name -ErrorAction SilentlyContinue | Select-Object -First 1 }
        if (-not $svc) { return $null }
        $cim = Get-CimInstance -ClassName Win32_Service -Filter "Name='$($svc.Name -replace "'", "''")'"
        return [PSCustomObject]@{
            Name = $svc.Name; Description = $svc.DisplayName; State = $script:WinStates["$($svc.Status)"] ?? "$($svc.Status)"
            Active = $svc.Status -eq 'Running'; Pid = if ($cim.ProcessId) { [int]$cim.ProcessId } else { $null }
            Disabled = $svc.StartType -eq 'Disabled'; StartType = $script:WinStarts["$($cim.StartMode)"] ?? "$($cim.StartMode)"
            Refuse = $false; Dependents = @($svc.DependentServices | Where-Object Status -eq 'Running' | ForEach-Object Name); Service = $svc
        }
    }
    $unit = if ($Name -match '\.(service|socket|timer)$') { $Name } else { "$Name.service" }
    $p = @{}
    foreach ($line in & systemctl show --no-pager -p 'Id,LoadState,ActiveState,SubState,MainPID,UnitFileState,RefuseManualStart,RefuseManualStop,Description' -- $unit 2>$null) {
        $i = $line.IndexOf('='); if ($i -gt 0) { $p[$line.Substring(0, $i)] = $line.Substring($i + 1) }
    }
    if (-not $p.LoadState -or $p.LoadState -eq 'not-found') { return $null }
    # Unités qui s'arrêtent avec celle-ci (Requires / BindsTo inversés), parmi celles qui tournent.
    $dependents = @(& systemctl list-dependencies --reverse --plain --no-legend --no-pager -- $p.Id 2>$null |
        ForEach-Object { $_.Trim() } | Where-Object { $_ -match '\.service$' -and $_ -ne $p.Id } |
        Where-Object { (& systemctl is-active -- $_ 2>$null) -eq 'active' } | Select-Object -First 15)
    [PSCustomObject]@{
        Name = $p.Id; Description = $p.Description; State = $script:LinuxStates[$p.SubState] ?? $p.SubState
        Active = $p.ActiveState -in 'active', 'reloading', 'activating'; Pid = if ($p.MainPID -and $p.MainPID -ne '0') { [int]$p.MainPID } else { $null }
        Disabled = $p.UnitFileState -in 'masked', 'masked-runtime'; StartType = $script:LinuxStarts[$p.UnitFileState] ?? $p.UnitFileState
        RefuseStart = $p.RefuseManualStart -eq 'yes'; RefuseStop = $p.RefuseManualStop -eq 'yes'; Dependents = $dependents; Service = $null
    }
}

function Get-ServiceSection($State) {
    $items = [ordered]@{ Service = $State.Name; Description = $State.Description; État = $State.State; Démarrage = $State.StartType }
    if ($State.Pid) { $items['PID'] = $State.Pid }
    if ($State.Dependents.Count) { $items['Services dépendants actifs'] = $State.Dependents -join ', ' }
    [PSCustomObject]@{ Title = 'Service'; Type = 'KeyValue'; Icon = 'settings'; Items = $items }
}

# services_control : démarre, arrête ou redémarre un service. Le type de démarrage ne change pas.
# Windows : Start-Service / Stop-Service / Restart-Service (-Force : services dépendants compris ; administrateur).
# Linux   : systemctl start / stop / restart --no-ask-password (root : la règle polkit par défaut demande un mot de passe).
function Invoke-SIServiceControl {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('start', 'stop', 'restart')][string]$Action,
        [switch]$DryRun
    )

    $state = Get-ServiceState $Name
    if (-not $state) { return New-ActionResult "Service $Name" @() @() @() "Service introuvable : $Name (voir services_list)." }
    $verb = @{ start = 'démarré'; stop = 'arrêté'; restart = 'redémarré' }[$Action]
    $short = $state.Name -replace '\.service$', ''

    $blocked = $null
    if ($Action -ne 'start' -and $short -in $script:ProtectedServices) {
        $blocked = "$($state.Name) est essentiel au système ou à la session : SysInfo ne l'arrête ni ne le redémarre."
    }
    elseif ($Action -eq 'start' -and $state.Active) { $blocked = "$($state.Name) est déjà démarré (utiliser restart pour le relancer)." }
    elseif ($Action -eq 'stop' -and -not $state.Active) { $blocked = "$($state.Name) est déjà arrêté." }
    elseif ($Action -ne 'stop' -and $state.Disabled) {
        $blocked = "$($state.Name) est $(if ($IsWindows) { 'désactivé' } else { 'masqué' }) : il faut d'abord changer son type de démarrage (action critique, non proposée ici)."
    }
    elseif (($Action -eq 'start' -and $state.RefuseStart) -or ($Action -ne 'start' -and $state.RefuseStop)) { $blocked = "systemd refuse qu'on $(if ($Action -eq 'start') { 'démarre' } else { 'arrête' }) $($state.Name) à la main." }
    elseif (-not [Environment]::IsPrivilegedProcess) {
        $blocked = "Piloter un service exige les droits $(if ($IsWindows) { 'administrateur' } else { 'root' }) : relancer SysInfo $(if ($IsWindows) { 'en administrateur' } else { 'avec sudo' })."
    }

    $findings = [System.Collections.Generic.List[object]]::new()
    if ($Action -ne 'start' -and $state.Dependents.Count) {
        $findings.Add([PSCustomObject]@{
                Severity = 'warning'; Code = 'SVC-CONTROL-DEPENDENTS'
                Message = "Services qui dépendent de $($state.Name) et seront aussi arrêtés : $($state.Dependents -join ', ')."
                Recommendation = $(if ($Action -eq 'restart') { 'Ils ne sont pas tous relancés automatiquement : vérifier leur état ensuite.' } else { $null })
            })
    }
    if ($Action -ne 'start' -and $short -match '^(sshd?|TermService|NetworkManager|systemd-networkd|wpa_supplicant|iwd|Dhcp|Dnscache|LanmanServer|WinRM)$') {
        $findings.Add([PSCustomObject]@{ Severity = 'warning'; Code = 'SVC-CONTROL-REMOTE-CUT'; Message = "Arrêter $($state.Name) peut couper les connexions réseau ou les sessions à distance en cours." })
    }
    if ($Action -eq 'stop') {
        $findings.Add([PSCustomObject]@{ Severity = 'info'; Code = 'SVC-CONTROL-TEMPORARY'; Message = "Le type de démarrage ($($state.StartType)) ne change pas : le service peut repartir au prochain démarrage ou à la demande." })
    }

    $after = @{ start = 'En cours'; stop = 'Arrêté'; restart = 'En cours (relancé)' }[$Action]
    $changes = @([PSCustomObject]@{ Target = $state.Name; Property = 'État'; Before = $state.State; After = $after })
    if ($DryRun -or $blocked) { return New-ActionResult "$($state.Name) sera $verb" @(Get-ServiceSection $state) $findings $changes $blocked }

    if ($IsWindows) {
        switch ($Action) {
            'start' { Start-Service -InputObject $state.Service -ErrorAction Stop }
            'stop' { Stop-Service -InputObject $state.Service -Force -ErrorAction Stop }
            'restart' { Restart-Service -InputObject $state.Service -Force -ErrorAction Stop }
        }
        $state.Service.WaitForStatus($(if ($Action -eq 'stop') { 'Stopped' } else { 'Running' }), [timespan]::FromSeconds(30))
    }
    else {
        $out = & systemctl --no-ask-password $Action -- $state.Name 2>&1
        if ($LASTEXITCODE -ne 0) { throw "systemctl $Action $($state.Name) a échoué : $(($out | Where-Object { $_ }) -join ' ')" }
    }

    $now = Get-ServiceState $state.Name
    $changes = @([PSCustomObject]@{ Target = $state.Name; Property = 'État'; Before = $state.State; After = $now.State })
    if ($state.Pid -ne $now.Pid) { $changes += [PSCustomObject]@{ Target = $state.Name; Property = 'PID'; Before = $state.Pid ?? '—'; After = $now.Pid ?? '—' } }
    $result = @()
    if (($Action -ne 'stop') -ne [bool]$now.Active) {
        $result += [PSCustomObject]@{
            Severity = 'warning'; Code = 'SVC-CONTROL-FAILED'
            Message = "$($state.Name) est « $($now.State) » après l'action."
            Recommendation = 'Consulter son journal avec services_get_service.'
        }
    }
    $done = New-ActionResult "$($state.Name) $verb · $($now.State)" @(Get-ServiceSection $now) $result $changes $null
    # Annulation : l'action inverse (un redémarrage ne s'annule pas).
    if ($Action -ne 'restart') { $done | Add-Member Undo @{ Function = 'control'; Parameters = @{ name = $state.Name; action = $(if ($Action -eq 'start') { 'stop' } else { 'start' }) } } }
    $done
}

# Type de démarrage actuel, sous forme de valeur du paramètre startType (auto, auto_delayed, manual, disabled, masked).
function Get-StartTypeKey($State) {
    if ($IsWindows) {
        $svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='$($State.Name -replace "'", "''")'"
        return $(switch ("$($svc.StartMode)") { 'Auto' { if ($svc.DelayedAutoStart) { 'auto_delayed' } else { 'auto' } } 'Manual' { 'manual' } 'Disabled' { 'disabled' } default { "$($svc.StartMode)".ToLower() } })
    }
    $file = (& systemctl show -p UnitFileState --value -- $State.Name 2>$null)
    switch ($file) { { $_ -in 'enabled', 'enabled-runtime' } { 'auto' } 'disabled' { 'manual' } { $_ -in 'masked', 'masked-runtime' } { 'masked' } default { $file } }
}

$script:StartTypeLabels = @{ auto = 'Automatique'; auto_delayed = 'Automatique (différé)'; manual = 'Manuel'; disabled = 'Désactivé'; masked = 'Masqué'; static = 'Statique'; indirect = 'Indirect' }

# services_set_start_type : change le type de démarrage d'un service.
# Windows : Set-Service -StartupType (auto, auto_delayed, manual, disabled ; administrateur).
# Linux   : systemctl enable (auto), disable (manual), mask (masked : ne peut plus démarrer du tout), unmask (root).
function Set-SIServiceStartType {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('auto', 'auto_delayed', 'manual', 'disabled', 'masked')][string]$StartType,
        [switch]$DryRun
    )
    $state = Get-ServiceState $Name
    if (-not $state) { return New-ActionResult "Service $Name" @() @() @() "Service introuvable : $Name (voir services_list)." }
    $short = $state.Name -replace '\.service$', ''
    $current = Get-StartTypeKey $state
    $blocked = $null
    if ($IsWindows -and $StartType -eq 'masked') { $blocked = 'masked n''existe que sous Linux : utiliser disabled.' }
    elseif ($IsLinux -and $StartType -in 'auto_delayed', 'disabled') { $StartType = if ($StartType -eq 'auto_delayed') { 'auto' } else { 'manual' } }
    if (-not $blocked -and $current -eq $StartType) { $blocked = "$($state.Name) est déjà en démarrage « $($script:StartTypeLabels[$StartType]) »." }
    if (-not $blocked -and $IsLinux -and $current -in 'static', 'indirect' -and $StartType -ne 'masked') { $blocked = "$($state.Name) est « $current » : il démarre à la demande d'autres unités, son type ne se change pas (seulement masked)." }
    if (-not $blocked -and $StartType -in 'manual', 'disabled', 'masked' -and $short -in $script:ProtectedServices) { $blocked = "$($state.Name) est essentiel au système ou à la session : SysInfo ne change pas son démarrage." }
    if (-not $blocked -and -not [Environment]::IsPrivilegedProcess) { $blocked = "Droits $(if ($IsWindows) { 'administrateur' } else { 'root' }) requis : relancer SysInfo $(if ($IsWindows) { 'en administrateur' } else { 'avec sudo -E' })." }

    $findings = [System.Collections.Generic.List[object]]::new()
    if ($StartType -in 'disabled', 'masked' -and $state.Dependents.Count) { $findings.Add([PSCustomObject]@{ Severity = 'warning'; Code = 'SVC-START-DEPENDENTS'; Message = "Ces services dépendent de $($state.Name) et ne pourront plus démarrer : $($state.Dependents -join ', ')." }) }
    if ($StartType -eq 'masked') { $findings.Add([PSCustomObject]@{ Severity = 'warning'; Code = 'SVC-START-MASKED'; Message = "Masqué, $($state.Name) ne peut plus démarrer, même à la demande d'une autre unité ou à la main." }) }
    $findings.Add([PSCustomObject]@{ Severity = 'info'; Code = 'SVC-START-NOW'; Message = "L'état actuel ($($state.State)) ne change pas : le nouveau type s'applique au prochain démarrage (services_control pour agir maintenant)." })
    $change = [PSCustomObject]@{ Target = $state.Name; Property = 'Démarrage'; Before = $script:StartTypeLabels[$current] ?? $current; After = $script:StartTypeLabels[$StartType] }
    if ($DryRun -or $blocked) { return New-ActionResult "Démarrage de $($state.Name) : $($change.Before) → $($change.After)" @(Get-ServiceSection $state) $findings @($change) $blocked }

    if ($IsWindows) {
        $type = @{ auto = 'Automatic'; auto_delayed = 'AutomaticDelayedStart'; manual = 'Manual'; disabled = 'Disabled' }[$StartType]
        Set-Service -Name $state.Name -StartupType $type -ErrorAction Stop
    }
    else {
        $steps = switch ($StartType) {
            'auto' { if ($current -eq 'masked') { , @('unmask') }; , @('enable') }
            'manual' { if ($current -eq 'masked') { , @('unmask') } else { , @('disable') } }
            'masked' { , @('mask') }
        }
        foreach ($step in $steps) {
            $out = & systemctl --no-ask-password @step -- $state.Name 2>&1
            if ($LASTEXITCODE -ne 0) { throw "systemctl $($step -join ' ') $($state.Name) a échoué : $(($out | Where-Object { $_ }) -join ' ')" }
        }
    }
    $now = Get-StartTypeKey $state
    $change.After = $script:StartTypeLabels[$now] ?? $now
    $done = New-ActionResult "Démarrage de $($state.Name) : $($change.After)" @(Get-ServiceSection (Get-ServiceState $state.Name)) @() @($change) $null
    if ($current -in 'auto', 'auto_delayed', 'manual', 'disabled', 'masked') { $done | Add-Member Undo @{ Function = 'set_start_type'; Parameters = @{ name = $state.Name; startType = $current } } }
    $done
}

#endregion

Export-ModuleMember -Function Get-ModuleData, Get-SIServices, Get-SIServiceDetail, Invoke-SIServiceControl, Set-SIServiceStartType
