# Module Impression & Périphériques : imprimantes (pilote, port, adresse, par défaut, état, partage), files d'attente
# et travaux bloqués, spouleur / CUPS, scanners, appareils Bluetooth appairés.
# Vider une file et redémarrer le spouleur : module Maintenance (maintenance_reset_print_queue).
#
# Sources
#   Windows : CIM Win32_Printer, Win32_TCPIPPrinterPort, Win32_PrintJob (en cache 60 s), service Spooler, journal
#             PrintService/Admin, Win32_Printer.PrintTestPage, Get-PnpDevice (classes Image et Bluetooth).
#   Linux   : lpstat (-r -d -p -l -v -o), service cups (systemctl), journalctl -u cups, lp (page de test CUPS),
#             scanimage -L (SANE, en cache 10 min : la recherche réseau est lente), bluetoothctl.
# Les identifiants d'une adresse d'imprimante (smb://utilisateur:motdepasse@…) sont masqués.

$script:Fr = [cultureinfo]::GetCultureInfo('fr-FR')

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

# Commande externe avec délai maximal (scanimage peut chercher longtemps sur le réseau) ; $null si dépassé.
function Invoke-ToolTimeout([string]$Name, [string[]]$Arguments, [int]$Seconds) {
    if (-not (Test-Tool $Name)) { return @() }
    $psi = [System.Diagnostics.ProcessStartInfo]::new((Get-Command $Name -CommandType Application | Select-Object -First 1).Source)
    foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync()
    if (-not $p.WaitForExit($Seconds * 1000)) { try { $p.Kill($true) } catch { }; return $null }
    $out.Result -split "`n" | Where-Object { $_ }
}

function New-Finding([string]$Severity, [string]$Code, [string]$Message, [string]$Recommendation) {
    [PSCustomObject]@{ Severity = $Severity; Code = $Code; Message = $Message; Recommendation = $Recommendation }
}

function New-ActionResult([string]$Subtitle, [object[]]$Sections, [object[]]$Findings, [object[]]$Changes, [string]$Blocked) {
    [PSCustomObject]@{
        Subtitle = $Subtitle
        Sections = @($Sections | Where-Object { $_ })
        Findings = @($Findings | Where-Object { $_ })
        Changes  = @($Changes | Where-Object { $_ })
        Blocked  = $Blocked
    }
}

function New-Change([string]$Target, [string]$Property, $Before, $After) {
    [PSCustomObject]@{ Target = $Target; Property = $Property; Before = $Before; After = $After }
}

# Adresse sans identifiants : smb://jean:secret@srv/imp → smb://jean:***@srv/imp.
function Hide-Credentials([string]$Uri) {
    if (-not $Uri) { return $Uri }
    $Uri -replace '(?i)(\w+://[^/\s:@]+:)[^@\s/]+@', '$1***@'
}

# Hôte d'une adresse d'imprimante (ipp://192.168.1.30/ipp/print → 192.168.1.30).
function Get-UriHost([string]$Uri) { if ($Uri -match '^\w+://(?:[^@/]+@)?\[?([^/:\]]+)') { $Matches[1] } else { $null } }

#endregion

#region Imprimantes et travaux

$script:WinStatus = @{ 1 = 'Autre'; 2 = 'Inconnu'; 3 = 'Prête'; 4 = 'Impression'; 5 = 'Préchauffage'; 6 = 'Arrêtée'; 7 = 'Hors ligne' }
$script:WinErrors = @{ 0 = $null; 1 = $null; 2 = $null; 3 = 'papier faible'; 4 = 'plus de papier'; 5 = 'toner faible'; 6 = 'plus de toner'; 7 = 'capot ouvert'; 8 = 'bourrage'; 9 = 'hors ligne'; 10 = 'intervention requise'; 11 = 'bac de sortie plein' }

