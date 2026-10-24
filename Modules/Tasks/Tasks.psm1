# Module Tâches planifiées : tâches du Planificateur de tâches (Windows), minuteries systemd et crons (Linux) :
# planification, action, compte, dernière et prochaine exécution, résultat, tâches en échec ou suspectes.
#
# Sources
#   Windows : objet COM Schedule.Service (toutes les tâches, cachées comprises : dernière / prochaine exécution, résultat,
#             exécutions manquées, actions, déclencheurs, compte ; ~20 fois plus rapide que Get-ScheduledTaskInfo),
#             Get-AuthenticodeSignature (programme hors dossiers système), journal TaskScheduler/Operational.
#   Linux   : systemctl list-timers --all -o json et systemctl show (système et --user), journalctl, crontab -l,
#             /etc/crontab, /etc/cron.d, /etc/cron.{hourly,daily,weekly,monthly}, /etc/anacrontab,
#             /var/spool/cron (autres comptes, root seulement).
# Créer ou supprimer une tâche : niveau X, jamais proposé.

$script:Fr = [cultureinfo]::GetCultureInfo('fr-FR')
$script:Nbsp = [char]0x00A0

$script:Cache = @{}
function Get-Cached([string]$Key, [int]$Seconds, [scriptblock]$Compute) {
    $entry = $script:Cache[$Key]
    if ($entry -and ((Get-Date) - $entry.At).TotalSeconds -lt $Seconds) { return $entry.Value }
    $value = & $Compute
    $script:Cache[$Key] = @{ At = Get-Date; Value = $value }
    $value
}

#region Outils

function Format-Date($Date) {
    if (-not $Date) { return $null }
    $d = [datetime]$Date
    if ($d.Year -lt 2000) { return $null }
    if ($d.Date -eq (Get-Date).Date) { return "aujourd'hui " + $d.ToString('HH:mm', $script:Fr) }
    $d.ToString('ddd d MMM HH:mm', $script:Fr)
}

$script:Tools = @{}
function Test-Tool([string]$Name) {
    if (-not $script:Tools.ContainsKey($Name)) { $script:Tools[$Name] = [bool](Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue) }
    $script:Tools[$Name]
}

function Invoke-Tool([string]$Name, [string[]]$Arguments) {
    if (-not (Test-Tool $Name)) { return @() }
    & $Name @Arguments 2>$null
}

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

# Ligne de commande sans secrets évidents (--password=…, token …, identifiants dans une URL).
function Hide-Secrets([string]$CommandLine) {
    if (-not $CommandLine) { return $null }
    $masked = $CommandLine -replace '(?i)((?:--?|/)?(?:pass(?:word|wd)?|pwd|token|secret|api[-_]?key|auth)[=:\s]+)("[^"]*"|\S+)', '$1***'
    $masked = $masked -replace '(?i)(\w+://[^/\s:@]+:)[^@\s/]+@', '$1***@'
    if ($masked.Length -gt 300) { $masked.Substring(0, 300) + '…' } else { $masked }
}

# Signes d'une tâche suspecte dans sa commande (les deux OS) ; rien = $null.
function Get-SuspiciousReasons([string]$Command, [bool]$Hidden, [bool]$Microsoft) {
    if (-not $Command) { return @() }
    $reasons = @()
    if ($Command -match '(?i)(\\AppData\\Local\\Temp\\|\\Temp\\|\\Users\\Public\\|\\Downloads\\|(^|\s|["''])/(tmp|var/tmp|dev/shm)/)') { $reasons += 'programme dans un dossier temporaire ou public' }
    if ($Command -match '(?i)(-enc(odedcommand)?\s|-e\s+[A-Za-z0-9+/=]{20,}|frombase64string|base64\s+(-d|--decode))') { $reasons += 'commande encodée (base64)' }
    if ($Command -match '(?i)(iex|invoke-expression|downloadstring|downloadfile|invoke-webrequest|\biwr\b|start-bitstransfer)') { $reasons += 'télécharge ou exécute du code' }
    if ($Command -match '(?i)(curl|wget)\b[^|;]*\|\s*(ba|z|da)?sh\b') { $reasons += 'télécharge puis exécute un script' }
    if ($Command -match '(?i)\b(mshta|regsvr32\s+/s.*?/i:|certutil.*-urlcache|bitsadmin\s+/transfer)') { $reasons += 'outil système détourné (mshta, regsvr32, certutil, bitsadmin)' }
    if ($Command -match '(?i)\b(nc|ncat|netcat)\b.*\s-e\s|/dev/tcp/') { $reasons += 'ouvre un accès réseau à un shell' }
    if ($Command -match '(?i)-w(indowstyle)?\s+hidden' -and -not $Microsoft) { $reasons += 'fenêtre masquée' }
    if ($Hidden -and -not $Microsoft -and $Command -match '(?i)\\AppData\\') { $reasons += 'tâche masquée lançant un programme du profil' }
    $reasons
}

