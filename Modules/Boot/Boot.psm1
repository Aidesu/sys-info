# Module Démarrage : durée du démarrage et ce qui le ralentit, démarrages précédents, gestionnaire de démarrage,
# ordre de démarrage UEFI, noyaux installés.
#
# Sources
#   Windows : journal Microsoft-Windows-Diagnostics-Performance/Operational (100 = durée, 101 à 110 = éléments lents ;
#             lisible en administrateur), registre (FwPOSTTime : durée du firmware), Win32_OperatingSystem,
#             bcdedit /enum et /enum firmware (administrateur).
#   Linux   : systemd-analyze (durée, blame, critical-chain), journalctl (« Startup finished » de chaque démarrage),
#             efibootmgr, /etc/default/grub, grubby (noyau par défaut, root), bootctl (systemd-boot), /proc/cmdline,
#             /lib/modules (noyaux installés), uname.
# Ce qui ne change qu'à chaque démarrage est gardé en cache pour tout le démarrage.
# Modifier le gestionnaire de démarrage (bcdedit /set, GRUB) : niveau X, jamais proposé.

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

function Format-Unit([double]$Value, [string]$Unit, [string]$Format = '0.#') {
    '{0}{1}{2}' -f $Value.ToString($Format, $script:Fr), $script:Nbsp, $Unit
}

function Format-Seconds([double]$Seconds) {
    if ($Seconds -ge 60) { return '{0}{1}min {2:00}{1}s' -f [Math]::Floor($Seconds / 60), $script:Nbsp, [Math]::Floor($Seconds % 60) }
    Format-Unit $Seconds 's' '0.#'
}

function Format-Date($Date) {
    if (-not $Date) { return '—' }
    ([datetime]$Date).ToString('ddd d MMM yyyy HH:mm', $script:Fr)
}

function Read-Text([string]$Path) { try { [System.IO.File]::ReadAllText($Path).Trim() } catch { $null } }

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

# « 5.716s », « 1min 2.3s », « 352us », « 29ms » → secondes.
function ConvertFrom-SystemdTime([string]$Text) {
    $total = 0.0
    foreach ($m in [regex]::Matches($Text, '([\d.]+)\s*(min|ms|us|µs|s|h)')) {
        $v = [double]::Parse($m.Groups[1].Value, [cultureinfo]::InvariantCulture)
        $total += switch ($m.Groups[2].Value) { 'h' { $v * 3600 } 'min' { $v * 60 } 's' { $v } 'ms' { $v / 1000 } default { $v / 1e6 } }
    }
    $total
}

# Clé du démarrage en cours : ce qui en dépend est recalculé seulement après un redémarrage.
function Get-BootKey {
    if ($IsLinux) { return Read-Text /proc/sys/kernel/random/boot_id }
    (Get-Cached 'bootTime' 3600 { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime }).ToString('o')
}

function Get-PerBoot([string]$Key, [scriptblock]$Compute) {
    $boot = Get-BootKey
    $entry = $script:Cache["boot:$Key"]
    if ($entry -and $entry.Boot -eq $boot) { return $entry.Value }
    $value = & $Compute
    $script:Cache["boot:$Key"] = @{ Boot = $boot; Value = $value }
    $value
}

#endregion

#region Durée du démarrage

# « Startup finished in 5.716s (firmware) + 4.011s (loader) + 1.579s (kernel) + 1.342s (initrd) + 20.360s (userspace) = 33.010s. »
function ConvertFrom-StartupMessage([string]$Message) {
    if ($Message -notmatch 'Startup finished in (.+)= (.+?)\.?\s*$') { return $null }
    $stages = $Matches[1]; $total = ConvertFrom-SystemdTime $Matches[2]
    $parts = [ordered]@{}
    foreach ($p in $stages -split '\+') { if ($p -match '^\s*(.+?)\s*\((\w+)\)\s*$') { $parts[$Matches[2]] = ConvertFrom-SystemdTime $Matches[1] } }
    [PSCustomObject]@{ Firmware = $parts['firmware']; Loader = $parts['loader']; Kernel = $parts['kernel']; Initrd = $parts['initrd']; Userspace = $parts['userspace']; Total = $total }
}