# Imprimantes : Name, Driver, Port, Uri, Address, Default, Shared, State, Problem, Network.
function Get-Printers {
    Get-Cached 'printers' 300 {
        if ($IsWindows) {
            $ports = @{}
            foreach ($p in Get-CimInstance Win32_TCPIPPrinterPort -ErrorAction SilentlyContinue) { $ports[$p.Name] = $p.HostAddress }
            foreach ($p in Get-CimInstance Win32_Printer -ErrorAction SilentlyContinue) {
                $problem = $script:WinErrors[[int]$p.DetectedErrorState]
                if ($p.WorkOffline) { $problem = 'hors ligne' }
                $virtual = $p.PortName -match '^(PORTPROMPT|nul|FILE|SHRFAX|XPS|PDF|ONENOTE)' -or $p.DriverName -match 'PDF|XPS|OneNote|Fax'
                [PSCustomObject]@{ Name = $p.Name; Driver = $p.DriverName; Port = $p.PortName; Uri = $p.PortName; Address = $ports[$p.PortName] ?? $(if ($p.PortName -match '^\\\\([^\\]+)') { $Matches[1] } else { $null })
                    Default = [bool]$p.Default; Shared = [bool]$p.Shared; ShareName = $p.ShareName; State = $script:WinStatus[[int]$p.PrinterStatus] ?? "$($p.PrinterStatus)"
                    Problem = $problem; Network = [bool]$p.Network -or [bool]$ports[$p.PortName]; Virtual = $virtual; Enabled = -not $p.WorkOffline }
            }
            return
        }
        # Un seul appel (lpstat attend ~1 s les imprimantes découvertes sur le réseau à chaque appel) ; en cache 5 min.
        $out = @(Invoke-Tool lpstat @('-d', '-v', '-l', '-p'))
        $default = "$($out | Where-Object { $_ -match '^system default destination:|destination par défaut' })" -replace '^.*:\s*', ''
        $uris = @{}
        foreach ($line in $out) { if ($line -match '^device for (\S+?):\s+(.+)$' -or $line -match '^périphérique pour (\S+?)\s*:\s+(.+)$') { $uris[$Matches[1]] = $Matches[2].Trim() } }
        $current = $null
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($line in $out | Where-Object { $_ -match '^(printer|imprimante)\s|^\s' }) {
            # « printer HP is idle.  enabled since … » ; « printer HP disabled since … - raison » ; puis lignes indentées.
            if ($line -match '^\S+\s+(\S+)\s+(.*)$' -and $line -notmatch '^\s') {
                $name = $Matches[1]; $rest = $Matches[2]
                $state = if ($rest -match 'disabled|désactivée') { 'Arrêtée' } elseif ($rest -match 'printing|impression|now printing') { 'Impression' } else { 'Prête' }
                $current = [PSCustomObject]@{ Name = $name; Driver = $null; Port = $null; Uri = Hide-Credentials $uris[$name]; Address = Get-UriHost $uris[$name]; Default = $name -eq $default
                    Shared = $false; ShareName = $null; State = $state; Problem = $(if ($state -eq 'Arrêtée' -and $rest -match ' - (.+)$') { $Matches[1] } elseif ($state -eq 'Arrêtée') { 'arrêtée' } else { $null })
                    Network = "$($uris[$name])" -match '^(ipp|ipps|http|https|socket|lpd|smb|dnssd)://'; Virtual = "$($uris[$name])" -match '^(cups-pdf|file):'; Enabled = $state -ne 'Arrêtée' }
                $list.Add($current)
            }
            elseif ($current -and $line -match '^\s+Interface:\s*(.+)$') { $current.Driver = [System.IO.Path]::GetFileNameWithoutExtension($Matches[1].Trim()) }
            elseif ($current -and $line -match '^\s+Description:\s*(.+)$') { $current.Driver = $current.Driver ?? $Matches[1].Trim() }
            elseif ($current -and $line -match '^\s+Alerts:\s*(.+)$' -and $Matches[1] -notmatch 'none') { $current.Problem = (@($current.Problem, $Matches[1].Trim()) | Where-Object { $_ }) -join ', ' }
        }
        # Partage CUPS (imprimante publiée sur le réseau).
        foreach ($p in $list) {
            $opt = "$(Invoke-Tool lpoptions @('-p', $p.Name))"
            if ($opt -match 'printer-is-shared=true') { $p.Shared = $true }
            if ($opt -match "printer-make-and-model='([^']+)'") { $p.Driver = $Matches[1] }
        }
        $list
    }
}

