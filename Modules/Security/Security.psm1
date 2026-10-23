# Module Sécurité : score, antivirus, pare-feu, chiffrement, protections de la plateforme, comptes et groupes
# privilégiés, sessions et échecs de connexion, politique de mots de passe, accès distant, protocoles obsolètes,
# persistance suspecte, certificats, autorisations, fichiers SUID.
#
# Sources
#   Windows : root/SecurityCenter2 (antivirus), Get-MpComputerStatus / Get-MpThreatDetection (Defender),
#             Get-NetFirewallProfile / Get-NetFirewallRule (pare-feu), Get-BitLockerVolume (admin) ou propriété
#             Shell System.Volume.BitLockerProtection (sans droits), Win32_DeviceGuard, registre (Secure Boot, LSA,
#             UAC, SmartScreen, RDP, SCHANNEL, LmCompatibilityLevel, Run, Winlogon, IFEO, AppInit_DLLs),
#             ADSI WinNT (comptes et groupes locaux), quser, net accounts, Get-SmbServerConfiguration,
#             Get-ScheduledTask, root/subscription (abonnements WMI), journal Security 4624 / 4625 (admin), Cert:\.
#   Linux   : clamscan / freshclam, firewall-cmd ou ufw, lsblk -J (LUKS), mokutil, getenforce, /sys/kernel/security,
#             getent passwd / group, lastlog2 ou lastlog, loginctl, last, journalctl (échecs sshd, PAM, sudo),
#             /etc/login.defs, pwquality.conf, faillock.conf, PAM, sshd_config (si lisible), ss, cron, systemd,
#             autostart, ld.so.preload, rpm -qf / dpkg -S (fichiers hors paquet), bundle des autorités, find, getfacl.
#
# Jamais exposé : clés BitLocker / de récupération, mots de passe, hashes (ni empreintes de certificats),
# contenu des fichiers utilisateurs. Tout est mis en cache : la posture de sécurité change peu.

$script:Fr = [cultureinfo]::GetCultureInfo('fr-FR')

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

function Format-Date($Date) { if ($Date) { ([datetime]$Date).ToString('dd/MM/yyyy HH:mm', $script:Fr) } else { $null } }

function New-Finding([string]$Severity, [string]$Code, [string]$Message, [string]$Recommendation) {
    [PSCustomObject]@{ Severity = $Severity; Code = $Code; Message = $Message; Recommendation = $Recommendation }
}

function Get-RegValue([string]$Path, [string]$Name) {
    (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue).$Name
}

function Read-Text([string]$Path) {
    try { [System.IO.File]::ReadAllLines($Path) } catch { $null }
}

function Test-Elevated {
    if ($IsWindows) { return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    [Environment]::IsPrivilegedProcess
}

function Yes([bool]$Value) { if ($Value) { 'Oui' } else { 'Non' } }

# Ordinateur portable (perte ou vol : le chiffrement compte davantage). Types SMBIOS de châssis portables.
function Test-Portable {
    $portable = 8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32
    $types = if ($IsWindows) { @((Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction SilentlyContinue).ChassisTypes) } else { @(Read-Text '/sys/class/dmi/id/chassis_type') }
    [bool]($types | Where-Object { [int]$_ -in $portable })
}

# Linux : paquet propriétaire de chaque fichier (rpm -qf ou dpkg -S, en un appel) ; $null = hors paquet.
function Get-PackageOwners([string[]]$Paths) {
    $map = @{}
    if ($Paths.Count -eq 0) { return $map }
    if (Get-Command rpm -ErrorAction SilentlyContinue) {
        # Une ligne « chemin<TAB>paquet » par fichier : rpm -qf en lot mélange stdout et stderr (fichiers hors paquet)
        # et écrit plusieurs lignes pour un fichier à plusieurs propriétaires.
        $script = 'for f; do printf "%s\t" "$f"; if o=$(rpm -qf --qf "%{NAME} " -- "$f" 2>/dev/null); then printf "%s" "$o"; else printf -- "-"; fi; echo; done'
        foreach ($line in & sh -c $script sh @Paths 2>$null) {
            $i = $line.LastIndexOf("`t")
            if ($i -lt 0) { continue }
            $owner = $line.Substring($i + 1).Trim()
            $map[$line.Substring(0, $i)] = if ($owner -and $owner -ne '-') { ($owner -split ' ')[0] } else { $null }
        }
    } elseif (Get-Command dpkg -ErrorAction SilentlyContinue) {
        foreach ($p in $Paths) { $map[$p] = $null }
        foreach ($line in & dpkg -S -- @Paths 2>$null) {
            if ($line -match '^([^:]+(?::[^:\s]+)?): (.+)$') { $map[$Matches[2]] = $Matches[1] }
        }
    }
    $map
}

#endregion

#region Antivirus

# Antivirus déclarés au Centre de sécurité (postes de travail ; absent sous Windows Server).
# productState : 2e octet = activé (0x10 / 0x11), 3e octet = signatures à jour (0x00).
function Get-AntivirusProducts {
    @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue) | ForEach-Object {
        $hex = '{0:X6}' -f [int]$_.productState
        [PSCustomObject]@{ Name = $_.displayName; Enabled = $hex.Substring(2, 2) -in '10', '11'; UpToDate = $hex.Substring(4, 2) -eq '00'; Path = $_.pathToSignedProductExe }
    }
}

function Get-AntivirusState {
    if ($IsWindows) {
        $products = @(Get-AntivirusProducts)
        $defender = if (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue) { try { Get-MpComputerStatus -ErrorAction Stop } catch { $null } } else { $null }
        $threats = @()
        if ($defender -and (Get-Command Get-MpThreatDetection -ErrorAction SilentlyContinue)) {
            $threats = @(try { Get-MpThreatDetection -ErrorAction Stop | Where-Object { $_.InitialDetectionTime -gt (Get-Date).AddDays(-30) } } catch { @() })
        }
        return [PSCustomObject]@{ Products = $products; Defender = $defender; Threats = $threats; Clam = $null }
    }
    # Linux : ClamAV si présent (base de signatures, démon clamd, mise à jour freshclam).
    $clam = $null
    if (Get-Command clamscan, clamdscan -ErrorAction SilentlyContinue) {
        $version = (& (Get-Command clamscan, clamdscan | Select-Object -First 1).Source --version 2>$null | Select-Object -First 1)
        $db = Get-ChildItem -Path /var/lib/clamav, /var/clamav -Include *.cvd, *.cld -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $daemon = foreach ($u in 'clamd@scan', 'clamav-daemon', 'clamd') { if ((& systemctl is-active "$u.service" 2>$null) -eq 'active') { $u; break } }
        $fresh = foreach ($u in 'clamav-freshclam', 'freshclam') { if ((& systemctl is-active "$u.service" 2>$null) -eq 'active') { $u; break } }
        $clam = [PSCustomObject]@{ Version = $version; Database = $db.LastWriteTime; Daemon = $daemon; Freshclam = $fresh }
    }
    [PSCustomObject]@{ Products = @(); Defender = $null; Threats = @(); Clam = $clam }
}

#endregion

#region Pare-feu

# Linux : firewalld (zones actives, services, ports ; un seul appel, firewall-cmd coûte ~0,4 s), sinon ufw
# (statut détaillé en root ; ufw.conf sinon), sinon nftables.
function Get-LinuxFirewall {
    $out = if (Get-Command firewall-cmd -ErrorAction SilentlyContinue) { @(& firewall-cmd --list-all-zones 2>$null) } else { @() }
    if ($LASTEXITCODE -eq 0 -and $out.Count -gt 0) {
        $zones = [System.Collections.Generic.List[object]]::new()
        $current = $null
        foreach ($line in $out) {
            if ($line -match '^(\S+)\s*(\(([^)]*)\))?\s*$') {
                $flags = $Matches[3] -split ',\s*'
                $current = if ('active' -in $flags) { [PSCustomObject]@{ Name = $Matches[1]; Default = 'default' -in $flags; Props = @{} } } else { $null }
                if ($current) { $zones.Add($current) }
            } elseif ($current -and $line -match '^\s+([\w -]+):\s*(.*)$') { $current.Props[$Matches[1].Trim()] = $Matches[2].Trim() }
        }
        $list = foreach ($z in $zones) {
            [PSCustomObject]@{ Name = $z.Name; Default = $z.Default; Interfaces = $z.Props.interfaces; Sources = $z.Props.sources; Target = $z.Props.target; Services = $z.Props.services; Ports = $z.Props.ports; Rich = $z.Props.'rich rules' }
        }
        return [PSCustomObject]@{ Tool = 'firewalld'; Active = $true; Zones = @($list); Note = $null }
    }
    if (Get-Command ufw -ErrorAction SilentlyContinue) {
        $out = @(& ufw status verbose 2>$null)
        if ($out -and "$($out[0])" -match 'Status:\s*(\w+)') { return [PSCustomObject]@{ Tool = 'ufw'; Active = $Matches[1] -eq 'active'; Zones = @(); Note = ($out -join "`n") } }
        $enabled = (Read-Text '/etc/ufw/ufw.conf') -match '^ENABLED=yes'
        return [PSCustomObject]@{ Tool = 'ufw'; Active = [bool]$enabled -and (& systemctl is-active ufw 2>$null) -eq 'active'; Zones = @(); Note = 'Règles lisibles en root seulement' }
    }
    if ((& systemctl is-active nftables 2>$null) -eq 'active') {
        return [PSCustomObject]@{ Tool = 'nftables'; Active = $true; Zones = @(); Note = 'Règles lisibles en root seulement (nft list ruleset)' }
    }
    [PSCustomObject]@{ Tool = $null; Active = $false; Zones = @(); Note = $null }
}

# Plus grande plage de ports ouverte dans une liste firewalld (« 1025-65535/tcp 8080/tcp »).
function Get-WidestRange([string]$Ports) {
    $max = 0
    foreach ($p in ($Ports -split '\s+')) { if ($p -match '^(\d+)-(\d+)/') { $max = [Math]::Max($max, [int]$Matches[2] - [int]$Matches[1] + 1) } }
    $max
}

#endregion

#region Chiffrement

# Linux : chaque point de montage (hors /boot, boucles) et s'il repose sur un volume LUKS / dm-crypt.
function Get-LinuxEncryption {
    $json = (& lsblk -J -o NAME,TYPE,FSTYPE,FSVER,MOUNTPOINTS,SIZE 2>$null) -join ''
    if (-not $json) { throw 'lsblk indisponible' }
    $list = [System.Collections.Generic.List[object]]::new()
    $walk = {
        param($Node, $Crypt)
        if ($Node.fstype -eq 'crypto_LUKS') { $Crypt = 'LUKS' + $(if ($Node.fsver) { " $($Node.fsver)" } else { '' }) }
        elseif ($Node.type -eq 'crypt' -and -not $Crypt) { $Crypt = 'dm-crypt' }
        foreach ($mp in @($Node.mountpoints) | Where-Object { $_ }) {
            if ($Node.type -eq 'loop' -or $Node.name -like 'zram*' -or $mp -like '/boot*' -or $mp -like '/var/lib/snapd/*') { continue }
            $list.Add([PSCustomObject]@{ Mount = $mp; FileSystem = $Node.fstype; Device = $Node.name; Size = $Node.size; Encryption = $Crypt })
        }
        foreach ($child in @($Node.children) | Where-Object { $_ }) { & $walk $child $Crypt }
    }
    foreach ($d in ($json | ConvertFrom-Json).blockdevices) { & $walk $d $null }
    # Un même système de fichiers Btrfs monté plusieurs fois (/, /home) : une ligne par point de montage.
    $list | Sort-Object Mount -Unique
}