# Démarrage en cours : durées par étape, unités qui ralentissent (blame), chaîne critique.
function Get-CurrentBoot {
    if ($IsLinux) {
        $result = Get-PerBoot 'analyze' {
            $summary = "$(Invoke-Tool systemd-analyze @('--no-pager') | Select-Object -First 1)"
            $times = ConvertFrom-StartupMessage $summary
            if (-not $times) { return [PSCustomObject]@{ Finished = $false; Times = $null; Blame = @(); Chain = @() } }
            $blame = foreach ($line in Invoke-Tool systemd-analyze @('blame', '--no-pager') | Select-Object -First 15) {
                if ($line -match '^\s*(.+?)\s+(\S+\.\w+)$') { [PSCustomObject]@{ Unit = $Matches[2]; Seconds = ConvertFrom-SystemdTime $Matches[1] } }
            }
            $chain = foreach ($line in Invoke-Tool systemd-analyze @('critical-chain', '--no-pager')) {
                if ($line -match '^[\s└─│├]*(\S+\.\w+)\s+@(\S+)(?:\s+\+(\S+))?') {
                    [PSCustomObject]@{ Unit = $Matches[1]; At = ConvertFrom-SystemdTime $Matches[2]; Seconds = if ($Matches[3]) { ConvertFrom-SystemdTime $Matches[3] } else { 0 } }
                }
            }
            [PSCustomObject]@{ Finished = $true; Times = $times; Blame = @($blame); Chain = @($chain) }
        }
        # Démarrage pas encore terminé : on retentera (pas de cache pour tout le démarrage).
        if (-not $result.Finished) { $script:Cache.Remove('boot:analyze') }
        return $result
    }

    Get-PerBoot 'windows' {
        $fw = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction SilentlyContinue).FwPOSTTime
        $last = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } -MaxEvents 1 -ErrorAction SilentlyContinue
        $times = $null; $slow = @(); $denied = $false
        if ($last) {
            $xml = [xml]$last.ToXml()
            $d = @{}; foreach ($n in $xml.Event.EventData.Data) { $d[$n.Name] = $n.'#text' }
            $times = [PSCustomObject]@{ Firmware = if ($fw) { $fw / 1000 } else { $null }; Loader = $null; Kernel = $null; Initrd = $null
                Userspace = [double]$d.MainPathBootTime / 1000; PostBoot = [double]$d.BootPostBootTime / 1000; Total = [double]$d.BootTime / 1000; At = $last.TimeCreated; Degraded = $d.IsDegradation -eq 'true' }
            # 101 application, 102 pilote, 103 service, 106 tâche de fond, 109 périphérique… : éléments qui ont ralenti ce démarrage.
            $since = $last.TimeCreated.AddMinutes(-1)
            $slow = foreach ($e in Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 101..110; StartTime = $since } -MaxEvents 30 -ErrorAction SilentlyContinue) {
                $x = [xml]$e.ToXml(); $v = @{}; foreach ($n in $x.Event.EventData.Data) { $v[$n.Name] = $n.'#text' }
                $name = $v.FriendlyName ?? $v.Name ?? $v.FileName
                $kind = @{ 101 = 'Application'; 102 = 'Pilote'; 103 = 'Service'; 104 = 'Mise en cache'; 105 = 'Périphérique'; 106 = 'Tâche de fond'; 107 = 'Pilote'; 108 = 'Pilote'; 109 = 'Périphérique'; 110 = 'Session' }[$e.Id]
                [PSCustomObject]@{ Unit = "$name ($kind)"; Seconds = [double]($v.TotalTime ?? 0) / 1000 }
            }
        }
        elseif ($fw) { $times = [PSCustomObject]@{ Firmware = $fw / 1000; Total = $null }; $denied = $true }
        else { $denied = $true }
        [PSCustomObject]@{ Finished = [bool]$times; Times = $times; Blame = @($slow | Sort-Object Seconds -Descending); Chain = @(); Denied = $denied -and -not $last }
    }
}

