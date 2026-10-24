# Module Domaine & Configuration : jointure (domaine Active Directory, Entra ID, realm Linux), contrôleur joignable,
# canal sécurisé, stratégies de groupe (dernière application, erreurs), gestion MDM / Intune, LAPS (jamais le mot de
# passe), variables d'environnement et PATH (doublons, chemins absents ou dangereux), paramètres noyau (sysctl) et
# clés de registre surveillés.
#
# Sources
#   Windows : Win32_ComputerSystem, dsregcmd /status, nltest /sc_query, registre (Group Policy\State, Enrollments,
#             stratégies LAPS et état LAPS, Windows Update, télémétrie, chemins longs, Winlogon), journal
#             GroupPolicy/Operational, gpresult /x, gpupdate /force.
#   Linux   : realm list, sssd (systemctl), /etc/krb5.conf, klist -s, /proc/sys (sysctl), /etc/environment.
# Contrôleur joignable : résolution du nom du domaine puis ports 389 (LDAP) et 88 (Kerberos), 1,5 s au plus.
# Jamais exposé : mot de passe LAPS, mot de passe d'ouverture automatique, valeurs des variables qui ressemblent à
# des secrets (TOKEN, SECRET, PASSWORD, KEY…).

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

function Get-RegValue([string]$Path, [string]$Name) { (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue).$Name }

# Valeur d'une variable d'environnement, masquée si son nom ou son contenu évoque un secret.
function Protect-Value([string]$Name, [string]$Value) {
    if ($Name -match '(?i)(token|secret|passw|pwd$|^pwd_|api_?key|access_?key|private|credential|auth|session|cookie|signature|_key$)' -and $Name -ne 'PWD') { return '*** (masqué)' }
    $Value = $Value -replace '(?i)(\w+://[^/\s:@]+:)[^@\s/]+@', '$1***@'
    if ($Value.Length -gt 200) { $Value.Substring(0, 200) + '…' } else { $Value }
}

# Hôte joignable sur l'un des ports (1,5 s au plus par port).
function Test-Ports([string]$HostName, [int[]]$Ports) {
    foreach ($port in $Ports) {
        $c = [System.Net.Sockets.TcpClient]::new()
        try { if ($c.ConnectAsync($HostName, $port).Wait(1500) -and $c.Connected) { return $port } } catch { } finally { $c.Dispose() }
    }
    $null
}

#endregion

#region Jointure

function Get-JoinState {
    Get-Cached 'join' 300 {
        $r = [ordered]@{ Kind = 'Groupe de travail'; Domain = $null; Workgroup = $null; Tenant = $null; Entra = $false; Ad = $false; Workplace = $false; Mdm = $null; MdmProvider = $null
            SecureChannel = $null; Reachable = $null; ReachPort = $null; Kerberos = $null; Realm = $null; Sssd = $null; Software = $null }
        if ($IsWindows) {
            $cs = Get-CimInstance Win32_ComputerSystem
            $r.Ad = [bool]$cs.PartOfDomain
            if ($r.Ad) { $r.Domain = $cs.Domain } else { $r.Workgroup = $cs.Workgroup }
            $ds = @{}
            foreach ($line in Invoke-Tool dsregcmd @('/status')) { if ($line -match '^\s*(\w+)\s*:\s*(.*)$') { $ds[$Matches[1]] = $Matches[2].Trim() } }
            $r.Entra = $ds.AzureAdJoined -eq 'YES'
            $r.Workplace = $ds.WorkplaceJoined -eq 'YES'
            $r.Tenant = $ds.TenantName
            if ($ds.MdmUrl) { $r.Mdm = $ds.MdmUrl }
            # Inscriptions MDM : HKLM\SOFTWARE\Microsoft\Enrollments\<GUID> (ProviderID « MS DM Server » = Intune, EnrollmentState 1 = inscrit).
            foreach ($e in Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction SilentlyContinue) {
                $p = Get-ItemProperty $e.PSPath -ErrorAction SilentlyContinue
                if ($p.ProviderID -and $p.EnrollmentState -eq 1) { $r.MdmProvider = if ($p.ProviderID -eq 'MS DM Server') { 'Microsoft Intune' } else { $p.ProviderID }; break }
            }
            $r.Kind = if ($r.Ad -and $r.Entra) { 'Hybride (Active Directory + Entra ID)' } elseif ($r.Ad) { 'Domaine Active Directory' } elseif ($r.Entra) { 'Entra ID' } elseif ($r.Workplace) { 'Groupe de travail (compte professionnel inscrit)' } else { 'Groupe de travail' }
            if ($r.Ad) {
                $sc = (Invoke-Tool nltest @("/sc_query:$($r.Domain)")) -join ' '
                $r.SecureChannel = if ($sc -match 'NERR_Success|ERROR_SUCCESS|Status = 0 0x0') { $true } elseif ($sc) { $false } else { $null }
            }
        }
        else {
            $text = @(Invoke-Tool realm @('list'))
            if ($text.Count) {
                $r.Realm = $text[0].Trim()
                foreach ($line in $text) {
                    if ($line -match '^\s+domain-name:\s*(.+)$') { $r.Domain = $Matches[1].Trim() }
                    if ($line -match '^\s+server-software:\s*(.+)$') { $r.Software = $Matches[1].Trim() }
                }
                $r.Domain = $r.Domain ?? $r.Realm
                $r.Kind = if ($r.Software -eq 'active-directory') { 'Domaine Active Directory (realmd)' } elseif ($r.Software -eq 'ipa') { 'Domaine FreeIPA (realmd)' } else { 'Domaine (realmd)' }
                $r.Ad = $true
            }
            $r.Sssd = "$(Invoke-Tool systemctl @('is-active', 'sssd'))".Trim()
            if (Test-Tool klist) { & klist -s 2>$null; $r.Kerberos = $LASTEXITCODE -eq 0 }
            if (Test-Tool intune-portal) { $r.MdmProvider = 'Microsoft Intune (intune-portal)' }
        }
        if ($r.Domain -and $r.Ad) {
            $r.ReachPort = Test-Ports $r.Domain @(389, 88)
            $r.Reachable = [bool]$r.ReachPort
        }
        [PSCustomObject]$r
    }
}