# Windows : état BitLocker des volumes fixes. Get-BitLockerVolume (admin) donne méthode, avancement et types de
# protecteurs ; sans droits, la propriété Shell System.Volume.BitLockerProtection donne l'état seul.
# Jamais de mot de passe de récupération : seuls les types de protecteurs sont lus.
function Get-WindowsEncryption {
    $drives = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)
    if ((Test-Elevated) -and (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue)) {
        return @(Get-BitLockerVolume -ErrorAction Stop | Where-Object VolumeType -ne 'Removable' | ForEach-Object {
                $on = "$($_.ProtectionStatus)" -eq 'On'
                [PSCustomObject]@{
                    Mount = $_.MountPoint; FileSystem = ($drives | Where-Object DeviceID -eq $_.MountPoint).FileSystem; Device = "$($_.VolumeType)"
                    Size = '{0} GiB' -f [Math]::Round($_.CapacityGB, 0)
                    Encryption = if ("$($_.VolumeStatus)" -eq 'FullyDecrypted') { $null } else { 'BitLocker ' + $(if ($on) { 'actif' } else { 'suspendu' }) + " · $($_.EncryptionMethod) · $($_.EncryptionPercentage) %" }
                    Protectors = (@($_.KeyProtector.KeyProtectorType) | ForEach-Object { "$_" } | Select-Object -Unique) -join ', '
                    Suspended = -not $on -and "$($_.VolumeStatus)" -ne 'FullyDecrypted'
                }
            })
    }
    $states = @{ 1 = 'BitLocker actif'; 3 = 'BitLocker (chiffrement en cours)'; 4 = 'BitLocker (déchiffrement en cours)'; 5 = 'BitLocker suspendu'; 6 = 'BitLocker actif (verrouillé)' }
    $shell = New-Object -ComObject Shell.Application
    foreach ($d in $drives) {
        $value = try { $shell.NameSpace("$($d.DeviceID)\").Self.ExtendedProperty('System.Volume.BitLockerProtection') } catch { $null }
        [PSCustomObject]@{
            Mount = $d.DeviceID; FileSystem = $d.FileSystem; Device = $d.VolumeName; Size = '{0} GiB' -f [Math]::Round($d.Size / 1GB, 0)
            Encryption = if ($value) { $states[[int]$value] } else { $null }
            Protectors = 'administrateur requis'; Suspended = [int]$value -eq 5
        }
    }
}

#endregion

#region Plateforme

function Get-PlatformProtections {
    $items = [ordered]@{}
    $issues = [System.Collections.Generic.List[object]]::new()
    if ($IsWindows) {
        $sb = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -ErrorAction SilentlyContinue
        $items['Secure Boot'] = if (-not $sb) { 'Non pris en charge (démarrage BIOS)' } elseif ($sb.UEFISecureBootEnabled -eq 1) { 'Activé' } else { 'Désactivé' }
        if ($sb -and $sb.UEFISecureBootEnabled -ne 1) { $issues.Add(@('warning', 'SEC-SECUREBOOT-OFF', 'Secure Boot est désactivé', 'L''activer dans le firmware (UEFI) : il empêche le chargement de chargeurs de démarrage et pilotes non signés (bootkits).')) }

        $dg = Get-CimInstance -Namespace root/Microsoft/Windows/DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction SilentlyContinue
        if ($dg) {
            $items['Sécurité basée sur la virtualisation'] = @{ 0 = 'Désactivée'; 1 = 'Activée (pas en cours d''exécution)'; 2 = 'En cours d''exécution' }[[int]$dg.VirtualizationBasedSecurityStatus]
            $running = @($dg.SecurityServicesRunning)
            $items['Intégrité de la mémoire (HVCI)'] = Yes (2 -in $running)
            $items['Credential Guard'] = Yes (1 -in $running)
            if ([int]$dg.VirtualizationBasedSecurityStatus -ne 2) { $issues.Add(@('info', 'SEC-VBS-OFF', 'La sécurité basée sur la virtualisation (VBS) ne fonctionne pas', 'Activer l''intégrité de la mémoire (Sécurité Windows › Sécurité des appareils › Isolation du noyau) si le matériel et les pilotes le permettent.')) }
        }
        $ppl = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'RunAsPPL'
        $items['Protection LSA'] = if ($ppl -in 1, 2) { 'Activée' } else { 'Désactivée' }
        if ($ppl -notin 1, 2) { $issues.Add(@('info', 'SEC-LSA-UNPROTECTED', 'La protection LSA (RunAsPPL) est désactivée', 'L''activer (Isolation du noyau › Protection de l''autorité de sécurité locale) : elle protège les identifiants en mémoire contre les outils de vol de mots de passe.')) }

        $policy = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
        $lua = Get-RegValue $policy 'EnableLUA'
        $consent = Get-RegValue $policy 'ConsentPromptBehaviorAdmin'
        $items['Contrôle de compte (UAC)'] = if ($lua -eq 0) { 'Désactivé' } else {
            @{ 0 = 'Élévation sans demande'; 1 = 'Identifiants (bureau sécurisé)'; 2 = 'Toujours avertir'; 3 = 'Identifiants'; 4 = 'Consentement'; 5 = 'Par défaut (programmes non Windows)' }[[int]($consent ?? 5)]
        }
        if ($lua -eq 0) { $issues.Add(@('critical', 'SEC-UAC-OFF', 'Le contrôle de compte d''utilisateur (UAC) est désactivé : tout programme lancé par un administrateur a tous les droits', 'Réactiver l''UAC (EnableLUA = 1) puis redémarrer.')) }
        elseif ($consent -eq 0) { $issues.Add(@('warning', 'SEC-UAC-LOW', 'L''UAC élève les administrateurs sans rien demander', 'Régler l''UAC au niveau par défaut (Panneau de configuration › Comptes d''utilisateurs).')) }

        $ss = Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen'
        $ssUser = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'SmartScreenEnabled'
        $smartOff = $ss -eq 0 -or $ssUser -eq 'Off'
        $items['SmartScreen'] = if ($smartOff) { 'Désactivé' } else { 'Activé' }
        if ($smartOff) { $issues.Add(@('warning', 'SEC-SMARTSCREEN-OFF', 'SmartScreen est désactivé (applications et fichiers téléchargés non vérifiés)', 'Le réactiver dans Sécurité Windows › Contrôle des applications et du navigateur.')) }

        # Stratégie d'exécution : la portée Process est forcée à Bypass par SysInfo, elle n'est pas montrée.
        $exec = @(Get-ExecutionPolicy -List | Where-Object { $_.Scope -ne 'Process' -and "$($_.ExecutionPolicy)" -ne 'Undefined' })
        $items['Stratégie d''exécution PowerShell'] = if ($exec) { ($exec | ForEach-Object { "$($_.Scope) : $($_.ExecutionPolicy)" }) -join ' · ' } else { 'Par défaut (Restricted / RemoteSigned)' }
        if ($exec | Where-Object { "$($_.ExecutionPolicy)" -in 'Unrestricted', 'Bypass' }) {
            $issues.Add(@('info', 'SEC-EXECPOLICY-OPEN', 'La stratégie d''exécution PowerShell autorise tous les scripts (Unrestricted ou Bypass)', 'Revenir à RemoteSigned : Set-ExecutionPolicy RemoteSigned -Scope LocalMachine.'))
        }
        return [PSCustomObject]@{ Items = $items; Issues = $issues.ToArray() }
    }

    # Linux
    $sb = if (Get-Command mokutil -ErrorAction SilentlyContinue) { "$(& mokutil --sb-state 2>&1 | Select-Object -First 1)" } else { $null }
    $efi = Test-Path /sys/firmware/efi
    $items['Secure Boot'] = if (-not $efi) { 'Non pris en charge (démarrage BIOS)' } elseif ($sb -match 'enabled') { 'Activé' } elseif ($sb -match 'disabled') { 'Désactivé' } else { 'Inconnu' }
    if ($efi -and $sb -match 'disabled') { $issues.Add(@('warning', 'SEC-SECUREBOOT-OFF', 'Secure Boot est désactivé', 'L''activer dans le firmware (UEFI) ; les pilotes hors noyau (NVIDIA, VirtualBox) doivent alors être signés avec une clé MOK enregistrée.')) }

    $lockdown = Read-Text '/sys/kernel/security/lockdown'
    if ($lockdown -and "$lockdown" -match '\[(\w+)\]') { $items['Verrouillage du noyau'] = @{ none = 'Aucun'; integrity = 'Intégrité'; confidentiality = 'Confidentialité' }[$Matches[1]] ?? $Matches[1] }

    $mac = $false
    if (Get-Command getenforce -ErrorAction SilentlyContinue) {
        $mode = "$(& getenforce 2>$null)".Trim()
        $items['SELinux'] = @{ Enforcing = 'Appliqué'; Permissive = 'Permissif (journalise sans bloquer)'; Disabled = 'Désactivé' }[$mode] ?? $mode
        $mac = $mode -eq 'Enforcing'
        if ($mode -in 'Permissive', 'Disabled') { $issues.Add(@('warning', 'SEC-MAC-OFF', "SELinux est $($items['SELinux'].ToLower())", 'Le remettre en mode Enforcing (/etc/selinux/config), après avoir corrigé les refus listés par ausearch -m avc.')) }
    }
    if ("$(Read-Text '/sys/module/apparmor/parameters/enabled')" -eq 'Y') {
        $profiles = Read-Text '/sys/kernel/security/apparmor/profiles'
        $items['AppArmor'] = if ($profiles) { 'Activé · {0} profils ({1} en mode enforce)' -f $profiles.Count, @($profiles -match '\(enforce\)').Count } else { 'Activé (profils lisibles en root)' }
        $mac = $true
    }
    if (-not $mac -and -not $items.Contains('SELinux')) { $issues.Add(@('info', 'SEC-MAC-OFF', 'Aucun contrôle d''accès obligatoire (SELinux ou AppArmor) n''est actif', 'Activer AppArmor ou SELinux selon la distribution : ils limitent ce qu''un service compromis peut faire.')) }
    [PSCustomObject]@{ Items = $items; Issues = $issues.ToArray() }
}

#endregion

#region Comptes, groupes, sessions

# Windows : comptes et groupes locaux via ADSI (WinNT://), le module LocalAccounts n'étant pas chargé par
# PowerShell 7. UserFlags : 0x2 désactivé, 0x20 mot de passe non requis, 0x10000 n'expire jamais.
function Get-AdsiProperty($Object, [string]$Name) {
    try { $Object.GetType().InvokeMember($Name, 'GetProperty', $null, $Object, $null) } catch { $null }
}

function Get-GroupName([string]$Sid) {
    try { (([Security.Principal.SecurityIdentifier]$Sid).Translate([Security.Principal.NTAccount]).Value -split '\\')[-1] } catch { $null }
}

function Get-WindowsGroupMembers([string]$Sid) {
    $name = Get-GroupName $Sid
    if (-not $name) { return @() }
    $group = [ADSI]"WinNT://./$name,group"
    foreach ($m in @($group.Invoke('Members'))) {
        $path = Get-AdsiProperty $m 'ADsPath'
        # WinNT://DOMAINE/nom ou WinNT://DOMAINE/MACHINE/nom
        (($path -replace '^WinNT://', '') -split '/' | Select-Object -Last 2) -join '\'
    }
}

$script:PrivilegedGroups = [ordered]@{
    'S-1-5-32-544' = 'administrateurs'; 'S-1-5-32-555' = 'accès Bureau à distance'; 'S-1-5-32-580' = 'gestion à distance (WinRM)'
    'S-1-5-32-551' = 'lecture de tous les fichiers (sauvegarde)'; 'S-1-5-32-578' = 'administration Hyper-V'
}
# Linux : groupes qui donnent des droits root ou presque.
$script:LinuxPrivileged = [ordered]@{
    wheel = 'administrateurs (sudo)'; sudo = 'administrateurs (sudo)'; admin = 'administrateurs (sudo)'; root = 'groupe root'
    docker = 'équivalent root (conteneurs privilégiés)'; lxd = 'équivalent root (conteneurs)'; libvirt = 'machines virtuelles (quasi root)'
    disk = 'accès brut aux disques'; adm = 'lecture des journaux'; shadow = 'lecture des empreintes de mots de passe'
}

function Get-Accounts {
    if ($IsWindows) {
        $computer = [ADSI]"WinNT://$env:COMPUTERNAME,computer"
        $admins = @(Get-WindowsGroupMembers 'S-1-5-32-544' | ForEach-Object { ($_ -split '\\')[-1] })
        $users = foreach ($u in @($computer.Children | Where-Object { $_.SchemaClassName -eq 'User' })) {
            $flags = [int]$u.UserFlags.Value
            $sid = try { (New-Object Security.Principal.SecurityIdentifier($u.objectSid.Value, 0)).Value } catch { $null }
            $last = try { [datetime]$u.LastLogin.Value } catch { $null }
            [PSCustomObject]@{
                Name = "$($u.Name)"; Id = $sid; FullName = "$($u.FullName)"; Enabled = -not ($flags -band 0x2)
                Admin = "$($u.Name)" -in $admins; LastLogon = $last
                PasswordAge = if ($u.PasswordAge.Value) { [int]([int]$u.PasswordAge.Value / 86400) } else { $null }
                NeverExpires = [bool]($flags -band 0x10000); NotRequired = [bool]($flags -band 0x20)
                Shell = $null; Builtin = $sid -match '-(500|501|503|504)$'; Guest = $sid -match '-501$'
            }
        }
        $groups = foreach ($sid in $script:PrivilegedGroups.Keys) {
            $members = @(try { Get-WindowsGroupMembers $sid } catch { @() })
            if ($members) { [PSCustomObject]@{ Group = Get-GroupName $sid; Role = $script:PrivilegedGroups[$sid]; Members = $members } }
        }
        return [PSCustomObject]@{ Users = @($users); Groups = @($groups) }
    }

    $uidMin = 1000
    $def = Read-Text '/etc/login.defs' | Where-Object { $_ -match '^\s*UID_MIN\s+(\d+)' } | Select-Object -First 1
    if ($def -match '(\d+)') { $uidMin = [int]$Matches[1] }
    $groupLines = @(& getent group 2>$null)
    $memberOf = @{}
    $groups = foreach ($line in $groupLines) {
        $f = $line -split ':'
        foreach ($m in ($f[3] -split ',' | Where-Object { $_ })) { $memberOf[$m] = @($memberOf[$m]) + $f[0] }
        if ($script:LinuxPrivileged.Contains($f[0]) -and $f[3]) { [PSCustomObject]@{ Group = $f[0]; Role = $script:LinuxPrivileged[$f[0]]; Members = @($f[3] -split ',' | Where-Object { $_ }) } }
    }
    # Dernière connexion : lastlog2 (base SQLite, récent) ou lastlog (fichier historique).
    $last = @{}
    $tool = if (Get-Command lastlog2 -ErrorAction SilentlyContinue) { 'lastlog2' } elseif (Get-Command lastlog -ErrorAction SilentlyContinue) { 'lastlog' } else { $null }
    if ($tool) {
        foreach ($line in & $tool 2>$null | Select-Object -Skip 1) {
            if ($line -match '^(\S+)\s.*?(\w{3} \w{3} +\d+ \d\d:\d\d:\d\d [+-]\d{4} \d{4})\s*$') {
                $last[$Matches[1]] = try { [datetime]::ParseExact(($Matches[2] -replace '\s+', ' '), 'ddd MMM d HH:mm:ss zzz yyyy', [cultureinfo]::InvariantCulture) } catch { $null }
            }
        }
    }
    $me = [Environment]::UserName
    $users = foreach ($line in & getent passwd 2>$null) {
        $f = $line -split ':'
        $uid = [int]$f[2]
        if (($uid -lt $uidMin -or $uid -ge 60000) -and $uid -ne 0) { continue }
        $groupsOf = @($memberOf[$f[0]])
        $shell = $f[6]
        # Expiration du mot de passe : chage -l n'est lisible que pour son propre compte (ou en root).
        $expires = $null
        if ($f[0] -eq $me -or [Environment]::IsPrivilegedProcess) {
            $chage = & env LC_ALL=C chage -l $f[0] 2>$null | Where-Object { $_ -match '^Password expires' }
            if ($chage -match ':\s*(.+)$') { $expires = $Matches[1].Trim() }
        }
        [PSCustomObject]@{
            Name = $f[0]; Id = $uid; FullName = ($f[4] -split ',')[0]; Enabled = $shell -notmatch '(nologin|false)$'
            Admin = $uid -eq 0 -or [bool]($groupsOf | Where-Object { $_ -in 'wheel', 'sudo', 'admin' }); LastLogon = $last[$f[0]]
            PasswordAge = $null; NeverExpires = $expires -eq 'never'; NotRequired = $false; Shell = $shell; Builtin = $uid -eq 0; Guest = $false
            Groups = $groupsOf
        }
    }
    [PSCustomObject]@{ Users = @($users); Groups = @($groups) }
}

# Sessions ouvertes. Windows : quser (absent des éditions Famille : utilisateur de la console via CIM).
# Linux : loginctl (sessions utilisateur, distantes ou non).
function Get-Sessions {
    if ($IsWindows) {
        $out = @(try { & quser 2>$null } catch { @() })
        if ($out.Count -gt 1) {
            return @($out | Select-Object -Skip 1 | ForEach-Object {
                    if ($_ -match '^\s*>?(\S+)\s+(\S+)?\s+(\d+)\s+(\S+)\s+(\S+)\s+(.+)$') {
                        [PSCustomObject]@{ User = $Matches[1]; Where = $Matches[2]; State = $Matches[4]; Since = $Matches[6].Trim(); Remote = $Matches[2] -like 'rdp-*'; Host = $null }
                    }
                })
        }
        $console = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName
        return @(if ($console) { [PSCustomObject]@{ User = $console; Where = 'console'; State = 'Active'; Since = $null; Remote = $false; Host = $null } })
    }
    $ids = @(& loginctl list-sessions --no-legend 2>$null | ForEach-Object { ($_.Trim() -split '\s+')[0] } | Where-Object { $_ })
    if ($ids.Count -eq 0) { return @() }
    $sessions = [System.Collections.Generic.List[object]]::new()
    $s = @{}
    foreach ($line in (& loginctl show-session @ids -p Id -p Name -p Remote -p RemoteHost -p Service -p Type -p Class -p TTY -p Timestamp -p State 2>$null) + '') {
        if (-not $line) {
            if ($s.Id -and $s.Class -eq 'user') {
                $sessions.Add([PSCustomObject]@{
                        User = $s.Name; Where = (@($s.TTY, $s.Type, $s.Service) | Where-Object { $_ -and $_ -ne 'unspecified' }) -join ' · '
                        State = $s.State; Since = $(if ($s.Timestamp -match '(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)') { Format-Date ([datetime]$Matches[1]) } else { $s.Timestamp }); Remote = $s.Remote -eq 'yes'; Host = $s.RemoteHost
                    })
            }
            $s = @{}; continue
        }
        $i = $line.IndexOf('='); if ($i -gt 0) { $s[$line.Substring(0, $i)] = $line.Substring($i + 1) }
    }
    $sessions.ToArray()
}

# Échecs de connexion. Linux : journal (sshd, PAM, sudo), lisible par les groupes wheel / adm / systemd-journal.
# Windows : journal Security 4625 (administrateur requis).
function Get-LogonFailures([int]$Hours, [int]$Max = 2000) {
    if ($IsWindows) {
        $events = Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4625; StartTime = (Get-Date).AddHours(-$Hours) } -MaxEvents $Max -ErrorAction Stop
        return @($events | ForEach-Object {
                $p = $_.Properties
                [PSCustomObject]@{ Time = $_.TimeCreated; User = "$($p[5].Value)"; Source = "$($p[19].Value)" -replace '^-$', ''; Kind = Get-LogonTypeName ([int]$p[10].Value); Detail = '0x{0:X}' -f [int]$p[9].Value }
            })
    }
    # Facilités auth (4) et authpriv (10) : champ indexé, ~100 fois plus rapide qu'un -g sur tout le journal.
    $lines = & journalctl -S "-${Hours}h" SYSLOG_FACILITY=4 SYSLOG_FACILITY=10 -g 'Failed password|Invalid user|authentication failure|incorrect password attempt' -o json --output-fields=MESSAGE,SYSLOG_IDENTIFIER,__REALTIME_TIMESTAMP -q --no-pager -n $Max 2>$null
    if (-not $lines) { return @() }
    foreach ($e in ('[' + (@($lines) -join ',') + ']') | ConvertFrom-Json) {
        $m = if ($e.MESSAGE -is [array]) { [System.Text.Encoding]::UTF8.GetString([byte[]]$e.MESSAGE) } else { [string]$e.MESSAGE }
        $time = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$e.__REALTIME_TIMESTAMP / 1000).LocalDateTime
        $id = [string]$e.SYSLOG_IDENTIFIER
        if ($m -match 'Failed password for (?:invalid user )?(\S+) from (\S+)') { [PSCustomObject]@{ Time = $time; User = $Matches[1]; Source = $Matches[2]; Kind = 'SSH'; Detail = 'mot de passe refusé' } }
        elseif ($m -match '^Invalid user (\S*) from (\S+)') { [PSCustomObject]@{ Time = $time; User = $Matches[1]; Source = $Matches[2]; Kind = 'SSH'; Detail = 'compte inexistant' } }
        elseif ($m -match 'pam_unix\(([^:]+):auth\): authentication failure') {
            $service = $Matches[1]
            $user = if ($m -match '\buser=(\S+)') { $Matches[1] } elseif ($m -match '\bruser=(\S+)') { $Matches[1] } else { '' }
            $rhost = if ($m -match '\brhost=(\S+)') { $Matches[1] } else { '' }
            # sshd journalise aussi « Failed password » : la ligne PAM correspondante ferait doublon.
            if ($id -eq 'sshd' -or $service -eq 'sshd') { continue }
            $kind = @{ kde = 'Écran de verrouillage'; 'kscreensaver' = 'Écran de verrouillage'; 'gdm-password' = 'Ouverture de session'; sddm = 'Ouverture de session'; plasmalogin = 'Ouverture de session'; login = 'Console'; su = 'su'; 'su-l' = 'su'; sudo = 'sudo'; 'polkit-1' = 'Élévation (polkit)' }[$service] ?? $service
            [PSCustomObject]@{ Time = $time; User = $user; Source = $rhost; Kind = $kind; Detail = 'mot de passe refusé' }
        }
        elseif ($m -match 'incorrect password attempts?') { [PSCustomObject]@{ Time = $time; User = (($m -split '\s+:')[0]).Trim(); Source = ''; Kind = 'sudo'; Detail = ($m -split ';')[0] } }
    }
}