# Démarrages précédents et leur durée. Linux : un seul appel à journalctl (« Startup finished » de PID 1).
function Get-BootHistory([int]$Max = 30) {
    if ($IsLinux) {
        $lines = Invoke-Tool journalctl @('-t', 'systemd', '_PID=1', '-g', 'Startup finished in', '-o', 'json', '--output-fields=_BOOT_ID,MESSAGE', '-q', '--no-pager')
        $boots = foreach ($line in $lines) {
            try { $j = $line | ConvertFrom-Json } catch { continue }
            $t = ConvertFrom-StartupMessage $j.MESSAGE
            if (-not $t) { continue }
            $at = [DateTimeOffset]::FromUnixTimeMilliseconds([long]([double]$j.__REALTIME_TIMESTAMP / 1000)).LocalDateTime
            $t | Add-Member -NotePropertyName At -NotePropertyValue $at -PassThru | Add-Member -NotePropertyName Boot -NotePropertyValue $j._BOOT_ID -PassThru
        }
        return @($boots | Sort-Object At | Select-Object -Last $Max)
    }
    $events = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } -MaxEvents $Max -ErrorAction SilentlyContinue
    $boots = foreach ($e in $events) {
        $x = [xml]$e.ToXml(); $d = @{}; foreach ($n in $x.Event.EventData.Data) { $d[$n.Name] = $n.'#text' }
        [PSCustomObject]@{ At = $e.TimeCreated; Firmware = $null; Loader = $null; Kernel = $null; Initrd = $null; Userspace = [double]$d.MainPathBootTime / 1000; Total = [double]$d.BootTime / 1000; Degraded = $d.IsDegradation -eq 'true' }
    }
    @($boots | Sort-Object At)
}

#endregion

#region Gestionnaire de démarrage et noyaux

# Entrées UEFI : Linux efibootmgr (sans droits), Windows bcdedit /enum firmware (administrateur).
function Get-FirmwareBoot {
    Get-PerBoot 'firmware' {
        if ($IsLinux) {
            $out = @(Invoke-Tool efibootmgr @())
            if (-not $out) { return [PSCustomObject]@{ Available = (Test-Path /sys/firmware/efi); Current = $null; Timeout = $null; Order = @(); Entries = @() } }
            $current = $null; $timeout = $null; $order = @()
            $entries = foreach ($line in $out) {
                if ($line -match '^BootCurrent:\s*(\w+)') { $current = $Matches[1] }
                elseif ($line -match '^Timeout:\s*(\d+)') { $timeout = [int]$Matches[1] }
                elseif ($line -match '^BootOrder:\s*(.+)$') { $order = $Matches[1].Trim() -split ',' }
                elseif ($line -match '^Boot(\w{4})(\*?)\s+(.+?)(?:\t(.*))?$') {
                    $id = $Matches[1]; $active = $Matches[2] -eq '*'; $name = $Matches[3].Trim(); $path = "$($Matches[4])"
                    $file = if ($path -match '/(\\[^)]*?\.EFI)') { $Matches[1] } elseif ($path -match '^(HD|PciRoot|BBS|VenHw)') { $Matches[1] } else { '' }
                    [PSCustomObject]@{ Id = $id; Active = $active; Name = $name; Path = $file }
                }
            }
            return [PSCustomObject]@{ Available = $true; Current = $current; Timeout = $timeout; Order = $order; Entries = @($entries) }
        }
        if (-not [Environment]::IsPrivilegedProcess) { return [PSCustomObject]@{ Available = $null; Denied = $true; Entries = @(); Order = @() } }
        $text = (& bcdedit /enum firmware 2>$null) -join "`n"
        $blocks = $text -split "`n\s*`n"
        $order = @(); $entries = @()
        foreach ($b in $blocks) {
            $id = if ($b -match 'identifi\w*\s+(\{[^}]+\}|\{\w+\})') { $Matches[1] } else { $null }
            $desc = if ($b -match 'description\s+(.+)') { $Matches[1].Trim() } else { $null }
            if ($b -match 'displayorder\s+((?:\{[^}]+\}\s*)+)') { $order = [regex]::Matches($Matches[1], '\{[^}]+\}').Value }
            if ($id -and $desc) { $entries += [PSCustomObject]@{ Id = $id; Active = $true; Name = $desc; Path = if ($b -match 'path\s+(.+)') { $Matches[1].Trim() } else { '' } } }
        }
        [PSCustomObject]@{ Available = $true; Current = '{bootmgr}'; Timeout = $null; Order = $order; Entries = $entries }
    }
}