# Travaux en attente : Printer, Id, Document, Owner, Submitted, Pages, Size, Status.
function Get-PrintJobs {
    Get-Cached 'jobs' 30 {
        if ($IsWindows) {
            foreach ($j in Get-CimInstance Win32_PrintJob -ErrorAction SilentlyContinue) {
                [PSCustomObject]@{ Printer = ($j.Name -split ',')[0]; Id = $j.JobId; Document = $j.Document; Owner = $j.Owner
                    Submitted = if ($j.TimeSubmitted) { [Management.ManagementDateTimeConverter]::ToDateTime($j.TimeSubmitted) } else { $null }
                    Pages = $j.TotalPages; Size = $j.Size; Status = $(if ($j.JobStatus) { $j.JobStatus } else { $j.Status }) }
            }
            return
        }
        # « HP-42 jean 1024 Sat 24 Oct 2026 10:12:03 CEST »
        foreach ($line in Invoke-Tool lpstat @('-o', '-W', 'not-completed')) {
            if ($line -match '^(\S+)-(\d+)\s+(\S+)\s+(\d+)\s+(.+)$') {
                $when = $null
                $text = $Matches[5] -replace '\s+[A-Z]{3,5}$', ''
                foreach ($fmt in 'ddd dd MMM yyyy HH:mm:ss', 'ddd MMM dd HH:mm:ss yyyy', 'ddd d MMM yyyy HH:mm:ss') {
                    $d = [datetime]::MinValue
                    if ([datetime]::TryParseExact($text, $fmt, [cultureinfo]::InvariantCulture, 'AllowWhiteSpaces', [ref]$d)) { $when = $d; break }
                }
                [PSCustomObject]@{ Printer = $Matches[1]; Id = $Matches[2]; Document = $null; Owner = $Matches[3]; Submitted = $when; Pages = $null; Size = [long]$Matches[4]; Status = 'en attente' }
            }
        }
    }
}

# Service d'impression : Windows Spooler, Linux CUPS ; erreurs des 7 derniers jours.
function Get-SpoolerState {
    Get-Cached 'spooler' 60 {
        if ($IsWindows) {
            $svc = Get-Service Spooler -ErrorAction SilentlyContinue
            $errors = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-PrintService/Admin'; Level = 1, 2; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 50 -ErrorAction SilentlyContinue)
            return [PSCustomObject]@{ Name = 'Spouleur d''impression'; Running = $svc.Status -eq 'Running'; StartType = "$($svc.StartType)"; Errors = $errors.Count; LastError = ($errors | Select-Object -First 1 | ForEach-Object { ($_.Message -split "`r?`n")[0] }) }
        }
        $active = "$(Invoke-Tool systemctl @('is-active', 'cups'))".Trim()
        if (-not $active) { $active = if ("$(Invoke-Tool lpstat @('-r'))" -match 'is running|en cours') { 'active' } else { 'inactive' } }
        $errors = @(Invoke-Tool journalctl @('-u', 'cups', '-p', 'err', '--since=-7d', '-o', 'cat', '--no-pager', '-q'))
        [PSCustomObject]@{ Name = 'CUPS'; Running = $active -eq 'active'; StartType = "$(Invoke-Tool systemctl @('is-enabled', 'cups'))".Trim(); Errors = $errors.Count; LastError = $errors | Select-Object -Last 1 }
    }
}

#endregion

#region Scanners et Bluetooth