function Get-LogonTypeName([int]$Type) {
    @{ 2 = 'Locale'; 3 = 'Réseau'; 4 = 'Tâche'; 5 = 'Service'; 7 = 'Déverrouillage'; 8 = 'Réseau (texte clair)'; 9 = 'Identifiants explicites'; 10 = 'Bureau à distance'; 11 = 'Locale (en cache)' }[$Type] ?? "Type $Type"
}

#endregion

#region Politique, accès distant, protocoles

# Windows : net accounts. Les libellés sont traduits mais l'ordre des lignes est fixe ; une valeur non numérique
# (Jamais, Aucun, Never…) vaut $null.
function Get-PasswordPolicy {
    $policy = [ordered]@{}
    if ($IsWindows) {
        $values = @(& net accounts 2>$null | Where-Object { $_ -match ':' } | ForEach-Object { $v = ($_ -split ':')[-1].Trim(); if ($v -match '^\d+$') { [int]$v } else { $null } })
        if ($values.Count -lt 8) { throw 'net accounts illisible' }
        return [PSCustomObject]@{ MinLength = $values[3]; MaxAgeDays = $values[2]; History = $values[4]; LockoutThreshold = $values[5]; LockoutMinutes = $values[6]; Source = 'net accounts' }
    }
    $defs = @{}
    foreach ($line in Read-Text '/etc/login.defs') { if ($line -match '^\s*(PASS_\w+)\s+(\S+)') { $defs[$Matches[1]] = $Matches[2] } }
    $minLen = 8   # pwquality : minlen = 8 par défaut (PASS_MIN_LEN de login.defs est ignoré par PAM)
    foreach ($line in @(Read-Text '/etc/security/pwquality.conf') + @(Get-ChildItem /etc/security/pwquality.conf.d -Filter *.conf -ErrorAction SilentlyContinue | ForEach-Object { Read-Text $_.FullName })) {
        if ($line -match '^\s*minlen\s*=\s*(\d+)') { $minLen = [int]$Matches[1] }
    }
    $pam = @(Read-Text '/etc/pam.d/system-auth') + @(Read-Text '/etc/pam.d/common-auth')
    $faillock = [bool]($pam -match '^\s*auth\s+.*pam_(faillock|tally2)\.so')
    $deny = 3; $unlock = 600
    foreach ($line in Read-Text '/etc/security/faillock.conf') {
        if ($line -match '^\s*deny\s*=\s*(\d+)') { $deny = [int]$Matches[1] }
        if ($line -match '^\s*unlock_time\s*=\s*(\d+)') { $unlock = [int]$Matches[1] }
    }
    $maxAge = if ($defs.PASS_MAX_DAYS -match '^\d+$' -and [int]$defs.PASS_MAX_DAYS -lt 99999) { [int]$defs.PASS_MAX_DAYS } else { $null }
    [PSCustomObject]@{
        MinLength = $minLen; MaxAgeDays = $maxAge; History = $null
        LockoutThreshold = if ($faillock) { $deny } else { $null }; LockoutMinutes = if ($faillock) { [int]($unlock / 60) } else { $null }
        Source = 'pwquality, login.defs, faillock'
    }
}

# Accès distant : liste de [Nom, État, Détail] et constats.
function Get-RemoteAccess {
    $rows = [System.Collections.Generic.List[object]]::new()
    $issues = [System.Collections.Generic.List[object]]::new()
    if ($IsWindows) {
        $ts = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
        $rdpOn = (Get-RegValue $ts 'fDenyTSConnections') -eq 0
        $nla = (Get-RegValue "$ts\WinStations\RDP-Tcp" 'UserAuthentication') -eq 1
        $port = Get-RegValue "$ts\WinStations\RDP-Tcp" 'PortNumber'
        $rows.Add(@('Bureau à distance (RDP)', $(if ($rdpOn) { 'Activé' } else { 'Désactivé' }), $(if ($rdpOn) { "port $port · NLA $(if ($nla) { 'exigée' } else { 'non exigée' })" } else { '' })))
        if ($rdpOn -and -not $nla) { $issues.Add(@('warning', 'SEC-RDP-NO-NLA', 'Le Bureau à distance est ouvert sans authentification au niveau du réseau (NLA)', 'Exiger la NLA (Paramètres › Bureau à distance › Paramètres avancés) : sans elle, l''écran de connexion est exposé avant toute authentification.')) }
        elseif ($rdpOn) { $issues.Add(@('info', 'SEC-RDP-ON', "Le Bureau à distance est activé (port $port)", 'Le désactiver s''il ne sert pas ; sinon, ne pas l''exposer directement sur Internet (VPN).')) }
        foreach ($svc in @(@('WinRM', 'Gestion à distance (WinRM)'), @('sshd', 'Serveur SSH (OpenSSH)'))) {
            $s = Get-Service -Name $svc[0] -ErrorAction SilentlyContinue
            if ($s) { $rows.Add(@($svc[1], $(if ($s.Status -eq 'Running') { 'En cours' } else { 'Arrêté' }), "démarrage $($s.StartType)")) }
        }
        return [PSCustomObject]@{ Rows = $rows.ToArray(); Issues = $issues.ToArray() }
    }

    $unit = foreach ($u in 'sshd', 'ssh') { if ((& systemctl is-active "$u.service" 2>$null) -eq 'active') { $u; break } }
    $socket = (& systemctl is-active sshd.socket ssh.socket 2>$null) -contains 'active'
    $active = [bool]$unit -or $socket
    $listen = @(& ss -Hltnp 2>$null | Where-Object { $_ -match 'sshd' -or $_ -match ':22\s' } | ForEach-Object { ($_ -split '\s+')[3] }) | Select-Object -Unique
    # sshd -T donne la configuration effective (root) ; sinon sshd_config s'il est lisible (première valeur gagne).
    $config = @{}
    $lines = if ([Environment]::IsPrivilegedProcess -and (Get-Command sshd -ErrorAction SilentlyContinue)) { & sshd -T 2>$null } else {
        @(Read-Text '/etc/ssh/sshd_config') + @(Get-ChildItem /etc/ssh/sshd_config.d -Filter *.conf -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { Read-Text $_.FullName })
    }
    foreach ($line in $lines) { if ($line -match '^\s*(\w+)\s+(.+?)\s*$' -and -not $config.ContainsKey($Matches[1].ToLower())) { $config[$Matches[1].ToLower()] = $Matches[2] } }
    $readable = $config.Count -gt 0
    $detail = if (-not $active) { '' } elseif (-not $readable) { 'configuration lisible en root seulement' } else {
        'connexion root : {0} · mot de passe : {1}' -f ($config.permitrootlogin ?? 'prohibit-password (défaut)'), ($config.passwordauthentication ?? 'yes (défaut)')
    }
    if ($listen) { $detail = (@("écoute $($listen -join ', ')", $detail) | Where-Object { $_ }) -join ' · ' }
    $rows.Add(@('Serveur SSH', $(if ($active) { 'En cours' } elseif (Get-Command sshd -ErrorAction SilentlyContinue) { 'Installé, arrêté' } else { 'Non installé' }), $detail))
    if ($active -and $readable) {
        if ($config.permitrootlogin -eq 'yes') { $issues.Add(@('warning', 'SEC-SSH-ROOT-LOGIN', 'Le serveur SSH accepte la connexion directe de root par mot de passe', 'Mettre PermitRootLogin no (ou prohibit-password) dans /etc/ssh/sshd_config et se connecter avec un compte nominatif.')) }
        if (($config.passwordauthentication ?? 'yes') -eq 'yes') { $issues.Add(@('info', 'SEC-SSH-PASSWORD-AUTH', 'Le serveur SSH accepte l''authentification par mot de passe', 'Passer aux clés SSH (PasswordAuthentication no), surtout si le port est joignable depuis Internet.')) }
    }
    foreach ($svc in @(@('xrdp', 'Bureau à distance (xrdp)'), @('vncserver@', 'Serveur VNC'), @('smb', 'Partage de fichiers (Samba)'), @('smbd', 'Partage de fichiers (Samba)'), @('cockpit.socket', 'Administration web (Cockpit)'))) {
        $name = if ($svc[0] -match '\.') { $svc[0] } else { "$($svc[0]).service" }
        if ((& systemctl is-active $name 2>$null) -eq 'active') { $rows.Add(@($svc[1], 'En cours', $name)) }
    }
    [PSCustomObject]@{ Rows = $rows.ToArray(); Issues = $issues.ToArray() }
}

