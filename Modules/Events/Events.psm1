# Module Événements : erreurs critiques, arrêts inattendus, écrans bleus / kernel panics, plantages d'applications,
# erreurs matérielles et mémoire, échecs de mises à jour, indice de fiabilité, chronologie.
#
# Sources
#   Windows : Get-WinEvent (journaux System et Application : Kernel-Power 41, EventLog 6005/6006/6008,
#             WER-SystemErrorReporting 1001, Application Error 1000, Application Hang 1002, WHEA-Logger,
#             WindowsUpdateClient 19/20, MsiInstaller 11707/11724), C:\Windows\Minidump,
#             Win32_ReliabilityStabilityMetrics et Win32_ReliabilityRecords (indice de fiabilité).
#   Linux   : journalctl (JSON : erreurs, noyau, démarrages précédents, gestionnaires de paquets, systemd-oomd),
#             coredumpctl (plantages d'applications), /var/lib/systemd/pstore (kernel panics conservés),
#             rpm -qa ou /var/log/dpkg.log (installations, pour la chronologie).
#
# Les journaux changent peu d'une minute à l'autre : chaque collecte est mise en cache 60 s (10 min pour les
# démarrages précédents, qui ne changent plus).

$script:Fr = [cultureinfo]::GetCultureInfo('fr-FR')
$script:Days = 7
$script:MaxErrors = 2000   # erreurs lues pour le résumé ; au-delà, le compte est affiché « 2 000 ou plus »

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

# Première ligne utile d'un message, raccourcie.
function Get-FirstLine([string]$Text, [int]$Max = 300) {
    if (-not $Text) { return $null }
    $line = ($Text -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    if (-not $line) { return $null }
    $line = $line.Trim()
    if ($line.Length -gt $Max) { $line.Substring(0, $Max) + '…' } else { $line }
}

$script:Levels = @{ 1 = 'Critique'; 2 = 'Erreur'; 3 = 'Avertissement'; 4 = 'Information'; 5 = 'Information'; 0 = 'Information' }

# Événement normalisé, identique sur les deux OS.
function New-LogEntry([datetime]$Time, [int]$Rank, [string]$Source, $Id, [string]$Message) {
    [PSCustomObject]@{ Time = $Time; Rank = $Rank; Level = $script:Levels[$Rank]; Source = $Source; Id = $Id; Message = Get-FirstLine $Message }
}

function New-Finding([string]$Severity, [string]$Code, [string]$Message, [string]$Recommendation) {
    [PSCustomObject]@{ Severity = $Severity; Code = $Code; Message = $Message; Recommendation = $Recommendation }
}

#endregion

#region Lecture des journaux

# Windows : Get-WinEvent normalisé (le message peut manquer si le fournisseur n'est plus installé).
function Read-WinEvents([hashtable]$Filter, [int]$Max = 500) {
    Get-WinEvent -FilterHashtable $Filter -MaxEvents $Max -ErrorAction SilentlyContinue | ForEach-Object {
        $message = $_.Message
        if (-not $message) { $message = ($_.Properties | ForEach-Object { "$($_.Value)" }) -join ' · ' }
        $rank = if ($_.Level -in 1, 2, 3) { [int]$_.Level } else { 4 }
        $entry = New-LogEntry $_.TimeCreated $rank $_.ProviderName $_.Id $message
        $entry | Add-Member -NotePropertyName Raw -NotePropertyValue $_ -PassThru
    }
}

# Linux : journalctl en JSON (une ligne par entrée), lu d'un bloc. PRIORITY 0-2 critique, 3 erreur, 4 avertissement.
function Read-Journal([string[]]$Arguments) {
    if (-not (Get-Command journalctl -ErrorAction SilentlyContinue)) { return @() }
    $fields = 'MESSAGE,PRIORITY,SYSLOG_IDENTIFIER,_SYSTEMD_UNIT,_COMM,__REALTIME_TIMESTAMP'
    $lines = & journalctl @Arguments -o json "--output-fields=$fields" -q --no-pager 2>$null
    if (-not $lines) { return @() }
    # Boucle sans appel de fonction : quelques milliers d'entrées doivent rester sous la demi-seconde.
    $entries = ('[' + (@($lines) -join ',') + ']') | ConvertFrom-Json
    $ranks = @{ '0' = 1; '1' = 1; '2' = 1; '3' = 2; '4' = 3 }
    foreach ($e in $entries) {
        # MESSAGE non UTF-8 : tableau d'octets.
        $message = if ($e.MESSAGE -is [array]) { [System.Text.Encoding]::UTF8.GetString([byte[]]$e.MESSAGE) } else { [string]$e.MESSAGE }
        $newline = $message.IndexOf("`n")
        if ($newline -ge 0) { $message = $message.Substring(0, $newline) }
        if ($message.Length -gt 300) { $message = $message.Substring(0, 300) + '…' }
        $rank = $ranks[[string]$e.PRIORITY] ?? 4
        [PSCustomObject]@{
            Time    = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$e.__REALTIME_TIMESTAMP / 1000).LocalDateTime
            Rank    = $rank
            Level   = $script:Levels[$rank]
            Source  = $e.SYSLOG_IDENTIFIER ?? $e._COMM ?? $e._SYSTEMD_UNIT ?? 'journal'
            Id      = $null
            Message = $message.Trim()
        }
    }
}

#endregion

#region Collectes (7 jours)

