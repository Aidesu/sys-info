# Module Sauvegarde : outils et tâches de sauvegarde, date et résultat de la dernière sauvegarde, synchronisation
# (OneDrive, Nextcloud, Syncthing…), points de restauration et instantanés. Alerte « aucune sauvegarde depuis X jours ».
# Les points de restauration se créent dans le module Maintenance (maintenance_create_restore_point).
#
# Sources
#   Windows : Restauration du système (CIM SystemRestore, administrateur ; registre et stratégie), vssadmin list shadows
#             (administrateur), Historique des fichiers (configuration %LOCALAPPDATA%\Microsoft\Windows\FileHistory,
#             journal FileHistory-Core), Sauvegarde Windows (journal Microsoft-Windows-Backup), OneDrive (registre,
#             dossiers protégés = dossiers connus redirigés), services et programmes d'outils tiers (Veeam, Macrium…).
#   Linux   : minuteries systemd et crons dont le nom ou la commande évoque une sauvegarde (restic, borg, rsync…),
#             outils installés (restic, borg, borgmatic, kopia, rclone, rsnapshot, duplicity, Déjà Dup, Pika, Vorta,
#             btrbk, Timeshift, snapper ; Flatpak compris), Déjà Dup (gsettings last-backup), snapper / Timeshift (root),
#             Nextcloud, Syncthing, Dropbox, OneDrive (abraunegg), rclone (noms des remotes seulement).
# Jamais exposé : identifiants, mots de passe des dépôts, contenu des sauvegardes.

$script:Fr = [cultureinfo]::GetCultureInfo('fr-FR')
$script:Nbsp = [char]0x00A0
$script:UserHome = [Environment]::GetFolderPath('UserProfile')

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
    $d.ToString('ddd d MMM yyyy HH:mm', $script:Fr)
}

function Format-Age($Date) {
    if (-not $Date) { return 'jamais' }
    $days = ((Get-Date) - [datetime]$Date).TotalDays
    if ($days -lt 1) { return "il y a $([Math]::Max(1, [Math]::Round($days * 24))) h" }
    "il y a $([Math]::Floor($days)) jour(s)"
}

function Read-Text([string]$Path) { try { [System.IO.File]::ReadAllText($Path) } catch { $null } }

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

function Test-Elevated { [Environment]::IsPrivilegedProcess }

# Processus en cours (noms), relus toutes les 30 s.
function Get-ProcessNames { Get-Cached 'procs' 30 { @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object ProcessName | Sort-Object -Unique) } }

#endregion

#region Outils de sauvegarde et tâches

# Motif des tâches de sauvegarde (minuteries systemd, crons, tâches planifiées Windows).
$script:JobPattern = '(?i)(backup|sauvegard|restic|borg|kopia|rsnapshot|rsync|duplicity|duplicacy|deja-?dup|btrbk|timeshift|snapper|bacula|urbackup|veeam|macrium|acronis|rclone)'

# Outils de sauvegarde connus : nom affiché, commandes, applications Flatpak, services Windows, processus.
$script:KnownTools = @(
    @{ Name = 'restic'; Commands = 'restic' }, @{ Name = 'BorgBackup'; Commands = 'borg' }, @{ Name = 'borgmatic'; Commands = 'borgmatic' }
    @{ Name = 'Kopia'; Commands = 'kopia'; Flatpak = 'io.kopia.KopiaUI' }, @{ Name = 'rsnapshot'; Commands = 'rsnapshot' }, @{ Name = 'Duplicity'; Commands = 'duplicity' }
    @{ Name = 'Déjà Dup'; Commands = 'deja-dup'; Flatpak = 'org.gnome.DejaDup' }, @{ Name = 'Pika Backup'; Commands = 'pika-backup'; Flatpak = 'org.gnome.World.PikaBackup' }
    @{ Name = 'Vorta'; Commands = 'vorta'; Flatpak = 'com.borgbase.Vorta' }, @{ Name = 'btrbk'; Commands = 'btrbk' }, @{ Name = 'Timeshift'; Commands = 'timeshift' }
    @{ Name = 'snapper'; Commands = 'snapper' }, @{ Name = 'Bacula / Bareos'; Commands = 'bacula-fd', 'bareos-fd' }, @{ Name = 'UrBackup'; Commands = 'urbackupclientctl'; Services = 'UrBackupClientBackend' }
    @{ Name = 'Veeam Agent'; Commands = 'veeamconfig'; Services = 'VeeamEndpointBackupSvc' }, @{ Name = 'Macrium Reflect'; Services = 'MacriumService', 'ReflectService' }
    @{ Name = 'Acronis'; Services = 'AcronisCyberProtectionService', 'syncagentsrv', 'afcdpsrv' }, @{ Name = 'Backblaze'; Services = 'bzserv' }, @{ Name = 'Carbonite'; Services = 'CarboniteService' }
    @{ Name = 'Duplicati'; Commands = 'duplicati'; Services = 'Duplicati' }, @{ Name = 'Cobian Backup'; Services = 'CobianReflectorService', 'CobianBackup11' }, @{ Name = 'AOMEI Backupper'; Services = 'Backupper Service' }
    @{ Name = 'EaseUS Todo Backup'; Services = 'EaseUS Agent' }, @{ Name = 'Iperius Backup'; Services = 'IperiusService' }, @{ Name = 'IDrive'; Services = 'IDriveService' }
    @{ Name = 'Arq'; Services = 'ArqAgent' }, @{ Name = 'CrashPlan'; Services = 'CrashPlanService', 'Code42Service' }
)