# Scanners. Linux : scanimage -L peut chercher 10 à 20 s sur le réseau : lancé en arrière-plan, le résultat est lu au
# rafraîchissement suivant et gardé 10 min (la page n'attend jamais).
$script:ScanProcess = $null
function Get-Scanners([switch]$Wait) {
    if ($IsWindows) {
        return Get-Cached 'scanners' 600 {
            foreach ($d in Get-PnpDevice -Class Image -PresentOnly -ErrorAction SilentlyContinue) {
                if ($d.FriendlyName -match '(?i)camera|webcam|caméra') { continue }
                [PSCustomObject]@{ Name = $d.FriendlyName; Connection = $d.InstanceId -replace '\\.*$', ''; State = if ($d.Status -eq 'OK') { 'prêt' } else { "$($d.Status)" } }
            }
        }
    }
    $entry = $script:Cache['scanners']
    if ($entry -and ((Get-Date) - $entry.At).TotalMinutes -lt 10) { return $entry.Value }
    if (-not (Test-Tool scanimage)) { return @() }
    if (-not $script:ScanProcess) {
        $psi = [System.Diagnostics.ProcessStartInfo]::new((Get-Command scanimage -CommandType Application | Select-Object -First 1).Source, '-L')
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
        $proc = [System.Diagnostics.Process]::Start($psi)
        $script:ScanProcess = @{ Process = $proc; Output = $proc.StandardOutput.ReadToEndAsync(); Started = Get-Date }
    }
    $sp = $script:ScanProcess
    if ($Wait) { [void]$sp.Process.WaitForExit(30000) }
    if (-not $sp.Process.HasExited) {
        if (((Get-Date) - $sp.Started).TotalSeconds -lt 60) { return $null }   # recherche en cours
        try { $sp.Process.Kill($true) } catch { }
    }
    $script:ScanProcess = $null
    $list = foreach ($line in ($(if ($sp.Process.HasExited) { $sp.Output.Result } else { '' }) -split "`n")) {
        # « device `airscan:e0:HP' is a eSCL HP ip=192.168.1.30 » ; les webcams (v4l) ne sont pas des scanners.
        if ($line -match "^device [`'](\S+?)' is an? (.+)$" -and $Matches[1] -notmatch '^v4l:') {
            $dev = $Matches[1]; $desc = $Matches[2]
            [PSCustomObject]@{ Name = $desc.Trim(); Connection = ($dev -split ':')[0]; State = 'détecté' }
        }
    }
    $script:Cache['scanners'] = @{ At = Get-Date; Value = @($list) }
    @($list)
}

function Get-BluetoothDevices {
    Get-Cached 'bluetooth' 60 {
        if ($IsWindows) {
            $radio = @(Get-PnpDevice -Class Bluetooth -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match '(?i)adapter|radio|wireless bluetooth|bluetooth\(r\)|realtek bluetooth|intel.*bluetooth' })
            $devices = foreach ($d in Get-PnpDevice -Class Bluetooth -ErrorAction SilentlyContinue) {
                if ($d.FriendlyName -match '(?i)enumerator|radio|adapter|microsoft bluetooth|rfcomm|identification|generic attribute|le generic|avrcp|service|wireless bluetooth|bluetooth\(r\)|intel.*bluetooth|realtek bluetooth') { continue }
                [PSCustomObject]@{ Name = $d.FriendlyName; Address = $(if ($d.InstanceId -match '_([0-9A-F]{12})') { ($Matches[1] -split '(..)' | Where-Object { $_ }) -join ':' } else { $null }); Kind = $null
                    Connected = $d.Status -eq 'OK' -and $d.Present; Battery = $null; Trusted = $null }
            }
            return [PSCustomObject]@{ Adapter = if ($radio) { $radio[0].FriendlyName } else { $null }; Powered = if ($radio) { $radio[0].Status -eq 'OK' } else { $null }; Devices = @($devices | Sort-Object Name -Unique) }
        }
        if (-not (Test-Tool bluetoothctl)) { return [PSCustomObject]@{ Adapter = $null; Powered = $null; Devices = @() } }
        $show = @(Invoke-ToolTimeout bluetoothctl @('show') 5)
        $adapter = ($show | Where-Object { $_ -match '^\s*Name:' } | Select-Object -First 1) -replace '^\s*Name:\s*', ''
        $line = $show | Where-Object { $_ -match '^\s*Powered:' } | Select-Object -First 1
        $powered = if ($line) { $line -match 'yes' } else { $null }
        $paired = @(Invoke-ToolTimeout bluetoothctl @('devices', 'Paired') 5)
        if (-not $paired -or ($paired -join ' ') -match 'Invalid command') { $paired = @(Invoke-ToolTimeout bluetoothctl @('paired-devices') 5) }
        $devices = foreach ($line in $paired) {
            if ($line -notmatch '^Device\s+([0-9A-F:]{17})\s+(.+)$') { continue }
            $mac = $Matches[1]; $name = $Matches[2].Trim()
            $info = @(Invoke-ToolTimeout bluetoothctl @('info', $mac) 5)
            $get = { param($k) ($info | Where-Object { $_ -match "^\s*$($k):\s*(.+)$" } | Select-Object -First 1) -replace "^\s*$($k):\s*", '' }
            $battery = & $get 'Battery Percentage'
            [PSCustomObject]@{ Name = $name; Address = $mac; Kind = & $get 'Icon'; Connected = (& $get 'Connected') -eq 'yes'; Trusted = (& $get 'Trusted') -eq 'yes'
                Battery = if ($battery -match '\((\d+)\)') { [int]$Matches[1] } else { $null } }
        }
        [PSCustomObject]@{ Adapter = $adapter; Powered = $powered; Devices = @($devices) }
    }
}