# Gestionnaire de démarrage du système : GRUB / systemd-boot (Linux), Windows Boot Manager (bcdedit, administrateur).
function Get-BootLoader {
    Get-PerBoot 'loader' {
        $r = [ordered]@{ Name = $null; Timeout = $null; Default = $null; Entries = @(); CommandLine = $null; Note = $null }
        if ($IsLinux) {
            $r.CommandLine = Read-Text /proc/cmdline
            if (Test-Path /etc/default/grub) {
                $r.Name = 'GRUB'
                $grub = @{}
                foreach ($line in [System.IO.File]::ReadAllLines('/etc/default/grub')) { if ($line -match '^\s*(GRUB_\w+)=(.*)$') { $grub[$Matches[1]] = $Matches[2].Trim('"', "'") } }
                $r.Timeout = $grub.GRUB_TIMEOUT
                $r.Default = switch ($grub.GRUB_DEFAULT) { 'saved' { 'dernier choisi (saved)' } $null { '—' } default { $_ } }
                if (Test-Tool grubby) {
                    $kernel = "$(Invoke-Tool grubby @('--default-kernel'))".Trim()
                    if ($kernel -match '^/boot/vmlinuz') { $r.Default = $kernel } else { $r.Note = 'Noyau par défaut lisible en root seulement (grubby).' }
                }
            }
            elseif ((Test-Tool bootctl) -and ("$(Invoke-Tool bootctl @('is-installed'))" -match 'yes')) {
                $r.Name = 'systemd-boot'
                $r.Default = "$(Invoke-Tool bootctl @('status') | Where-Object { $_ -match 'Default Boot Loader Entry|default' } | Select-Object -First 1)".Trim()
            }
            else { $r.Name = 'inconnu' }
            return [PSCustomObject]$r
        }
        $r.Name = 'Windows Boot Manager'
        if (-not [Environment]::IsPrivilegedProcess) { $r.Note = 'Entrées et délai lisibles en administrateur (bcdedit).'; return [PSCustomObject]$r }
        $text = (& bcdedit /enum 2>$null) -join "`n"
        if ($text -match 'timeout\s+(\d+)') { $r.Timeout = $Matches[1] }
        $r.Entries = @(foreach ($b in $text -split "`n\s*`n") {
                if ($b -match 'description\s+(.+)' -and $b -notmatch 'Windows Boot Manager|Gestionnaire de démarrage') { $Matches[1].Trim() }
            })
        $r.Default = if ($text -match '(?s)Windows Boot Manager.*?default\s+(\{[^}]+\})') { $Matches[1] } else { $null }
        [PSCustomObject]$r
    }
}