# Outils de sauvegarde présents (en cache 10 min).
function Get-BackupTools {
    Get-Cached 'tools' 600 {
        $flatpaks = if ($IsLinux -and (Test-Tool flatpak)) { @(Invoke-Tool flatpak @('list', '--app', '--columns=application')) } else { @() }
        $services = if ($IsWindows) { @(Get-Service -ErrorAction SilentlyContinue) } else { @() }
        foreach ($t in $script:KnownTools) {
            $how = @()
            foreach ($c in @($t.Commands)) { if ($c -and (Test-Tool $c)) { $how += "commande $c" } }
            if ($t.Flatpak -and $flatpaks -contains $t.Flatpak) { $how += 'Flatpak' }
            foreach ($s in @($t.Services)) { $svc = $services | Where-Object Name -eq $s | Select-Object -First 1; if ($svc) { $how += "service $s ($($svc.Status))" } }
            if ($how) { [PSCustomObject]@{ Name = $t.Name; How = $how -join ', ' } }
        }
    }
}

# Tâches de sauvegarde : minuteries systemd et crons (Linux), tâches planifiées (Windows) dont le nom ou la commande
# évoque une sauvegarde, avec dernière exécution et résultat.
function Get-BackupJobs {
    Get-Cached 'jobs' 120 {
        if ($IsWindows) {
            try {
                $service = New-Object -ComObject Schedule.Service; $service.Connect()
                $queue = [System.Collections.Generic.Queue[object]]::new(); $queue.Enqueue($service.GetFolder('\'))
                while ($queue.Count) {
                    $f = $queue.Dequeue()
                    foreach ($sub in $f.GetFolders(0)) { $queue.Enqueue($sub) }
                    foreach ($t in $f.GetTasks(1)) {
                        $cmd = (@($t.Definition.Actions | Where-Object Type -eq 0 | ForEach-Object { "$($_.Path) $($_.Arguments)" }) -join ' ; ')
                        if ("$($t.Path) $cmd" -notmatch $script:JobPattern -or $t.Path -like '\Microsoft\*') { continue }
                        $result = [int64]$t.LastTaskResult; if ($result -lt 0) { $result += 0x100000000 }
                        [PSCustomObject]@{ Source = 'Planificateur'; Name = $t.Path; Last = if ($t.LastRunTime.Year -gt 2000) { $t.LastRunTime } else { $null }
                            Next = if ($t.NextRunTime.Year -gt 2000) { $t.NextRunTime } else { $null }; Ok = $result -in 0, 0x41301; Result = '0x{0:X}' -f $result; Enabled = [bool]$t.Enabled; Unit = $null; User = $false }
                    }
                }
            }
            catch { }
            return
        }
        foreach ($user in $false, $true) {
            [string[]]$scope = if ($user) { @('--user') } else { @() }
            $json = "$(Invoke-Tool systemctl ($scope + @('list-timers', '--all', '-o', 'json', '--no-pager')))"
            if (-not $json) { continue }
            foreach ($t in @($json | ConvertFrom-Json)) {
                if ("$($t.unit) $($t.activates)" -notmatch $script:JobPattern) { continue }
                $show = @{}
                foreach ($line in Invoke-Tool systemctl ($scope + @('show', $t.activates, '-p', 'Result,ExecMainStatus,ActiveState,ExecMainExitTimestamp', '--timestamp=unix', '--no-pager'))) { $i = $line.IndexOf('='); if ($i -gt 0) { $show[$line.Substring(0, $i)] = $line.Substring($i + 1) } }
                $usec = { param($v) if ([double]$v -gt 0) { [DateTimeOffset]::FromUnixTimeMilliseconds([long]([double]$v / 1000)).LocalDateTime } else { $null } }
                # Dernière exécution : celle de la minuterie, sinon la fin du service (lancé à la main).
                $last = & $usec $t.last
                if (-not $last -and $show.ExecMainExitTimestamp -match '^@(\d+)') { $last = [DateTimeOffset]::FromUnixTimeSeconds([long]$Matches[1]).LocalDateTime }
                [PSCustomObject]@{ Source = if ($user) { 'systemd (utilisateur)' } else { 'systemd' }; Name = $t.unit; Last = $last; Next = & $usec $t.next
                    Ok = $show.Result -eq 'success' -and $show.ActiveState -ne 'failed'; Result = $show.Result; Enabled = $true; Unit = $t.activates; User = $user }
            }
        }
        $cron = @(Invoke-Tool crontab @('-l')) + @(Get-ChildItem /etc/cron.d -File -ErrorAction SilentlyContinue | ForEach-Object { Read-Text $_.FullName } | ForEach-Object { $_ -split "`n" })
        foreach ($line in $cron) {
            if ($line -and $line -notmatch '^\s*#' -and $line -match $script:JobPattern -and $line -match '^\s*(@\w+|(\S+\s+){4}\S+)\s+(.+)$') {
                [PSCustomObject]@{ Source = 'cron'; Name = ($line.Trim() -replace '(?i)(pass(word)?|token|key)=\S+', '$1=***'); Last = $null; Next = $null; Ok = $null; Result = $null; Enabled = $true; Unit = $null; User = $false }
            }
        }
        foreach ($f in Get-ChildItem /etc/cron.daily, /etc/cron.weekly, /etc/cron.monthly -File -ErrorAction SilentlyContinue) {
            if ($f.Name -match $script:JobPattern) { [PSCustomObject]@{ Source = 'cron'; Name = $f.FullName; Last = $null; Next = $null; Ok = $null; Result = $null; Enabled = $true; Unit = $null; User = $false } }
        }
    }
}

# Sauvegardes dont l'application garde la date : Déjà Dup, Historique des fichiers, Sauvegarde Windows.
function Get-KnownLastBackups {
    Get-Cached 'lastBackups' 300 {
        if ($IsLinux -and (Test-Tool gsettings)) {
            $schemas = @(Invoke-Tool gsettings @('list-schemas'))
            if ($schemas -contains 'org.gnome.DejaDup') {
                $last = "$(Invoke-Tool gsettings @('get', 'org.gnome.DejaDup', 'last-backup'))".Trim("'", ' ')
                $date = $null
                if ($last -and [datetime]::TryParse($last, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$date)) {
                    [PSCustomObject]@{ Tool = 'Déjà Dup'; Last = $date; Ok = $true; Detail = 'gsettings org.gnome.DejaDup last-backup' }
                }
            }
        }
        if ($IsWindows) {
            # Historique des fichiers : configuration (cible, activé) et dernier « sauvegarde terminée » du journal.
            $config = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Windows\FileHistory\Configuration\Config*.xml" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($config) {
                $xml = try { [xml](Get-Content -LiteralPath $config.FullName -Raw) } catch { $null }
                $enabled = "$($xml.DataProtectionUserConfig.UserConfig.ProtectionEnabled)" -ne '0'
                $event = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-FileHistory-Core/WHC'; Id = 201, 202 } -MaxEvents 1 -ErrorAction SilentlyContinue
                [PSCustomObject]@{ Tool = 'Historique des fichiers'; Last = $event.TimeCreated; Ok = $enabled; Detail = $(if ($enabled) { 'activé' } else { 'désactivé' }) }
            }
            $backup = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Backup'; Id = 4, 5, 8, 9, 14, 17, 18, 19, 20, 21, 22, 49, 50, 52, 100, 517, 518, 521, 527, 528, 544, 545, 546, 561, 564, 612 } -MaxEvents 1 -ErrorAction SilentlyContinue
            if ($backup) { [PSCustomObject]@{ Tool = 'Sauvegarde Windows (wbadmin)'; Last = $backup.TimeCreated; Ok = $backup.Id -in 4, 14; Detail = ($backup.Message -split "`r?`n")[0] } }
        }
    }
}

#endregion

#region Synchronisation

# Clients de synchronisation : dossiers synchronisés, en cours ou non. Ce n'est pas une sauvegarde (une suppression est synchronisée).
function Get-SyncClients {
    Get-Cached 'sync' 300 {
        $procs = Get-ProcessNames
        if ($IsWindows) {
            foreach ($key in Get-ChildItem 'HKCU:\Software\Microsoft\OneDrive\Accounts' -ErrorAction SilentlyContinue) {
                $p = Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue
                if (-not $p.UserFolder) { continue }
                # Dossiers protégés : dossiers connus (Bureau, Documents, Images) redirigés dans OneDrive.
                $shell = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction SilentlyContinue
                $protected = @(foreach ($f in @(@('Desktop', 'Bureau'), @('Personal', 'Documents'), @('My Pictures', 'Images'))) {
                        $path = [Environment]::ExpandEnvironmentVariables("$($shell.($f[0]))")
                        if ($path -and $path.StartsWith($p.UserFolder, [StringComparison]::OrdinalIgnoreCase)) { $f[1] }
                    })
                [PSCustomObject]@{ Name = "OneDrive ($($key.PSChildName -replace '^Business', 'professionnel ' -replace '^Personal', 'personnel'))"; Folders = $p.UserFolder
                    Running = $procs -contains 'OneDrive'; Detail = $(if ($protected) { 'dossiers protégés : ' + ($protected -join ', ') } else { 'aucun dossier connu protégé' }) }
            }
            foreach ($c in @(@('Dropbox', 'Dropbox'), @('Google Drive', 'GoogleDriveFS'), @('Nextcloud', 'nextcloud'), @('iCloud', 'iCloudDrive'))) {
                if ($procs -contains $c[1]) { [PSCustomObject]@{ Name = $c[0]; Folders = '—'; Running = $true; Detail = 'en cours' } }
            }
            return
        }
        $nc = Join-Path $script:UserHome '.config/Nextcloud/nextcloud.cfg'
        if (Test-Path -LiteralPath $nc) {
            $folders = @([regex]::Matches((Read-Text $nc), '(?m)^\d+\\Folders\\\d+\\localPath=(.+)$').ForEach({ $_.Groups[1].Value.Trim() }))
            [PSCustomObject]@{ Name = 'Nextcloud'; Folders = ($folders -join ', '); Running = $procs -contains 'nextcloud'; Detail = '{0} dossier(s)' -f $folders.Count }
        }
        foreach ($cfg in (Join-Path $script:UserHome '.local/state/syncthing/config.xml'), (Join-Path $script:UserHome '.config/syncthing/config.xml')) {
            if (-not (Test-Path -LiteralPath $cfg)) { continue }
            $xml = try { [xml](Read-Text $cfg) } catch { $null }
            $folders = @($xml.configuration.folder | ForEach-Object { $_.path })
            [PSCustomObject]@{ Name = 'Syncthing'; Folders = ($folders -join ', '); Running = $procs -contains 'syncthing'; Detail = '{0} dossier(s), {1} appareil(s)' -f $folders.Count, @($xml.configuration.device).Count }
            break
        }
        if (Test-Path -LiteralPath (Join-Path $script:UserHome '.dropbox/info.json')) {
            $info = try { Read-Text (Join-Path $script:UserHome '.dropbox/info.json') | ConvertFrom-Json } catch { $null }
            [PSCustomObject]@{ Name = 'Dropbox'; Folders = (@($info.PSObject.Properties.Value.path) -join ', '); Running = $procs -contains 'dropbox'; Detail = '' }
        }
        if (Test-Path -LiteralPath (Join-Path $script:UserHome '.config/onedrive')) {
            [PSCustomObject]@{ Name = 'OneDrive (client onedrive)'; Folders = (Join-Path $script:UserHome 'OneDrive'); Running = $procs -contains 'onedrive'; Detail = '' }
        }
        if (Test-Tool rclone) {
            # Noms des remotes seulement (jamais la configuration : elle contient des jetons).
            $remotes = @(Invoke-Tool rclone @('listremotes'))
            if ($remotes) { [PSCustomObject]@{ Name = 'rclone'; Folders = ($remotes -join ', '); Running = $procs -contains 'rclone'; Detail = '{0} remote(s)' -f $remotes.Count } }
        }
    }
}

#endregion

#region Points de restauration et instantanés

function Get-Snapshots {
    Get-Cached 'snapshots' 300 {
        $r = [ordered]@{ Tool = $null; Enabled = $null; Problem = $null; Points = @(); Denied = $false }
        if ($IsWindows) {
            $r.Tool = 'Restauration du système'
            $policy = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore' -ErrorAction SilentlyContinue
            if ($policy.DisableSR -eq 1) { $r.Enabled = $false; $r.Problem = 'désactivée par une stratégie' }
            if (Test-Elevated) {
                $types = @{ 0 = 'Installation'; 1 = 'Désinstallation'; 10 = 'Pilote'; 12 = 'Modification de paramètres'; 13 = 'Annulation' }
                $r.Points = @(Get-CimInstance -Namespace root/default -ClassName SystemRestore -ErrorAction SilentlyContinue | Sort-Object SequenceNumber -Descending | ForEach-Object {
                        [PSCustomObject]@{ Date = [Management.ManagementDateTimeConverter]::ToDateTime($_.CreationTime); Description = $_.Description; Type = $types[[int]$_.RestorePointType] ?? "$($_.RestorePointType)"; Volume = 'système' }
                    })
                if ($null -eq $r.Enabled) { $r.Enabled = $r.Points.Count -gt 0 -or ((& vssadmin list shadowstorage 2>$null) -match 'C:') }
            }
            else { $r.Denied = $true }
            return [PSCustomObject]$r
        }
        if (Test-Tool snapper) {
            $r.Tool = 'snapper'
            if (Test-Elevated) {
                $json = (Invoke-Tool snapper @('--jsonout', '-c', 'root', 'list')) -join ''
                if ($json) {
                    $r.Enabled = $true
                    $r.Points = @(($json | ConvertFrom-Json).root | Where-Object { $_.number -ne 0 } | Sort-Object number -Descending | ForEach-Object { [PSCustomObject]@{ Date = [datetime]$_.date; Description = $_.description; Type = $_.type; Volume = '/' } })
                }
                else { $r.Enabled = $false; $r.Problem = 'pas de configuration « root »' }
            }
            else { $r.Denied = $true; $r.Enabled = Test-Path /etc/snapper/configs/root }
        }
        elseif (Test-Tool timeshift) {
            $r.Tool = 'Timeshift'
            $cfg = try { Read-Text /etc/timeshift/timeshift.json | ConvertFrom-Json } catch { $null }
            if ($cfg) { $r.Enabled = "$($cfg.schedule_daily)$($cfg.schedule_weekly)$($cfg.schedule_monthly)$($cfg.schedule_hourly)$($cfg.schedule_boot)" -match 'true' }
            if (Test-Elevated) {
                $r.Points = @(Invoke-Tool timeshift @('--list', '--scripted') | Where-Object { $_ -match '^\s*\d+\s+>\s+(\S+)\s+(\S+)\s*(.*)$' } | ForEach-Object {
                        $null = $_ -match '^\s*\d+\s+>\s+(\S+)\s+(\S+)\s*(.*)$'
                        [PSCustomObject]@{ Date = try { [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd_HH-mm-ss', $null) } catch { $null }; Description = $Matches[3].Trim(); Type = $Matches[2]; Volume = '/' }
                    })
            }
            else { $r.Denied = $true }
        }
        if (Test-Tool zfs) {
            $zfs = foreach ($line in Invoke-Tool zfs @('list', '-H', '-t', 'snapshot', '-o', 'name,creation', '-p')) {
                $f = $line -split "`t"
                if ($f.Count -ge 2) { [PSCustomObject]@{ Date = [DateTimeOffset]::FromUnixTimeSeconds([long]$f[1]).LocalDateTime; Description = $f[0]; Type = 'ZFS'; Volume = ($f[0] -split '@')[0] } }
            }
            if ($zfs) { $r.Tool = (@($r.Tool, 'ZFS') | Where-Object { $_ }) -join ' + '; $r.Points = @($r.Points) + @($zfs); $r.Enabled = $true }
        }
        if (-not $r.Tool) {
            $fs = "$(Invoke-Tool findmnt @('-no', 'FSTYPE', '/'))".Trim()
            $r.Problem = "aucun outil d'instantanés (snapper, Timeshift$(if ($fs -eq 'btrfs') { ' : adaptés au Btrfs de ce système' }))"
        }
        [PSCustomObject]$r
    }
}

#endregion

#region Vue d'ensemble

function Get-ModuleData {
    $sections = [System.Collections.Generic.List[object]]::new()
    $findings = [System.Collections.Generic.List[object]]::new()
    $errors = [ordered]@{}
    function Invoke-Block([string]$Name, [scriptblock]$Block) {
        try { & $Block } catch { $errors[$Name] = $_.Exception.Message; $null }
    }

    $tools = @(Invoke-Block 'Outils' { Get-BackupTools })
    $jobs = @(Invoke-Block 'Tâches' { Get-BackupJobs })
    $known = @(Invoke-Block 'Dernières sauvegardes' { Get-KnownLastBackups })
    $sync = @(Invoke-Block 'Synchronisation' { Get-SyncClients })
    $snap = Invoke-Block 'Instantanés' { Get-Snapshots }

    # Dernière sauvegarde réussie connue (tâches et applications qui gardent la date).
    $done = @(@($jobs | Where-Object { $_.Last -and $_.Ok -ne $false } | ForEach-Object { [PSCustomObject]@{ What = "$($_.Name) ($($_.Source))"; Last = $_.Last } }) +
        @($known | Where-Object { $_.Last -and $_.Ok } | ForEach-Object { [PSCustomObject]@{ What = $_.Tool; Last = $_.Last } }))
    $latest = $done | Sort-Object Last -Descending | Select-Object -First 1
    $lastPoint = @($snap.Points) | Sort-Object Date -Descending | Select-Object -First 1

    $items = [ordered]@{
        'Dernière sauvegarde' = if ($latest) { '{0} ({1}) · {2}' -f (Format-Date $latest.Last), (Format-Age $latest.Last), $latest.What } elseif ($tools -or $jobs) { 'date inconnue' } else { 'aucune sauvegarde détectée' }
        'Outils de sauvegarde' = if ($tools) { ($tools | ForEach-Object Name) -join ', ' } else { 'aucun' }
        'Tâches de sauvegarde' = $jobs.Count
        'Synchronisation' = if ($sync) { ($sync | ForEach-Object Name) -join ', ' } else { 'aucune' }
        "Points de restauration / instantanés" = if ($snap.Tool) { '{0}{1}' -f $snap.Tool, $(if ($snap.Points.Count) { " · $($snap.Points.Count) · dernier $(Format-Date $lastPoint.Date)" } elseif ($snap.Denied) { ' · liste lisible avec les droits administrateur / root' } else { '' }) } else { $snap.Problem ?? '—' }
    }
    $sections.Add([PSCustomObject]@{ Title = 'Résumé'; Type = 'KeyValue'; Icon = 'arrow_download'; Items = $items })

    # Constats : pas de sauvegarde, sauvegarde ancienne ou en échec, synchronisation seule.
    if (-not $tools -and -not $jobs -and -not $known) {
        $findings.Add((New-Finding 'warning' 'BAK-NONE' $(if ($sync) { 'Aucune sauvegarde détectée : seulement une synchronisation (' + (($sync | ForEach-Object Name) -join ', ') + ').' } else { 'Aucune sauvegarde détectée sur cet ordinateur.' }) $(if ($IsWindows) { 'Activer l''Historique des fichiers ou la sauvegarde OneDrive des dossiers, ou installer un logiciel de sauvegarde vers un disque externe ou un NAS.' } else { 'Mettre en place une sauvegarde (Déjà Dup, Pika Backup, restic, borg) vers un disque externe ou un serveur.' })))
    }
    elseif ($latest) {
        $days = ((Get-Date) - $latest.Last).TotalDays
        if ($days -ge 30) { $findings.Add((New-Finding 'critical' 'BAK-OLD' ('Dernière sauvegarde il y a {0} jours ({1}).' -f [Math]::Floor($days), $latest.What) 'Relancer la sauvegarde et vérifier pourquoi elle ne tourne plus (disque débranché, tâche désactivée).')) }
        elseif ($days -ge 7) { $findings.Add((New-Finding 'warning' 'BAK-OLD' ('Dernière sauvegarde il y a {0} jours ({1}).' -f [Math]::Floor($days), $latest.What) 'Vérifier que la sauvegarde tourne régulièrement.')) }
    }
    else { $findings.Add((New-Finding 'info' 'BAK-UNKNOWN-DATE' ("Outil de sauvegarde présent ({0}) mais date de la dernière sauvegarde inconnue." -f ((@($tools.Name) + @($jobs.Name) | Select-Object -First 3) -join ', ')) 'Vérifier dans l''outil que les sauvegardes réussissent.')) }
    foreach ($j in $jobs | Where-Object { $_.Ok -eq $false -and $_.Last }) {
        $findings.Add((New-Finding 'warning' 'BAK-FAILED' ('La tâche de sauvegarde {0} a échoué ({1}, {2}).' -f $j.Name, (Format-Date $j.Last), $j.Result) $(if ($j.Unit) { "Voir son journal : tasks_get_task, journalctl $(if ($j.User) { '--user-unit' } else { '-u' }) $($j.Unit)." } else { 'Voir l''historique de la tâche (tasks_get_task).' })))
    }
    foreach ($k in $known | Where-Object { $_.Ok -eq $false }) {
        $findings.Add((New-Finding 'warning' 'BAK-FAILED' ('{0} : {1}.' -f $k.Tool, $k.Detail) 'Vérifier la configuration et le disque de destination.'))
    }
    if ($sync -and -not $tools -and -not $jobs -and $known.Count -eq 0) {
        $findings.Add((New-Finding 'info' 'BAK-SYNC-ONLY' 'La synchronisation n''est pas une sauvegarde : un fichier supprimé, chiffré ou abîmé est aussitôt synchronisé.' 'Garder une sauvegarde avec historique de versions (corbeille et versions du service, ou outil de sauvegarde).'))
    }
    foreach ($s in $sync | Where-Object { -not $_.Running }) { $findings.Add((New-Finding 'info' 'BAK-SYNC-STOPPED' "$($s.Name) est configuré mais ne tourne pas : les dossiers ne sont plus synchronisés." 'Relancer le client de synchronisation.')) }
    if ($snap -and $snap.Enabled -eq $false -and $snap.Problem) { $findings.Add((New-Finding 'info' 'BAK-RESTORE-OFF' "Points de restauration : $($snap.Problem)." 'Activer la protection du système (Windows) ou configurer snapper / Timeshift (Linux).')) }

    if ($jobs.Count) {
        $sections.Add([PSCustomObject]@{ Title = 'Tâches de sauvegarde'; Type = 'Table'; Icon = 'timer'; Columns = @('Tâche', 'Source', 'Dernière exécution', 'Résultat', 'Prochaine exécution')
                Rows = @($jobs | ForEach-Object { , @($_.Name, $_.Source, (Format-Date $_.Last), $(if ($null -eq $_.Ok) { '—' } elseif ($_.Ok) { 'réussie' } else { "échec ($($_.Result))" }), (Format-Date $_.Next)) }) })
    }
    if ($tools.Count -or $known.Count) {
        $rows = @($tools | ForEach-Object { , @($_.Name, $_.How, $null) }) + @($known | ForEach-Object { , @($_.Tool, $_.Detail, (Format-Date $_.Last)) })
        $sections.Add([PSCustomObject]@{ Title = 'Outils de sauvegarde'; Type = 'Table'; Icon = 'apps_list'; Columns = @('Outil', 'Détecté par', 'Dernière sauvegarde'); Rows = $rows })
    }
    if ($sync.Count) {
        $sections.Add([PSCustomObject]@{ Title = 'Synchronisation'; Type = 'Table'; Icon = 'arrow_swap'; Columns = @('Service', 'En cours', 'Dossiers', 'Détail')
                Rows = @($sync | ForEach-Object { , @($_.Name, $(if ($_.Running) { 'oui' } else { 'non' }), $_.Folders, $_.Detail) }) })
    }
    if (@($snap.Points).Count) {
        $sections.Add([PSCustomObject]@{ Title = 'Points de restauration et instantanés'; Type = 'Table'; Icon = 'arrow_clockwise'; Columns = @('Date', 'Description', 'Type', 'Volume')
                Rows = @($snap.Points | Sort-Object Date -Descending | Select-Object -First 50 | ForEach-Object { , @((Format-Date $_.Date), $_.Description, $_.Type, $_.Volume) }) })
    }

    if ($errors.Count) { $sections.Add([PSCustomObject]@{ Title = 'Erreurs de collecte'; Type = 'KeyValue'; Icon = 'error_circle'; Items = $errors }) }

    $subtitle = if ($latest) { 'dernière sauvegarde {0}' -f (Format-Age $latest.Last) } elseif ($tools -or $jobs) { 'sauvegarde : date inconnue' } else { 'aucune sauvegarde détectée' }
    if ($sync) { $subtitle += ' · synchronisation : ' + (($sync | ForEach-Object Name) -join ', ') }
    [PSCustomObject]@{ Subtitle = $subtitle; Sections = $sections.ToArray(); Findings = $findings.ToArray() }
}

#endregion

#region Fonctions ciblées

# backup_list_snapshots : points de restauration et instantanés (Windows : aussi les clichés VSS).
function Get-SISnapshots {
    param([ValidateRange(1, 500)][int]$Top = 100)
    $script:Cache.Remove('snapshots')
    $snap = Get-Snapshots
    $sections = [System.Collections.Generic.List[object]]::new()
    $sections.Add([PSCustomObject]@{ Title = 'Points de restauration et instantanés'; Type = 'Table'; Icon = 'arrow_clockwise'; Columns = @('Date', 'Description', 'Type', 'Volume')
            Rows = @($snap.Points | Sort-Object Date -Descending | Select-Object -First $Top | ForEach-Object { , @((Format-Date $_.Date), $_.Description, $_.Type, $_.Volume) }) })
    if ($IsWindows -and (Test-Elevated)) {
        $shadows = (& vssadmin list shadows 2>$null) -join "`n"
        $rows = foreach ($b in $shadows -split 'Contents of shadow copy set|Contenu de l''ensemble de clichés instantanés') {
            if ($b -match '(?m)(creation time|heure de création)\s*:\s*(.+)$') {
                $when = $Matches[2].Trim()
                $volume = if ($b -match '(?m)(Original Volume|Volume d''origine)\s*:\s*\(([^)]+)\)') { $Matches[2] } else { '—' }
                , @($when, $volume)
            }
        }
        $sections.Add([PSCustomObject]@{ Title = 'Clichés instantanés (VSS)'; Type = 'Table'; Icon = 'hard_drive'; Columns = @('Créé le', 'Volume'); Rows = @($rows) })
        $storage = (& vssadmin list shadowstorage 2>$null | Where-Object { $_ -match ':' }) -join ' · '
        if ($storage) { $sections.Add([PSCustomObject]@{ Title = 'Espace réservé aux clichés'; Type = 'KeyValue'; Icon = 'hard_drive'; Items = [ordered]@{ 'vssadmin list shadowstorage' = $storage } }) }
    }
    $findings = @()
    if ($snap.Denied) { $findings += New-Finding 'info' 'BAK-SNAPSHOTS-DENIED' 'La liste complète des points de restauration demande les droits administrateur (root sous Linux).' $null }
    if (-not $snap.Tool) { $findings += New-Finding 'info' 'BAK-RESTORE-OFF' "Points de restauration : $($snap.Problem)." 'Installer et configurer snapper ou Timeshift.' }
    [PSCustomObject]@{ Subtitle = '{0} · {1} point(s)' -f ($snap.Tool ?? 'aucun outil'), @($snap.Points).Count; Sections = $sections.ToArray(); Findings = $findings }
}

#endregion

Export-ModuleMember -Function Get-ModuleData, Get-SISnapshots