$script:BtKinds = @{ 'audio-headset' = 'casque'; 'audio-headphones' = 'écouteurs'; 'audio-card' = 'audio'; 'input-mouse' = 'souris'; 'input-keyboard' = 'clavier'; 'input-gaming' = 'manette'; 'phone' = 'téléphone'; 'computer' = 'ordinateur' }

#endregion

#region Vue d'ensemble

function Get-ModuleData {
    $sections = [System.Collections.Generic.List[object]]::new()
    $findings = [System.Collections.Generic.List[object]]::new()
    $errors = [ordered]@{}
    function Invoke-Block([string]$Name, [scriptblock]$Block) {
        try { & $Block } catch { $errors[$Name] = $_.Exception.Message; $null }
    }

    $printers = @(Invoke-Block 'Imprimantes' { Get-Printers })
    $jobs = @(Invoke-Block "Files d'attente" { Get-PrintJobs })
    $spooler = Invoke-Block 'Spouleur' { Get-SpoolerState }
    $real = @($printers | Where-Object { -not $_.Virtual })

    $items = [ordered]@{
        'Service d''impression' = if ($spooler) { '{0} : {1}' -f $spooler.Name, $(if ($spooler.Running) { 'en marche' } else { 'arrêté' }) } else { '—' }
        'Imprimantes' = '{0} ({1} physique(s))' -f $printers.Count, $real.Count
        'Par défaut' = ($printers | Where-Object Default | Select-Object -First 1).Name ?? 'aucune'
        'Travaux en attente' = $jobs.Count
        'Erreurs du service (7 jours)' = $spooler.Errors
    }
    $sections.Add([PSCustomObject]@{ Title = 'Impression'; Type = 'KeyValue'; Icon = 'desktop'; Items = $items })

    if ($spooler -and -not $spooler.Running -and $printers.Count) {
        $findings.Add((New-Finding 'critical' 'PRN-SPOOLER-DOWN' "$($spooler.Name) est arrêté : aucune impression possible." 'Redémarrer le service (maintenance_reset_print_queue ou onglet Services).'))
    }
    if ($spooler.Errors -ge 5) { $findings.Add((New-Finding 'info' 'PRN-SPOOLER-ERRORS' ("{0} erreur(s) du service d'impression en 7 jours (dernière : {1})." -f $spooler.Errors, $spooler.LastError) 'Voir le journal du service (onglet Événements).')) }

    if ($printers.Count) {
        $sections.Add([PSCustomObject]@{ Title = 'Imprimantes'; Type = 'Table'; Icon = 'desktop'; Columns = @('Imprimante', 'État', 'Problème', 'Par défaut', 'Adresse', 'Pilote', 'Partagée', 'Réseau')
                Rows = @($printers | Sort-Object { -not $_.Default }, Name | ForEach-Object { , @($_.Name, $_.State, $_.Problem, $(if ($_.Default) { 'oui' } else { '' }), ($_.Address ?? $_.Uri ?? $_.Port), $_.Driver, $(if ($_.Shared) { 'oui' } else { 'non' }), $(if ($_.Network) { 'oui' } else { 'non' })) }) })
        foreach ($p in $real | Where-Object { $_.Problem -or $_.State -in 'Hors ligne', 'Arrêtée' }) {
            $findings.Add((New-Finding 'warning' 'PRN-PRINTER-PROBLEM' ('{0} : {1}.' -f $p.Name, ($p.Problem ?? $p.State.ToLower())) 'Vérifier que l''imprimante est allumée, connectée, et qu''elle a du papier et de l''encre ; la réactiver si elle a été suspendue.'))
        }
        if (-not ($printers | Where-Object Default) -and $real.Count) { $findings.Add((New-Finding 'info' 'PRN-NO-DEFAULT' 'Aucune imprimante par défaut.' 'Choisir une imprimante par défaut dans les paramètres d''impression.')) }
        foreach ($p in $real | Where-Object Shared) { $findings.Add((New-Finding 'info' 'PRN-SHARED' "$($p.Name) est partagée sur le réseau." 'Désactiver le partage si d''autres postes n''en ont pas besoin.')) }
    }

    if ($jobs.Count) {
        $sections.Add([PSCustomObject]@{ Title = "Travaux en file d'attente"; Type = 'Table'; Icon = 'timer'; Columns = @('Imprimante', 'N°', 'Document', 'Propriétaire', 'Envoyé', 'Pages', 'État')
                Rows = @($jobs | ForEach-Object { , @($_.Printer, $_.Id, $_.Document, $_.Owner, (Format-Date $_.Submitted), $_.Pages, $_.Status) }) })
        $stuck = @($jobs | Where-Object { $_.Submitted -and ((Get-Date) - $_.Submitted).TotalMinutes -ge 30 -or "$($_.Status)" -match '(?i)error|erreur|blocked|bloqu' })
        if ($stuck.Count) {
            $findings.Add((New-Finding 'warning' 'PRN-JOB-STUCK' ('{0} travail(aux) bloqué(s) depuis plus de 30 min ou en erreur (le plus ancien : {1} sur {2}).' -f $stuck.Count, (Format-Date ($stuck | Sort-Object Submitted | Select-Object -First 1).Submitted), $stuck[0].Printer) 'Vider la file d''attente (maintenance_reset_print_queue) puis relancer l''impression.'))
        }
    }

    # Scanners
    $scanners = Invoke-Block 'Scanners' { Get-Scanners }
    $scanners = @($scanners)
    if ($scanners.Count) {
        $sections.Add([PSCustomObject]@{ Title = 'Scanners'; Type = 'Table'; Icon = 'search'; Columns = @('Scanner', 'Connexion', 'État'); Rows = @($scanners | ForEach-Object { , @($_.Name, $_.Connection, $_.State) }) })
    }

    # Bluetooth
    $bt = Invoke-Block 'Bluetooth' { Get-BluetoothDevices }
    if ($bt -and ($bt.Adapter -or $bt.Devices.Count)) {
        $items = [ordered]@{ 'Adaptateur' = $bt.Adapter ?? '—'; 'Allumé' = if ($null -eq $bt.Powered) { '—' } elseif ($bt.Powered) { 'oui' } else { 'non' }
            'Appareils appairés' = $bt.Devices.Count; 'Connectés' = @($bt.Devices | Where-Object Connected).Count }
        $sections.Add([PSCustomObject]@{ Title = 'Bluetooth'; Type = 'KeyValue'; Icon = 'link'; Items = $items })
        if ($bt.Devices.Count) {
            $sections.Add([PSCustomObject]@{ Title = 'Appareils Bluetooth appairés'; Type = 'Table'; Icon = 'link'; Columns = @('Appareil', 'Type', 'Connecté', 'Batterie %', 'Adresse')
                    Rows = @($bt.Devices | Sort-Object { -not $_.Connected }, Name | ForEach-Object { , @($_.Name, ($script:BtKinds["$($_.Kind)"] ?? $_.Kind), $(if ($_.Connected) { 'oui' } else { 'non' }), $_.Battery, $_.Address) }) })
            foreach ($d in $bt.Devices | Where-Object { $null -ne $_.Battery -and $_.Battery -le 15 }) { $findings.Add((New-Finding 'info' 'PRN-BT-BATTERY-LOW' ('{0} : batterie à {1} %.' -f $d.Name, $d.Battery) 'Recharger l''appareil.')) }
        }
        if ($bt.Powered -eq $false -and $bt.Devices.Count) { $findings.Add((New-Finding 'info' 'PRN-BT-OFF' 'Le Bluetooth est éteint : les appareils appairés ne peuvent pas se connecter.' 'Allumer le Bluetooth si un appareil doit se connecter.')) }
    }

    if ($errors.Count) { $sections.Add([PSCustomObject]@{ Title = 'Erreurs de collecte'; Type = 'KeyValue'; Icon = 'error_circle'; Items = $errors }) }

    $parts = @('{0} imprimante(s)' -f $printers.Count)
    if ($jobs.Count) { $parts += '{0} travail(aux) en attente' -f $jobs.Count }
    if ($spooler -and -not $spooler.Running) { $parts += "$($spooler.Name) arrêté" }
    if ($scanners.Count) { $parts += '{0} scanner(s)' -f $scanners.Count }
    if ($bt.Devices.Count) { $parts += 'Bluetooth : {0} appairé(s)' -f $bt.Devices.Count }
    [PSCustomObject]@{ Subtitle = $parts -join ' · '; Sections = $sections.ToArray(); Findings = $findings.ToArray() }
}