# Stratégies de groupe (Windows) : dernière application (ordinateur et utilisateur) et erreurs des 7 derniers jours.
function Get-GpoState {
    if (-not $IsWindows) { return $null }
    Get-Cached 'gpo' 300 {
        $time = {
            param($path)
            $hi = Get-RegValue $path 'EndTimeHi'; $lo = Get-RegValue $path 'EndTimeLo'
            if ($null -ne $hi -and $null -ne $lo) { [datetime]::FromFileTime(([int64][uint32]$hi -shl 32) -bor [uint32]$lo) } else { $null }
        }
        $base = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\State'
        $machine = & $time "$base\Machine\Extension-List\{00000000-0000-0000-0000-000000000000}"
        $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $user = & $time "$base\$sid\Extension-List\{00000000-0000-0000-0000-000000000000}"
        $errors = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-GroupPolicy/Operational'; Level = 1, 2; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 50 -ErrorAction SilentlyContinue)
        [PSCustomObject]@{ Machine = $machine; User = $user; Errors = $errors.Count; LastError = ($errors | Select-Object -First 1 | ForEach-Object { ($_.Message -split "`r?`n")[0] }) }
    }
}

# LAPS (Windows) : configuré, annuaire de sauvegarde, dernière rotation. Jamais le mot de passe.
function Get-LapsState {
    if (-not $IsWindows) { return $null }
    Get-Cached 'laps' 600 {
        $r = [ordered]@{ Kind = $null; Directory = $null; LastRotation = $null; AgeDays = $null }
        foreach ($p in 'HKLM:\SOFTWARE\Microsoft\Policies\LAPS', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\LAPS') {
            $dir = Get-RegValue $p 'BackupDirectory'
            if ($null -ne $dir) { $r.Kind = 'Windows LAPS'; $r.Directory = @{ 0 = 'désactivé'; 1 = 'Entra ID'; 2 = 'Active Directory' }[[int]$dir]; $r.AgeDays = Get-RegValue $p 'PasswordAgeDays'; break }
        }
        if (-not $r.Kind -and (Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft Services\AdmPwd' 'AdmPwdEnabled') -eq 1) { $r.Kind = 'LAPS hérité (AdmPwd)'; $r.Directory = 'Active Directory' }
        $last = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\LAPS\State' 'LastPasswordUpdateTime'
        if ($last) { $r.LastRotation = [datetime]::FromFileTime([int64]$last) }
        [PSCustomObject]$r
    }
}

#endregion

#region Environnement et paramètres

# Entrées du PATH (processus SysInfo ; Windows : aussi machine et utilisateur) : ordre, chemin, état.
function Get-PathEntries {
    $sep = [System.IO.Path]::PathSeparator
    $scopes = [System.Collections.Generic.List[object]]::new()
    if ($IsWindows) {
        $scopes.Add(@('Machine', [Environment]::GetEnvironmentVariable('Path', 'Machine')))
        $scopes.Add(@('Utilisateur', [Environment]::GetEnvironmentVariable('Path', 'User')))
    }
    else { $scopes.Add(@('Session', $env:PATH)) }
    $seen = @{}
    $i = 0
    foreach ($scope in $scopes) {
        foreach ($raw in "$($scope[1])" -split [regex]::Escape($sep)) {
            if ($raw -eq '' ) { $i++; [PSCustomObject]@{ Rank = $i; Scope = $scope[0]; Path = '(vide)'; State = 'vide : équivaut au dossier courant'; Problem = 'empty' }; continue }
            $i++
            $path = [Environment]::ExpandEnvironmentVariables($raw).TrimEnd('\', '/')
            if ($path -eq '') { $path = '/' }
            $key = if ($IsWindows) { $path.ToLowerInvariant() } else { $path }
            $state = 'ok'; $problem = $null
            if (-not [System.IO.Path]::IsPathRooted($path)) { $state = 'relatif : dépend du dossier courant'; $problem = 'relative' }
            elseif ($seen.ContainsKey($key)) { $state = "doublon (déjà en position $($seen[$key]))"; $problem = 'duplicate' }
            elseif (-not [System.IO.Directory]::Exists($path)) { $state = 'absent'; $problem = 'missing' }
            elseif ($IsLinux) {
                # Dossier modifiable par tous (sans sticky bit) : n'importe qui peut y déposer une commande.
                $mode = (Get-Item -LiteralPath $path -ErrorAction SilentlyContinue).UnixFileMode
                if ($mode -and ($mode.HasFlag([System.IO.UnixFileMode]::OtherWrite)) -and -not $mode.HasFlag([System.IO.UnixFileMode]::StickyBit)) { $state = 'modifiable par tous'; $problem = 'writable' }
            }
            if (-not $seen.ContainsKey($key)) { $seen[$key] = $i }
            [PSCustomObject]@{ Rank = $i; Scope = $scope[0]; Path = $path; State = $state; Problem = $problem }
        }
    }
}

# Paramètres surveillés : clé, valeur, valeur conseillée, rôle, gravité si différent ; Linux : sysctl.
$script:Sysctls = @(
    @{ Key = 'kernel.randomize_va_space'; Want = '2'; Role = 'Adresses mémoire aléatoires (ASLR)'; Severity = 'warning' }
    @{ Key = 'kernel.kptr_restrict'; Want = '1'; Role = 'Masque les adresses du noyau aux utilisateurs'; Accept = '1', '2' }
    @{ Key = 'kernel.dmesg_restrict'; Want = '1'; Role = 'Journal du noyau réservé aux administrateurs' }
    @{ Key = 'kernel.yama.ptrace_scope'; Want = '1'; Role = 'Un programme ne peut pas espionner un autre programme (ptrace)'; Accept = '1', '2', '3' }
    @{ Key = 'kernel.unprivileged_bpf_disabled'; Want = '1'; Role = 'eBPF réservé aux administrateurs'; Accept = '1', '2' }
    @{ Key = 'fs.protected_symlinks'; Want = '1'; Role = 'Protège des liens symboliques piégés (/tmp)'; Severity = 'warning' }
    @{ Key = 'fs.protected_hardlinks'; Want = '1'; Role = 'Protège des liens physiques piégés'; Severity = 'warning' }
    @{ Key = 'fs.protected_fifos'; Want = '1'; Role = 'Protège les tubes nommés dans les dossiers partagés'; Accept = '1', '2' }
    @{ Key = 'fs.protected_regular'; Want = '1'; Role = 'Protège les fichiers dans les dossiers partagés'; Accept = '1', '2' }
    @{ Key = 'fs.suid_dumpable'; Want = '0'; Role = 'Pas de vidage mémoire des programmes privilégiés'; Accept = '0', '2' }
    @{ Key = 'net.ipv4.ip_forward'; Want = '0'; Role = 'Routage IPv4 (normal avec Docker, libvirt, un VPN ou un routeur)'; Context = 'forward' }
    @{ Key = 'net.ipv4.conf.all.accept_redirects'; Want = '0'; Role = 'Refuse les redirections ICMP' }
    @{ Key = 'net.ipv4.conf.all.send_redirects'; Want = '0'; Role = 'N''envoie pas de redirections ICMP'; Context = 'forward' }
    @{ Key = 'net.ipv4.conf.all.accept_source_route'; Want = '0'; Role = 'Refuse le routage par la source' }
    @{ Key = 'net.ipv4.tcp_syncookies'; Want = '1'; Role = 'Protection contre l''inondation SYN' }
    @{ Key = 'net.ipv6.conf.all.accept_redirects'; Want = '0'; Role = 'Refuse les redirections ICMPv6' }
    @{ Key = 'kernel.sysrq'; Want = '176'; Role = 'Touches magiques SysRq (176 = synchro, démontage, redémarrage seulement)'; Accept = '0', '16', '176', '128', '144', '160' }
    @{ Key = 'vm.swappiness'; Role = 'Tendance à utiliser le swap (60 par défaut)' }
    @{ Key = 'vm.overcommit_memory'; Role = 'Surréservation de la mémoire (0 = heuristique)' }
    @{ Key = 'fs.inotify.max_user_watches'; Role = 'Fichiers surveillables (IDE, synchronisation)' }
    @{ Key = 'vm.max_map_count'; Role = 'Zones mémoire par processus (jeux, Elasticsearch)' }
)

function Get-WatchedSettings {
    Get-Cached 'settings' 300 {
        if ($IsLinux) {
            $forwardOk = (Test-Path /var/run/docker.sock) -or (Test-Tool virsh) -or (Test-Tool podman) -or (Test-Path /sys/class/net/wg0) -or (Test-Path /sys/class/net/tun0)
            foreach ($s in $script:Sysctls) {
                $value = Read-Text "/proc/sys/$($s.Key -replace '\.', '/')"
                if ($null -eq $value) { continue }
                $accept = if ($s.Accept) { $s.Accept } elseif ($s.Want) { @($s.Want) } else { $null }
                $bad = $accept -and $value -notin $accept -and -not ($s.Context -eq 'forward' -and $forwardOk)
                [PSCustomObject]@{ Key = $s.Key; Value = $value; Want = $s.Want; Role = $s.Role; Bad = $bad; Severity = $s.Severity ?? 'info' }
            }
            return
        }
        $wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
        $items = @(
            @{ Key = 'Chemins longs (LongPathsEnabled)'; Value = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'LongPathsEnabled'; Want = '1'; Role = 'Chemins de plus de 260 caractères' }
            @{ Key = 'Serveur WSUS (WUServer)'; Value = Get-RegValue $wu 'WUServer'; Want = $null; Role = 'Mises à jour depuis un serveur de l''entreprise' }
            @{ Key = 'Mises à jour automatiques désactivées (NoAutoUpdate)'; Value = Get-RegValue "$wu\AU" 'NoAutoUpdate'; Want = '0'; Role = 'Windows Update automatique'; Severity = 'warning'; Code = 'CFG-WU-DISABLED' }
            @{ Key = 'Télémétrie (AllowTelemetry)'; Value = Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry'; Want = $null; Role = 'Données de diagnostic (0 = sécurité, 1 = requises, 3 = facultatives)' }
            @{ Key = 'Ouverture de session automatique (AutoAdminLogon)'; Value = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' 'AutoAdminLogon'; Want = '0'; Role = 'Session ouverte sans mot de passe au démarrage'; Severity = 'warning'; Code = 'CFG-AUTOLOGON' }
            @{ Key = 'Exécution automatique (NoDriveTypeAutoRun)'; Value = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoDriveTypeAutoRun'; Want = '255'; Role = 'Lancement automatique des supports amovibles (255 = jamais)' }
        )
        foreach ($s in $items) {
            if ($null -eq $s.Value) { continue }
            $value = "$($s.Value)"
            [PSCustomObject]@{ Key = $s.Key; Value = $value; Want = $s.Want; Role = $s.Role; Bad = $s.Want -and $value -ne $s.Want; Severity = $s.Severity ?? 'info'; Code = $s.Code }
        }
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

    # Jointure
    $j = Invoke-Block 'Jointure' { Get-JoinState }
    $gpo = Invoke-Block 'Stratégies de groupe' { Get-GpoState }
    $laps = Invoke-Block 'LAPS' { Get-LapsState }
    if ($j) {
        $items = [ordered]@{ 'Type' = $j.Kind }
        if ($j.Domain) { $items['Domaine'] = $j.Domain }
        if ($j.Workgroup) { $items['Groupe de travail'] = $j.Workgroup }
        if ($j.Tenant) { $items['Locataire Entra ID'] = $j.Tenant }
        if ($null -ne $j.Reachable) { $items['Contrôleur de domaine'] = if ($j.Reachable) { "joignable (port $($j.ReachPort))" } else { 'injoignable (ports 389 et 88)' } }
        if ($null -ne $j.SecureChannel) { $items['Canal sécurisé'] = if ($j.SecureChannel) { 'valide' } else { 'rompu' } }
        if ($j.Sssd -and $j.Ad) { $items['sssd'] = $j.Sssd }
        if ($null -ne $j.Kerberos -and $j.Ad) { $items['Ticket Kerberos'] = if ($j.Kerberos) { 'valide' } else { 'aucun' } }
        $items['Gestion MDM'] = $j.MdmProvider ?? $(if ($j.Mdm) { $j.Mdm } else { 'aucune' })
        if ($gpo) {
            $items['Stratégies appliquées (ordinateur)'] = Format-Date $gpo.Machine
            $items['Stratégies appliquées (utilisateur)'] = Format-Date $gpo.User
            $items['Erreurs de stratégies (7 jours)'] = $gpo.Errors
        }
        if ($laps) { $items['LAPS'] = if ($laps.Kind) { '{0} · {1}{2}' -f $laps.Kind, $laps.Directory, $(if ($laps.LastRotation) { " · rotation le $(Format-Date $laps.LastRotation)" } else { '' }) } else { 'non configuré' } }
        $sections.Add([PSCustomObject]@{ Title = 'Jointure et gestion'; Type = 'KeyValue'; Icon = 'globe'; Items = $items })

        if ($j.Ad -and $j.Reachable -eq $false) { $findings.Add((New-Finding 'warning' 'CFG-DC-UNREACHABLE' "Aucun contrôleur du domaine $($j.Domain) n'est joignable." 'Vérifier le réseau, le VPN et le DNS (le nom du domaine doit résoudre vers les contrôleurs) : ouverture de session et stratégies en dépendent.')) }
        if ($j.SecureChannel -eq $false) { $findings.Add((New-Finding 'critical' 'CFG-SECURE-CHANNEL' "Le canal sécurisé avec le domaine $($j.Domain) est rompu : les comptes du domaine ne peuvent plus ouvrir de session sur ce poste." 'Réparer la relation d''approbation (Test-ComputerSecureChannel -Repair, ou retirer puis rejoindre le domaine), en administrateur du domaine.')) }
        if ($IsLinux -and $j.Ad -and $j.Sssd -and $j.Sssd -ne 'active') { $findings.Add((New-Finding 'warning' 'CFG-SSSD-DOWN' 'sssd est arrêté : les comptes du domaine ne peuvent pas se connecter.' 'Démarrer sssd (systemctl start sssd) et voir son journal.')) }
        if ($gpo -and $j.Ad -and $gpo.Machine -and ((Get-Date) - $gpo.Machine).TotalDays -ge 7) { $findings.Add((New-Finding 'warning' 'CFG-GPO-OLD' ('Stratégies de groupe appliquées pour la dernière fois le {0}.' -f (Format-Date $gpo.Machine)) 'Vérifier l''accès au domaine puis forcer l''application (domain_force_gpupdate).')) }
        if ($gpo.Errors -ge 3) { $findings.Add((New-Finding 'warning' 'CFG-GPO-ERRORS' ("{0} erreur(s) d'application des stratégies en 7 jours (dernière : {1})." -f $gpo.Errors, $gpo.LastError) 'Voir le détail (domain_get_gpo) et le journal GroupPolicy/Operational.')) }
        if ($IsWindows -and $j.Ad -and $laps -and -not $laps.Kind) { $findings.Add((New-Finding 'info' 'CFG-LAPS-OFF' 'Poste du domaine sans LAPS : le mot de passe administrateur local est peut-être le même sur tous les postes.' 'Déployer Windows LAPS par stratégie de groupe ou Intune.')) }
        if ($laps.LastRotation -and ((Get-Date) - $laps.LastRotation).TotalDays -gt [Math]::Max(60, 2 * [int]($laps.AgeDays ?? 30))) { $findings.Add((New-Finding 'warning' 'CFG-LAPS-OLD' ('Le mot de passe LAPS n''a pas changé depuis le {0}.' -f (Format-Date $laps.LastRotation)) 'Vérifier l''accès à l''annuaire et le journal LAPS (Get-LapsDiagnostics).')) }
    }

    # PATH
    $path = @(Invoke-Block 'PATH' { Get-PathEntries })
    if ($path.Count) {
        $sections.Add([PSCustomObject]@{ Title = 'PATH'; Type = 'Table'; Icon = 'arrow_routing'; Columns = @('Ordre', 'Portée', 'Dossier', 'État'); Rows = @($path | ForEach-Object { , @($_.Rank, $_.Scope, $_.Path, $_.State) }) })
        $dup = @($path | Where-Object Problem -eq 'duplicate'); $missing = @($path | Where-Object Problem -eq 'missing')
        if ($dup.Count) { $findings.Add((New-Finding 'info' 'CFG-PATH-DUPLICATE' ('{0} dossier(s) en double dans le PATH : {1}.' -f $dup.Count, (($dup.Path | Select-Object -Unique) -join ', ')) 'Retirer les doublons (fichier de profil du shell, ou Variables d''environnement sous Windows) : sans risque, la recherche des commandes est plus rapide.')) }
        if ($missing.Count) { $findings.Add((New-Finding 'info' 'CFG-PATH-MISSING' ('{0} dossier(s) du PATH n''existent pas : {1}.' -f $missing.Count, (($missing.Path | Select-Object -First 5) -join ', ')) 'Les retirer du PATH (logiciel désinstallé).')) }
        foreach ($p in $path | Where-Object { $_.Problem -in 'writable', 'relative', 'empty' }) {
            $findings.Add((New-Finding 'warning' 'CFG-PATH-UNSAFE' ('Entrée du PATH dangereuse : {0} ({1}).' -f $p.Path, $p.State) 'La retirer : une commande piégée déposée là serait lancée à la place de la vraie.'))
        }
    }

    # Paramètres surveillés
    $settings = @(Invoke-Block 'Paramètres' { Get-WatchedSettings })
    if ($settings.Count) {
        $sections.Add([PSCustomObject]@{ Title = $(if ($IsLinux) { 'Paramètres du noyau surveillés (sysctl)' } else { 'Clés de registre surveillées' }); Type = 'Table'; Icon = 'settings'; Columns = @('Paramètre', 'Valeur', 'Conseillé', 'Écart', 'Rôle')
                Rows = @($settings | ForEach-Object { , @($_.Key, $_.Value, $_.Want, $(if ($_.Bad) { 'oui' } else { '' }), $_.Role) }) })
        foreach ($s in $settings | Where-Object Bad) {
            $code = $s.Code ?? 'CFG-SYSCTL'
            $msg = if ($code -eq 'CFG-AUTOLOGON') { "L'ouverture de session automatique est activée : le mot de passe est enregistré dans le registre et la session s'ouvre sans le demander." }
                   elseif ($code -eq 'CFG-WU-DISABLED') { 'Les mises à jour automatiques de Windows sont désactivées par stratégie.' }
                   else { '{0} = {1} (conseillé : {2}) : {3}.' -f $s.Key, $s.Value, $s.Want, $s.Role.ToLower() }
            $advice = if ($IsLinux) { "Régler dans /etc/sysctl.d/ (ex. $($s.Key) = $($s.Want)) si rien sur ce poste n'en a besoin." } elseif ($code -eq 'CFG-AUTOLOGON') { 'Désactiver l''ouverture automatique (netplwiz) ; retirer DefaultPassword du registre.' } else { 'Vérifier la stratégie qui l''impose.' }
            $findings.Add((New-Finding $s.Severity $code $msg $advice))
        }
        foreach ($s in $settings | Where-Object { $_.Key -like 'Serveur WSUS*' }) { $findings.Add((New-Finding 'info' 'CFG-WSUS' "Mises à jour gérées par un serveur WSUS : $($s.Value)." 'Les mises à jour dépendent de ce serveur : vérifier qu''il est joignable et à jour.')) }
    }

    if ($errors.Count) { $sections.Add([PSCustomObject]@{ Title = 'Erreurs de collecte'; Type = 'KeyValue'; Icon = 'error_circle'; Items = $errors }) }

    $parts = @($j.Kind)
    if ($j.Domain) { $parts += $j.Domain }
    if ($j.MdmProvider) { $parts += $j.MdmProvider }
    $parts += 'PATH : {0} entrée(s)' -f $path.Count
    [PSCustomObject]@{ Subtitle = ($parts | Where-Object { $_ }) -join ' · '; Sections = $sections.ToArray(); Findings = $findings.ToArray() }
}

#endregion

#region Fonctions ciblées

# domain_get_environment : variables d'environnement (secrets masqués) et analyse du PATH.
function Get-SIEnvironment {
    param([string]$Filter, [ValidateSet('process', 'machine', 'user', 'all')][string]$Scope = 'process')
    $rows = [System.Collections.Generic.List[object]]::new()
    $targets = switch ($Scope) { 'all' { if ($IsWindows) { 'Process', 'Machine', 'User' } else { 'Process' } } 'machine' { 'Machine' } 'user' { 'User' } default { 'Process' } }
    foreach ($t in $targets) {
        $vars = if ($IsWindows -or $t -eq 'Process') { [Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]$t) } else { @{} }
        foreach ($name in $vars.Keys | Sort-Object) {
            if ($Filter -and $name -notlike "*$Filter*") { continue }
            $rows.Add(@(@{ Process = 'processus'; Machine = 'machine'; User = 'utilisateur' }[$t], $name, (Protect-Value $name "$($vars[$name])")))
        }
    }
    $sections = [System.Collections.Generic.List[object]]::new()
    $sections.Add([PSCustomObject]@{ Title = 'Variables d''environnement'; Type = 'Table'; Icon = 'settings'; Columns = @('Portée', 'Variable', 'Valeur'); Rows = $rows.ToArray() })
    if ($IsLinux -and (Test-Path /etc/environment)) {
        $etc = foreach ($line in [System.IO.File]::ReadAllLines('/etc/environment')) { if ($line -match '^\s*([A-Za-z_]\w*)=(.*)$') { , @($Matches[1], (Protect-Value $Matches[1] $Matches[2].Trim('"'))) } }
        $sections.Add([PSCustomObject]@{ Title = '/etc/environment'; Type = 'Table'; Icon = 'settings'; Columns = @('Variable', 'Valeur'); Rows = @($etc) })
    }
    $path = @(Get-PathEntries)
    $sections.Add([PSCustomObject]@{ Title = 'PATH'; Type = 'Table'; Icon = 'arrow_routing'; Columns = @('Ordre', 'Portée', 'Dossier', 'État'); Rows = @($path | ForEach-Object { , @($_.Rank, $_.Scope, $_.Path, $_.State) }) })
    [PSCustomObject]@{ Subtitle = '{0} variable(s) · PATH : {1} entrée(s), {2} à corriger' -f $rows.Count, $path.Count, @($path | Where-Object Problem).Count; Sections = $sections.ToArray(); Findings = @() }
}

# domain_get_sysctl : paramètres du noyau Linux (/proc/sys), filtrés par préfixe.
function Get-SISysctl {
    param([string]$Prefix = 'kernel.', [ValidateRange(1, 2000)][int]$Top = 300)
    if (-not $IsLinux) { throw 'sysctl : Linux uniquement.' }
    $root = '/proc/sys/' + (($Prefix.TrimEnd('.')) -replace '\.', '/')
    $base = $root
    while (-not (Test-Path -LiteralPath $base) -and $base -ne '/proc/sys') { $base = Split-Path $base }
    $rows = [System.Collections.Generic.List[object]]::new(); $denied = 0
    foreach ($file in [System.IO.Directory]::EnumerateFiles($base, '*', [System.IO.SearchOption]::AllDirectories)) {
        $key = $file.Substring(10) -replace '/', '.'
        if ($Prefix -and -not $key.StartsWith($Prefix.TrimEnd('.'))) { continue }
        $value = try { [System.IO.File]::ReadAllText($file).Trim() -replace '\s+', ' ' } catch { $denied++; continue }
        $rows.Add(@($key, $value))
        if ($rows.Count -ge $Top) { break }
    }
    $findings = @()
    if ($denied) { $findings += New-Finding 'info' 'CFG-SYSCTL-DENIED' "$denied paramètre(s) lisible(s) en root seulement." $null }
    [PSCustomObject]@{ Subtitle = "$($rows.Count) paramètre(s) $Prefix"; Sections = @([PSCustomObject]@{ Title = 'Paramètres du noyau'; Type = 'Table'; Icon = 'settings'; Columns = @('Paramètre', 'Valeur'); Rows = $rows.ToArray() }); Findings = $findings }
}

# domain_get_gpo : stratégies de groupe appliquées (gpresult /x : ordinateur en administrateur, utilisateur toujours).
function Get-SIGpo {
    if (-not $IsWindows) { throw 'Stratégies de groupe : Windows uniquement.' }
    $xmlFile = Join-Path ([System.IO.Path]::GetTempPath()) ('sysinfo-gpresult-{0}.xml' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
    $scope = if ([Environment]::IsPrivilegedProcess) { @() } else { @('/scope', 'user') }
    try {
        & gpresult @scope /x $xmlFile /f 2>&1 | Out-Null
        if (-not (Test-Path -LiteralPath $xmlFile)) { throw 'gpresult n''a pas produit de rapport (poste hors domaine, ou aucune stratégie).' }
        [xml]$x = Get-Content -LiteralPath $xmlFile -Raw
        $rows = foreach ($part in @(@('Ordinateur', $x.Rsop.ComputerResults), @('Utilisateur', $x.Rsop.UserResults))) {
            foreach ($g in @($part[1].GPO)) {
                if (-not $g) { continue }
                $state = if ("$($g.AccessDenied)" -eq 'true') { 'accès refusé' } elseif ("$($g.FilterAllowed)" -eq 'false') { 'filtrée (WMI)' } elseif ("$($g.IsValid)" -eq 'false') { 'invalide' } elseif ("$($g.Enabled)" -eq 'false') { 'désactivée' } else { 'appliquée' }
                , @($part[0], "$($g.Name)", $state, "$($g.Link.SOMPath)")
            }
        }
        $ext = foreach ($part in @(@('Ordinateur', $x.Rsop.ComputerResults), @('Utilisateur', $x.Rsop.UserResults))) {
            foreach ($e in @($part[1].ExtensionStatus)) { if ($e -and "$($e.Error)" -ne '0') { , @($part[0], "$($e.Name)", "$($e.Error)", "$($e.EndTime)") } }
        }
        $findings = @()
        if (@($ext).Count) { $findings += New-Finding 'warning' 'CFG-GPO-ERRORS' "$(@($ext).Count) extension(s) de stratégie en erreur." 'Voir le tableau et le journal GroupPolicy/Operational.' }
        if (-not [Environment]::IsPrivilegedProcess) { $findings += New-Finding 'info' 'CFG-GPO-USER-ONLY' 'Stratégies de l''ordinateur lisibles en administrateur : seules celles de l''utilisateur sont listées.' $null }
        [PSCustomObject]@{
            Subtitle = '{0} stratégie(s)' -f @($rows).Count
            Sections = @(
                [PSCustomObject]@{ Title = 'Stratégies de groupe'; Type = 'Table'; Icon = 'settings'; Columns = @('Portée', 'Stratégie', 'État', 'Liée à'); Rows = @($rows) }
                [PSCustomObject]@{ Title = 'Extensions en erreur'; Type = 'Table'; Icon = 'error_circle'; Columns = @('Portée', 'Extension', 'Code', 'Fin'); Rows = @($ext) }
            )
            Findings = $findings
        }
    }
    finally { Remove-Item -LiteralPath $xmlFile -ErrorAction SilentlyContinue }
}

# domain_force_gpupdate : réapplique les stratégies de groupe tout de suite (gpupdate /force).
function Invoke-SIGpupdate {
    param([ValidateSet('all', 'computer', 'user')][string]$Target = 'all', [switch]$DryRun)
    $blocked = $null
    if (-not $IsWindows) { $blocked = 'Stratégies de groupe : Windows uniquement.' }
    else {
        $j = Get-JoinState
        if (-not $j.Ad) { $blocked = "Ce poste n'est pas dans un domaine Active Directory : pas de stratégies de groupe à appliquer (Entra ID / Intune : synchroniser depuis Paramètres › Comptes)." }
        elseif ($j.Reachable -eq $false) { $blocked = "Aucun contrôleur du domaine $($j.Domain) n'est joignable : connecter le poste au réseau de l'entreprise ou au VPN." }
        elseif ($Target -eq 'computer' -and -not [Environment]::IsPrivilegedProcess) { $blocked = 'Stratégies de l''ordinateur : droits administrateur requis.' }
    }
    $userOnly = $IsWindows -and $Target -eq 'all' -and -not [Environment]::IsPrivilegedProcess
    if ($userOnly) { $Target = 'user' }
    $gpo = if ($IsWindows) { Get-GpoState } else { $null }
    $section = [PSCustomObject]@{ Title = 'Stratégies de groupe'; Type = 'KeyValue'; Icon = 'settings'; Items = [ordered]@{ 'Cible' = @{ all = 'ordinateur et utilisateur'; computer = 'ordinateur'; user = 'utilisateur' }[$Target]
            'Dernière application (ordinateur)' = Format-Date $gpo.Machine; 'Dernière application (utilisateur)' = Format-Date $gpo.User } }
 $findings = @()
    if ($userOnly) { $findings += New-Finding 'info' 'CFG-GPUPDATE-USER-ONLY' 'Sans droits administrateur, seules les stratégies de l''utilisateur sont réappliquées.' $null }
    $findings += @(New-Finding 'info' 'CFG-GPUPDATE-LOGOFF' 'Certaines stratégies (installation de logiciels, redirection de dossiers) ne s''appliquent qu''à la prochaine ouverture de session ou au redémarrage : gpupdate le signale sans rien forcer.' $null)
    $change = New-Change 'Stratégies de groupe' 'Dernière application' (Format-Date $gpo.Machine) 'maintenant'
    if ($DryRun -or $blocked) { return [PSCustomObject]@{ Subtitle = 'Les stratégies de groupe seront réappliquées'; Sections = @($section); Findings = $findings; Changes = @($change); Blocked = $blocked } }

    Write-Information "gpupdate /force /target:$Target"
    $gpArgs = @('/force', '/wait:120') + $(if ($Target -ne 'all') { @("/target:$Target") } else { @() })
    $out = & gpupdate @gpArgs 2>&1 | ForEach-Object { Write-Information "$_"; "$_" }
    if ($LASTEXITCODE -ne 0) { throw "gpupdate a échoué : $(($out | Where-Object { $_ }) -join ' ')" }
    $script:Cache.Remove('gpo')
    $after = Get-GpoState
    [PSCustomObject]@{ Subtitle = 'Stratégies de groupe réappliquées'; Sections = @($section); Findings = @(); Changes = @(New-Change 'Stratégies de groupe' 'Dernière application' (Format-Date $gpo.Machine) (Format-Date $after.Machine)); Blocked = $null }
}

function New-Change([string]$Target, [string]$Property, $Before, $After) {
    [PSCustomObject]@{ Target = $Target; Property = $Property; Before = $Before; After = $After }
}

#endregion

Export-ModuleMember -Function Get-ModuleData, Get-SIEnvironment, Get-SISysctl, Get-SIGpo, Invoke-SIGpupdate