# Windows : SMBv1, TLS 1.0 / 1.1 côté serveur (SCHANNEL), NTLMv1 (LmCompatibilityLevel < 3).
# Une clé absente = valeur par défaut du système (sûre sur Windows 10 1709+ / 11).
function Get-LegacyProtocols {
    $rows = [System.Collections.Generic.List[object]]::new()
    $issues = [System.Collections.Generic.List[object]]::new()
    $smb1 = try { (Get-SmbServerConfiguration -ErrorAction Stop).EnableSMB1Protocol } catch { $v = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' 'SMB1'; if ($null -ne $v) { $v -eq 1 } else { $null } }
    $rows.Add(@('SMBv1 (serveur)', $(if ($smb1) { 'Activé' } elseif ($null -eq $smb1) { 'Par défaut (désactivé)' } else { 'Désactivé' })))
    if ($smb1) { $issues.Add(@('warning', 'SEC-SMB1-ON', 'Le protocole SMBv1 est activé (vecteur de WannaCry / NotPetya)', 'Le désactiver : Set-SmbServerConfiguration -EnableSMB1Protocol $false, et retirer la fonctionnalité « Support de partage de fichiers SMB 1.0 ».')) }
    foreach ($proto in 'TLS 1.0', 'TLS 1.1') {
        $enabled = Get-RegValue "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\$proto\Server" 'Enabled'
        $rows.Add(@("$proto (serveur)", $(if ($null -eq $enabled) { 'Par défaut du système' } elseif ($enabled -ne 0) { 'Activé explicitement' } else { 'Désactivé' })))
        if ($null -ne $enabled -and $enabled -ne 0) { $issues.Add(@('warning', 'SEC-TLS-OLD', "$proto est activé explicitement côté serveur", "Le désactiver (SCHANNEL\Protocols\$proto\Server, Enabled = 0) : TLS 1.2 et 1.3 suffisent.")) }
    }
    $lm = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'LmCompatibilityLevel'
    $rows.Add(@('Authentification NTLM', $(if ($null -eq $lm) { 'Par défaut (NTLMv2)' } elseif ($lm -lt 3) { "NTLMv1 / LM autorisés (niveau $lm)" } else { "NTLMv2 seulement (niveau $lm)" })))
    if ($null -ne $lm -and $lm -lt 3) { $issues.Add(@('warning', 'SEC-NTLMV1', "NTLMv1 / LM sont autorisés (LmCompatibilityLevel = $lm)", 'Régler LmCompatibilityLevel à 5 (« Envoyer uniquement des réponses NTLMv2, refuser LM et NTLM ») : NTLMv1 se casse en quelques heures.')) }
    [PSCustomObject]@{ Rows = $rows.ToArray(); Issues = $issues.ToArray() }
}

#endregion

#region Persistance

# Pourquoi une commande de démarrage paraît suspecte ($null = rien de particulier).
function Get-SuspectReason([string]$Command) {
    if (-not $Command) { return $null }
    if ($IsWindows) {
        if ($Command -match '\\(AppData\\Local\\)?Temp\\|\\Users\\Public\\|\\Downloads\\|\\Téléchargements\\') { return 'Dossier temporaire, public ou de téléchargement' }
        if ($Command -match '(?i)powershell.*\s-(e|ec|enc|encodedcommand)\s') { return 'PowerShell avec commande encodée' }
        if ($Command -match '(?i)(downloadstring|downloadfile|invoke-webrequest|iwr\s|iex\s|invoke-expression|frombase64string)') { return 'Script qui télécharge ou exécute du code' }
        if ($Command -match '(?i)\b(mshta|wscript|cscript|regsvr32\b.*(/i:|scrobj)|certutil\b.*-urlcache|bitsadmin)\b') { return 'Lanceur de script détourné (LOLBin)' }
        if ($Command -match '(?i)rundll32(\.exe)?\s+[^,]*\\(AppData|Temp|ProgramData)\\') { return 'rundll32 sur une bibliothèque hors système' }
        return $null
    }
    if ($Command -match '(^|[\s''"=])(/tmp|/var/tmp|/dev/shm)/') { return 'Dossier temporaire' }
    if ($Command -match '(curl|wget)\b[^|;]*\|\s*(ba|z|da)?sh\b') { return 'Télécharge et exécute un script' }
    if ($Command -match 'base64\s+(-d|--decode)|\beval\b.*\$\(') { return 'Commande encodée ou évaluée' }
    if ($Command -match '\bnc(at)?\b.*\s-[ec]\s|/dev/tcp/|socat\b.*exec') { return 'Shell inversé (connexion réseau vers un shell)' }
    if ($Command -match '/\.[^/\s.][^/\s]*/') { return 'Dossier caché' }
    $null
}

# Windows : chemin de l'exécutable d'une commande (entre guillemets, ou jusqu'au premier .exe).
function Get-CommandPath([string]$Command) {
    if (-not $Command) { return $null }
    $c = [Environment]::ExpandEnvironmentVariables($Command)
    if ($c -match '^\s*"([^"]+)"') { return $Matches[1] }
    if ($c -match '^\s*(.+?\.(exe|com|bat|cmd|vbs|js|ps1|dll))\b') { return $Matches[1] }
    ($c -split '\s+')[0]
}

$script:Signatures = @{}
function Get-SignatureStatus([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    if (-not $script:Signatures.ContainsKey($Path)) {
        $script:Signatures[$Path] = try { "$((Get-AuthenticodeSignature -FilePath $Path -ErrorAction Stop).Status)" } catch { $null }
    }
    $script:Signatures[$Path]
}

# Entrées de persistance normalisées : Kind, Name, Location, Command, Vendor (Microsoft / paquet), Reason (suspect).
function Get-PersistenceEntries([bool]$IncludeVendor) {
    $entries = [System.Collections.Generic.List[object]]::new()
    function Add-Entry([string]$Kind, [string]$Name, [string]$Location, [string]$Command, [string]$Vendor, [string]$Reason) {
        $entries.Add([PSCustomObject]@{ Kind = $Kind; Name = $Name; Location = $Location; Command = $Command; Vendor = $Vendor; Reason = $Reason ?? (Get-SuspectReason $Command) })
    }

    if ($IsWindows) {
        foreach ($key in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce') {
            $item = Get-Item -LiteralPath $key -ErrorAction SilentlyContinue
            if (-not $item) { continue }
            foreach ($name in $item.GetValueNames() | Where-Object { $_ }) {
                $cmd = "$($item.GetValue($name))"
                $path = Get-CommandPath $cmd
                $reason = $null
                if ($path -and $path -match '^[A-Za-z]:\\' -and -not (Test-Path -LiteralPath $path)) { $reason = 'Fichier introuvable' }
                elseif ($path -match '\.exe$' -and $path -notlike "$env:WINDIR*") {
                    $sig = Get-SignatureStatus $path
                    if ($sig -and $sig -ne 'Valid') { $reason = if ($sig -eq 'NotSigned') { 'Exécutable non signé' } else { "Signature invalide ($sig)" } }
                }
                Add-Entry 'Clé Run' $name ($key -replace '^HK(LM|CU):\\SOFTWARE\\', 'HK$1\…\' -replace 'Microsoft\\Windows\\CurrentVersion\\', '') $cmd $null ((Get-SuspectReason $cmd) ?? $reason)
            }
        }
        $wsh = New-Object -ComObject WScript.Shell
        foreach ($folder in [Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup')) {
            foreach ($f in Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue | Where-Object Name -ne 'desktop.ini') {
                $target = if ($f.Extension -eq '.lnk') { $s = $wsh.CreateShortcut($f.FullName); ('"{0}" {1}' -f $s.TargetPath, $s.Arguments).Trim() } else { $f.FullName }
                Add-Entry 'Dossier Démarrage' $f.BaseName $folder $target $null $null
            }
        }
        $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        $shellValue = "$(Get-RegValue $winlogon 'Shell')"; $userinit = "$(Get-RegValue $winlogon 'Userinit')"
        if ($shellValue -and $shellValue -notmatch '^\s*explorer\.exe\s*$') { Add-Entry 'Winlogon' 'Shell' $winlogon $shellValue $null 'Shell de session remplacé (attendu : explorer.exe)' }
        if ($userinit -and $userinit -notmatch '^\s*[A-Za-z]:\\Windows\\system32\\userinit\.exe\s*,?\s*$') { Add-Entry 'Winlogon' 'Userinit' $winlogon $userinit $null 'Programme ajouté à l''ouverture de session (attendu : userinit.exe seul)' }
        foreach ($k in Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options' -ErrorAction SilentlyContinue) {
            $dbg = Get-RegValue $k.PSPath 'Debugger'
            if ($dbg) { Add-Entry 'IFEO (débogueur)' $k.PSChildName 'Image File Execution Options' $dbg $null "Le lancement de $($k.PSChildName) exécute ce programme à la place" }
        }
        $appinit = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows' -ErrorAction SilentlyContinue
        if ($appinit.AppInit_DLLs -and $appinit.LoadAppInit_DLLs -eq 1) { Add-Entry 'AppInit_DLLs' 'AppInit_DLLs' 'Windows NT\CurrentVersion\Windows' $appinit.AppInit_DLLs $null 'Bibliothèque injectée dans chaque programme graphique' }

        foreach ($t in Get-ScheduledTask -ErrorAction SilentlyContinue) {
            $microsoft = $t.TaskPath -like '\Microsoft\*'
            if ($microsoft -and -not $IncludeVendor) { continue }
            foreach ($a in @($t.Actions) | Where-Object { $_.Execute }) {
                $cmd = ('{0} {1}' -f $a.Execute, $a.Arguments).Trim()
                Add-Entry 'Tâche planifiée' ($t.TaskPath + $t.TaskName) "$($t.State)" $cmd $(if ($microsoft) { 'Microsoft' } else { $null }) $null
            }
        }
        # Abonnements WMI permanents (filtre → consommateur) : technique de persistance sans fichier. Lecture admin.
        foreach ($c in @(Get-CimInstance -Namespace root/subscription -ClassName __EventConsumer -ErrorAction SilentlyContinue)) {
            if ($c.Name -eq 'SCM Event Log Consumer') { continue }
            $cmd = $c.CommandLineTemplate ?? $c.ScriptText ?? $c.ExecutablePath
            Add-Entry 'Abonnement WMI' $c.Name $c.CimClass.CimClassName "$cmd" $null 'Consommateur WMI permanent (exécute du code sur événement)'
        }
        return $entries.ToArray()
    }

    # Linux
    foreach ($file in @('/etc/crontab') + @(Get-ChildItem /etc/cron.d -File -ErrorAction SilentlyContinue).FullName) {
        foreach ($line in Read-Text $file) {
            if ($line -match '^\s*(#|$)' -or $line -match '^\s*\w+\s*=') { continue }
            $f = $line.Trim() -split '\s+'
            $cmd = if ($line -match '^\s*@\w+') { ($f | Select-Object -Skip 2) -join ' ' } else { ($f | Select-Object -Skip 6) -join ' ' }
            Add-Entry 'cron' (Split-Path $file -Leaf) $file $cmd $file $null
        }
    }
    foreach ($period in 'hourly', 'daily', 'weekly', 'monthly') {
        foreach ($f in Get-ChildItem "/etc/cron.$period" -File -ErrorAction SilentlyContinue) { Add-Entry "cron.$period" $f.Name $f.DirectoryName $f.FullName $f.FullName $null }
    }
    foreach ($line in & crontab -l 2>$null) {
        if ($line -match '^\s*(#|$)' -or $line -match '^\s*\w+\s*=') { continue }
        $f = $line.Trim() -split '\s+'
        Add-Entry 'crontab' ([Environment]::UserName) 'crontab -l' $(if ($line -match '^\s*@\w+') { ($f | Select-Object -Skip 1) -join ' ' } else { ($f | Select-Object -Skip 5) -join ' ' }) $null $null
    }
    if ([Environment]::IsPrivilegedProcess) {
        foreach ($f in Get-ChildItem /var/spool/cron, /var/spool/cron/crontabs -File -ErrorAction SilentlyContinue) {
            foreach ($line in Read-Text $f.FullName) {
                if ($line -match '^\s*(#|$)' -or $line -match '^\s*\w+\s*=') { continue }
                Add-Entry 'crontab' $f.Name $f.FullName ((($line.Trim() -split '\s+') | Select-Object -Skip 5) -join ' ') $null $null
            }
        }
    }
    # Unités systemd locales : fichiers réguliers (pas les liens d'activation) de /etc/systemd/system et de l'utilisateur.
    $userUnits = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.config/systemd/user'
    foreach ($dir in '/etc/systemd/system', $userUnits) {
        foreach ($f in Get-ChildItem $dir -File -Filter *.service -ErrorAction SilentlyContinue | Where-Object { -not $_.LinkType }) {
            $exec = (Read-Text $f.FullName | Where-Object { $_ -match '^\s*ExecStart\s*=' } | Select-Object -First 1) -replace '^\s*ExecStart\s*=\s*[-@+!:]*', ''
            Add-Entry $(if ($dir -eq $userUnits) { 'Unité systemd (utilisateur)' } else { 'Unité systemd' }) $f.Name $dir $exec $f.FullName $null
        }
    }
    foreach ($dir in (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.config/autostart'), '/etc/xdg/autostart') {
        foreach ($f in Get-ChildItem $dir -File -Filter *.desktop -ErrorAction SilentlyContinue) {
            $text = Read-Text $f.FullName
            if ($text -match '^Hidden\s*=\s*true') { continue }
            $exec = ($text | Where-Object { $_ -match '^Exec\s*=' } | Select-Object -First 1) -replace '^Exec\s*=\s*', ''
            Add-Entry 'Démarrage automatique (session)' $f.BaseName $dir $exec $f.FullName $null
        }
    }
    foreach ($rc in '/etc/rc.local', '/etc/rc.d/rc.local') {
        $item = Get-Item $rc -ErrorAction SilentlyContinue
        if ($item -and ($item.UnixFileMode -band [System.IO.UnixFileMode]::UserExecute)) {
            $body = @(Read-Text $rc | Where-Object { $_ -notmatch '^\s*(#|$|exit 0)' -and $_ -notmatch '^\s*touch /var/lock' })
            if ($body) { Add-Entry 'rc.local' 'rc.local' $rc ($body -join ' ; ') $null $null }
        }
    }
    $preload = @(Read-Text '/etc/ld.so.preload' | Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' })
    if ($preload) { Add-Entry 'ld.so.preload' 'ld.so.preload' '/etc/ld.so.preload' ($preload -join ' ') $null 'Bibliothèque préchargée dans tous les programmes (technique de rootkit)' }

    # Fichiers fournis par un paquet de la distribution : marqués comme tels, masqués sauf demande.
    $files = @($entries | Where-Object { $_.Vendor -like '/*' } | ForEach-Object Vendor | Select-Object -Unique)
    $owners = Get-PackageOwners $files
    $result = foreach ($e in $entries) {
        if ($e.Vendor -like '/*') { $e.Vendor = $owners[$e.Vendor] }
        if ($e.Vendor -and -not $IncludeVendor -and -not $e.Reason) { continue }
        $e
    }
    @($result)
}

#endregion

#region Certificats

# Certificats normalisés : Store, Subject, Issuer, NotAfter, Root, Added (racine ajoutée localement), HasKey.
function Get-CertificateList([string]$Scope) {
    $list = [System.Collections.Generic.List[object]]::new()
    function Add-Cert($Cert, [string]$Store, [bool]$Root, [bool]$Added) {
        $list.Add([PSCustomObject]@{
                Store = $Store; Subject = $Cert.GetNameInfo('SimpleName', $false); Issuer = $Cert.GetNameInfo('SimpleName', $true)
                NotAfter = $Cert.NotAfter; Root = $Root; Added = $Added; HasKey = $Cert.HasPrivateKey
            })
    }
    if ($IsWindows) {
        # Racines « ajoutées » : présentes dans Root (machine ou utilisateur) mais ni dans AuthRoot (programme de
        # certificats racines de Microsoft, mis à jour par Windows Update) ni émises par Microsoft.
        $auth = @{}
        foreach ($c in Get-ChildItem Cert:\LocalMachine\AuthRoot -ErrorAction SilentlyContinue) { $auth[$c.Thumbprint] = $true }
        if ($Scope -in 'personal', 'all') {
            foreach ($s in 'LocalMachine\My', 'CurrentUser\My') { foreach ($c in Get-ChildItem "Cert:\$s" -ErrorAction SilentlyContinue) { Add-Cert $c $s $false $false } }
        }
        if ($Scope -in 'roots', 'added', 'all') {
            foreach ($s in 'LocalMachine\Root', 'CurrentUser\Root', 'LocalMachine\CA') {
                foreach ($c in Get-ChildItem "Cert:\$s" -ErrorAction SilentlyContinue) {
                    $added = $s -like '*\Root' -and -not $auth[$c.Thumbprint] -and $c.Issuer -notmatch 'Microsoft' -and $c.Subject -eq $c.Issuer
                    if ($Scope -eq 'added' -and -not $added) { continue }
                    Add-Cert $c $s ($s -like '*\Root') $added
                }
            }
        }
        return $list.ToArray()
    }
    if ($Scope -in 'roots', 'all') {
        $bundle = '/etc/pki/tls/certs/ca-bundle.crt', '/etc/ssl/certs/ca-certificates.crt', '/etc/ssl/ca-bundle.pem' | Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($bundle) {
            $col = [System.Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
            $col.ImportFromPemFile($bundle)
            foreach ($c in $col) { Add-Cert $c 'Autorités du système' $true $false }
        }
    }
    if ($Scope -in 'roots', 'added', 'all') {
        foreach ($dir in '/etc/pki/ca-trust/source/anchors', '/usr/local/share/ca-certificates', '/etc/ca-certificates/trust-source/anchors') {
            foreach ($f in Get-ChildItem $dir -File -Recurse -ErrorAction SilentlyContinue) {
                $col = [System.Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
                try { $col.ImportFromPemFile($f.FullName) } catch { try { $col.Import($f.FullName) } catch { continue } }
                foreach ($c in $col) { Add-Cert $c "Ajoutée ($dir)" $true $true }
            }
        }
    }
    if ($Scope -in 'personal', 'all') {
        # Certificats d'un service local (serveur web, VPN…) : /etc/pki/tls/certs et /etc/ssl/certs hors bundles.
        foreach ($f in Get-ChildItem /etc/pki/tls/certs, /etc/ssl/certs -File -Include *.crt, *.pem -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch 'ca-bundle|ca-certificates|^ca-' -and -not $_.LinkType -and $_.Length -lt 20KB }) {
            try { Add-Cert ([System.Security.Cryptography.X509Certificates.X509Certificate2]::new($f.FullName)) $f.DirectoryName $false $false } catch { }
        }
    }
    $list.ToArray()
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
    function Add-Issues($Issues) { foreach ($i in $Issues) { Add-Finding $i[0] $i[1] $i[2] $i[3] } }

    $summary = [ordered]@{ 'Score de sécurité' = $null }
    $portable = Get-Cached 'portable' 3600 { Test-Portable }

    # Antivirus
    $av = Invoke-Block 'Antivirus' { Get-Cached 'av' 120 { Get-AntivirusState } }
    if ($av -and $IsWindows) {
        $d = $av.Defender
        $third = @($av.Products | Where-Object { $_.Name -notmatch 'Windows Defender|Microsoft Defender' })
        $activeThird = @($third | Where-Object Enabled)
        $defActive = $d -and $d.AntivirusEnabled -and $d.RealTimeProtectionEnabled -and "$($d.AMRunningMode)" -notmatch 'Passive'
        $summary['Antivirus'] = if ($activeThird) { ($activeThird.Name -join ', ') } elseif ($defActive) { 'Microsoft Defender' } else { 'Aucun actif' }
        $rows = foreach ($p in $av.Products) { , @($p.Name, (Yes $p.Enabled), (Yes $p.UpToDate), $p.Path) }
        if ($rows) { $sections.Add([PSCustomObject]@{ Title = 'Antivirus déclarés'; Type = 'Table'; Icon = 'shield_checkmark'; Columns = @('Produit', 'Actif', 'À jour', 'Programme'); Rows = @($rows) }) }
        if ($d) {
            $items = [ordered]@{
                'Mode' = "$($d.AMRunningMode)"; 'Protection en temps réel' = Yes $d.RealTimeProtectionEnabled
                'Protection contre les falsifications' = Yes $d.IsTamperProtected
                'Signatures' = '{0} · {1} jour(s)' -f (Format-Date $d.AntivirusSignatureLastUpdated), $d.AntivirusSignatureAge
                'Dernière analyse rapide' = Format-Date $d.QuickScanEndTime; 'Dernière analyse complète' = Format-Date $d.FullScanEndTime
                'Menaces (30 jours)' = $av.Threats.Count
            }
            $sections.Add([PSCustomObject]@{ Title = 'Microsoft Defender'; Type = 'KeyValue'; Icon = 'shield_checkmark'; Items = $items })
            if ($defActive -and $d.AntivirusSignatureAge -gt 7) { Add-Finding 'warning' 'SEC-AV-OUTDATED' ("Les signatures de Microsoft Defender ont {0} jours" -f $d.AntivirusSignatureAge) 'Lancer une mise à jour (Sécurité Windows › Mises à jour de la protection) et vérifier Windows Update.' }
            if ($defActive -and -not $d.IsTamperProtected) { Add-Finding 'info' 'SEC-AV-TAMPER-OFF' 'La protection contre les falsifications de Defender est désactivée' 'L''activer : elle empêche un logiciel malveillant de couper l''antivirus.' }
        }
        foreach ($t in $av.Threats | Select-Object -First 10) {
            $resolved = $t.ThreatStatusID -in 2, 3, 4, 6, 106
            Add-Finding $(if ($resolved) { 'warning' } else { 'critical' }) 'SEC-AV-THREAT' ('Menace détectée le {0} : {1}' -f (Format-Date $t.InitialDetectionTime), (@($t.Resources) | Select-Object -First 1)) `
                $(if ($resolved) { 'Traitée par Defender ; lancer une analyse complète pour vérifier qu''il ne reste rien.' } else { 'Non traitée : ouvrir Sécurité Windows › Historique de protection et appliquer l''action recommandée.' })
        }
        foreach ($p in $third | Where-Object { $_.Enabled -and -not $_.UpToDate }) { Add-Finding 'warning' 'SEC-AV-OUTDATED' "$($p.Name) n'est pas à jour" 'Lancer la mise à jour depuis l''antivirus.' }
        if (-not $activeThird -and -not $defActive) { Add-Finding 'critical' 'SEC-AV-OFF' 'Aucun antivirus actif (protection en temps réel coupée)' 'Réactiver Microsoft Defender (Sécurité Windows › Protection contre les virus et menaces) ou l''antivirus installé.' }
    } elseif ($av) {
        $summary['Antivirus'] = if ($av.Clam) { 'ClamAV' + $(if ($av.Clam.Daemon) { ' (démon actif)' } else { ' (analyse à la demande)' }) } else { 'Aucun (habituel sous Linux)' }
        if ($av.Clam) {
            $age = if ($av.Clam.Database) { [int]((Get-Date) - $av.Clam.Database).TotalDays } else { $null }
            $sections.Add([PSCustomObject]@{ Title = 'ClamAV'; Type = 'KeyValue'; Icon = 'shield_checkmark'; Items = [ordered]@{
                        'Version' = $av.Clam.Version; 'Base de signatures' = if ($age -ne $null) { ('{0} · {1} jour(s)' -f (Format-Date $av.Clam.Database), $age) } else { 'introuvable' }
                        'Démon' = $av.Clam.Daemon ?? 'arrêté'; 'Mise à jour automatique' = $av.Clam.Freshclam ?? 'arrêtée'
                    } })
            if ($age -gt 7) { Add-Finding 'warning' 'SEC-AV-OUTDATED' "La base de ClamAV a $age jours" 'Lancer freshclam et activer le service clamav-freshclam.' }
        }
    }

    # Pare-feu
    $fw = Invoke-Block 'Pare-feu' {
        Get-Cached 'firewall' 120 {
            if ($IsWindows) {
                $profiles = @(Get-NetFirewallProfile -ErrorAction Stop)
                $active = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object { "$($_.NetworkCategory)" -replace 'DomainAuthenticated', 'Domain' })
                $inbound = @(Get-NetFirewallRule -Direction Inbound -Action Allow -Enabled True -ErrorAction SilentlyContinue).Count
                [PSCustomObject]@{ Profiles = $profiles; Active = $active; Inbound = $inbound }
            } else { Get-LinuxFirewall }
        }
    }
    if ($fw -and $IsWindows) {
        $names = @{ Domain = 'Domaine'; Private = 'Privé'; Public = 'Public' }
        $rows = foreach ($p in $fw.Profiles) {
            , @(($names["$($p.Name)"] ?? "$($p.Name)"), (Yes ("$($p.Enabled)" -eq 'True')), $(if ("$($p.Name)" -in $fw.Active) { 'Oui' } else { 'Non' }), "$($p.DefaultInboundAction)", "$($p.DefaultOutboundAction)")
        }
        $sections.Add([PSCustomObject]@{ Title = "Pare-feu · $($fw.Inbound) règles entrantes autorisées"; Type = 'Table'; Icon = 'shield_checkmark'; Columns = @('Profil', 'Activé', 'Réseau actuel', 'Entrant par défaut', 'Sortant par défaut'); Rows = @($rows) })
        $off = @($fw.Profiles | Where-Object { "$($_.Enabled)" -ne 'True' })
        $summary['Pare-feu'] = if ($off.Count -eq 0) { 'Activé (tous les profils)' } else { 'Désactivé : ' + (($off | ForEach-Object { $names["$($_.Name)"] }) -join ', ') }
        foreach ($p in $off) {
            $current = "$($p.Name)" -in $fw.Active
            Add-Finding $(if ($current) { 'critical' } else { 'warning' }) 'SEC-FIREWALL-OFF' ('Le pare-feu est désactivé pour le profil {0}{1}' -f $names["$($p.Name)"], $(if ($current) { ' (réseau actuel)' } else { '' })) `
                'Le réactiver (Sécurité Windows › Pare-feu et protection du réseau) ; un logiciel tiers peut l''avoir remplacé, à vérifier.'
        }
        foreach ($p in $fw.Profiles | Where-Object { "$($_.Enabled)" -eq 'True' -and "$($_.DefaultInboundAction)" -eq 'Allow' }) {
            Add-Finding 'warning' 'SEC-FIREWALL-OPEN' "Le profil $($names["$($p.Name)"]) autorise par défaut tout le trafic entrant" 'Remettre l''action entrante par défaut à « Bloquer ».'
        }
    } elseif ($fw) {
        $summary['Pare-feu'] = if ($fw.Active) { $fw.Tool } elseif ($fw.Tool) { "$($fw.Tool) (inactif)" } else { 'Aucun' }
        if ($fw.Zones) {
            $rows = foreach ($z in $fw.Zones) { , @(($z.Name + $(if ($z.Default) { ' (défaut)' } else { '' })), ((@($z.Interfaces, $z.Sources) | Where-Object { $_ }) -join ' '), $z.Target, $z.Services, $z.Ports) }
            $sections.Add([PSCustomObject]@{ Title = "Pare-feu ($($fw.Tool))"; Type = 'Table'; Icon = 'shield_checkmark'; Columns = @('Zone', 'Interfaces / sources', 'Cible', 'Services ouverts', 'Ports ouverts'); Rows = @($rows) })
            foreach ($z in $fw.Zones) {
                $wide = Get-WidestRange $z.Ports
                if ($wide -gt 1000) { Add-Finding 'info' 'SEC-FIREWALL-WIDE' ("La zone {0} ouvre {1} ports d'un coup ({2})" -f $z.Name, $wide, $z.Ports) 'Fermer la plage et n''ouvrir que les services utilisés : firewall-cmd --permanent --zone=… --remove-port=…, ou passer l''interface dans une zone plus stricte (public).' }
                # Zones créées par Docker / libvirt pour leurs ponts virtuels : ACCEPT y est normal.
                $virtual = $z.Name -in 'docker', 'libvirt', 'libvirt-routed' -or ($z.Interfaces -and -not ($z.Interfaces -split '\s+' | Where-Object { $_ -notmatch '^(docker|br-|virbr|veth|podman|cni|vnet|lxc)' }))
                if ($z.Target -eq 'ACCEPT' -and -not $virtual) { Add-Finding 'warning' 'SEC-FIREWALL-OPEN' "La zone $($z.Name) accepte tout le trafic entrant (cible ACCEPT)" 'Passer l''interface dans une zone dont la cible est default ou REJECT.' }
            }
        } elseif ($fw.Note) {
            $sections.Add([PSCustomObject]@{ Title = "Pare-feu ($($fw.Tool))"; Type = 'KeyValue'; Icon = 'shield_checkmark'; Items = [ordered]@{ 'État' = if ($fw.Active) { 'Actif' } else { 'Inactif' }; 'Détail' = $fw.Note } })
        }
        if (-not $fw.Active) { Add-Finding 'warning' 'SEC-FIREWALL-OFF' $(if ($fw.Tool) { "Le pare-feu ($($fw.Tool)) est inactif" } else { 'Aucun pare-feu actif (firewalld, ufw ou nftables)' }) 'Activer le pare-feu de la distribution : systemctl enable --now firewalld (Fedora, RHEL) ou ufw enable (Ubuntu).' }
    }

    # Chiffrement
    $volumes = @(Invoke-Block 'Chiffrement' { Get-Cached 'encryption' 300 { if ($IsWindows) { Get-WindowsEncryption } else { Get-LinuxEncryption } } } | Where-Object { $_ })
    if ($volumes.Count -gt 0) {
        $columns = @('Volume', 'Système de fichiers', 'Taille', 'Chiffrement')
        if ($IsWindows) { $columns += 'Protecteurs' } else { $columns += 'Périphérique' }
        $rows = foreach ($v in $volumes) { , @($v.Mount, $v.FileSystem, $v.Size, ($v.Encryption ?? 'Non chiffré'), $(if ($IsWindows) { $v.Protectors } else { $v.Device })) }
        $sections.Add([PSCustomObject]@{ Title = 'Chiffrement des disques'; Type = 'Table'; Icon = 'lock_closed'; Columns = $columns; Rows = @($rows) })
        $important = @($volumes | Where-Object { $_.Mount -in '/', '/home', '[SWAP]' -or ($IsWindows -and $_.Mount -match '^[A-Z]:$') })
        $clear = @($important | Where-Object { -not $_.Encryption })
        $summary['Chiffrement'] = if ($clear.Count -eq 0) { 'Volumes système chiffrés' } else { 'Non chiffré : ' + ($clear.Mount -join ', ') }
        # Un constat par volume (Btrfs : / et /home sur la même partition = un seul constat).
        foreach ($g in $clear | Where-Object Mount -ne '[SWAP]' | Group-Object { if ($IsWindows) { $_.Mount } else { $_.Device } }) {
            $label = if ($IsWindows -or $g.Count -eq 1) { $g.Group[0].Mount } else { '{0} ({1})' -f $g.Name, ($g.Group.Mount -join ', ') }
            Add-Finding $(if ($portable) { 'warning' } else { 'info' }) 'SEC-DISK-UNENCRYPTED' ("Le volume {0} n'est pas chiffré{1}" -f $label, $(if ($portable) { ' (ordinateur portable)' } else { '' })) `
                $(if ($IsWindows) { 'Activer BitLocker (ou le chiffrement de l''appareil) et sauvegarder la clé de récupération hors de l''ordinateur.' } else { 'Le chiffrement LUKS se choisit à l''installation ; en cas de perte ou de vol, les données sont lisibles en démontant le disque.' })
        }
        if (($important | Where-Object { $_.Mount -eq '/' -and $_.Encryption }) -and ($clear | Where-Object Mount -eq '[SWAP]')) {
            Add-Finding 'info' 'SEC-SWAP-UNENCRYPTED' 'Le swap n''est pas chiffré alors que la racine l''est' 'Chiffrer le swap (ou utiliser zram) : la mémoire paginée peut contenir des secrets.'
        }
        foreach ($v in $volumes | Where-Object Suspended) { Add-Finding 'warning' 'SEC-BITLOCKER-SUSPENDED' "BitLocker est suspendu sur $($v.Mount)" 'Reprendre la protection : Resume-BitLocker (souvent oublié après une mise à jour du BIOS).' }
    }

    # Plateforme
    $platform = Invoke-Block 'Plateforme' { Get-Cached 'platform' 300 { Get-PlatformProtections } }
    if ($platform) {
        $sections.Add([PSCustomObject]@{ Title = 'Protections de la plateforme'; Type = 'KeyValue'; Icon = 'developer_board'; Items = $platform.Items })
        Add-Issues $platform.Issues
        $summary['Secure Boot'] = $platform.Items['Secure Boot']
    }

    # Comptes et groupes
    $accounts = Invoke-Block 'Comptes' { Get-Cached 'accounts' 300 { Get-Accounts } }
    if ($accounts) {
        $rows = foreach ($u in $accounts.Users | Sort-Object { -not $_.Enabled }, Name) {
            $row = @($u.Name, $u.FullName, (Yes $u.Enabled), (Yes $u.Admin), (Format-Date $u.LastLogon))
            if ($IsWindows) { $row += @($u.PasswordAge, (Yes $u.NeverExpires), (Yes (-not $u.NotRequired))) } else { $row += @($u.Shell, (($u.Groups | Where-Object { $_ -and $script:LinuxPrivileged.Contains($_) }) -join ', ')) }
            , $row
        }
        $columns = @('Compte', 'Nom complet', 'Actif', 'Administrateur', 'Dernière connexion')
        $columns += if ($IsWindows) { @('Âge du mot de passe (j)', 'Mot de passe sans expiration', 'Mot de passe requis') } else { @('Shell', 'Groupes privilégiés') }
        $sections.Add([PSCustomObject]@{ Title = 'Comptes locaux'; Type = 'Table'; Icon = 'lock_closed'; Columns = $columns; Rows = @($rows) })
        if ($accounts.Groups) {
            $rows = foreach ($g in $accounts.Groups) { , @($g.Group, $g.Role, $g.Members.Count, ($g.Members -join ', ')) }
            $sections.Add([PSCustomObject]@{ Title = 'Groupes privilégiés'; Type = 'Table'; Icon = 'shield_checkmark'; Columns = @('Groupe', 'Donne', 'Membres', 'Liste'); Rows = @($rows) })
        }
        $enabled = @($accounts.Users | Where-Object Enabled)
        $summary['Comptes actifs'] = '{0} dont {1} administrateur(s)' -f $enabled.Count, @($enabled | Where-Object Admin).Count
        foreach ($u in $enabled) {
            if ($u.Guest) { Add-Finding 'warning' 'SEC-GUEST-ENABLED' 'Le compte Invité est activé' 'Le désactiver : il permet d''ouvrir une session sans mot de passe.' }
            if ($u.NotRequired) { Add-Finding 'warning' 'SEC-PASSWORD-NOT-REQUIRED' "Le compte $($u.Name) peut avoir un mot de passe vide" "Exiger un mot de passe : net user $($u.Name) /passwordreq:yes" }
            if ($u.LastLogon -and $u.LastLogon -lt (Get-Date).AddDays(-90) -and -not $u.Builtin -and $u.Id -ne 0) {
                Add-Finding 'info' 'SEC-ACCOUNT-INACTIVE' ('Le compte {0} est actif mais inutilisé depuis le {1}' -f $u.Name, (Format-Date $u.LastLogon)) 'Désactiver ou supprimer les comptes qui ne servent plus.'
            }
        }
        if ($IsLinux) {
            foreach ($g in $accounts.Groups | Where-Object { $_.Group -in 'docker', 'lxd', 'disk' }) {
                Add-Finding 'info' 'SEC-ROOT-EQUIVALENT-GROUP' ('{0} : membre(s) du groupe {1} ({2})' -f ($g.Members -join ', '), $g.Group, $g.Role) `
                    "Ce groupe donne de fait les droits root sans mot de passe ; n'y laisser que les comptes qui en ont besoin (Docker sans root : mode rootless ou Podman)."
            }
        }
    }

    # Sessions et échecs de connexion (24 h)
    $sessions = @(Invoke-Block 'Sessions' { Get-Cached 'sessions' 30 { Get-Sessions } } | Where-Object { $_ })
    if ($sessions.Count -gt 0) {
        $rows = foreach ($s in $sessions) { , @($s.User, $s.Where, $s.State, $(if ($s.Remote) { "Oui ($($s.Host))" } else { 'Non' }), $s.Since) }
        $sections.Add([PSCustomObject]@{ Title = 'Sessions ouvertes'; Type = 'Table'; Icon = 'desktop'; Columns = @('Utilisateur', 'Où', 'État', 'Distante', 'Depuis'); Rows = @($rows) })
    }
    $failures = $null
    if (-not $IsWindows -or (Test-Elevated)) { $failures = @(Invoke-Block 'Échecs de connexion' { Get-Cached 'failures' 120 { Get-LogonFailures 24 } } | Where-Object { $_ }) }
    $summary['Échecs de connexion (24 h)'] = if ($null -eq $failures) { 'journal Sécurité lisible en administrateur' } else { $failures.Count }
    if ($failures.Count -gt 0) {
        $groups = @($failures | Group-Object { '{0}|{1}|{2}' -f $_.User, $_.Source, $_.Kind } | Sort-Object Count -Descending)
        $rows = foreach ($g in $groups | Select-Object -First 20) {
            $f = $g.Group[0]; $last = ($g.Group | Sort-Object Time -Descending)[0]
            , @($f.User, $f.Source, $f.Kind, $g.Count, (Format-Date $last.Time))
        }
        $sections.Add([PSCustomObject]@{ Title = 'Échecs de connexion (24 h)'; Type = 'Table'; Icon = 'warning'; Columns = @('Compte', 'Source', 'Type', 'Nombre', 'Dernier'); Rows = @($rows) })
        if ($failures.Count -ge 10) {
            $top = $groups[0].Group[0]
            Add-Finding $(if ($failures.Count -ge 100) { 'critical' } else { 'warning' }) 'SEC-LOGON-FAILURES' ('{0} échecs de connexion en 24 h (le plus fréquent : {1}{2})' -f $failures.Count, $top.User, $(if ($top.Source) { " depuis $($top.Source)" } else { '' })) `
                'Attaque par force brute ou mot de passe oublié : vérifier la source, limiter l''exposition (pare-feu, clés SSH, fail2ban) et le verrouillage des comptes.'
        }
    }

    # Politique de mots de passe
    $policy = Invoke-Block 'Politique de mots de passe' { Get-Cached 'policy' 600 { Get-PasswordPolicy } }
    if ($policy) {
        $items = [ordered]@{
            'Longueur minimale' = if ($policy.MinLength) { $policy.MinLength } else { 'Aucune' }
            'Durée de vie maximale' = if ($policy.MaxAgeDays) { "$($policy.MaxAgeDays) jours" } else { 'Illimitée' }
            'Verrouillage après' = if ($policy.LockoutThreshold) { "$($policy.LockoutThreshold) échecs" + $(if ($policy.LockoutMinutes) { " · $($policy.LockoutMinutes) min" } else { '' }) } else { 'Jamais' }
            'Source' = $policy.Source
        }
        if ($IsWindows) { $items.Insert(2, 'Historique', $(if ($policy.History) { "$($policy.History) mots de passe" } else { 'Aucun' })) }
        $sections.Add([PSCustomObject]@{ Title = 'Politique de mots de passe'; Type = 'KeyValue'; Icon = 'lock_closed'; Items = $items })
        if (-not $policy.LockoutThreshold) { Add-Finding 'info' 'SEC-NO-LOCKOUT' 'Aucun verrouillage de compte après des échecs de connexion' $(if ($IsWindows) { 'Définir un seuil (net accounts /lockoutthreshold:10) pour freiner les attaques par force brute.' } else { 'Activer pam_faillock (authselect enable-feature with-faillock sous Fedora / RHEL).' }) }
        if ($policy.MinLength -lt 8) { Add-Finding 'info' 'SEC-PASSWORD-SHORT' ("Longueur minimale des mots de passe : {0}" -f [int]$policy.MinLength) $(if ($IsWindows) { 'net accounts /minpwlen:12 (sans effet sur les comptes Microsoft, qui ont leur propre politique).' } else { 'minlen = 12 dans /etc/security/pwquality.conf.' }) }
    }

    # Accès distant, protocoles
    $remote = Invoke-Block 'Accès distant' { Get-Cached 'remote' 120 { Get-RemoteAccess } }
    if ($remote) {
        $sections.Add([PSCustomObject]@{ Title = 'Accès distant'; Type = 'Table'; Icon = 'link'; Columns = @('Service', 'État', 'Détail'); Rows = @($remote.Rows) })
        Add-Issues $remote.Issues
    }
    if ($IsWindows) {
        $legacy = Invoke-Block 'Protocoles' { Get-Cached 'legacy' 600 { Get-LegacyProtocols } }
        if ($legacy) {
            $sections.Add([PSCustomObject]@{ Title = 'Protocoles obsolètes'; Type = 'Table'; Icon = 'network_check'; Columns = @('Protocole', 'État'); Rows = @($legacy.Rows) })
            Add-Issues $legacy.Issues
        }
    }

    # Persistance suspecte
    $persistence = @(Invoke-Block 'Persistance' { Get-Cached 'persistence' 600 { Get-PersistenceEntries $false } } | Where-Object { $_ })
    $suspects = @($persistence | Where-Object Reason)
    $summary['Persistance suspecte'] = '{0} sur {1} entrées' -f $suspects.Count, $persistence.Count
    if ($suspects.Count -gt 0) {
        $rows = foreach ($s in $suspects) { , @($s.Kind, $s.Name, $s.Reason, $s.Command, $s.Location) }
        $sections.Add([PSCustomObject]@{ Title = 'Persistance suspecte'; Type = 'Table'; Icon = 'warning'; Columns = @('Type', 'Nom', 'Motif', 'Commande', 'Emplacement'); Rows = @($rows) })
        foreach ($s in $suspects | Select-Object -First 15) {
            $missing = $s.Reason -eq 'Fichier introuvable'
            Add-Finding $(if ($missing) { 'info' } else { 'warning' }) 'SEC-PERSISTENCE-SUSPECT' ('{0} « {1} » : {2}' -f $s.Kind, $s.Name, $s.Reason.ToLower()) `
                $(if ($missing) { 'Entrée orpheline d''un programme désinstallé : la supprimer.' } else { 'Vérifier l''origine de ce programme ; s''il est inconnu, analyser la machine (antivirus hors ligne) avant de le supprimer.' })
        }
    }

    # Racines ajoutées localement
    $added = @(Invoke-Block 'Certificats' { Get-Cached 'rootsadded' 600 { Get-CertificateList 'added' } } | Where-Object { $_ })
    if ($added.Count -gt 0) {
        $rows = foreach ($c in $added) { , @($c.Subject, $c.Store, (Format-Date $c.NotAfter)) }
        $sections.Add([PSCustomObject]@{ Title = 'Autorités racines ajoutées'; Type = 'Table'; Icon = 'lock_closed'; Columns = @('Autorité', 'Magasin', 'Expire le'); Rows = @($rows) })
        foreach ($c in $added | Select-Object -First 10) {
            Add-Finding 'info' 'SEC-ROOT-CERT-ADDED' "Autorité racine ajoutée localement : $($c.Subject)" 'Normal pour un antivirus qui inspecte HTTPS, un proxy d''entreprise ou un outil de développement ; sinon, elle permet d''intercepter toutes les connexions chiffrées : la retirer.'
        }
    }

    # Score : 100 moins 20 par constat critique, 8 par attention, 2 par information.
    $weights = @{ critical = 20; warning = 8; info = 2 }
    $score = [Math]::Max(0, 100 - ($findings | ForEach-Object { $weights[$_.Severity] } | Measure-Object -Sum).Sum)
    $counts = $findings | Group-Object Severity -AsHashTable -AsString
    $summary['Score de sécurité'] = '{0} / 100 ({1} critique(s), {2} attention, {3} information(s))' -f $score, @($counts['critical']).Where({ $_ }).Count, @($counts['warning']).Where({ $_ }).Count, @($counts['info']).Where({ $_ }).Count
    $sections.Insert(0, [PSCustomObject]@{ Title = 'Résumé'; Type = 'KeyValue'; Icon = 'shield_checkmark'; Items = $summary })

    if ($errors.Count -gt 0) {
        $sections.Add([PSCustomObject]@{ Title = 'Erreurs du module'; Type = 'KeyValue'; Icon = 'error_circle'; Items = $errors })
    }

    $subtitle = 'Score {0} / 100 · antivirus : {1} · pare-feu : {2}' -f $score, $summary['Antivirus'], $summary['Pare-feu']
    [PSCustomObject]@{ Subtitle = $subtitle; Sections = $sections.ToArray(); Findings = $findings.ToArray() }
}

#region Fonctions ciblées (module.json › functions)

# security_get_logons : connexions réussies et échouées.
function Get-SILogons {
    param(
        [ValidateRange(1, 2160)][int]$SinceHours = 168,
        [ValidateSet('all', 'success', 'failed')][string]$Result = 'all',
        [ValidateRange(1, 1000)][int]$Top = 100
    )
    $since = (Get-Date).AddHours(-$SinceHours)
    $logons = [System.Collections.Generic.List[object]]::new()
    if ($IsWindows) {
        if (-not (Test-Elevated)) { throw 'Le journal Sécurité de Windows n''est lisible qu''en administrateur : relancer SysInfo en administrateur.' }
        if ($Result -ne 'failed') {
            # 4624 : connexions interactives, déverrouillages, Bureau à distance, identifiants en cache (pas les services).
            foreach ($e in Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4624; StartTime = $since } -MaxEvents 5000 -ErrorAction SilentlyContinue) {
                $p = $e.Properties; $type = [int]$p[8].Value
                if ($type -notin 2, 7, 10, 11) { continue }
                $logons.Add([PSCustomObject]@{ Time = $e.TimeCreated; User = ('{0}\{1}' -f $p[6].Value, $p[5].Value); Kind = Get-LogonTypeName $type; Source = ("$($p[18].Value)" -replace '^-$', ''); Ok = $true; Detail = "$($p[11].Value)" })
                if ($logons.Count -ge $Top * 3) { break }
            }
        }
        if ($Result -ne 'success') {
            foreach ($f in @(try { Get-LogonFailures $SinceHours 5000 } catch { @() })) { $logons.Add([PSCustomObject]@{ Time = $f.Time; User = $f.User; Kind = $f.Kind; Source = $f.Source; Ok = $false; Detail = "état $($f.Detail)" }) }
        }
    } else {
        if ($Result -ne 'failed') {
            foreach ($line in & last -F -w -s $since.ToString('yyyy-MM-dd HH:mm') 2>$null) {
                if ($line -notmatch '^(\S+)\s+(\S+)\s+(.*?)\s*(\w{3} \w{3} +\d+ \d\d:\d\d:\d\d \d{4})\s+(.*)$' -or $Matches[1] -in 'reboot', 'shutdown', 'wtmp') { continue }
                $time = try { [datetime]::ParseExact(($Matches[4] -replace '\s+', ' '), 'ddd MMM d HH:mm:ss yyyy', [cultureinfo]::InvariantCulture) } catch { $null }
                $hostName = $Matches[3]; $tty = $Matches[2]
                $kind = if ($tty -like 'pts/*' -and $hostName -match '^\d|:[0-9a-f]*:|\.[a-z]') { 'Distante (SSH)' } elseif ($tty -like 'pts/*') { 'Terminal' } else { 'Locale' }
                $logons.Add([PSCustomObject]@{ Time = $time; User = $Matches[1]; Kind = $kind; Source = $hostName; Ok = $true; Detail = $tty + ' · ' + ($Matches[5] -replace '\s+', ' ') })
            }
        }
        if ($Result -ne 'success') {
            foreach ($f in Get-LogonFailures $SinceHours 5000) { $logons.Add([PSCustomObject]@{ Time = $f.Time; User = $f.User; Kind = $f.Kind; Source = $f.Source; Ok = $false; Detail = $f.Detail }) }
        }
    }

    $all = @($logons | Sort-Object Time -Descending)
    $failed = @($all | Where-Object { -not $_.Ok })
    $rows = foreach ($l in $all | Select-Object -First $Top) { , @((Format-Date $l.Time), $(if ($l.Ok) { 'Réussie' } else { 'Échec' }), $l.User, $l.Kind, $l.Source, $l.Detail) }
    $sections = [System.Collections.Generic.List[object]]::new()
    $sections.Add([PSCustomObject]@{ Title = 'Connexions'; Type = 'Table'; Icon = 'lock_closed'; Columns = @('Date', 'Résultat', 'Compte', 'Type', 'Source', 'Détail'); Rows = @($rows) })
    $findings = @()
    if ($failed.Count -gt 0) {
        $groups = @($failed | Group-Object { '{0}|{1}' -f $_.User, $_.Source } | Sort-Object Count -Descending)
        $grows = foreach ($g in $groups | Select-Object -First 50) { $f = $g.Group[0]; , @($f.User, $f.Source, $g.Count, (Format-Date ($g.Group | Sort-Object Time)[0].Time), (Format-Date ($g.Group | Sort-Object Time -Descending)[0].Time)) }
        $sections.Add([PSCustomObject]@{ Title = 'Échecs regroupés'; Type = 'Table'; Icon = 'warning'; Columns = @('Compte', 'Source', 'Nombre', 'Premier', 'Dernier'); Rows = @($grows) })
        # Échecs locaux (écran de verrouillage, sudo) : fautes de frappe tant qu'ils restent peu nombreux.
        foreach ($g in $groups | Where-Object { $_.Count -ge 30 -or ($_.Count -ge 10 -and $_.Group[0].Source) } | Select-Object -First 5) {
            $f = $g.Group[0]
            $findings += New-Finding 'warning' 'SEC-LOGON-FAILURES' ('{0} échecs pour {1}{2}' -f $g.Count, $f.User, $(if ($f.Source) { " depuis $($f.Source)" } else { '' })) 'Vérifier cette source ; bloquer l''adresse si elle est inconnue.'
        }
    }
    [PSCustomObject]@{
        Subtitle = '{0} connexion(s) réussie(s), {1} échec(s) sur {2} h' -f ($all.Count - $failed.Count), $failed.Count, $SinceHours
        Sections = $sections.ToArray(); Findings = $findings
    }
}

# security_get_firewall_rules : règles du pare-feu.
function Get-SIFirewallRules {
    param(
        [ValidateSet('inbound', 'outbound', 'all')][string]$Direction = 'inbound',
        [ValidateSet('allow', 'block', 'all')][string]$Action = 'allow',
        [string]$Filter,
        [ValidateRange(1, 2000)][int]$Top = 200
    )
    $findings = [System.Collections.Generic.List[object]]::new()
    if ($IsWindows) {
        $query = @{ Enabled = 'True' }
        if ($Direction -ne 'all') { $query.Direction = @{ inbound = 'Inbound'; outbound = 'Outbound' }[$Direction] }
        if ($Action -ne 'all') { $query.Action = @{ allow = 'Allow'; block = 'Block' }[$Action] }
        $rules = @(Get-NetFirewallRule @query -ErrorAction Stop)
        # Filtres lus en bloc puis joints par InstanceID : bien plus rapide qu'un appel par règle.
        $ports = @{}; foreach ($f in Get-NetFirewallPortFilter -All -ErrorAction SilentlyContinue) { $ports[$f.InstanceID] = $f }
        $apps = @{}; foreach ($f in Get-NetFirewallApplicationFilter -All -ErrorAction SilentlyContinue) { $apps[$f.InstanceID] = $f }
        $addrs = @{}; foreach ($f in Get-NetFirewallAddressFilter -All -ErrorAction SilentlyContinue) { $addrs[$f.InstanceID] = $f }
        $list = foreach ($r in $rules) {
            $p = $ports[$r.InstanceID]; $a = $apps[$r.InstanceID]; $ad = $addrs[$r.InstanceID]
            $program = "$($a.Program)"; $localPort = (@($p.LocalPort) -join ','); $remote = (@($ad.RemoteAddress) -join ',')
            $text = '{0} {1} {2} {3}' -f $r.DisplayName, $program, $localPort, $a.Service
            if ($Filter -and $text -notlike "*$Filter*") { continue }
            $broad = $null
            if ("$($r.Direction)" -eq 'Inbound' -and "$($r.Action)" -eq 'Allow') {
                $public = "$($r.Profile)" -match 'Any|Public'
                $anyAddr = $remote -in 'Any', ''
                if ($localPort -eq 'Any' -and $program -in 'Any', '' -and $anyAddr -and $public) { $broad = 'Tous les ports, toutes les adresses, réseau public' }
                elseif ($program -and $program -ne 'Any' -and $program -notmatch '^(%SystemRoot%|%windir%|C:\\Windows|%ProgramFiles%|C:\\Program Files|System$)' -and $anyAddr -and $public) { $broad = 'Programme hors des dossiers système, ouvert sur le réseau public' }
            }
            [PSCustomObject]@{ Rule = $r; Program = $program; LocalPort = $localPort; Remote = $remote; Protocol = "$($p.Protocol)"; Broad = $broad }
        }
        $list = @($list | Sort-Object { -not $_.Broad }, { $_.Rule.DisplayName })
        $rows = foreach ($l in $list | Select-Object -First $Top) {
            , @($l.Rule.DisplayName, "$($l.Rule.Direction)", "$($l.Rule.Action)", "$($l.Rule.Profile)", $l.Protocol, $l.LocalPort, $l.Remote, $l.Program, $l.Broad)
        }
        foreach ($l in $list | Where-Object Broad | Select-Object -First 15) { $findings.Add((New-Finding 'info' 'SEC-FIREWALL-RULE-BROAD' ("Règle « {0} » : {1}" -f $l.Rule.DisplayName, $l.Broad.ToLower()) 'Restreindre la règle au profil Privé, à des adresses ou à des ports précis, ou la désactiver si le programme n''est plus utilisé.')) }
        return [PSCustomObject]@{
            Subtitle = '{0} règle(s) activée(s){1}' -f $list.Count, $(if ($Filter) { " · « $Filter »" } else { '' })
            Sections = @([PSCustomObject]@{ Title = 'Règles'; Type = 'Table'; Icon = 'shield_checkmark'; Columns = @('Nom', 'Sens', 'Action', 'Profils', 'Protocole', 'Ports locaux', 'Adresses distantes', 'Programme', 'Large'); Rows = @($rows) })
            Findings = $findings.ToArray()
        }
    }

    $fw = Get-LinuxFirewall
    if (-not $fw.Active) { throw $(if ($fw.Tool) { "Le pare-feu $($fw.Tool) est inactif" } else { 'Aucun pare-feu actif (firewalld, ufw ou nftables)' }) }
    if ($fw.Tool -ne 'firewalld') {
        if ($fw.Note -and $fw.Note -match 'root') { throw "$($fw.Tool) : $($fw.Note.ToLower()) ; relancer SysInfo avec sudo." }
        $lines = @($fw.Note -split "`n" | Where-Object { $_ -match '\S' -and (-not $Filter -or $_ -like "*$Filter*") } | Select-Object -First $Top)
        return [PSCustomObject]@{ Subtitle = $fw.Tool; Sections = @([PSCustomObject]@{ Title = 'ufw status verbose'; Type = 'Table'; Icon = 'shield_checkmark'; Columns = @('Ligne'); Rows = @($lines | ForEach-Object { , @($_) }) }); Findings = @() }
    }
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($z in $fw.Zones) {
        $add = { param($Kind, $Value) if ($Value -and (-not $Filter -or "$($z.Name) $Value" -like "*$Filter*") -and $rows.Count -lt $Top) { $rows.Add(@($z.Name, $z.Interfaces, $z.Target, $Kind, $Value)) } }
        foreach ($s in $z.Services -split '\s+') { & $add 'Service' $s }
        foreach ($p in $z.Ports -split '\s+') { & $add 'Port' $p }
        if ($z.Rich) { & $add 'Règle riche' $z.Rich }
        $wide = Get-WidestRange $z.Ports
        if ($wide -gt 1000) { $findings.Add((New-Finding 'info' 'SEC-FIREWALL-WIDE' ("La zone {0} ouvre {1} ports d'un coup ({2})" -f $z.Name, $wide, $z.Ports) 'N''ouvrir que les ports des services utilisés.')) }
    }
    [PSCustomObject]@{
        Subtitle = 'firewalld · {0} zone(s) active(s)' -f $fw.Zones.Count
        Sections = @([PSCustomObject]@{ Title = 'Ouvertures par zone'; Type = 'Table'; Icon = 'shield_checkmark'; Columns = @('Zone', 'Interfaces', 'Cible', 'Type', 'Valeur'); Rows = $rows.ToArray() })
        Findings = $findings.ToArray()
    }
}

# security_find_persistence : points de persistance.
function Find-SIPersistence {
    param(
        [bool]$SuspiciousOnly = $false,
        [bool]$IncludeVendor = $false
    )
    $entries = @(Get-PersistenceEntries $IncludeVendor)
    if ($SuspiciousOnly) { $entries = @($entries | Where-Object Reason) }
    $rows = foreach ($e in $entries | Sort-Object { -not $_.Reason }, Kind, Name) { , @($e.Kind, $e.Name, ($e.Reason ?? ''), $e.Command, $e.Location, ($e.Vendor ?? '')) }
    $findings = foreach ($e in $entries | Where-Object Reason | Select-Object -First 30) {
        New-Finding $(if ($e.Reason -eq 'Fichier introuvable') { 'info' } else { 'warning' }) 'SEC-PERSISTENCE-SUSPECT' ('{0} « {1} » : {2}' -f $e.Kind, $e.Name, $e.Reason.ToLower()) 'Vérifier l''origine de ce programme avant de le supprimer.'
    }
    [PSCustomObject]@{
        Subtitle = '{0} entrée(s), dont {1} suspecte(s)' -f $entries.Count, @($entries | Where-Object Reason).Count
        Sections = @([PSCustomObject]@{ Title = 'Points de persistance'; Type = 'Table'; Icon = 'arrow_routing'; Columns = @('Type', 'Nom', 'Motif', 'Commande', 'Emplacement', $(if ($IsWindows) { 'Éditeur' } else { 'Paquet' })); Rows = @($rows) })
        Findings = @($findings)
    }
}

# security_get_certificates : certificats et échéances.
function Get-SICertificates {
    param(
        [ValidateSet('personal', 'roots', 'added', 'all')][string]$Scope = 'personal',
        [ValidateRange(0, 365)][int]$ExpiringDays = 30,
        [ValidateRange(1, 2000)][int]$Top = 200
    )
    $now = Get-Date
    $certs = @(Get-CertificateList $Scope)
    $rows = foreach ($c in $certs | Sort-Object NotAfter | Select-Object -First $Top) {
        $days = [int][Math]::Floor(($c.NotAfter - $now).TotalDays)
        $state = if ($days -lt 0) { 'Expiré' } elseif ($days -le $ExpiringDays) { 'Expire bientôt' } else { 'Valide' }
        , @($c.Subject, $c.Issuer, $c.Store, (Format-Date $c.NotAfter), $days, $state, $(if ($c.Added) { 'Ajoutée' } elseif ($c.Root) { 'Racine' } else { '' }), (Yes $c.HasKey))
    }
    $findings = [System.Collections.Generic.List[object]]::new()
    foreach ($c in $certs | Where-Object { -not $_.Root }) {
        $days = ($c.NotAfter - $now).TotalDays
        if ($days -lt 0 -and $c.HasKey) { $findings.Add((New-Finding 'info' 'SEC-CERT-EXPIRED' ("Certificat expiré le {0} : {1}" -f (Format-Date $c.NotAfter), $c.Subject) 'Le renouveler s''il sert encore (serveur, VPN, signature), sinon le supprimer.')) }
        elseif ($days -ge 0 -and $days -le $ExpiringDays) { $findings.Add((New-Finding 'warning' 'SEC-CERT-EXPIRING' ("Certificat qui expire dans {0} jour(s) : {1}" -f [int]$days, $c.Subject) 'Prévoir son renouvellement.')) }
    }
    foreach ($c in $certs | Where-Object Added | Select-Object -First 10) { $findings.Add((New-Finding 'info' 'SEC-ROOT-CERT-ADDED' "Autorité racine ajoutée localement : $($c.Subject)" 'Vérifier qu''elle vient d''un logiciel connu (antivirus, proxy d''entreprise, outil de développement).')) }
    [PSCustomObject]@{
        Subtitle = '{0} certificat(s) · {1} expiré(s)' -f $certs.Count, @($certs | Where-Object { $_.NotAfter -lt $now }).Count
        Sections = @([PSCustomObject]@{ Title = 'Certificats'; Type = 'Table'; Icon = 'lock_closed'; Columns = @('Sujet', 'Émetteur', 'Magasin', 'Expire le', 'Jours restants', 'État', 'Racine', 'Clé privée'); Rows = @($rows) })
        Findings = $findings.ToArray()
    }
}

# security_get_acl : autorisations d'un fichier ou dossier (métadonnées seulement).
function Get-SIAcl {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Chemin introuvable : $Path" }
    $item = Get-Item -LiteralPath $Path -Force
    $findings = [System.Collections.Generic.List[object]]::new()
    if ($IsWindows) {
        $acl = Get-Acl -LiteralPath $Path
        # Identités larges : Tout le monde, Utilisateurs, Utilisateurs authentifiés (par SID, indépendant de la langue).
        $broad = 'S-1-1-0', 'S-1-5-32-545', 'S-1-5-11'
        $rows = foreach ($r in $acl.Access) {
            $sid = try { $r.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { $null }
            $rights = "$($r.FileSystemRights)"
            if ($sid -in $broad -and "$($r.AccessControlType)" -eq 'Allow' -and $rights -match 'FullControl|Modify|Write|CreateFiles|AppendData|ChangePermissions|TakeOwnership') {
                $findings.Add((New-Finding 'warning' 'SEC-ACL-WEAK' ('{0} : {1} a le droit « {2} »' -f $Path, $r.IdentityReference, $rights) 'Retirer l''écriture aux groupes larges, sauf dossier de partage voulu.'))
            }
            , @("$($r.IdentityReference)", $rights, "$($r.AccessControlType)", (Yes $r.IsInherited), "$($r.InheritanceFlags)")
        }
        return [PSCustomObject]@{
            Subtitle = '{0} · propriétaire {1}' -f $Path, $acl.Owner
            Sections = @(
                [PSCustomObject]@{ Title = 'Élément'; Type = 'KeyValue'; Icon = 'info'; Items = [ordered]@{ 'Chemin' = $item.FullName; 'Type' = if ($item.PSIsContainer) { 'Dossier' } else { 'Fichier' }; 'Propriétaire' = $acl.Owner; 'Héritage désactivé' = Yes $acl.AreAccessRulesProtected } }
                [PSCustomObject]@{ Title = 'Règles d''accès'; Type = 'Table'; Icon = 'lock_closed'; Columns = @('Identité', 'Droits', 'Type', 'Hérité', 'Propagation'); Rows = @($rows) }
            )
            Findings = $findings.ToArray()
        }
    }
    $stat = (& stat -c '%A|%a|%U|%G|%F' -- $Path 2>$null) -split '\|'
    $mode = [Convert]::ToInt32($stat[1], 8)
    $items = [ordered]@{ 'Chemin' = $item.FullName; 'Type' = $stat[4]; 'Propriétaire' = $stat[2]; 'Groupe' = $stat[3]; 'Mode' = '{0} ({1})' -f $stat[0], $stat[1] }
    if ($mode -band 0x800) { $items['SUID'] = 'Oui (s''exécute avec les droits du propriétaire)' }
    if ($mode -band 0x400) { $items['SGID'] = 'Oui' }
    if ($mode -band 0x200) { $items['Sticky bit'] = 'Oui (chacun ne supprime que ses fichiers)' }
    if (($mode -band 0x2) -and -not ($mode -band 0x200)) { $findings.Add((New-Finding 'warning' 'SEC-ACL-WEAK' "$Path est modifiable par tous les utilisateurs" "chmod o-w '$Path' (ou ajouter le sticky bit pour un dossier partagé : chmod +t).")) }
    $rows = @()
    if (Get-Command getfacl -ErrorAction SilentlyContinue) {
        $rows = foreach ($line in & getfacl -p --omit-header -- $Path 2>$null) {
            if ($line -match '^(default:)?(user|group|mask|other):([^:]*):(\S+)') { , @($(if ($Matches[1]) { 'Par défaut (héritée)' } else { 'Accès' }), @{ user = 'Utilisateur'; group = 'Groupe'; mask = 'Masque'; other = 'Autres' }[$Matches[2]], $(if ($Matches[3]) { $Matches[3] } elseif ($Matches[2] -in 'user', 'group') { '(propriétaire)' } else { '' }), $Matches[4]) }
        }
    }
    [PSCustomObject]@{
        Subtitle = '{0} · {1} · {2}:{3}' -f $Path, $stat[0], $stat[2], $stat[3]
        Sections = @(
            [PSCustomObject]@{ Title = 'Élément'; Type = 'KeyValue'; Icon = 'info'; Items = $items }
            [PSCustomObject]@{ Title = 'Entrées d''ACL (getfacl)'; Type = 'Table'; Icon = 'lock_closed'; Columns = @('Portée', 'Type', 'Qui', 'Droits'); Rows = @($rows) }
        )
        Findings = $findings.ToArray()
    }
}

# security_find_special_files (Linux) : SUID / SGID ou modifiables par tous, avec le paquet propriétaire.
function Find-SISpecialFiles {
    param(
        [ValidateSet('suid', 'writable')][string]$Kind = 'suid',
        [string]$Path = '/',
        [ValidateRange(1, 2000)][int]$Top = 300
    )
    if (-not $IsLinux) { throw 'Fonction disponible sous Linux uniquement.' }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Dossier introuvable : $Path" }
    $filter = if ($Kind -eq 'suid') { @('-type', 'f', '(', '-perm', '-4000', '-o', '-perm', '-2000', ')') } else { @('(', '-type', 'f', '-perm', '-0002', ')', '-o', '(', '-type', 'd', '-perm', '-0002', '!', '-perm', '-1000', ')') }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    # timeout : un arbre énorme ne bloque pas l'outil plus d'une minute. /proc et /sys sont exclus par -xdev.
    Write-Information "find $Path -xdev $($filter -join ' ')"
    Write-Progress -Activity 'Recherche de fichiers' -Status "Parcours de $Path (60 s au plus)…"
    $found = @(& timeout 60 find $Path -xdev @filter -printf '%m|%u|%g|%TY-%Tm-%Td|%p\n' 2>$null | Select-Object -First ($Top * 4))
    $partial = $LASTEXITCODE -eq 124
    $list = foreach ($line in $found) { $f = $line -split '\|', 5; [PSCustomObject]@{ Mode = $f[0]; Owner = $f[1]; Group = $f[2]; Date = $f[3]; Path = $f[4] } }
    $owners = Get-PackageOwners @($list.Path)
    $findings = [System.Collections.Generic.List[object]]::new()
    $rows = foreach ($l in $list | Sort-Object { [bool]$owners[$_.Path] }, Path | Select-Object -First $Top) {
        $pkg = $owners[$l.Path]
        if (-not $pkg -and $findings.Count -lt 20) {
            $findings.Add($(if ($Kind -eq 'suid') { New-Finding 'warning' 'SEC-SUID-UNPACKAGED' "Exécutable SUID/SGID hors paquet : $($l.Path) (propriétaire $($l.Owner))" 'Vérifier son origine ; s''il n''est pas nécessaire, retirer le bit : chmod u-s,g-s.' }
                    else { New-Finding 'info' 'SEC-WORLD-WRITABLE' "Modifiable par tous : $($l.Path)" "Retirer l'écriture pour les autres (chmod o-w) sauf besoin explicite." }))
        }
        , @($l.Path, $l.Mode, $l.Owner, $l.Group, $l.Date, ($pkg ?? 'hors paquet'))
    }
    if ($partial) { $findings.Add((New-Finding 'info' 'SEC-SCAN-PARTIAL' "Recherche arrêtée après 60 s : résultat partiel pour $Path" 'Relancer sur un dossier plus précis.')) }
    [PSCustomObject]@{
        Subtitle = '{0} fichier(s) {1} sous {2} · {3} hors paquet · {4:0.0} s' -f @($list).Count, $(if ($Kind -eq 'suid') { 'SUID/SGID' } else { 'modifiables par tous' }), $Path, @($list | Where-Object { -not $owners[$_.Path] }).Count, $watch.Elapsed.TotalSeconds
        Sections = @([PSCustomObject]@{ Title = $(if ($Kind -eq 'suid') { 'Fichiers SUID / SGID' } else { 'Fichiers et dossiers modifiables par tous' }); Type = 'Table'; Icon = 'lock_closed'; Columns = @('Chemin', 'Mode', 'Propriétaire', 'Groupe', 'Modifié le', 'Paquet'); Rows = @($rows) })
        Findings = $findings.ToArray()
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
function New-Change([string]$Target, [string]$Property, $Before, $After) {
    [PSCustomObject]@{ Target = $Target; Property = $Property; Before = $Before; After = $After }
}

# Antivirus pilotable : Microsoft Defender actif (Windows) ou ClamAV (Linux). Renvoie l'état, ou la raison d'un refus.
function Get-AntivirusTarget {
    $av = Get-AntivirusState
    if ($IsWindows) {
        $d = $av.Defender
        if (-not $d) { return @{ State = $av; Blocked = 'Microsoft Defender est absent ou ne répond pas.' } }
        $other = @($av.Products | Where-Object { $_.Enabled -and $_.Name -notmatch 'Defender' })
        if ($d.AMRunningMode -match 'Passive|Disabled|EDR' -or (-not $d.AntivirusEnabled -and $other)) {
            return @{ State = $av; Blocked = "Microsoft Defender n'est pas l'antivirus actif$(if ($other) { " ($($other[0].Name))" }) : utiliser l'interface de cet antivirus." }
        }
        return @{ State = $av; Blocked = $null }
    }
    if (-not $av.Clam) { return @{ State = $av; Blocked = 'Aucun antivirus pilotable : installer ClamAV (paquet clamav / clamav-update) pour activer ces actions.' } }
    @{ State = $av; Blocked = $null }
}

function Get-AntivirusSection($State) {
    $items = [ordered]@{}
    if ($IsWindows -and $State.Defender) {
        $d = $State.Defender
        $items['Antivirus'] = 'Microsoft Defender'
        $items['Signatures'] = "$($d.AntivirusSignatureVersion) · $(Format-Date $d.AntivirusSignatureLastUpdated)"
        $items['Dernière analyse rapide'] = if ($d.QuickScanEndTime) { Format-Date $d.QuickScanEndTime } else { 'jamais' }
        $items['Protection en temps réel'] = Yes $d.RealTimeProtectionEnabled
    }
    elseif ($State.Clam) {
        $items['Antivirus'] = "$($State.Clam.Version)"
        $items['Base de signatures'] = if ($State.Clam.Database) { Format-Date $State.Clam.Database } else { 'absente' }
        $items['Démon clamd'] = $State.Clam.Daemon ?? 'arrêté'
        $items['Mise à jour automatique'] = $State.Clam.Freshclam ?? 'non'
    }
    if ($items.Count -eq 0) { return $null }
    [PSCustomObject]@{ Title = 'Antivirus'; Type = 'KeyValue'; Icon = 'shield_checkmark'; Items = $items }
}

# Dossiers d'une analyse rapide sous Linux : là où arrivent et se lancent les fichiers de l'utilisateur.
function Get-QuickScanPaths {
    $desktop = & xdg-user-dir DESKTOP 2>$null
    $downloads = & xdg-user-dir DOWNLOAD 2>$null
    @($downloads, $desktop, (Join-Path $HOME '.local/bin'), (Join-Path $HOME '.config/autostart'), '/tmp', '/var/tmp', '/dev/shm') |
        Where-Object { $_ -and $_ -ne $HOME -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
}

# security_start_scan : analyse antivirus rapide (tâche longue).
# Windows : Start-MpScan -ScanType QuickScan (mémoire, démarrage, emplacements sensibles), puis menaces détectées depuis.
# Linux   : clamdscan (démon actif) ou clamscan sur Téléchargements, Bureau, ~/.local/bin, autostart, /tmp, /var/tmp.
function Start-SIAntivirusScan {
    param([switch]$DryRun)

    $target = Get-AntivirusTarget
    $state = $target.State
    $blocked = $target.Blocked
    $paths = if ($IsLinux) { @(Get-QuickScanPaths) } else { @() }
    if (-not $blocked -and $IsLinux -and -not $state.Clam.Database) { $blocked = 'La base de signatures ClamAV est absente : lancer d''abord security_update_signatures (ou freshclam).' }

    $section = Get-AntivirusSection $state
    $sections = @($section)
    if ($paths) { $sections += [PSCustomObject]@{ Title = 'Dossiers analysés'; Type = 'Table'; Icon = 'search'; Columns = @('Dossier'); Rows = @($paths | ForEach-Object { , @($_) }) } }
    $findings = @(New-Finding 'info' 'SEC-SCAN-DURATION' 'Analyse rapide : quelques minutes, le processeur et le disque seront sollicités pendant ce temps.' $null)
    $before = if ($IsWindows -and $state.Defender.QuickScanEndTime) { Format-Date $state.Defender.QuickScanEndTime } else { 'jamais' }
    if ($DryRun -or $blocked) {
        return New-ActionResult 'Une analyse antivirus rapide sera lancée' $sections $findings @(New-Change 'Antivirus' 'Dernière analyse rapide' $before 'maintenant') $blocked
    }

    $start = Get-Date
    $found = [System.Collections.Generic.List[object]]::new()
    if ($IsWindows) {
        Write-Information 'Start-MpScan -ScanType QuickScan'
        try { Start-MpScan -ScanType QuickScan -ErrorAction Stop } catch { throw "L'analyse n'a pas pu être lancée : $($_.Exception.Message)" }
        foreach ($t in @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object { $_.InitialDetectionTime -ge $start.AddMinutes(-1) })) {
            $name = (Get-MpThreat -ThreatID $t.ThreatID -ErrorAction SilentlyContinue).ThreatName
            $found.Add(@(($name ?? "menace $($t.ThreatID)"), (@($t.Resources) -join ', '), $(if ($t.ActionSuccess) { 'traitée' } else { 'à traiter' })))
        }
    }
    else {
        $scanner = if ($state.Clam.Daemon -and (Get-Command clamdscan -ErrorAction SilentlyContinue)) { @('clamdscan', '--multiscan', '--fdpass', '-i', '--no-summary') } else { @('clamscan', '-r', '-i', '--no-summary') }
        Write-Information "$($scanner -join ' ') $($paths -join ' ')"
        $n = 0
        $out = & $scanner[0] @($scanner[1..9]) @paths 2>&1 | ForEach-Object {
            $n++; if ($n % 25 -eq 0) { Write-Progress -Activity 'Analyse ClamAV' -Status "$n ligne(s) de sortie" }
            if ("$_" -match 'FOUND$|ERROR') { Write-Information "$_" }
            "$_"
        }
        # 0 : rien trouvé, 1 : menace(s) trouvée(s), 2 : erreur (souvent des fichiers illisibles, l'analyse continue).
        if ($LASTEXITCODE -ge 2 -and -not ($out -match 'FOUND$')) {
            $errors = @($out | Where-Object { $_ -match 'ERROR' } | Select-Object -First 3)
            if ($errors.Count -eq @($out).Count -or -not $out) { throw "ClamAV a échoué : $($out -join ' ')" }
        }
        foreach ($line in $out | Where-Object { $_ -match '^(.+?): (.+) FOUND$' }) {
            if ($line -match '^(.+?): (.+) FOUND$') { $found.Add(@($Matches[2], $Matches[1], 'à traiter')) }
        }
    }

    $duration = (Get-Date) - $start
    $result = @()
    if ($found.Count) {
        $result += New-Finding 'critical' 'SEC-AV-THREAT' "$($found.Count) menace(s) détectée(s) par l'analyse rapide." $(if ($IsWindows) { 'Ouvrir Sécurité Windows › Protection contre les virus pour confirmer leur suppression.' } else { 'Vérifier ces fichiers et les supprimer s''ils sont malveillants (ClamAV ne les supprime pas).' })
        $sections += [PSCustomObject]@{ Title = 'Menaces détectées'; Type = 'Table'; Icon = 'warning'; Columns = @('Menace', 'Fichier ou ressource', 'État'); Rows = $found.ToArray() }
    }
    $after = '{0} · {1} menace(s) · {2} min' -f (Format-Date (Get-Date)), $found.Count, [Math]::Round($duration.TotalMinutes, 1).ToString($script:Fr)
    $now = (Get-AntivirusTarget).State
    $sections[0] = Get-AntivirusSection $now
    New-ActionResult "Analyse rapide terminée · $($found.Count) menace(s)" $sections $result @(New-Change 'Antivirus' 'Dernière analyse rapide' $before $after) $null
}

# security_update_signatures : met à jour les signatures antivirus (tâche longue).
# Windows : Update-MpSignature. Linux : freshclam (root ; inutile si le service clamav-freshclam tourne déjà).
function Update-SIAntivirusSignatures {
    param([switch]$DryRun)

    $target = Get-AntivirusTarget
    $state = $target.State
    $blocked = $target.Blocked
    if (-not $blocked -and $IsLinux) {
        if (-not (Get-Command freshclam -ErrorAction SilentlyContinue)) { $blocked = 'freshclam est absent : installer le paquet clamav-update (Fedora) ou clamav-freshclam (Debian, Ubuntu).' }
        elseif ($state.Clam.Freshclam) { $blocked = "Le service $($state.Clam.Freshclam) met déjà les signatures à jour automatiquement (et verrouille la base)." }
        elseif (-not [Environment]::IsPrivilegedProcess) { $blocked = 'freshclam écrit dans /var/lib/clamav : relancer SysInfo avec sudo.' }
    }
    $before = if ($IsWindows -and $state.Defender) { "$($state.Defender.AntivirusSignatureVersion) ($(Format-Date $state.Defender.AntivirusSignatureLastUpdated))" }
              elseif ($state.Clam.Database) { Format-Date $state.Clam.Database } else { 'aucune' }
    $section = Get-AntivirusSection $state
    if ($DryRun -or $blocked) {
        return New-ActionResult 'Les signatures antivirus seront mises à jour' @($section) @() @(New-Change 'Antivirus' 'Signatures' $before 'dernière version disponible') $blocked
    }

    if ($IsWindows) {
        try { Update-MpSignature -ErrorAction Stop } catch { throw "La mise à jour a échoué : $($_.Exception.Message)" }
    }
    else {
        $out = & freshclam --stdout 2>&1 | ForEach-Object { Write-Information "$_"; "$_" }
        if ($LASTEXITCODE -ne 0) { throw "freshclam a échoué : $(($out | Select-Object -Last 3) -join ' ')" }
    }
    $now = (Get-AntivirusTarget).State
    $after = if ($IsWindows -and $now.Defender) { "$($now.Defender.AntivirusSignatureVersion) ($(Format-Date $now.Defender.AntivirusSignatureLastUpdated))" }
             elseif ($now.Clam.Database) { Format-Date $now.Clam.Database } else { 'aucune' }
    $findings = @()
    if ($after -eq $before) { $findings += New-Finding 'info' 'SEC-AV-ALREADY-CURRENT' 'Les signatures étaient déjà à jour.' $null }
    New-ActionResult "Signatures antivirus : $after" @(Get-AntivirusSection $now) $findings @(New-Change 'Antivirus' 'Signatures' $before $after) $null
}

# security_set_firewall : modifie le pare-feu.
#   enable / disable : Windows : profils (Set-NetFirewallProfile) ; Linux : ufw enable / disable, ou service firewalld.
#   allow_port       : ouvre un port entrant (Windows : règle « SysInfo » dans le groupe SysInfo ; firewalld : port de la
#                      zone par défaut, permanent ; ufw allow).
#   block_port       : Windows : règle de blocage SysInfo ; Linux : retire le port ouvert (ufw deny).
#   remove_rule      : Windows : supprime une règle du groupe SysInfo (jamais les autres) ; Linux : retire le port.
function Set-SIFirewall {
    param(
        [Parameter(Mandatory)][ValidateSet('enable', 'disable', 'allow_port', 'block_port', 'remove_rule')][string]$Operation,
        [ValidateRange(1, 65535)][int]$Port,
        [ValidateSet('tcp', 'udp')][string]$Protocol = 'tcp',
        [ValidateSet('all', 'domain', 'private', 'public')][string]$FirewallProfile = 'all',
        [string]$RuleName,
        [switch]$DryRun
    )
    $blocked = $null; $changes = @(); $undo = $null
    $findings = [System.Collections.Generic.List[object]]::new()
    $needsPort = $Operation -in 'allow_port', 'block_port' -or ($Operation -eq 'remove_rule' -and $IsLinux)
    if ($needsPort -and -not $Port) { return New-ActionResult 'Pare-feu' @() @() @() "Le paramètre port est obligatoire pour $Operation." }
    $spec = "$Port/$Protocol"
    # Port couvert par une plage ouverte (« 1025-65535/tcp ») ou par un port seul ; renvoie l'élément trouvé.
    $covering = { param($List) foreach ($p in ($List -split '\s+')) { if ($p -eq $spec) { return $p }; if ($p -match "^(\d+)-(\d+)/$Protocol$" -and $Port -ge [int]$Matches[1] -and $Port -le [int]$Matches[2]) { return $p } } }
    $items = [ordered]@{ Opération = $Operation }

    if ($IsWindows) {
        $profiles = if ($FirewallProfile -eq 'all') { @('Domain', 'Private', 'Public') } else { @((Get-Culture).TextInfo.ToTitleCase($FirewallProfile)) }
        $state = @(Get-NetFirewallProfile -Name $profiles -ErrorAction SilentlyContinue)
        $items['Profils'] = ($state | ForEach-Object { '{0} : {1}' -f $_.Name, $(if ($_.Enabled) { 'actif' } else { 'désactivé' }) }) -join ' · '
        switch ($Operation) {
            { $_ -in 'enable', 'disable' } {
                $want = $Operation -eq 'enable'
                $todo = @($state | Where-Object { [bool]$_.Enabled -ne $want })
                if (-not $todo) { $blocked = "Le pare-feu est déjà $(if ($want) { 'actif' } else { 'désactivé' }) sur ces profils." }
                $changes = @($todo | ForEach-Object { New-Change "Profil $($_.Name)" 'Pare-feu' $(if ($want) { 'désactivé' } else { 'actif' }) $(if ($want) { 'actif' } else { 'désactivé' }) })
                $undo = @{ Function = 'set_firewall'; Parameters = @{ operation = $(if ($want) { 'disable' } else { 'enable' }); firewallProfile = $FirewallProfile } }
                if (-not $want) { $findings.Add((New-Finding 'critical' 'SEC-FIREWALL-DISABLING' 'Sans pare-feu, tous les services en écoute deviennent joignables depuis le réseau.' 'Préférer l''ouverture d''un seul port (allow_port).')) }
            }
            { $_ -in 'allow_port', 'block_port' } {
                $action = if ($Operation -eq 'allow_port') { 'Allow' } else { 'Block' }
                $RuleName = "SysInfo - $($Protocol.ToUpper()) $Port ($(if ($action -eq 'Allow') { 'autoriser' } else { 'bloquer' }))"
                if (Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue) { $blocked = "La règle « $RuleName » existe déjà." }
                $items['Règle'] = "$RuleName · entrant · profils $FirewallProfile"
                $changes = @(New-Change $RuleName 'Règle' 'absente' 'créée')
                $undo = @{ Function = 'set_firewall'; Parameters = @{ operation = 'remove_rule'; ruleName = $RuleName } }
                if ($action -eq 'Allow' -and $FirewallProfile -in 'all', 'public') { $findings.Add((New-Finding 'warning' 'SEC-FIREWALL-PUBLIC' "Le port $spec sera ouvert aussi sur les réseaux publics (Wi-Fi d'hôtel, de gare…)." 'Limiter au profil private si l''accès ne sert qu''à la maison ou au bureau.')) }
            }
            'remove_rule' {
                if (-not $RuleName) { $blocked = 'Le paramètre ruleName est obligatoire (règles du groupe SysInfo : security_get_firewall_rules, filtre SysInfo).' }
                else {
                    $rule = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue | Select-Object -First 1
                    if (-not $rule) { $blocked = "Aucune règle « $RuleName »." }
                    elseif ($rule.Group -ne 'SysInfo') { $blocked = "« $RuleName » n'a pas été créée par SysInfo : SysInfo ne supprime que ses propres règles." }
                    $changes = @(New-Change $RuleName 'Règle' 'présente' 'supprimée')
                }
            }
        }
    }
    else {
        $fw = Get-LinuxFirewall
        $items['Pare-feu'] = if ($fw.Tool) { "$($fw.Tool) · $(if ($fw.Active) { 'actif' } else { 'inactif' })" } else { 'aucun' }
        if (-not $fw.Tool) { $blocked = 'Aucun pare-feu géré (firewalld ou ufw) sur ce système.' }
        elseif ($fw.Tool -eq 'nftables') { $blocked = 'Pare-feu nftables écrit à la main : SysInfo ne le modifie pas.' }
        $zone = ($fw.Zones | Where-Object Default | Select-Object -First 1) ?? ($fw.Zones | Select-Object -First 1)
        if ($zone) { $items['Zone'] = "$($zone.Name) (ports ouverts : $(if ($zone.Ports) { $zone.Ports } else { 'aucun' }) ; services : $($zone.Services))" }
        if (-not $blocked) {
            switch ($Operation) {
                { $_ -in 'enable', 'disable' } {
                    $want = $Operation -eq 'enable'
                    if ($fw.Active -eq $want) { $blocked = "Le pare-feu $($fw.Tool) est déjà $(if ($want) { 'actif' } else { 'inactif' })." }
                    $changes = @(New-Change $fw.Tool 'Pare-feu' $(if ($fw.Active) { 'actif' } else { 'inactif' }) $(if ($want) { 'actif' } else { 'inactif' }))
                    $undo = @{ Function = 'set_firewall'; Parameters = @{ operation = $(if ($want) { 'disable' } else { 'enable' }) } }
                    if (-not $want) { $findings.Add((New-Finding 'critical' 'SEC-FIREWALL-DISABLING' 'Sans pare-feu, tous les services en écoute deviennent joignables depuis le réseau.' 'Préférer l''ouverture d''un seul port (allow_port).')) }
                }
                'allow_port' {
                    $open = if ($fw.Tool -eq 'firewalld') { & $covering $zone.Ports } else { $null }
                    if ($open) { $blocked = "Le port $spec est déjà ouvert dans la zone $($zone.Name) ($open)." }
                    $changes = @(New-Change $(if ($zone) { "Zone $($zone.Name)" } else { $fw.Tool }) "Port $spec" 'fermé' 'ouvert')
                    $undo = @{ Function = 'set_firewall'; Parameters = @{ operation = 'remove_rule'; port = $Port; protocol = $Protocol } }
                }
                { $_ -in 'block_port', 'remove_rule' } {
                    $open = if ($fw.Tool -eq 'firewalld') { & $covering $zone.Ports } else { $spec }
                    if (-not $open) { $blocked = "Le port $spec n'est pas ouvert dans la zone $($zone.Name) (déjà fermé ; un service nommé peut l'ouvrir : voir security_get_firewall_rules)." }
                    elseif ($open -ne $spec) { $blocked = "Le port $spec est ouvert par la plage $open de la zone $($zone.Name) : SysInfo ne retire que des ports seuls (firewall-cmd --remove-port=$open pour fermer la plage)." }
                    $changes = @(New-Change $(if ($zone) { "Zone $($zone.Name)" } else { $fw.Tool }) "Port $spec" 'ouvert' 'fermé')
                    $undo = @{ Function = 'set_firewall'; Parameters = @{ operation = 'allow_port'; port = $Port; protocol = $Protocol } }
                }
            }
        }
    }
    if (-not $blocked -and -not (Test-Elevated)) { $blocked = "Droits $(if ($IsWindows) { 'administrateur' } else { 'root' }) requis : relancer SysInfo $(if ($IsWindows) { 'en administrateur' } else { 'avec sudo -E' })." }
    $section = [PSCustomObject]@{ Title = 'Pare-feu'; Type = 'KeyValue'; Icon = 'shield_checkmark'; Items = $items }
    $subtitle = switch ($Operation) { 'enable' { 'Le pare-feu sera activé' } 'disable' { 'Le pare-feu sera désactivé' } 'allow_port' { "Le port $spec sera ouvert en entrée" } 'block_port' { "Le port $spec sera bloqué en entrée" } 'remove_rule' { 'La règle sera supprimée' } }
    if ($DryRun -or $blocked) { return New-ActionResult $subtitle $section $findings $changes $blocked }

    if ($IsWindows) {
        switch ($Operation) {
            'enable' { Set-NetFirewallProfile -Name $profiles -Enabled True -ErrorAction Stop }
            'disable' { Set-NetFirewallProfile -Name $profiles -Enabled False -ErrorAction Stop }
            'remove_rule' { Remove-NetFirewallRule -DisplayName $RuleName -ErrorAction Stop }
            default {
                $ruleProfile = if ($FirewallProfile -eq 'all') { 'Any' } else { (Get-Culture).TextInfo.ToTitleCase($FirewallProfile) }
                New-NetFirewallRule -DisplayName $RuleName -Group 'SysInfo' -Direction Inbound -Action $(if ($Operation -eq 'allow_port') { 'Allow' } else { 'Block' }) -Protocol $Protocol.ToUpper() -LocalPort $Port -Profile $ruleProfile -ErrorAction Stop | Out-Null
            }
        }
    }
    elseif ($fw.Tool -eq 'ufw') {
        $args1 = switch ($Operation) { 'enable' { @('--force', 'enable') } 'disable' { @('disable') } 'allow_port' { @('allow', $spec) } 'block_port' { @('deny', $spec) } 'remove_rule' { @('delete', 'allow', $spec) } }
        $out = & ufw @args1 2>&1
        if ($LASTEXITCODE -ne 0) { throw "ufw a échoué : $($out -join ' ')" }
    }
    else {
        if ($Operation -in 'enable', 'disable') {
            $out = & systemctl $(if ($Operation -eq 'enable') { 'start' } else { 'stop' }) firewalld 2>&1
        }
        else {
            $flag = if ($Operation -eq 'allow_port') { "--add-port=$spec" } else { "--remove-port=$spec" }
            $out = & firewall-cmd --permanent "--zone=$($zone.Name)" $flag 2>&1
            if ($LASTEXITCODE -eq 0) { $out = & firewall-cmd --reload 2>&1 }
        }
        if ($LASTEXITCODE -ne 0) { throw "firewalld a échoué : $($out -join ' ')" }
    }
    $done = New-ActionResult ($subtitle -replace ' sera ', ' est ') $section @() $changes $null
    if ($undo) { $done | Add-Member Undo $undo }
    $done
}

#endregion

Export-ModuleMember -Function Get-ModuleData, Get-SILogons, Get-SIFirewallRules, Find-SIPersistence, Get-SICertificates, Get-SIAcl, Find-SISpecialFiles, Start-SIAntivirusScan, Update-SIAntivirusSignatures, Set-SIFirewall