#endregion

#region Fonctions ciblées

function Find-Printer([string]$Name) {
    $printers = @(Get-Printers)
    $p = $printers | Where-Object Name -eq $Name | Select-Object -First 1
    if (-not $p -and -not $Name) { $p = $printers | Where-Object Default | Select-Object -First 1 }
    [PSCustomObject]@{ Printer = $p; All = $printers }
}

# printing_get_printer : détail d'une imprimante (par défaut : l'imprimante par défaut) et ses travaux.
function Get-SIPrinter {
    param([string]$Name)
    $script:Cache.Remove('printers'); $script:Cache.Remove('jobs')
    $found = Find-Printer $Name
    $p = $found.Printer
    if (-not $p) { throw $(if ($found.All.Count) { "Imprimante introuvable : « $Name ». Imprimantes : $(($found.All | ForEach-Object Name) -join ', ')." } else { 'Aucune imprimante installée.' }) }
    $items = [ordered]@{ 'Imprimante' = $p.Name; 'État' = $p.State; 'Problème' = $p.Problem ?? 'aucun'; 'Par défaut' = if ($p.Default) { 'oui' } else { 'non' }
        'Pilote / modèle' = $p.Driver ?? '—'; 'Port' = $p.Port ?? '—'; 'Adresse' = $p.Uri ?? $p.Address ?? '—'; 'Réseau' = if ($p.Network) { 'oui' } else { 'non' }
        'Partagée' = if ($p.Shared) { "oui$(if ($p.ShareName) { " ($($p.ShareName))" })" } else { 'non' } }
    if ($IsLinux) {
        $attrs = @(Invoke-Tool lpoptions @('-p', $p.Name))
        if ("$attrs" -match "printer-state-reasons=(\S+)") { $items['Raisons de l''état'] = $Matches[1] }
        if ("$attrs" -match "printer-location='?([^' ]+)") { $items['Emplacement'] = $Matches[1] }
    }
    $jobs = @(Get-PrintJobs | Where-Object Printer -eq $p.Name)
    $findings = @()
    if ($p.Problem) { $findings += New-Finding 'warning' 'PRN-PRINTER-PROBLEM' "$($p.Name) : $($p.Problem)." 'Vérifier l''imprimante (alimentation, câble ou réseau, papier, encre).' }
    if ($p.Network -and $p.Address) {
        # Imprimante réseau joignable ? (port IPP 631, sinon RAW 9100), 2 s au plus.
        $reach = $false
        foreach ($port in 631, 9100) {
            $c = [System.Net.Sockets.TcpClient]::new()
            try { if ($c.ConnectAsync($p.Address, $port).Wait(2000) -and $c.Connected) { $reach = $true; break } } catch { } finally { $c.Dispose() }
        }
        $items['Joignable sur le réseau'] = if ($reach) { 'oui' } else { 'non (ports 631 et 9100)' }
        if (-not $reach) { $findings += New-Finding 'warning' 'PRN-UNREACHABLE' "$($p.Name) ne répond pas sur le réseau ($($p.Address))." 'Vérifier qu''elle est allumée et sur le même réseau ; son adresse a pu changer (DHCP).' }
    }
    [PSCustomObject]@{
        Subtitle = "$($p.Name) · $($p.State) · $($jobs.Count) travail(aux)"
        Sections = @(
            [PSCustomObject]@{ Title = 'Imprimante'; Type = 'KeyValue'; Icon = 'desktop'; Items = $items }
            [PSCustomObject]@{ Title = "File d'attente"; Type = 'Table'; Icon = 'timer'; Columns = @('N°', 'Document', 'Propriétaire', 'Envoyé', 'Pages', 'État'); Rows = @($jobs | ForEach-Object { , @($_.Id, $_.Document, $_.Owner, (Format-Date $_.Submitted), $_.Pages, $_.Status) }) }
        )
        Findings = $findings
    }
}