#endregion

#region Windows

$script:TriggerTypes = @{ 0 = 'à un événement'; 1 = 'une fois'; 2 = 'chaque jour'; 3 = 'chaque semaine'; 4 = 'chaque mois'; 5 = 'chaque mois (jour de la semaine)'
    6 = 'à l''inactivité'; 7 = 'à la création'; 8 = 'au démarrage'; 9 = 'à l''ouverture de session'; 11 = 'au verrouillage / déverrouillage' }
$script:TaskStates = @{ 0 = 'Inconnu'; 1 = 'Désactivée'; 2 = 'En file'; 3 = 'Prête'; 4 = 'En cours' }

# Résultats courants du Planificateur (LastTaskResult) qui ne sont pas des échecs.
$script:NotFailures = @(0, 0x41300, 0x41301, 0x41302, 0x41303, 0x41304, 0x41305, 0x41306, 0x41325, 0x8004131F, 0x800710E0)

function Get-WindowsTasks {
    Get-Cached 'windowsTasks' 300 {
        $service = New-Object -ComObject Schedule.Service
        $service.Connect()
        $folders = [System.Collections.Generic.Queue[object]]::new()
        $folders.Enqueue($service.GetFolder('\'))
        $signatures = @{}
        while ($folders.Count) {
            $folder = $folders.Dequeue()
            foreach ($sub in $folder.GetFolders(0)) { $folders.Enqueue($sub) }
            foreach ($t in $folder.GetTasks(1)) {
                $def = $t.Definition
                $microsoft = $t.Path -like '\Microsoft\*'
                $actions = foreach ($a in $def.Actions) {
                    if ($a.Type -eq 0) { ('{0} {1}' -f $a.Path, $a.Arguments).Trim() } elseif ($a.Type -eq 5) { 'action COM' } else { 'action' }
                }
                $command = $actions -join ' ; '
                $triggers = @(foreach ($tr in $def.Triggers) { $script:TriggerTypes[[int]$tr.Type] ?? "déclencheur $($tr.Type)" }) -join ', '
                $result = [int64]$t.LastTaskResult; if ($result -lt 0) { $result += 0x100000000 }
                $hidden = [bool]$def.Settings.Hidden
                $reasons = @(Get-SuspiciousReasons $command $hidden $microsoft)
                # Programme hors dossiers système et non signé : suspect hors \Microsoft\.
                $exe = @($def.Actions | Where-Object Type -eq 0 | ForEach-Object { [Environment]::ExpandEnvironmentVariables(($_.Path -replace '"', '')) }) | Select-Object -First 1
                if (-not $microsoft -and $exe -and $exe -notmatch '(?i)^(C:\\Windows\\|%windir%|%SystemRoot%)' -and (Test-Path -LiteralPath $exe -ErrorAction SilentlyContinue)) {
                    if (-not $signatures.ContainsKey($exe)) { $signatures[$exe] = (Get-AuthenticodeSignature -LiteralPath $exe -ErrorAction SilentlyContinue).Status }
                    if ("$($signatures[$exe])" -ne 'Valid' -and $exe -match '(?i)\\(AppData|ProgramData|Users)\\') { $reasons += 'programme non signé dans un dossier modifiable par l''utilisateur' }
                }
                [PSCustomObject]@{
                    Source = 'Planificateur'; Id = $t.Path; Name = $t.Name; Folder = Split-Path $t.Path
                    Schedule = if ($triggers) { $triggers } else { 'à la demande' }; Command = Hide-Secrets $command
                    Account = "$($def.Principal.UserId)"; Enabled = [bool]$t.Enabled; State = $script:TaskStates[[int]$t.State]
                    Last = if ($t.LastRunTime.Year -gt 2000) { $t.LastRunTime } else { $null }; Next = if ($t.NextRunTime.Year -gt 2000) { $t.NextRunTime } else { $null }
                    Result = if ($t.LastRunTime.Year -gt 2000) { '0x{0:X}' -f $result } else { $null }
                    Failed = $t.Enabled -and $t.LastRunTime.Year -gt 2000 -and $result -notin $script:NotFailures
                    Missed = [int]$t.NumberOfMissedRuns; Hidden = $hidden; Microsoft = $microsoft; Suspicious = $reasons; Unit = $null; User = $false
                }
            }
        }
    }
}

#endregion

#region Linux

# Planification systemd en français : « *-*-* 00:00:00 » → « chaque jour à 00:00 », « OnBootUSec=10min » → « 10min après le démarrage ».
$script:Days = @{ Mon = 'lundi'; Tue = 'mardi'; Wed = 'mercredi'; Thu = 'jeudi'; Fri = 'vendredi'; Sat = 'samedi'; Sun = 'dimanche' }
function ConvertTo-ScheduleText([string]$Calendar, [string]$Monotonic) {
    $parts = foreach ($m in [regex]::Matches("$Calendar", 'OnCalendar=([^;]+)')) {
        $c = $m.Groups[1].Value.Trim()
        switch -Regex ($c) {
            '^\*-\*-\* (\d\d):(\d\d):00$' { "chaque jour à $($Matches[1]):$($Matches[2])"; break }
            '^\*-\*-\* \*:(\d\d):00$' { "chaque heure à hh:$($Matches[1])"; break }
            '^(\w{3}) \*-\*-\* (\d\d):(\d\d):00$' { "chaque $($script:Days[$Matches[1]] ?? $Matches[1]) à $($Matches[2]):$($Matches[3])"; break }
            '^\*-\*-(\d\d) (\d\d):(\d\d):00$' { "chaque mois le $([int]$Matches[1]) à $($Matches[2]):$($Matches[3])"; break }
            '^\*-(\d\d)-(\d\d) (\d\d):(\d\d):00$' { "chaque année le $([int]$Matches[2])/$($Matches[1]) à $($Matches[3]):$($Matches[4])"; break }
            default { $c }
        }
    }
    $labels = @{ OnBootUSec = 'après le démarrage'; OnStartupUSec = 'après le démarrage du gestionnaire'; OnActiveUSec = 'après l''activation'; OnUnitActiveUSec = 'après la dernière exécution'; OnUnitInactiveUSec = 'après la fin de la dernière exécution' }
    $parts = @($parts) + @(foreach ($m in [regex]::Matches("$Monotonic", '\{ (\w+)=(\S+)')) {
            $what = $labels[$m.Groups[1].Value]
            if ($m.Groups[1].Value -eq 'OnUnitActiveUSec') { "toutes les $($m.Groups[2].Value)" } elseif ($what) { "$($m.Groups[2].Value) $what" } else { "$($m.Groups[1].Value) $($m.Groups[2].Value)" }
        })
    if ($parts) { ($parts | Where-Object { $_ }) -join ', ' } else { '—' }
}

# Minuteries systemd (système ou --user) avec le service qu'elles lancent et son dernier résultat.
function Get-SystemdTimers([bool]$User) {
    $scope = if ($User) { @('--user') } else { @() }
    $json = "$(Invoke-Tool systemctl (@($scope) + @('list-timers', '--all', '-o', 'json', '--no-pager')))"
    if (-not $json) { return @() }
    $timers = @($json | ConvertFrom-Json)
    if (-not $timers.Count) { return @() }
    # Un seul appel de systemctl show pour toutes les minuteries, un autre pour tous les services.
    $show = {
        param([string[]]$Units, [string]$Props)
        $map = @{}; $cur = @{}
        foreach ($line in Invoke-Tool systemctl (@($scope) + @('show') + $Units + @('-p', $Props, '--no-pager'))) {
            if ($line -eq '') { if ($cur.Id) { $map[$cur.Id] = $cur }; $cur = @{}; continue }
            $i = $line.IndexOf('=')
            if ($i -gt 0) { $k = $line.Substring(0, $i); $v = $line.Substring($i + 1); $cur[$k] = if ($cur.ContainsKey($k)) { "$($cur[$k]) ; $v" } else { $v } }
        }
        if ($cur.Id) { $map[$cur.Id] = $cur }
        $map
    }
    $timerInfo = & $show @($timers.unit) 'Id,Description,TimersCalendar,TimersMonotonic,UnitFileState,ActiveState,Persistent'
    $serviceInfo = & $show @($timers.activates | Where-Object { $_ }) 'Id,Result,ExecMainStatus,ExecMainExitTimestamp,ExecStart,ActiveState,User'
    $usec = { param($v) if ([double]$v -gt 0) { [DateTimeOffset]::FromUnixTimeMilliseconds([long]([double]$v / 1000)).LocalDateTime } else { $null } }
    foreach ($t in $timers) {
        $ti = $timerInfo[$t.unit] ?? @{}; $si = $serviceInfo[$t.activates] ?? @{}
        $schedule = ConvertTo-ScheduleText $ti.TimersCalendar $ti.TimersMonotonic
        $command = if ($si.ExecStart -match 'argv\[\]=([^;]+)') { $Matches[1].Trim() } else { $null }
        $failed = $si.Result -and $si.Result -ne 'success' -or ($si.ActiveState -eq 'failed')
        [PSCustomObject]@{
            Source = if ($User) { 'systemd (utilisateur)' } else { 'systemd' }; Id = $t.unit; Name = ($t.unit -replace '\.timer$', ''); Folder = $null
            Schedule = $schedule; Command = Hide-Secrets $command; Account = if ($User) { [Environment]::UserName } elseif ($si.User) { $si.User } else { 'root' }
            Enabled = $ti.UnitFileState -in 'enabled', 'static', 'linked', 'enabled-runtime' -or $ti.ActiveState -eq 'active'; State = $ti.ActiveState
            Last = & $usec $t.last; Next = & $usec $t.next
            Result = if ($si.Result) { if ($si.ExecMainStatus -and $si.ExecMainStatus -ne '0') { "$($si.Result) (code $($si.ExecMainStatus))" } else { $si.Result } } else { $null }
            Failed = [bool]$failed; Missed = 0; Hidden = $false; Microsoft = $false; Suspicious = @(Get-SuspiciousReasons $command $false $false)
            Unit = $t.activates; User = $User; Description = $ti.Description; FileState = $ti.UnitFileState
        }
    }
}

# Crons : crontab de l'utilisateur, /etc/crontab, /etc/cron.d, anacrontab et scripts de /etc/cron.<période>.
function Get-CronJobs {
    $jobs = [System.Collections.Generic.List[object]]::new()
    $add = {
        param([string]$Source, [string]$Line, [bool]$HasUser, [string]$File)
        $l = $Line.Trim()
        if (-not $l -or $l.StartsWith('#') -or $l -match '^\w+\s*=') { return }
        if ($l -match '^(@\w+)\s+(.*)$') { $schedule = $Matches[1]; $rest = $Matches[2] }
        elseif ($l -match '^((?:\S+\s+){4}\S+)\s+(.*)$') { $schedule = $Matches[1]; $rest = $Matches[2] }
        else { return }
        $account = [Environment]::UserName
        if ($HasUser -and $rest -match '^(\S+)\s+(.*)$') { $account = $Matches[1]; $rest = $Matches[2] }
        $jobs.Add([PSCustomObject]@{ Source = $Source; Id = "$File : $schedule $rest"; Name = (($rest -split '\s+')[0] | Split-Path -Leaf); Folder = $File; Schedule = $schedule
                Command = Hide-Secrets $rest; Account = $account; Enabled = $true; State = 'cron'; Last = $null; Next = $null; Result = $null; Failed = $false; Missed = 0
                Hidden = $false; Microsoft = $false; Suspicious = @(Get-SuspiciousReasons $rest $false $false); Unit = $null; User = -not $HasUser })
    }
    foreach ($line in Invoke-Tool crontab @('-l')) { & $add 'cron (utilisateur)' $line $false 'crontab' }
    foreach ($file in @('/etc/crontab') + @(Get-ChildItem /etc/cron.d -File -ErrorAction SilentlyContinue | ForEach-Object FullName)) {
        if (Test-Path -LiteralPath $file) { foreach ($line in [System.IO.File]::ReadAllLines($file)) { & $add 'cron' $line $true $file } }
    }
    if (Test-Path /etc/anacrontab) {
        foreach ($line in [System.IO.File]::ReadAllLines('/etc/anacrontab')) {
            if ($line -match '^\s*(@?\w+)\s+(\d+)\s+(\S+)\s+(.+)$' -and $line -notmatch '^\s*#') {
                $period = $Matches[1]; $id = $Matches[3]; $command = $Matches[4]
                $jobs.Add([PSCustomObject]@{ Source = 'anacron'; Id = "anacron : $id"; Name = $id; Folder = '/etc/anacrontab'
                        Schedule = $(if ($period -match '^\d+$') { if ($period -eq '1') { 'chaque jour' } else { "tous les $period jours" } } else { $period }); Command = Hide-Secrets $command; Account = 'root'
                        Enabled = $true; State = 'cron'; Last = $null; Next = $null; Result = $null; Failed = $false; Missed = 0; Hidden = $false; Microsoft = $false
                        Suspicious = @(Get-SuspiciousReasons $command $false $false); Unit = $null; User = $false })
            }
        }
    }
    foreach ($period in 'hourly', 'daily', 'weekly', 'monthly') {
        foreach ($f in Get-ChildItem "/etc/cron.$period" -File -ErrorAction SilentlyContinue) {
            $label = @{ hourly = 'chaque heure'; daily = 'chaque jour'; weekly = 'chaque semaine'; monthly = 'chaque mois' }[$period]
            $jobs.Add([PSCustomObject]@{ Source = 'cron'; Id = $f.FullName; Name = $f.Name; Folder = "/etc/cron.$period"; Schedule = $label; Command = $f.FullName; Account = 'root'
                    Enabled = $true; State = 'cron'; Last = $null; Next = $null; Result = $null; Failed = $false; Missed = 0; Hidden = $false; Microsoft = $false
                    Suspicious = @(); Unit = $null; User = $false })
        }
    }
    $jobs
}

#endregion

# Toutes les tâches (en cache 2 min ; Windows 5 min).
function Get-AllTasks {
    if ($IsWindows) { return @(Get-WindowsTasks) }
    Get-Cached 'linuxTasks' 110 {
        @(Get-SystemdTimers $false) + @(Get-SystemdTimers $true) + @(Get-CronJobs)
    }
}

function ConvertTo-TaskRow($Task) {
    $state = if (-not $Task.Enabled) { 'désactivée' } elseif ($Task.Failed) { 'en échec' } elseif ($Task.Suspicious.Count) { 'suspecte' } else { 'active' }
    , @($Task.Source, $(if ($Task.Folder -and $IsWindows -and $Task.Folder -ne '\') { "$($Task.Folder)\$($Task.Name)" } else { $Task.Name }), $Task.Schedule, (Format-Date $Task.Last), $Task.Result, (Format-Date $Task.Next), $state, $Task.Account, $Task.Command)
}

$script:TaskColumns = @('Source', 'Tâche', 'Planification', 'Dernière exécution', 'Résultat', 'Prochaine exécution', 'État', 'Compte', 'Commande')

#region Vue d'ensemble

function Get-ModuleData {
    $sections = [System.Collections.Generic.List[object]]::new()
    $findings = [System.Collections.Generic.List[object]]::new()
    $errors = [ordered]@{}
    $tasks = @(try { Get-AllTasks } catch { $errors['Tâches'] = $_.Exception.Message })

    $failed = @($tasks | Where-Object { $_.Failed })
    $suspicious = @($tasks | Where-Object { $_.Suspicious.Count })
    $disabled = @($tasks | Where-Object { -not $_.Enabled })
    $items = [ordered]@{ 'Tâches' = $tasks.Count; 'Actives' = $tasks.Count - $disabled.Count; 'Désactivées' = $disabled.Count; 'En échec' = $failed.Count; 'Suspectes' = $suspicious.Count }
    foreach ($g in $tasks | Group-Object Source) { $items["Source : $($g.Name)"] = $g.Count }
    if ($IsWindows) { $items['Hors \Microsoft\'] = @($tasks | Where-Object { -not $_.Microsoft }).Count }
    $sections.Add([PSCustomObject]@{ Title = 'Résumé'; Type = 'KeyValue'; Icon = 'timer'; Items = $items })

    if ($failed.Count) {
        $sections.Add([PSCustomObject]@{ Title = 'Tâches en échec'; Type = 'Table'; Icon = 'error_circle'; Columns = $script:TaskColumns; Rows = @($failed | ForEach-Object { ConvertTo-TaskRow $_ }) })
        foreach ($t in $failed | Select-Object -First 10) {
            $findings.Add((New-Finding 'warning' 'TSK-FAILED' ('{0} a échoué à sa dernière exécution ({1}, résultat {2}).' -f $t.Name, ((Format-Date $t.Last) ?? 'date inconnue'), $t.Result) $(if ($IsWindows) { 'Voir l''historique de la tâche (tasks_get_task) : programme absent, droits ou compte invalide.' } else { "Voir le journal du service (tasks_get_task, journalctl -u $($t.Unit))." })))
        }
    }
    if ($suspicious.Count) {
        $sections.Add([PSCustomObject]@{ Title = 'Tâches suspectes'; Type = 'Table'; Icon = 'warning'; Columns = @('Source', 'Tâche', 'Raisons', 'Compte', 'Commande')
                Rows = @($suspicious | ForEach-Object { , @($_.Source, $_.Name, ($_.Suspicious -join ', '), $_.Account, $_.Command) }) })
        foreach ($t in $suspicious | Select-Object -First 10) {
            $findings.Add((New-Finding 'warning' 'TSK-SUSPICIOUS' ('Tâche « {0} » suspecte : {1}.' -f $t.Name, ($t.Suspicious -join ', ')) 'Vérifier qui l''a créée et ce que lance la commande ; la désactiver (tasks_set_enabled) en cas de doute, puis lancer une analyse antivirus.'))
        }
    }
    $missed = @($tasks | Where-Object { $_.Missed -gt 0 -and -not $_.Microsoft })
    foreach ($t in $missed | Select-Object -First 5) { $findings.Add((New-Finding 'info' 'TSK-MISSED' ('{0} : {1} exécution(s) manquée(s) (machine éteinte ou en veille).' -f $t.Name, $t.Missed) 'Cocher « Exécuter la tâche dès que possible si un démarrage planifié est manqué » si elle est importante.')) }

    $upcoming = @($tasks | Where-Object { $_.Next -and $_.Enabled } | Sort-Object Next | Select-Object -First 10)
    if ($upcoming.Count) {
        $sections.Add([PSCustomObject]@{ Title = 'Prochaines exécutions'; Type = 'Table'; Icon = 'arrow_clockwise'; Columns = @('Prochaine exécution', 'Tâche', 'Source', 'Planification')
                Rows = @($upcoming | ForEach-Object { , @((Format-Date $_.Next), $_.Name, $_.Source, $_.Schedule) }) })
    }

    # Liste : sous Windows, les tâches hors \Microsoft\ (les autres via tasks_list).
    $shown = if ($IsWindows) { @($tasks | Where-Object { -not $_.Microsoft }) } else { $tasks }
    $sections.Add([PSCustomObject]@{ Title = $(if ($IsWindows) { 'Tâches hors \Microsoft\' } else { 'Toutes les tâches' }); Type = 'Table'; Icon = 'apps_list'; Columns = $script:TaskColumns
            Rows = @($shown | Sort-Object Source, Name | ForEach-Object { ConvertTo-TaskRow $_ }) })

    if ($IsLinux -and -not [Environment]::IsPrivilegedProcess) { $errors['Crontabs des autres comptes'] = 'lisibles en root seulement (/var/spool/cron)' }
    if ($errors.Count) { $sections.Add([PSCustomObject]@{ Title = 'Remarques et erreurs de collecte'; Type = 'KeyValue'; Icon = 'info'; Items = $errors }) }

    $parts = @('{0} tâche(s)' -f $tasks.Count)
    if ($failed.Count) { $parts += '{0} en échec' -f $failed.Count }
    if ($suspicious.Count) { $parts += '{0} suspecte(s)' -f $suspicious.Count }
    if ($upcoming.Count) { $parts += 'prochaine : {0} ({1})' -f $upcoming[0].Name, (Format-Date $upcoming[0].Next) }
    [PSCustomObject]@{ Subtitle = $parts -join ' · '; Sections = $sections.ToArray(); Findings = $findings.ToArray() }
}

#endregion

#region Fonctions ciblées

# tasks_list : liste filtrée.
function Get-SITasks {
    param(
        [string]$Filter,
        [ValidateSet('all', 'enabled', 'disabled', 'failed', 'suspicious')][string]$State = 'all',
        [ValidateSet('all', 'system', 'user', 'cron')][string]$Source = 'all',
        [bool]$IncludeMicrosoft = $true,
        [ValidateRange(1, 1000)][int]$Top = 100
    )
    $tasks = @(Get-AllTasks)
    if ($Filter) { $tasks = @($tasks | Where-Object { "$($_.Name) $($_.Folder) $($_.Command) $($_.Description)" -like "*$Filter*" }) }
    $tasks = @(switch ($State) {
            'enabled' { $tasks | Where-Object Enabled } 'disabled' { $tasks | Where-Object { -not $_.Enabled } }
            'failed' { $tasks | Where-Object Failed } 'suspicious' { $tasks | Where-Object { $_.Suspicious.Count } } default { $tasks } })
    $tasks = @(switch ($Source) {
            'system' { $tasks | Where-Object { $_.Source -in 'systemd', 'Planificateur' -and -not $_.User } }
            'user' { $tasks | Where-Object User } 'cron' { $tasks | Where-Object { $_.Source -like '*cron*' } } default { $tasks } })
    if (-not $IncludeMicrosoft) { $tasks = @($tasks | Where-Object { -not $_.Microsoft }) }
    $total = $tasks.Count
    [PSCustomObject]@{
        Subtitle = '{0} tâche(s){1}' -f $total, $(if ($total -gt $Top) { ", $Top affichées" } else { '' })
        Sections = @([PSCustomObject]@{ Title = 'Tâches'; Type = 'Table'; Icon = 'apps_list'; Columns = $script:TaskColumns; Rows = @($tasks | Sort-Object Source, Folder, Name | Select-Object -First $Top | ForEach-Object { ConvertTo-TaskRow $_ }) })
        Findings = @()
    }
}

# Retrouve une tâche par nom (Windows : nom ou chemin \Dossier\Nom ; Linux : nom de la minuterie, avec ou sans .timer).
function Find-Task([string]$Name) {
    $tasks = @(Get-AllTasks)
    $exact = @($tasks | Where-Object { $_.Id -eq $Name -or $_.Name -eq $Name -or $_.Id -eq "$Name.timer" })
    if ($exact.Count) { return $exact }
    @($tasks | Where-Object { $_.Name -like "*$Name*" })
}

# tasks_get_task : détail d'une tâche et historique de ses exécutions.
function Get-SITask {
    param([Parameter(Mandatory)][string]$Name, [ValidateRange(1, 200)][int]$Lines = 30)
    $found = @(Find-Task $Name)
    if (-not $found.Count) { throw "Aucune tâche « $Name » (tasks_list pour la liste)." }
    if ($found.Count -gt 1) { throw "Plusieurs tâches correspondent à « $Name » : $(($found | Select-Object -First 8 | ForEach-Object Id) -join ', ')." }
    $t = $found[0]
    $items = [ordered]@{ 'Tâche' = $t.Id; 'Source' = $t.Source; 'Description' = $t.Description ?? '—'; 'Planification' = $t.Schedule; 'Commande' = $t.Command ?? '—'; 'Compte' = $t.Account
        'Active' = if ($t.Enabled) { 'oui' } else { 'non' }; 'État' = $t.State; 'Dernière exécution' = (Format-Date $t.Last) ?? '—'; 'Résultat' = $t.Result ?? '—'; 'Prochaine exécution' = (Format-Date $t.Next) ?? '—' }
    if ($t.Unit) { $items['Service lancé'] = $t.Unit }
    if ($t.Suspicious.Count) { $items['Signes suspects'] = $t.Suspicious -join ', ' }
    if ($IsWindows) { $items['Masquée'] = if ($t.Hidden) { 'oui' } else { 'non' }; $items['Exécutions manquées'] = $t.Missed }
    $sections = [System.Collections.Generic.List[object]]::new()
    $sections.Add([PSCustomObject]@{ Title = 'Tâche'; Type = 'KeyValue'; Icon = 'timer'; Items = $items })

    $log = @()
    if ($IsLinux -and $t.Unit) {
        $journalArgs = @(if ($t.User) { '--user-unit' } else { '-u' }) + @($t.Unit, '-n', "$Lines", '-o', 'short-iso', '--no-pager', '-q')
        $log = foreach ($line in Invoke-Tool journalctl $journalArgs) { if ($line -match '^(\S+)\s+\S+\s+([^:]+):\s?(.*)$') { , @($Matches[1], $Matches[2], (Hide-Secrets $Matches[3])) } }
    }
    elseif ($IsWindows) {
        $xpath = "*[EventData[Data[@Name='TaskName']='$($t.Id -replace "'", '')']]"
        $log = foreach ($e in Get-WinEvent -LogName 'Microsoft-Windows-TaskScheduler/Operational' -FilterXPath $xpath -MaxEvents $Lines -ErrorAction SilentlyContinue) {
            , @($e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'), "$($e.Id)", (($e.Message -split "`r?`n")[0]))
        }
    }
    if ($log) { $sections.Add([PSCustomObject]@{ Title = 'Dernières exécutions (journal)'; Type = 'Table'; Icon = 'info'; Columns = @('Heure', 'Source', 'Message'); Rows = @($log) }) }
    $findings = @()
    if ($t.Failed) { $findings += New-Finding 'warning' 'TSK-FAILED' "$($t.Name) a échoué à sa dernière exécution ($($t.Result))." 'Voir le journal ci-dessus.' }
    if ($t.Suspicious.Count) { $findings += New-Finding 'warning' 'TSK-SUSPICIOUS' "Tâche suspecte : $($t.Suspicious -join ', ')." 'Vérifier son origine ; la désactiver en cas de doute.' }
    if (-not $log -and $IsWindows) { $findings += New-Finding 'info' 'TSK-HISTORY-OFF' 'Pas d''historique : le journal TaskScheduler/Operational est désactivé (Planificateur › Activer l''historique de toutes les tâches).' $null }
    [PSCustomObject]@{ Subtitle = "$($t.Name) · $($t.Schedule)"; Sections = $sections.ToArray(); Findings = $findings }
}

# Vérifications communes aux actions : tâche unique, pilotable, droits.
function Get-ActionTarget([string]$Name) {
    $found = @(Find-Task $Name)
    if (-not $found.Count) { return @{ Blocked = "Aucune tâche « $Name » (tasks_list pour la liste)." } }
    if ($found.Count -gt 1) { return @{ Blocked = "Plusieurs tâches correspondent à « $Name » : $(($found | Select-Object -First 8 | ForEach-Object Id) -join ', ')." } }
    $t = $found[0]
    if ($t.Source -like '*cron*') { return @{ Task = $t; Blocked = 'Les crons se modifient dans leur fichier (crontab -e, /etc/cron.d) : non piloté par SysInfo.' } }
    if ($IsLinux -and -not $t.User -and -not [Environment]::IsPrivilegedProcess) { return @{ Task = $t; Blocked = "$($t.Id) est une minuterie système : droits root requis (lancer SysInfo avec sudo)." } }
    @{ Task = $t; Blocked = $null }
}

function Get-TaskSection($Task) {
    [PSCustomObject]@{ Title = 'Tâche'; Type = 'KeyValue'; Icon = 'timer'; Items = [ordered]@{ 'Tâche' = $Task.Id; 'Source' = $Task.Source; 'Planification' = $Task.Schedule; 'Commande' = $Task.Command ?? '—'
            'Compte' = $Task.Account; 'Active' = if ($Task.Enabled) { 'oui' } else { 'non' }; 'Dernière exécution' = (Format-Date $Task.Last) ?? '—'; 'Résultat' = $Task.Result ?? '—' } }
}

# tasks_run : exécute une tâche tout de suite (Windows : Run ; Linux : démarre le service de la minuterie).
function Start-SITask {
    param([Parameter(Mandatory)][string]$Name, [switch]$DryRun)
    $target = Get-ActionTarget $Name
    $t = $target.Task
    $blocked = $target.Blocked
    if (-not $blocked -and $IsWindows -and -not $t.Enabled) { $blocked = "$($t.Name) est désactivée : l'activer d'abord (tasks_set_enabled)." }
    if (-not $blocked -and $t.State -in 'En cours', 'activating') { $blocked = "$($t.Name) est déjà en cours d'exécution." }
    $findings = @()
    if ($t.Suspicious.Count) { $findings += New-Finding 'warning' 'TSK-SUSPICIOUS' "Tâche suspecte : $($t.Suspicious -join ', '). L'exécuter lancera cette commande." 'Ne pas l''exécuter sans savoir d''où elle vient.' }
    $section = if ($t) { Get-TaskSection $t } else { $null }
    $label = if ($t) { $t.Name } else { $Name }
    $change = New-Change $label 'Exécution' 'planifiée' 'lancée maintenant'
    if ($DryRun -or $blocked) { return New-ActionResult "$label sera exécutée maintenant" @($section) $findings @($change) $blocked $null }

    if ($IsWindows) {
        $service = New-Object -ComObject Schedule.Service; $service.Connect()
        [void]$service.GetFolder($t.Folder).GetTask($t.Name).Run($null)
    }
    else {
        [string[]]$scope = if ($t.User) { @('--user') } else { @() }
        $out = & systemctl @scope start --no-block $t.Unit 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Lancement refusé : $($out -join ' ')" }
    }
    $script:Cache.Clear()
    New-ActionResult "$label lancée" @($section) @() @($change) $null $null
}

# tasks_set_enabled : active ou désactive une tâche (Windows : Enabled ; Linux : systemctl enable/disable --now de la minuterie).
function Set-SITaskEnabled {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][bool]$Enabled, [bool]$Persistent = $true, [switch]$DryRun)
    $target = Get-ActionTarget $Name
    $t = $target.Task
    $blocked = $target.Blocked
    if (-not $blocked -and $t.Enabled -eq $Enabled) { $blocked = "$($t.Name) est déjà $(if ($Enabled) { 'active' } else { 'désactivée' })." }
    if (-not $blocked -and $IsLinux -and -not $Enabled -and $t.Id -match '^(systemd-tmpfiles-clean|logrotate|fstrim|man-db|shadow|raid-check)') {
        $blocked = "$($t.Id) assure l'entretien du système : non désactivée par SysInfo."
    }
    $findings = @()
    if (-not $Enabled -and $t.Microsoft) { $findings += New-Finding 'info' 'TSK-DISABLE-MICROSOFT' "Tâche de Windows : la désactiver peut empêcher une fonction du système (mises à jour, maintenance, diagnostics)." 'La réactiver si un problème apparaît (annulation dans l''onglet Audit).' }
    $section = if ($t) { Get-TaskSection $t } else { $null }
    $label = if ($t) { $t.Name } else { $Name }
    $yesNo = { param($v) if ($null -eq $v) { $null } elseif ($v) { 'oui' } else { 'non' } }
    $change = New-Change $label 'Active' (& $yesNo $t.Enabled) (& $yesNo $Enabled)
    if ($DryRun -or $blocked) { return New-ActionResult "$label sera $(if ($Enabled) { 'activée' } else { 'désactivée' })" @($section) $findings @($change) $blocked $null }

    if ($IsWindows) {
        $service = New-Object -ComObject Schedule.Service; $service.Connect()
        $task = $service.GetFolder($t.Folder).GetTask($t.Name)
        $task.Enabled = $Enabled
    }
    else {
        [string[]]$scope = if ($t.User) { @('--user') } else { @() }
        # Minuterie lancée sans être activée (voulue par une autre unité) : on l'arrête seulement, sans toucher à son fichier.
        $persist = $Persistent -and ($Enabled -or $t.FileState -eq 'enabled')
        $verb = if ($Enabled) { if ($persist) { 'enable' } else { 'start' } } else { if ($persist) { 'disable' } else { 'stop' } }
        [string[]]$extra = if ($persist) { @('--now') } else { @() }
        $out = & systemctl @scope $verb @extra $t.Id 2>&1
        if ($LASTEXITCODE -ne 0) { throw "systemctl $verb a échoué : $($out -join ' ')" }
    }
    $script:Cache.Clear()
    $after = @(Find-Task $t.Id) | Select-Object -First 1
    $undo = @{ Function = 'set_enabled'; Parameters = @{ name = $t.Id; enabled = -not $Enabled; persistent = [bool]($IsWindows -or $persist) } }
    New-ActionResult "$label $(if ($Enabled) { 'activée' } else { 'désactivée' })" @(Get-TaskSection ($after ?? $t)) @() @(New-Change $label 'Active' (& $yesNo $t.Enabled) (& $yesNo ($after.Enabled ?? $Enabled))) $null $undo
}

#endregion

Export-ModuleMember -Function Get-ModuleData, Get-SITasks, Get-SITask, Start-SITask, Set-SITaskEnabled