# Arrêts inattendus.
# Windows : Kernel-Power 41 (redémarrage sans arrêt propre) et EventLog 6008 (arrêt inattendu), regroupés à 10 min près.
# Linux   : démarrages précédents dont le journal ne se termine pas par un arrêt propre (« Journal stopped »…).
function Get-UnexpectedShutdowns([int]$Days) {
    $since = (Get-Date).AddDays(-$Days)
    if ($IsWindows) {
        $events = @(Read-WinEvents @{ LogName = 'System'; Id = 41, 6008; StartTime = $since } 200 | Sort-Object Time)
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($e in $events) {
            $last = if ($list.Count -gt 0) { $list[$list.Count - 1] } else { $null }
            $detail = if ($e.Id -eq 41) {
                $code = [long]($e.Raw.Properties[0].Value)
                if ($code -ne 0) { 'Kernel-Power 41 · écran bleu 0x{0:X}' -f $code } else { 'Kernel-Power 41 · coupure de courant, arrêt forcé ou blocage' }
            } else { 'EventLog 6008 · ' + $e.Message }
            if ($last -and ($e.Time - $last.Time).TotalMinutes -lt 10) {
                if ($e.Id -eq 41) { $last.Detail = $detail }
                continue
            }
            $list.Add([PSCustomObject]@{ Time = $e.Time; Detail = $detail })
        }
        return $list
    }

    $boots = (& journalctl --list-boots -o json --no-pager 2>$null) -join '' | ConvertFrom-Json -ErrorAction SilentlyContinue
    foreach ($boot in @($boots) | Where-Object { $_.index -lt 0 }) {
        $end = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$boot.last_entry / 1000).LocalDateTime
        if ($end -lt $since) { continue }
        $tail = @(& journalctl -b $boot.boot_id -n 20 -o cat -q --no-pager 2>$null)
        if (-not ($tail -match 'Journal stopped|systemd-shutdown|Reached target.*(Power-Off|Reboot|Shutdown|Halt|Exit)')) {
            [PSCustomObject]@{ Time = $end; Detail = 'Fin du démarrage sans arrêt propre (dernière entrée du journal)' }
        }
    }
}

# Codes d'écran bleu fréquents → nom et cause probable.
$script:BugChecks = @{
    0x0A = @('IRQL_NOT_LESS_OR_EQUAL', 'pilote défectueux')
    0x19 = @('BAD_POOL_HEADER', 'pilote ou mémoire')
    0x1A = @('MEMORY_MANAGEMENT', 'mémoire vive (tester la RAM)')
    0x1E = @('KMODE_EXCEPTION_NOT_HANDLED', 'pilote défectueux')
    0x3B = @('SYSTEM_SERVICE_EXCEPTION', 'pilote ou logiciel de sécurité')
    0x50 = @('PAGE_FAULT_IN_NONPAGED_AREA', 'pilote, mémoire ou disque')
    0x7A = @('KERNEL_DATA_INPAGE_ERROR', 'disque ou câble (vérifier le SMART)')
    0x7E = @('SYSTEM_THREAD_EXCEPTION_NOT_HANDLED', 'pilote défectueux')
    0x9F = @('DRIVER_POWER_STATE_FAILURE', 'pilote en veille / reprise')
    0xA0 = @('INTERNAL_POWER_ERROR', 'gestion de l''alimentation')
    0xC2 = @('BAD_POOL_CALLER', 'pilote défectueux')
    0xD1 = @('DRIVER_IRQL_NOT_LESS_OR_EQUAL', 'pilote défectueux (souvent réseau)')
    0xEF = @('CRITICAL_PROCESS_DIED', 'fichiers système ou disque')
    0x101 = @('CLOCK_WATCHDOG_TIMEOUT', 'processeur, overclocking ou BIOS')
    0x10D = @('WDF_VIOLATION', 'pilote défectueux')
    0x116 = @('VIDEO_TDR_FAILURE', 'pilote ou carte graphique')
    0x124 = @('WHEA_UNCORRECTABLE_ERROR', 'erreur matérielle (processeur, RAM, alimentation, températures)')
    0x133 = @('DPC_WATCHDOG_VIOLATION', 'pilote ou firmware du SSD')
    0x139 = @('KERNEL_SECURITY_CHECK_FAILURE', 'pilote ou mémoire')
    0x1000007E = @('SYSTEM_THREAD_EXCEPTION_NOT_HANDLED_M', 'pilote défectueux')
    0x1000008E = @('KERNEL_MODE_EXCEPTION_NOT_HANDLED_M', 'pilote ou mémoire')
}

# Écrans bleus (Windows) et kernel panics / oops (Linux).
# Windows : WER-SystemErrorReporting 1001 (« The bugcheck was: 0x000000d1 (…) »), fichiers C:\Windows\Minidump.
# Linux   : panics conservés par systemd-pstore (/var/lib/systemd/pstore), oops et BUG du noyau dans le journal.
function Get-Bugchecks([int]$Days) {
    $since = (Get-Date).AddDays(-$Days)
    if ($IsWindows) {
        $dumps = @(Get-ChildItem -Path "$env:SystemRoot\Minidump" -Filter '*.dmp' -ErrorAction SilentlyContinue)
        return Read-WinEvents @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = $since } 50 | ForEach-Object {
            $code = if ($_.Message -match '0x([0-9a-fA-F]+)') { [Convert]::ToInt64($Matches[1], 16) } else { $null }
            $known = if ($null -ne $code) { $script:BugChecks[[int]$code] } else { $null }
            # Minidump écrit au redémarrage qui suit l'écran bleu (lisible en administrateur seulement).
            $at = $_.Time
            $dump = $dumps | Where-Object { [Math]::Abs(($_.LastWriteTime - $at).TotalMinutes) -lt 30 } | Select-Object -First 1
            [PSCustomObject]@{
                Time = $_.Time; Kind = 'Écran bleu'
                Code = if ($null -ne $code) { '0x{0:X}' -f $code } else { $null }
                Name = if ($known) { $known[0] } else { $null }
                Cause = if ($known) { $known[1] } else { $null }
                Detail = $_.Message + $(if ($dump) { " · vidage $($dump.Name)" } else { '' })
            }
        }
    }

    foreach ($dir in Get-ChildItem -Path /var/lib/systemd/pstore -Directory -ErrorAction SilentlyContinue | Where-Object LastWriteTime -ge $since) {
        $text = Get-ChildItem -Path $dir.FullName -Filter 'dmesg*' -ErrorAction SilentlyContinue | Select-Object -First 1 | Get-Content -Raw -ErrorAction SilentlyContinue
        $line = if ($text) { ($text -split "`n" | Where-Object { $_ -match 'Kernel panic|BUG:|RIP:' } | Select-Object -First 1) } else { $null }
        [PSCustomObject]@{ Time = $dir.LastWriteTime; Kind = 'Kernel panic'; Code = $null; Name = $null; Cause = $null; Detail = Get-FirstLine ($line ?? "Panic conservé dans $($dir.FullName)") }
    }
    Read-Journal @('-k', '-S', "-${Days}d", '-g', 'Oops|kernel BUG|BUG: |general protection fault|Kernel panic', '-n', '50') | ForEach-Object {
        [PSCustomObject]@{ Time = $_.Time; Kind = 'Oops du noyau'; Code = $null; Name = $null; Cause = $null; Detail = $_.Message }
    }
}