# Noyaux installés (Linux) : /lib/modules (toutes distributions), noyau en cours (uname).
function Get-Kernels {
    if (-not $IsLinux) { return @() }
    Get-PerBoot 'kernels' {
        $running = Read-Text /proc/sys/kernel/osrelease
        $list = foreach ($dir in [System.IO.Directory]::GetDirectories('/lib/modules')) {
            $name = [System.IO.Path]::GetFileName($dir)
            # Un dossier sans image du noyau (restes d'un noyau désinstallé) n'est pas démarrable.
            $image = [System.IO.File]::Exists("$dir/vmlinuz") -or [System.IO.File]::Exists("/boot/vmlinuz-$name")
            if (-not $image) { continue }
            [PSCustomObject]@{ Version = $name; Running = $name -eq $running; Installed = [System.IO.Directory]::GetLastWriteTime($dir) }
        }
        # Tri par version (7.2.10 après 7.2.9).
        @($list | Sort-Object { [regex]::Replace($_.Version, '\d+', { $args[0].Value.PadLeft(6, '0') }) })
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

    $boot = Invoke-Block 'Durée du démarrage' { Get-CurrentBoot }
    $t = $boot.Times
    $bootTime = Get-Cached 'bootAt' 3600 { if ($IsWindows) { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime } else { (Get-Date).AddSeconds(-[double]((Read-Text /proc/uptime) -split ' ')[0]) } }

    $items = [ordered]@{ 'Démarré le' = Format-Date $bootTime }
    if ($t -and $t.Total) {
        $items['Durée totale'] = Format-Seconds $t.Total
        foreach ($p in @(@('Firmware', 'Micrologiciel (UEFI / BIOS)'), @('Loader', 'Gestionnaire de démarrage'), @('Kernel', 'Noyau'), @('Initrd', 'Initrd'), @('Userspace', $(if ($IsWindows) { "Jusqu'au bureau" } else { 'Services (espace utilisateur)' })), @('PostBoot', 'Après le bureau'))) {
            if ($null -ne $t.($p[0])) { $items[$p[1]] = Format-Seconds $t.($p[0]) }
        }
    }
    elseif ($t -and $t.Firmware) { $items['Micrologiciel (UEFI / BIOS)'] = Format-Seconds $t.Firmware }
    if ($boot -and -not $boot.Finished -and $IsLinux) { $items['Durée totale'] = 'démarrage pas encore terminé' }
    if ($boot.Denied) { $items['Durée totale'] = 'lisible en administrateur (journal Diagnostics-Performance)' }
    $sections.Add([PSCustomObject]@{ Title = 'Dernier démarrage'; Type = 'KeyValue'; Icon = 'play'; Items = $items })

    if ($t.Total -ge 90) { $findings.Add((New-Finding 'warning' 'BOOT-SLOW' ('Démarrage lent : {0}.' -f (Format-Seconds $t.Total)) 'Voir les éléments qui ralentissent le démarrage ci-dessous ; désactiver les services et programmes inutiles au démarrage.')) }
    elseif ($t.Total -ge 60) { $findings.Add((New-Finding 'info' 'BOOT-SLOW' ('Démarrage assez long : {0}.' -f (Format-Seconds $t.Total)) 'Voir les éléments qui ralentissent le démarrage ci-dessous.')) }
    if ($t.Firmware -ge 15) { $findings.Add((New-Finding 'info' 'BOOT-FIRMWARE-SLOW' ('Le micrologiciel met {0} avant de lancer le système.' -f (Format-Seconds $t.Firmware)) 'Activer le démarrage rapide (Fast Boot) dans le BIOS / UEFI, retirer les périphériques USB de démarrage inutiles.')) }
    if ($t.Degraded) { $findings.Add((New-Finding 'warning' 'BOOT-DEGRADED' 'Windows a signalé ce démarrage comme plus lent que d''habitude.' 'Voir les éléments qui ralentissent ci-dessous (journal Diagnostics-Performance).')) }

    # Ce qui ralentit : Linux, chaîne critique (ce qui retarde vraiment) et blame ; Windows, événements 101 à 110.
    if ($boot.Chain.Count) {
        $slow = @($boot.Chain | Where-Object Seconds -ge 0.5 | Sort-Object Seconds -Descending)
        $sections.Add([PSCustomObject]@{ Title = 'Chaîne critique (ce qui retarde le bureau)'; Type = 'Table'; Icon = 'timer'; Columns = @('Unité', 'Prête à (s)', 'Durée (s)')
                Rows = @($boot.Chain | ForEach-Object { , @($_.Unit, [Math]::Round($_.At, 2), [Math]::Round($_.Seconds, 2)) }) })
        foreach ($u in $slow | Where-Object Seconds -ge 5 | Select-Object -First 3) {
            $advice = switch -Regex ($u.Unit) {
                'wait-online' { 'Ce service attend le réseau : le désactiver si aucun service ne doit attendre le réseau au démarrage (systemctl disable NetworkManager-wait-online.service).'; break }
                'plymouth' { 'Écran de démarrage graphique : normal.'; break }
                'login|gdm|sddm|lightdm' { 'Écran de connexion : son temps inclut souvent l''attente du pilote graphique.'; break }
                default { 'Vérifier si ce service est utile au démarrage (onglet Services).' }
            }
            $findings.Add((New-Finding 'info' 'BOOT-SLOW-UNIT' ('{0} retarde le démarrage de {1}.' -f $u.Unit, (Format-Seconds $u.Seconds)) $advice))
        }
    }
    if ($boot.Blame.Count) {
        $sections.Add([PSCustomObject]@{ Title = $(if ($IsWindows) { 'Éléments qui ont ralenti le démarrage' } else { 'Unités les plus longues à démarrer' }); Type = 'Table'; Icon = 'pulse'; Columns = @('Élément', 'Durée (s)')
                Rows = @($boot.Blame | Select-Object -First 15 | ForEach-Object { , @($_.Unit, [Math]::Round($_.Seconds, 2)) }) })
        if ($IsWindows) { foreach ($s in $boot.Blame | Where-Object Seconds -ge 5 | Select-Object -First 3) { $findings.Add((New-Finding 'info' 'BOOT-SLOW-UNIT' ('{0} a ralenti le démarrage ({1}).' -f $s.Unit, (Format-Seconds $s.Seconds)) 'Mettre à jour ou désactiver cet élément au démarrage.')) } }
    }

    # Démarrages précédents
    $history = @(Invoke-Block 'Démarrages précédents' { Get-Cached 'history' 600 { Get-BootHistory 30 } })
    if ($history.Count -ge 2) {
        $span = [Math]::Max(86400, ((Get-Date) - $history[0].At).TotalSeconds)
        $sections.Add([PSCustomObject]@{ Title = 'Durée des démarrages'; Type = 'Metric'; Icon = 'timer'; Unit = 's'; Label = 'Total'; Value = [Math]::Round($history[-1].Total, 1)
                Secondary = [PSCustomObject]@{ Label = $(if ($IsWindows) { "Jusqu'au bureau" } else { 'Services' }); Value = [Math]::Round([double]$history[-1].Userspace, 1) }
                Detail = '{0} derniers démarrages' -f $history.Count
                History = [PSCustomObject]@{ Window = [Math]::Round($span); Points = @($history | ForEach-Object { , @($_.At.ToString('o'), [Math]::Round($_.Total, 1), [Math]::Round([double]$_.Userspace, 1)) }) } })
        $median = ($history.Total | Sort-Object)[[int][Math]::Floor($history.Count / 2)]
        if ($t.Total -and $median -gt 0 -and $t.Total -ge 1.5 * $median -and $t.Total - $median -ge 10) {
            $findings.Add((New-Finding 'warning' 'BOOT-SLOWER' ('Ce démarrage a duré {0}, contre {1} d''habitude.' -f (Format-Seconds $t.Total), (Format-Seconds $median)) 'Un service, une mise à jour ou un disque en difficulté peut l''expliquer : voir la chaîne critique et l''onglet Événements.'))
        }
    }

    # Gestionnaire de démarrage
    $loader = Invoke-Block 'Gestionnaire de démarrage' { Get-BootLoader }
    if ($loader) {
        $items = [ordered]@{ 'Gestionnaire' = $loader.Name }
        if ($null -ne $loader.Timeout) { $items['Délai du menu'] = '{0} s' -f $loader.Timeout }
        if ($loader.Default) { $items['Entrée par défaut'] = $loader.Default }
        if ($loader.Entries.Count) { $items['Entrées'] = $loader.Entries -join ', ' }
        if ($loader.CommandLine) { $items['Ligne de commande du noyau'] = $loader.CommandLine }
        if ($loader.Note) { $items['Remarque'] = $loader.Note }
        $sections.Add([PSCustomObject]@{ Title = 'Gestionnaire de démarrage'; Type = 'KeyValue'; Icon = 'settings'; Items = $items })
    }

    # Ordre de démarrage UEFI
    $fw = Invoke-Block 'UEFI' { Get-FirmwareBoot }
    if ($fw.Entries.Count) {
        $rows = foreach ($e in $fw.Entries) {
            $rank = [array]::IndexOf(@($fw.Order), $e.Id)
            , @($(if ($rank -ge 0) { $rank + 1 } else { $null }), $e.Name, $e.Path, $(if ($e.Id -eq $fw.Current) { 'en cours' } elseif (-not $e.Active) { 'inactive' } else { '' }), $e.Id)
        }
        $sections.Add([PSCustomObject]@{ Title = 'Ordre de démarrage UEFI'; Type = 'Table'; Icon = 'arrow_sort'; Columns = @('Rang', 'Entrée', 'Fichier', 'État', 'Identifiant')
                Rows = @($rows | Sort-Object { if ($null -eq $_[0]) { 999 } else { $_[0] } }) })
        $first = $fw.Entries | Where-Object { $_.Id -eq @($fw.Order)[0] } | Select-Object -First 1
        if ($first -and $first.Name -match 'USB|Network|PXE|IPv4|IPv6|LAN' -and $fw.Current -ne $first.Id) {
            $findings.Add((New-Finding 'info' 'BOOT-ORDER-EXTERNAL' "La première entrée de démarrage UEFI est « $($first.Name) » : le démarrage tente d'abord un périphérique externe ou le réseau." 'Mettre le disque système en premier dans le BIOS / UEFI si ce n''est pas voulu (démarrage plus rapide).'))
        }
    }
    elseif ($fw.Denied) { $errors['UEFI'] = 'Ordre de démarrage UEFI lisible en administrateur (bcdedit /enum firmware).' }
    elseif ($fw -and $fw.Available -eq $false) { $errors['UEFI'] = 'Démarrage en mode BIOS (Legacy) : pas d''entrées UEFI.' }

    # Noyaux
    $kernels = @(Invoke-Block 'Noyaux' { Get-Kernels })
    if ($kernels.Count) {
        $sections.Add([PSCustomObject]@{ Title = 'Noyaux installés'; Type = 'Table'; Icon = 'developer_board'; Columns = @('Version', 'État', 'Installé le')
                Rows = @($kernels | Sort-Object { [regex]::Replace($_.Version, '\d+', { $args[0].Value.PadLeft(6, '0') }) } -Descending | ForEach-Object { , @($_.Version, $(if ($_.Running) { 'en cours' } else { '' }), $_.Installed.ToString('dd/MM/yyyy', $script:Fr)) }) })
        $newest = $kernels[-1]
        if (-not $newest.Running -and ($kernels | Where-Object Running)) {
            $findings.Add((New-Finding 'info' 'BOOT-NEWER-KERNEL' ("Un noyau plus récent est installé ({0}) que celui en cours ({1}) : il sera utilisé au prochain redémarrage." -f $newest.Version, ($kernels | Where-Object Running).Version) 'Redémarrer pour utiliser le nouveau noyau (correctifs de sécurité).'))
        }
        if ($kernels.Count -eq 1) { $findings.Add((New-Finding 'info' 'BOOT-NO-FALLBACK' 'Un seul noyau installé : pas de noyau de secours si une mise à jour pose problème.' 'Garder au moins deux noyaux (installonly_limit de dnf, paquets linux-image).')) }
    }

    if ($errors.Count) { $sections.Add([PSCustomObject]@{ Title = 'Remarques et erreurs de collecte'; Type = 'KeyValue'; Icon = 'info'; Items = $errors }) }

    $parts = @()
    if ($t.Total) { $parts += 'démarrage en {0}' -f (Format-Seconds $t.Total) }
    $parts += 'démarré le ' + ([datetime]$bootTime).ToString('d MMM HH:mm', $script:Fr)
    if ($loader.Name) { $parts += $loader.Name }
    if ($kernels | Where-Object Running) { $parts += 'noyau ' + ($kernels | Where-Object Running).Version }
    [PSCustomObject]@{ Subtitle = $parts -join ' · '; Sections = $sections.ToArray(); Findings = $findings.ToArray() }
}

#endregion

#region Fonctions ciblées

# boot_get_history : démarrages précédents et durée de chaque étape.
function Get-SIBootHistory {
    param([ValidateRange(1, 100)][int]$Top = 30)
    $history = @(Get-BootHistory $Top)
    $rows = foreach ($b in $history | Sort-Object At -Descending) {
        $r = { param($v) if ($null -ne $v) { [Math]::Round([double]$v, 2) } else { $null } }
        , @((Format-Date $b.At), (& $r $b.Total), (& $r $b.Firmware), (& $r $b.Loader), (& $r $b.Kernel), (& $r $b.Initrd), (& $r $b.Userspace))
    }
    $findings = @()
    if (-not $history.Count) {
        $findings += New-Finding 'info' 'BOOT-HISTORY-EMPTY' $(if ($IsWindows) { 'Aucune durée de démarrage lisible : le journal Diagnostics-Performance demande les droits administrateur.' } else { 'Aucun démarrage dans le journal (journal non persistant ou effacé).' }) $null
    }
    $stats = if ($history.Count) {
        $totals = @($history.Total | Sort-Object)
        [ordered]@{ 'Démarrages' = $history.Count; 'Médiane' = Format-Seconds $totals[[int][Math]::Floor($totals.Count / 2)]; 'Plus rapide' = Format-Seconds $totals[0]; 'Plus lent' = Format-Seconds $totals[-1] }
    } else { [ordered]@{ 'Démarrages' = 0 } }
    [PSCustomObject]@{
        Subtitle = '{0} démarrage(s)' -f $history.Count
        Sections = @(
            [PSCustomObject]@{ Title = 'Résumé'; Type = 'KeyValue'; Icon = 'timer'; Items = $stats }
            [PSCustomObject]@{ Title = 'Démarrages'; Type = 'Table'; Icon = 'play'; Columns = @('Date', 'Total (s)', 'Micrologiciel (s)', 'Gestionnaire (s)', 'Noyau (s)', 'Initrd (s)', $(if ($IsWindows) { "Jusqu'au bureau (s)" } else { 'Services (s)' })); Rows = @($rows) }
        )
        Findings = $findings
    }
}

# boot_analyze : tout ce qui a démarré et combien de temps (Linux : blame complet, chaîne critique ; Windows : événements 101 à 110).
function Get-SIBootAnalysis {
    param([ValidateRange(1, 500)][int]$Top = 50, [ValidateRange(0, 600)][double]$MinSeconds = 0)
    $sections = [System.Collections.Generic.List[object]]::new()
    if ($IsLinux) {
        $blame = foreach ($line in Invoke-Tool systemd-analyze @('blame', '--no-pager')) {
            if ($line -match '^\s*(.+?)\s+(\S+\.\w+)$') { [PSCustomObject]@{ Unit = $Matches[2]; Seconds = ConvertFrom-SystemdTime $Matches[1] } }
        }
        $blame = @($blame | Where-Object Seconds -ge $MinSeconds | Select-Object -First $Top)
        $sections.Add([PSCustomObject]@{ Title = 'Durée de démarrage de chaque unité'; Type = 'Table'; Icon = 'pulse'; Columns = @('Unité', 'Durée (s)'); Rows = @($blame | ForEach-Object { , @($_.Unit, [Math]::Round($_.Seconds, 3)) }) })
        $boot = Get-CurrentBoot
        if ($boot.Chain.Count) { $sections.Add([PSCustomObject]@{ Title = 'Chaîne critique'; Type = 'Table'; Icon = 'timer'; Columns = @('Unité', 'Prête à (s)', 'Durée (s)'); Rows = @($boot.Chain | ForEach-Object { , @($_.Unit, [Math]::Round($_.At, 3), [Math]::Round($_.Seconds, 3)) }) }) }
        $count = $blame.Count
    }
    else {
        $events = foreach ($e in Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 101..110 } -MaxEvents 300 -ErrorAction SilentlyContinue) {
            $x = [xml]$e.ToXml(); $v = @{}; foreach ($n in $x.Event.EventData.Data) { $v[$n.Name] = $n.'#text' }
            [PSCustomObject]@{ At = $e.TimeCreated; Name = $v.FriendlyName ?? $v.Name ?? $v.FileName; Kind = $e.Id; Seconds = [double]($v.TotalTime ?? 0) / 1000; Degradation = [double]($v.DegradationTime ?? 0) / 1000 }
        }
        $events = @($events | Where-Object Seconds -ge $MinSeconds | Sort-Object Seconds -Descending | Select-Object -First $Top)
        $sections.Add([PSCustomObject]@{ Title = 'Éléments qui ont ralenti les démarrages'; Type = 'Table'; Icon = 'pulse'; Columns = @('Date', 'Élément', 'Type', 'Durée (s)', 'Retard (s)')
                Rows = @($events | ForEach-Object { , @((Format-Date $_.At), $_.Name, @{ 101 = 'Application'; 102 = 'Pilote'; 103 = 'Service'; 106 = 'Tâche de fond'; 109 = 'Périphérique' }[$_.Kind] ?? "$($_.Kind)", [Math]::Round($_.Seconds, 2), [Math]::Round($_.Degradation, 2)) }) })
        $count = $events.Count
    }
    [PSCustomObject]@{ Subtitle = "$count élément(s)"; Sections = $sections.ToArray(); Findings = @() }
}

#endregion

Export-ModuleMember -Function Get-ModuleData, Get-SIBootHistory, Get-SIBootAnalysis