# printing_list_jobs : travaux de toutes les files d'attente.
function Get-SIPrintJobs {
    param([string]$Printer)
    $script:Cache.Remove('jobs')
    $jobs = @(Get-PrintJobs)
    if ($Printer) { $jobs = @($jobs | Where-Object Printer -eq $Printer) }
    [PSCustomObject]@{
        Subtitle = '{0} travail(aux)' -f $jobs.Count
        Sections = @([PSCustomObject]@{ Title = "Travaux en file d'attente"; Type = 'Table'; Icon = 'timer'; Columns = @('Imprimante', 'N°', 'Document', 'Propriétaire', 'Envoyé', 'Pages', 'Taille (Kio)', 'État')
                Rows = @($jobs | ForEach-Object { , @($_.Printer, $_.Id, $_.Document, $_.Owner, (Format-Date $_.Submitted), $_.Pages, $(if ($_.Size) { [Math]::Round($_.Size / 1KB, 1) } else { $null }), $_.Status) }) })
        Findings = @()
    }
}

# printing_print_test_page : imprime la page de test de l'imprimante. Windows : Win32_Printer.PrintTestPage ;
# Linux : lp avec la page de test de CUPS.
function Invoke-SIPrintTestPage {
    param([string]$Name, [switch]$DryRun)
    $script:Cache.Remove('printers')
    $found = Find-Printer $Name
    $p = $found.Printer
    $blocked = $null
    if (-not $p) { $blocked = if ($found.All.Count) { "Imprimante introuvable : « $Name ». Imprimantes : $(($found.All | ForEach-Object Name) -join ', ')." } else { 'Aucune imprimante installée.' } }
    elseif ($p.Virtual) { $blocked = "$($p.Name) est une imprimante virtuelle (PDF, XPS, fichier) : pas de page de test." }
    elseif (-not $p.Enabled -or $p.State -eq 'Arrêtée') { $blocked = "$($p.Name) est arrêtée ou hors ligne : la réactiver d'abord." }
    $testFile = $null
    if (-not $blocked -and $IsLinux) {
        $testFile = @('/usr/share/cups/data/testprint', '/usr/share/cups/data/default-testpage.pdf', '/usr/share/cups/data/testprint.ps') | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $testFile) { $blocked = 'Page de test de CUPS introuvable (/usr/share/cups/data).' }
        elseif (-not (Test-Tool lp)) { $blocked = 'Commande lp absente (paquet cups-client).' }
    }
    $section = if ($p) { [PSCustomObject]@{ Title = 'Imprimante'; Type = 'KeyValue'; Icon = 'desktop'; Items = [ordered]@{ 'Imprimante' = $p.Name; 'État' = $p.State; 'Adresse' = $p.Uri ?? $p.Address ?? $p.Port; 'Pilote' = $p.Driver ?? '—' } } } else { $null }
    $findings = @(New-Finding 'info' 'PRN-TEST-PAGE' 'Une page sera imprimée (papier et encre).' $null)
    $change = New-Change ($p.Name ?? $Name) "File d'attente" 'inchangée' '1 page de test'
 $target = $p.Name ?? $(if ($Name) { $Name } else { "l'imprimante par défaut" })
    if ($DryRun -or $blocked) { return New-ActionResult "Une page de test sera imprimée sur $target" @($section) $findings @($change) $blocked }

    if ($IsWindows) {
        $printer = Get-CimInstance Win32_Printer -Filter "Name='$($p.Name -replace "'", "''" -replace '\\', '\\')'"
        $r = Invoke-CimMethod -InputObject $printer -MethodName PrintTestPage
        if ($r.ReturnValue -ne 0) { throw "Page de test refusée (code $($r.ReturnValue))." }
        $id = $null
    }
    else {
        $out = & lp -d $p.Name -t 'SysInfo - page de test' $testFile 2>&1
        if ($LASTEXITCODE -ne 0) { throw "lp a échoué : $($out -join ' ')" }
        $id = if ("$out" -match '(\S+-\d+)') { $Matches[1] } else { $null }
    }
    New-ActionResult "Page de test envoyée à $($p.Name)$(if ($id) { " ($id)" })" @($section) @() @(New-Change $p.Name "File d'attente" 'inchangée' "page de test envoyée$(if ($id) { " ($id)" })") $null
}

#endregion

Export-ModuleMember -Function Get-ModuleData, Get-SIPrinter, Get-SIPrintJobs, Invoke-SIPrintTestPage