$script:Signals = @{ 4 = 'SIGILL'; 5 = 'SIGTRAP'; 6 = 'SIGABRT'; 7 = 'SIGBUS'; 8 = 'SIGFPE'; 11 = 'SIGSEGV'; 31 = 'SIGSYS' }

# Plantages et blocages d'applications.
# Windows : Application Error 1000 (application, version, module fautif, code d'exception), Application Hang 1002.
# Linux   : coredumpctl (exécutable, signal), même sans fichier core conservé.
function Get-AppCrashes([int]$Days) {
    $since = (Get-Date).AddDays(-$Days)
    if ($IsWindows) {
        return Read-WinEvents @{ LogName = 'Application'; ProviderName = 'Application Error', 'Application Hang'; Id = 1000, 1002; StartTime = $since } 300 | ForEach-Object {
            $p = $_.Raw.Properties
            if ($_.Id -eq 1000) {
                [PSCustomObject]@{ Time = $_.Time; Kind = 'Plantage'; App = "$($p[0].Value)"; Version = "$($p[1].Value)"; Module = "$($p[3].Value)"; Code = "0x$($p[6].Value)" -replace '^0x0x', '0x' }
            }
            else {
                [PSCustomObject]@{ Time = $_.Time; Kind = 'Blocage'; App = "$($p[0].Value)"; Version = "$($p[1].Value)"; Module = $null; Code = $null }
            }
        }
    }
    if (-not (Get-Command coredumpctl -ErrorAction SilentlyContinue)) { return @() }
    $json = (& coredumpctl --json=short list "--since=-${Days}d" --no-pager 2>$null) -join ''
    if (-not $json) { return @() }
    foreach ($c in $json | ConvertFrom-Json) {
        [PSCustomObject]@{
            Time = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$c.time / 1000).LocalDateTime; Kind = 'Plantage'
            App = [System.IO.Path]::GetFileName($c.exe); Version = $null; Module = $c.exe
            Code = $script:Signals[[int]$c.sig] ?? "signal $($c.sig)"
        }
    }
}

# Erreurs matérielles et manques de mémoire.
# Windows : WHEA-Logger (erreurs corrigées = avertissement, fatales = erreur).
# Linux   : noyau (mce Hardware Error, EDAC CE/UE, OOM killer) et systemd-oomd.
function Get-HardwareErrors([int]$Days) {
    $since = (Get-Date).AddDays(-$Days)
    if ($IsWindows) {
        return Read-WinEvents @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = $since } 200 | ForEach-Object {
            [PSCustomObject]@{ Time = $_.Time; Kind = if ($_.Rank -le 2) { 'Erreur matérielle fatale' } else { 'Erreur matérielle corrigée' }; Source = "WHEA $($_.Id)"; Detail = $_.Message; Oom = $false; Fatal = $_.Rank -le 2 }
        }
    }
    $pattern = 'mce: \[Hardware Error\]|Machine check events logged|EDAC .*(CE|UE) |Hardware Error|Out of memory: Killed process|oom-kill:'
    $kernel = Read-Journal @('-k', '-S', "-${Days}d", '-g', $pattern, '-n', '200') | ForEach-Object {
        $oom = $_.Message -match 'Out of memory|oom-kill'
        [PSCustomObject]@{
            Time = $_.Time; Kind = if ($oom) { 'Mémoire insuffisante (OOM killer)' } else { 'Erreur matérielle' }; Source = 'noyau'
            Detail = $_.Message; Oom = $oom; Fatal = $_.Message -match 'UE |uncorrected|Fatal'
        }
    }
    $oomd = Read-Journal @('-t', 'systemd-oomd', '-S', "-${Days}d", '-g', 'Killed', '-n', '100') | ForEach-Object {
        [PSCustomObject]@{ Time = $_.Time; Kind = 'Mémoire insuffisante (systemd-oomd)'; Source = 'systemd-oomd'; Detail = $_.Message; Oom = $true; Fatal = $false }
    }
    @($kernel) + @($oomd) | Where-Object { $_ }
}

# Échecs de mises à jour.
# Windows : WindowsUpdateClient 20 (échec d'installation).
# Linux   : erreurs des gestionnaires de paquets dans le journal (PackageKit, dnf, dnf5, apt, unattended-upgrades).
function Get-UpdateFailures([int]$Days) {
    $since = (Get-Date).AddDays(-$Days)
    if ($IsWindows) {
        return Read-WinEvents @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WindowsUpdateClient'; Id = 20; StartTime = $since } 100 | ForEach-Object {
            [PSCustomObject]@{ Time = $_.Time; Source = 'Windows Update'; Detail = $_.Message }
        }
    }
    $query = @('-p', 'err', '-S', "-${Days}d", '-n', '100')
    foreach ($id in 'packagekitd', 'PackageKit', 'dnf', 'dnf5', 'dnf5daemon-server', 'apt', 'apt-get', 'unattended-upgrade') { $query += @('-t', $id) }
    Read-Journal $query | ForEach-Object { [PSCustomObject]@{ Time = $_.Time; Source = $_.Source; Detail = $_.Message } }
}

# Erreurs et événements critiques de la période (base des « erreurs fréquentes » et des « dernières erreurs »).
# Windows : journaux System et Application, niveaux Critique et Erreur. Linux : journal, priorité err et au-dessus.
function Get-ErrorEvents([int]$Days) {
    $since = (Get-Date).AddDays(-$Days)
    if ($IsWindows) { return Read-WinEvents @{ LogName = 'System', 'Application'; Level = 1, 2; StartTime = $since } $script:MaxErrors }
    Read-Journal @('-p', 'err', '-S', "-${Days}d", '-n', $script:MaxErrors)
}

# Regroupement : même source et même message, une fois les nombres, adresses et identifiants remplacés.
function Get-RecurringErrors($Events, [int]$Top = 15) {
    $Events | Group-Object {
        $key = if ($null -ne $_.Id) { "$($_.Id)" } else { ($_.Message -replace '0x[0-9a-fA-F]+|[0-9a-fA-F]{8}-[0-9a-fA-F-]{27}|\d+', '#') }
        "$($_.Source)|$key"
    } | Sort-Object Count -Descending | Select-Object -First $Top | ForEach-Object {
        $last = $_.Group | Sort-Object Time -Descending | Select-Object -First 1
        [PSCustomObject]@{ Count = $_.Count; Source = $last.Source; Id = $last.Id; Last = $last.Time; Level = $last.Level; Message = $last.Message }
    }
}

# Windows : dernier indice de stabilité (1 à 10), calculé chaque heure par le service RAC.
function Get-StabilityIndex {
    if (-not $IsWindows) { return $null }
    Get-CimInstance -ClassName Win32_ReliabilityStabilityMetrics -ErrorAction SilentlyContinue |
        Sort-Object TimeGenerated -Descending | Select-Object -First 1 |
        ForEach-Object { [PSCustomObject]@{ Index = [Math]::Round([double]$_.SystemStabilityIndex, 1); Time = $_.TimeGenerated } }
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

    $days = $script:Days
    $shutdowns = @(Invoke-Block 'Arrêts inattendus' { Get-Cached 'shutdowns' 600 { Get-UnexpectedShutdowns $days } } | Where-Object { $_ })
    $bugchecks = @(Invoke-Block 'Écrans bleus' { Get-Cached 'bugchecks' 60 { Get-Bugchecks $days } } | Where-Object { $_ })
    $crashes = @(Invoke-Block 'Plantages' { Get-Cached 'crashes' 60 { Get-AppCrashes $days } } | Where-Object { $_ })
    $hardware = @(Invoke-Block 'Erreurs matérielles' { Get-Cached 'hardware' 60 { Get-HardwareErrors $days } } | Where-Object { $_ })
    $updates = @(Invoke-Block 'Mises à jour' { Get-Cached 'updates' 60 { Get-UpdateFailures $days } } | Where-Object { $_ })
    $events = @(Invoke-Block 'Erreurs' { Get-Cached 'errors' 60 { Get-ErrorEvents $days } } | Where-Object { $_ })
    $stability = Invoke-Block 'Fiabilité' { Get-Cached 'stability' 600 { Get-StabilityIndex } }

    $panics = @($bugchecks | Where-Object Kind -ne 'Oops du noyau')
    $oops = @($bugchecks | Where-Object Kind -eq 'Oops du noyau')
    $oom = @($hardware | Where-Object Oom)
    $hw = @($hardware | Where-Object { -not $_.Oom })

    # Résumé de la période
    $capped = $events.Count -ge $script:MaxErrors
    $count = { param($n) if ($capped) { "$n (sur les $($script:MaxErrors) plus récentes)" } else { $n } }
    $summary = [ordered]@{
        'Erreurs critiques' = & $count @($events | Where-Object Rank -eq 1).Count
        'Erreurs'           = & $count @($events | Where-Object Rank -eq 2).Count
        'Arrêts inattendus' = $shutdowns.Count
        ($(if ($IsWindows) { 'Écrans bleus' } else { 'Kernel panics' })) = $panics.Count
        'Plantages d''applications' = @($crashes | Where-Object Kind -eq 'Plantage').Count
    }
    if ($IsWindows) { $summary['Blocages d''applications'] = @($crashes | Where-Object Kind -eq 'Blocage').Count }
    if ($IsLinux) { $summary['Oops du noyau'] = $oops.Count }
    $summary['Erreurs matérielles'] = $hw.Count
    $summary['Manques de mémoire (OOM)'] = $oom.Count
    $summary['Échecs de mises à jour'] = $updates.Count
    if ($stability) { $summary['Indice de fiabilité'] = '{0} / 10 ({1})' -f $stability.Index.ToString('0.0', $script:Fr), (Format-Date $stability.Time) }
    $sections.Add([PSCustomObject]@{ Title = "Résumé des $days derniers jours"; Type = 'KeyValue'; Icon = 'pulse'; Items = $summary })

    if ($shutdowns.Count -gt 0) {
        $rows = foreach ($s in $shutdowns | Sort-Object Time -Descending) { , @((Format-Date $s.Time), $s.Detail) }
        $sections.Add([PSCustomObject]@{ Title = 'Arrêts inattendus'; Type = 'Table'; Icon = 'plug_disconnected'; Columns = @('Date', 'Détail'); Rows = @($rows) })
        Add-Finding $(if ($shutdowns.Count -ge 3) { 'critical' } else { 'warning' }) 'EVT-UNEXPECTED-SHUTDOWN' `
            ('{0} arrêt(s) inattendu(s) en {1} jours, le dernier le {2}' -f $shutdowns.Count, $days, (Format-Date ($shutdowns | Sort-Object Time | Select-Object -Last 1).Time)) `
            'Coupure de courant, bouton maintenu, surchauffe ou blocage : vérifier l''alimentation, les températures et les écrans bleus.'
    }

    if ($bugchecks.Count -gt 0) {
        $rows = foreach ($b in $bugchecks | Sort-Object Time -Descending) {
            , @((Format-Date $b.Time), $b.Kind, $b.Code, $b.Name, $b.Cause, $b.Detail)
        }
        $sections.Add([PSCustomObject]@{
                Title = $(if ($IsWindows) { 'Écrans bleus' } else { 'Kernel panics et oops' }); Type = 'Table'; Icon = 'error_circle'
                Columns = @('Date', 'Type', 'Code', 'Nom', 'Cause probable', 'Détail'); Rows = @($rows)
            })
        foreach ($group in $panics | Group-Object { $_.Code ?? $_.Kind }) {
            $first = $group.Group[0]
            Add-Finding 'critical' $(if ($IsWindows) { 'EVT-BSOD' } else { 'EVT-KERNEL-PANIC' }) `
                ('{0} {1}{2} : {3} fois, le dernier le {4}' -f $first.Kind, ($first.Code ?? ''), $(if ($first.Name) { " ($($first.Name))" } else { '' }), $group.Count, (Format-Date ($group.Group | Sort-Object Time | Select-Object -Last 1).Time)) `
                $(if ($first.Cause) { "Cause probable : $($first.Cause). Voir la chronologie (events_get_timeline) pour ce qui a changé juste avant." } else { 'Voir la chronologie pour ce qui a changé juste avant (pilote, mise à jour, matériel).' })
        }
        if ($oops.Count -gt 0) {
            Add-Finding 'warning' 'EVT-KERNEL-OOPS' ('{0} oops du noyau en {1} jours' -f $oops.Count, $days) 'Un pilote ou module du noyau a planté sans arrêter le système : chercher le module cité dans le message.'
        }
    }

    if ($crashes.Count -gt 0) {
        $rows = foreach ($c in $crashes | Sort-Object Time -Descending | Select-Object -First 100) {
            , @((Format-Date $c.Time), $c.Kind, $c.App, $c.Version, $c.Module, $c.Code)
        }
        $sections.Add([PSCustomObject]@{
                Title = 'Plantages d''applications'; Type = 'Table'; Icon = 'dismiss'
                Columns = @('Date', 'Type', 'Application', 'Version', $(if ($IsWindows) { 'Module fautif' } else { 'Exécutable' }), $(if ($IsWindows) { 'Code' } else { 'Signal' })); Rows = @($rows)
            })
        foreach ($group in $crashes | Group-Object App | Where-Object Count -ge 3 | Sort-Object Count -Descending) {
            $modules = ($group.Group.Module | Where-Object { $_ } | Group-Object | Sort-Object Count -Descending | Select-Object -First 1).Name
            Add-Finding 'warning' 'EVT-APP-CRASHES' ('{0} a planté {1} fois en {2} jours' -f $group.Name, $group.Count, $days) `
                $(if ($IsWindows -and $modules) { "Module le plus souvent en cause : $modules. Mettre à jour ou réinstaller l'application." } else { 'Mettre à jour ou réinstaller l''application ; si plusieurs applications plantent, suspecter la mémoire vive.' })
        }
    }

    if ($hardware.Count -gt 0) {
        $rows = foreach ($h in $hardware | Sort-Object Time -Descending | Select-Object -First 100) { , @((Format-Date $h.Time), $h.Kind, $h.Source, $h.Detail) }
        $sections.Add([PSCustomObject]@{ Title = 'Erreurs matérielles et mémoire'; Type = 'Table'; Icon = 'developer_board'; Columns = @('Date', 'Type', 'Source', 'Détail'); Rows = @($rows) })
        if ($hw.Count -gt 0) {
            $fatal = @($hw | Where-Object Fatal).Count
            Add-Finding $(if ($fatal -gt 0) { 'critical' } else { 'warning' }) 'EVT-HARDWARE-ERROR' `
                ('{0} erreur(s) matérielle(s) en {1} jours, dont {2} non corrigée(s)' -f $hw.Count, $days, $fatal) `
                'Processeur, mémoire ou bus PCIe : vérifier les températures, retirer l''overclocking, tester la RAM (MemTest86).'
        }
        if ($oom.Count -gt 0) {
            Add-Finding 'warning' 'EVT-OOM-KILL' ('{0} processus tué(s) faute de mémoire en {1} jours' -f $oom.Count, $days) `
                'La mémoire vive a manqué : ajouter du swap ou de la RAM, ou limiter les applications gourmandes.'
        }
    }

    if ($updates.Count -gt 0) {
        $rows = foreach ($u in $updates | Sort-Object Time -Descending | Select-Object -First 50) { , @((Format-Date $u.Time), $u.Source, $u.Detail) }
        $sections.Add([PSCustomObject]@{ Title = 'Échecs de mises à jour'; Type = 'Table'; Icon = 'arrow_download'; Columns = @('Date', 'Source', 'Détail'); Rows = @($rows) })
        Add-Finding 'warning' 'EVT-UPDATE-FAILED' ('{0} échec(s) de mise à jour en {1} jours' -f $updates.Count, $days) `
            $(if ($IsWindows) { 'Relancer Windows Update ; si l''erreur persiste, réparer Windows Update (module Maintenance).' } else { 'Relancer la mise à jour dans un terminal pour lire l''erreur complète (dnf upgrade / apt upgrade).' })
    }

    if ($stability -and $stability.Index -lt 5) {
        Add-Finding 'warning' 'EVT-RELIABILITY-LOW' ('Indice de fiabilité à {0} / 10' -f $stability.Index.ToString('0.0', $script:Fr)) `
            'Voir l''historique de fiabilité (events_get_reliability) pour les défaillances qui l''ont fait baisser.'
    }

    # Erreurs les plus fréquentes (regroupées) puis les plus récentes
    if ($events.Count -gt 0) {
        $recurring = @(Get-RecurringErrors $events)
        $rows = foreach ($r in $recurring) { , @($r.Count, $r.Source, $r.Id, (Format-Date $r.Last), $r.Message) }
        $sections.Add([PSCustomObject]@{
                Title = 'Erreurs les plus fréquentes'; Type = 'Table'; Icon = 'arrow_sort'
                Columns = @('Occurrences', 'Source', 'ID', 'Dernière', 'Message'); Rows = @($rows)
            })
        $rows = foreach ($e in $events | Sort-Object Time -Descending | Select-Object -First 30) { , @((Format-Date $e.Time), $e.Level, $e.Source, $e.Id, $e.Message) }
        $sections.Add([PSCustomObject]@{
                Title = 'Dernières erreurs'; Type = 'Table'; Icon = 'warning'
                Columns = @('Date', 'Niveau', 'Source', 'ID', 'Message'); Rows = @($rows)
            })
        $burst = $recurring | Where-Object Count -ge 100 | Select-Object -First 1
        if ($burst) {
            Add-Finding 'info' 'EVT-ERROR-FLOOD' ('« {0} » : {1} occurrences en {2} jours' -f $burst.Source, $burst.Count, $days) `
                'Une erreur aussi répétée noie le journal ; corriger sa cause rend les autres problèmes visibles.'
        }
    }

    if ($errors.Count -gt 0) {
        $sections.Add([PSCustomObject]@{ Title = 'Erreurs du module'; Type = 'KeyValue'; Icon = 'error_circle'; Items = $errors })
    }

    $subtitle = '{0} derniers jours · {1}{2} erreur(s) · {3} arrêt(s) inattendu(s) · {4} plantage(s)' -f $days, $(if ($capped) { '≥ ' } else { '' }), $events.Count, $shutdowns.Count, $crashes.Count
    [PSCustomObject]@{ Subtitle = $subtitle; Sections = $sections.ToArray(); Findings = $findings.ToArray() }
}

#region Fonctions ciblées (module.json › functions)

# events_query : recherche filtrée dans les journaux.
function Search-SIEvents {
    param(
        [string]$Log = 'System',
        [string]$Source,
        [ValidateRange(0, 65535)][int]$EventId = -1,
        [ValidateSet('critical', 'error', 'warning', 'info')][string]$Level = 'error',
        [ValidateRange(1, 2160)][int]$SinceHours = 24,
        [string]$Contains,
        [ValidateRange(1, 500)][int]$Top = 50
    )
    $rank = @{ critical = 1; error = 2; warning = 3; info = 4 }[$Level]
    $since = (Get-Date).AddHours(-$SinceHours)

    if ($IsWindows) {
        $filter = @{ LogName = $Log; StartTime = $since; Level = @(1..$rank) + $(if ($rank -eq 4) { 0, 5 } else { @() }) }
        if ($Source) { $filter.ProviderName = $Source }
        if ($PSBoundParameters.ContainsKey('EventId')) { $filter.Id = $EventId }
        # Filtre texte après lecture : on lit plus large pour en garder assez.
        $events = @(Read-WinEvents $filter $(if ($Contains) { 5000 } else { $Top }))
    }
    else {
        $priority = @{ 1 = 'crit'; 2 = 'err'; 3 = 'warning'; 4 = 'info' }[$rank]
        $query = @('-p', $priority, '-S', "-${SinceHours}h", '-r', '-n', $(if ($Contains) { 5000 } else { $Top }))
        if ($Log -eq 'kernel') { $query += '-k' }
        if ($Source) { $query += $(if ($Source -match '\.(service|socket|timer|mount|scope)$') { @('-u', $Source) } else { @('-t', $Source) }) }
        $events = @(Read-Journal $query)
    }
    if ($Contains) { $events = @($events | Where-Object { $_.Message -like "*$Contains*" }) }
    $events = @($events | Sort-Object Time -Descending | Select-Object -First $Top)

    $rows = foreach ($e in $events) { , @((Format-Date $e.Time), $e.Level, $e.Source, $e.Id, $e.Message) }
    $filters = @("journal $Log", "niveau ≥ $Level", "$SinceHours h")
    if ($Source) { $filters += "source $Source" }
    if ($PSBoundParameters.ContainsKey('EventId')) { $filters += "ID $EventId" }
    if ($Contains) { $filters += "texte « $Contains »" }
    [PSCustomObject]@{
        Subtitle = '{0} événement(s) · {1}' -f $events.Count, ($filters -join ' · ')
        Sections = @([PSCustomObject]@{ Title = 'Événements'; Type = 'Table'; Icon = 'search'; Columns = @('Date', 'Niveau', 'Source', 'ID', 'Message'); Rows = @($rows) })
        Findings = @()
    }
}

# Installations de logiciels et de mises à jour, pour la chronologie.
# Windows : WindowsUpdateClient 19 (mise à jour installée), MsiInstaller 11707 / 11724 (installation / suppression).
# Linux   : rpm -qa (date d'installation de chaque paquet) ou /var/log/dpkg.log.
function Get-Installs([int]$Days) {
    $since = (Get-Date).AddDays(-$Days)
    if ($IsWindows) {
        $wu = Read-WinEvents @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WindowsUpdateClient'; Id = 19; StartTime = $since } 300 |
            ForEach-Object { [PSCustomObject]@{ Time = $_.Time; Category = 'Mise à jour installée'; Source = 'Windows Update'; Detail = $_.Message } }
        $msi = Read-WinEvents @{ LogName = 'Application'; ProviderName = 'MsiInstaller'; Id = 11707, 11724; StartTime = $since } 300 |
            ForEach-Object { [PSCustomObject]@{ Time = $_.Time; Category = if ($_.Id -eq 11707) { 'Logiciel installé' } else { 'Logiciel supprimé' }; Source = 'MsiInstaller'; Detail = $_.Message } }
        return @($wu) + @($msi)
    }
    if (Get-Command rpm -ErrorAction SilentlyContinue) {
        $limit = [DateTimeOffset]::new($since).ToUnixTimeSeconds()
        return & rpm -qa --qf '%{INSTALLTIME} %{NAME}-%{VERSION}-%{RELEASE}\n' 2>$null | ForEach-Object {
            $f = $_ -split ' ', 2
            if ([long]$f[0] -ge $limit) { [PSCustomObject]@{ Time = [DateTimeOffset]::FromUnixTimeSeconds([long]$f[0]).LocalDateTime; Category = 'Paquet installé ou mis à jour'; Source = 'rpm'; Detail = $f[1] } }
        }
    }
    Get-Content -Path /var/log/dpkg.log -ErrorAction SilentlyContinue | ForEach-Object {
        # « 2026-10-20 10:12:01 upgrade nom:amd64 1.0 1.1 »
        if ($_ -match '^(\S+ \S+) (install|upgrade|remove) (\S+) \S+ (\S+)') {
            $time = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $null)
            if ($time -ge $since) { [PSCustomObject]@{ Time = $time; Category = @{ install = 'Paquet installé'; upgrade = 'Paquet mis à jour'; remove = 'Paquet supprimé' }[$Matches[2]]; Source = 'dpkg'; Detail = "$($Matches[3]) $($Matches[4])" } }
        }
    }
}

# Démarrages et arrêts propres.
# Windows : EventLog 6005 (démarrage) et 6006 (arrêt propre). Linux : journalctl --list-boots.
function Get-Boots([int]$Days) {
    $since = (Get-Date).AddDays(-$Days)
    if ($IsWindows) {
        return Read-WinEvents @{ LogName = 'System'; ProviderName = 'EventLog'; Id = 6005, 6006; StartTime = $since } 500 | ForEach-Object {
            [PSCustomObject]@{ Time = $_.Time; Category = if ($_.Id -eq 6005) { 'Démarrage' } else { 'Arrêt propre' }; Source = 'EventLog'; Detail = $null }
        }
    }
    $boots = (& journalctl --list-boots -o json --no-pager 2>$null) -join '' | ConvertFrom-Json -ErrorAction SilentlyContinue
    foreach ($b in @($boots)) {
        $start = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$b.first_entry / 1000).LocalDateTime
        if ($start -ge $since) { [PSCustomObject]@{ Time = $start; Category = 'Démarrage'; Source = 'systemd'; Detail = "démarrage $($b.index)" } }
    }
}

# events_get_timeline : chronologie corrélée.
function Get-SITimeline {
    param(
        [ValidateRange(1, 90)][int]$Days = 7,
        [ValidateRange(1, 1000)][int]$Top = 200
    )
    $entries = [System.Collections.Generic.List[object]]::new()
    $add = { param($Items) foreach ($i in $Items) { if ($i) { $entries.Add($i) } } }
    & $add (Get-Boots $Days)
    & $add (Get-UnexpectedShutdowns $Days | ForEach-Object { [PSCustomObject]@{ Time = $_.Time; Category = 'Arrêt inattendu'; Source = $null; Detail = $_.Detail } })
    & $add (Get-Bugchecks $Days | ForEach-Object { [PSCustomObject]@{ Time = $_.Time; Category = $_.Kind; Source = $_.Code; Detail = (@($_.Name, $_.Detail) | Where-Object { $_ }) -join ' · ' } })
    & $add (Get-AppCrashes $Days | ForEach-Object { [PSCustomObject]@{ Time = $_.Time; Category = "$($_.Kind) d'application"; Source = $_.App; Detail = (@($_.Module, $_.Code) | Where-Object { $_ }) -join ' · ' } })
    & $add (Get-HardwareErrors $Days | ForEach-Object { [PSCustomObject]@{ Time = $_.Time; Category = $_.Kind; Source = $_.Source; Detail = $_.Detail } })
    & $add (Get-UpdateFailures $Days | ForEach-Object { [PSCustomObject]@{ Time = $_.Time; Category = 'Échec de mise à jour'; Source = $_.Source; Detail = $_.Detail } })
    & $add (Get-Installs $Days)
    & $add (Get-ErrorEvents $Days | Where-Object Rank -eq 1 | ForEach-Object { [PSCustomObject]@{ Time = $_.Time; Category = 'Erreur critique'; Source = $_.Source; Detail = $_.Message } })

    # Entrées identiques (catégorie, source, détail) dans la même heure : une seule ligne « ×N », sinon les erreurs
    # répétées noient la chronologie.
    $sorted = @($entries | Group-Object { '{0}|{1}|{2}|{3:yyyyMMddHH}' -f $_.Category, $_.Source, $_.Detail, $_.Time } | ForEach-Object {
            $first = $_.Group | Sort-Object Time -Descending | Select-Object -First 1
            if ($_.Count -gt 1) { $first = $first.PSObject.Copy(); $first.Detail = '{0} (×{1})' -f $first.Detail, $_.Count }
            $first
        } | Sort-Object Time -Descending)
    $rows = foreach ($e in $sorted | Select-Object -First $Top) { , @((Format-Date $e.Time), $e.Category, $e.Source, $e.Detail) }
    $counts = ($entries | Group-Object Category | Sort-Object Count -Descending | ForEach-Object { '{0} {1}' -f $_.Count, $_.Name.ToLowerInvariant() }) -join ' · '
    [PSCustomObject]@{
        Subtitle = '{0} derniers jours · {1} entrée(s) en {2} ligne(s){3}' -f $Days, $entries.Count, $sorted.Count, $(if ($sorted.Count -gt $Top) { " · $Top plus récentes affichées" } else { '' })
        Sections = @(
            [PSCustomObject]@{ Title = 'Répartition'; Type = 'KeyValue'; Icon = 'pulse'; Items = [ordered]@{ 'Entrées' = $(if ($counts) { $counts } else { 'Aucune' }) } }
            [PSCustomObject]@{ Title = 'Chronologie'; Type = 'Table'; Icon = 'timer'; Columns = @('Date', 'Catégorie', 'Source', 'Détail'); Rows = @($rows) }
        )
        Findings = @()
    }
}

# events_get_reliability (Windows) : indice de stabilité par jour et défaillances enregistrées.
function Get-SIReliability {
    param([ValidateRange(1, 90)][int]$Days = 30)
    if (-not $IsWindows) { throw 'Historique de fiabilité disponible sous Windows seulement' }
    $since = (Get-Date).AddDays(-$Days)
    $metrics = @(Get-CimInstance -ClassName Win32_ReliabilityStabilityMetrics -ErrorAction Stop | Where-Object TimeGenerated -ge $since)
    $daily = $metrics | Group-Object { $_.TimeGenerated.Date } | Sort-Object { [datetime]$_.Name } -Descending | ForEach-Object {
        $last = $_.Group | Sort-Object TimeGenerated -Descending | Select-Object -First 1
        , @($last.TimeGenerated.ToString('dd/MM/yyyy', $script:Fr), [Math]::Round([double]$last.SystemStabilityIndex, 1))
    }
    $records = Get-CimInstance -ClassName Win32_ReliabilityRecords -ErrorAction SilentlyContinue | Where-Object TimeGenerated -ge $since |
        Sort-Object TimeGenerated -Descending | Select-Object -First 200 | ForEach-Object {
            , @((Format-Date $_.TimeGenerated), $_.SourceName, $_.ProductName, (Get-FirstLine $_.Message))
        }
    $current = $metrics | Sort-Object TimeGenerated -Descending | Select-Object -First 1
    $findings = @()
    if ($current -and $current.SystemStabilityIndex -lt 5) {
        $findings += New-Finding 'warning' 'EVT-RELIABILITY-LOW' ('Indice de fiabilité à {0} / 10' -f ([double]$current.SystemStabilityIndex).ToString('0.0', $script:Fr)) 'Les défaillances listées expliquent la baisse ; traiter d''abord les plus récentes.'
    }
    [PSCustomObject]@{
        Subtitle = if ($current) { 'Indice actuel : {0} / 10 · {1} jours' -f ([double]$current.SystemStabilityIndex).ToString('0.0', $script:Fr), $Days } else { 'Aucune donnée de fiabilité (service RAC désactivé ?)' }
        Sections = @(
            [PSCustomObject]@{ Title = 'Indice de stabilité par jour'; Type = 'Table'; Icon = 'pulse'; Columns = @('Jour', 'Indice (1 à 10)'); Rows = @($daily) }
            [PSCustomObject]@{ Title = 'Enregistrements de fiabilité'; Type = 'Table'; Icon = 'warning'; Columns = @('Date', 'Source', 'Produit', 'Message'); Rows = @($records) }
        )
        Findings = $findings
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

# Dossier des exports : Documents/SysInfo/Exports (Linux : dossier Documents XDG, sinon le dossier personnel).
function Get-ExportDirectory {
    $docs = if ($IsWindows) { [Environment]::GetFolderPath('MyDocuments') }
            else { (& xdg-user-dir DOCUMENTS 2>$null) ?? (Join-Path $HOME 'Documents') }
    if (-not $docs -or -not (Test-Path -LiteralPath $docs)) { $docs = $HOME }
    Join-Path $docs 'SysInfo/Exports'
}

function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1GB) { return '{0} GiB' -f ($Bytes / 1GB).ToString('0.0', $script:Fr) }
    if ($Bytes -ge 1MB) { return '{0} MiB' -f ($Bytes / 1MB).ToString('0.0', $script:Fr) }
    '{0} KiB' -f [Math]::Ceiling($Bytes / 1KB)
}

# events_export_log : exporte un journal sur une période dans un fichier, pour l'archiver ou le transmettre.
# Le fichier est toujours créé dans Documents/SysInfo/Exports (jamais ailleurs, jamais écrasé).
# Windows : wevtutil epl (fichier .evtx, ouvrable dans l'Observateur d'événements ; journal Security : administrateur).
# Linux   : journalctl -o short-iso (texte) ou -o json, système entier ou noyau.
function Export-SIEventLog {
    param(
        [string]$Log = $(if ($IsWindows) { 'System' } else { 'system' }),
        [ValidateRange(1, 2160)][int]$SinceHours = 24,
        [ValidateSet('all', 'critical', 'error', 'warning')][string]$Level = 'all',
        [ValidateSet('text', 'json')][string]$Format = 'text',
        [switch]$DryRun
    )

    $dir = Get-ExportDirectory
    $safe = $Log -replace '[^\w.-]', '_'
    $blocked = $null; $count = $null
    $rank = @{ all = 5; critical = 1; error = 2; warning = 3 }[$Level]

    if ($IsWindows) {
        $ext = 'evtx'
        $info = Get-WinEvent -ListLog $Log -ErrorAction SilentlyContinue
        if (-not $info) { $blocked = "Journal « $Log » introuvable (exemples : System, Application, Setup, Security)." }
        elseif ($Log -eq 'Security' -and -not [Environment]::IsPrivilegedProcess) { $blocked = 'Le journal Security ne se lit qu''en administrateur : relancer SysInfo en administrateur.' }
        $levels = if ($rank -lt 5) { ' and (' + ((1..$rank | ForEach-Object { "Level=$_" }) -join ' or ') + ')' } else { '' }
        $xpath = "*[System[TimeCreated[timediff(@SystemTime) <= $([long]$SinceHours * 3600000)]$levels]]"
        if (-not $blocked) { $count = @(Get-WinEvent -LogName $Log -FilterXPath $xpath -MaxEvents 200000 -ErrorAction SilentlyContinue).Count }
    }
    else {
        $ext = if ($Format -eq 'json') { 'json' } else { 'log' }
        if ($Log -notin 'system', 'kernel') { $blocked = "Journal « $Log » inconnu : « system » (journal entier) ou « kernel »." }
        elseif (-not (Get-Command journalctl -ErrorAction SilentlyContinue)) { $blocked = 'journalctl est introuvable (journal systemd absent).' }
        $query = @('-q', '--no-pager', '-S', "-${SinceHours}h")
        if ($rank -lt 5) { $query += @('-p', @{ 1 = 'crit'; 2 = 'err'; 3 = 'warning' }[$rank]) }
        if ($Log -eq 'kernel') { $query += '-k' }
        if (-not $blocked) { $count = [int](& sh -c 'journalctl "$@" -o json --output-fields=PRIORITY | wc -l' sh @query) }
    }

    # Horodaté à l'exécution : l'aperçu montre le modèle du nom.
    $file = Join-Path $dir ('journal-{0}-{1}.{2}' -f $safe, $(if ($DryRun) { 'AAAAMMJJ-HHMMSS' } else { Get-Date -Format 'yyyyMMdd-HHmmss' }), $ext)
    $items = [ordered]@{
        Journal   = $Log
        Période   = "$SinceHours dernières heures"
        Niveau    = @{ all = 'tous'; critical = 'critique'; error = 'erreur et plus grave'; warning = 'avertissement et plus grave' }[$Level]
        Format    = if ($IsWindows) { 'EVTX (Observateur d''événements)' } elseif ($Format -eq 'json') { 'JSON (une entrée par ligne)' } else { 'texte (horodatage ISO)' }
        Fichier   = $file
    }
    if ($null -ne $count) { $items['Événements'] = $count }
    $section = [PSCustomObject]@{ Title = 'Export'; Type = 'KeyValue'; Icon = 'arrow_download'; Items = $items }
    $findings = @()
    if ($IsLinux -and -not [Environment]::IsPrivilegedProcess -and -not ((& id -Gn) -split ' ' | Where-Object { $_ -in 'wheel', 'adm', 'systemd-journal' })) {
        $findings += New-Finding 'info' 'EVT-EXPORT-PARTIAL' 'Sans droits root ni groupe systemd-journal / wheel / adm, seul votre propre journal est exporté.' $null
    }
    $findings += New-Finding 'info' 'EVT-EXPORT-PRIVATE' 'Un journal peut contenir des noms de comptes, de machines et des adresses : vérifier avant de le transmettre.' $null
    if ($count -eq 0 -and -not $blocked) { $blocked = 'Aucun événement sur cette période avec ce niveau : rien à exporter.' }

    $change = [PSCustomObject]@{ Target = $file; Property = 'Fichier'; Before = 'absent'; After = "$count événement(s)" }
    if ($DryRun -or $blocked) {
        $subtitle = if ($null -ne $count) { "$count événement(s) du journal $Log seront exportés" } else { "Export du journal $Log" }
        return New-ActionResult $subtitle @($section) $findings @($change) $blocked
    }

    [void](New-Item -ItemType Directory -Path $dir -Force)
    if ($IsWindows) {
        $out = & wevtutil epl $Log $file "/q:$xpath" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "wevtutil a échoué : $($out -join ' ')" }
    }
    else {
        $mode = if ($Format -eq 'json') { 'json' } else { 'short-iso' }
        $out = & sh -c 'f="$1"; m="$2"; shift 2; journalctl "$@" -o "$m" > "$f"' sh $file $mode @query 2>&1
        if ($LASTEXITCODE -ne 0) { throw "journalctl a échoué : $($out -join ' ')" }
        & chmod 600 $file 2>$null
    }

    $size = (Get-Item -LiteralPath $file).Length
    $change.After = "$count événement(s) · $(Format-Size $size)"
    New-ActionResult "Journal $Log exporté : $file" @($section) $findings @($change) $null
}

#endregion

Export-ModuleMember -Function Get-ModuleData, Search-SIEvents, Get-SITimeline, Get-SIReliability, Export-SIEventLog
