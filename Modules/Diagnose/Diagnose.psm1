# Module Diagnostic guidé : un outil par problème (PC lent, pas d'Internet, plantages, disque plein, réveils
# intempestifs, imprimante en panne, suspicion de logiciel malveillant). Chacun enchaîne les modules concernés et renvoie
# les causes probables classées, les vérifications faites et l'étape suivante (souvent une action d'un module).
# Tout est en lecture : les corrections passent par les actions des modules (confirmées par l'utilisateur).
#
# Sources : les autres modules, par [SysInfo.Host.ModuleHost] (mêmes données que leurs pages, lectures seulement) ;
# seul dans pwsh, le module importe les autres lui-même. Réseau local (interfaces, passerelle) : NetworkInterface (.NET).

$script:Fr = [cultureinfo]::GetCultureInfo('fr-FR')
$script:Nbsp = [char]0x00A0
$script:SelfId = 'diagnose'
$script:Aggregators = @('reports', 'diagnose', 'inventory')
$script:ModulesRoot = Split-Path $PSScriptRoot

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

function New-Finding([string]$Severity, [string]$Code, [string]$Message, [string]$Recommendation) {
    [PSCustomObject]@{ Severity = $Severity; Code = $Code; Message = $Message; Recommendation = $Recommendation }
}

function Get-Prop($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $Object.$Name
}

#endregion

#region Accès aux autres modules (même mécanisme que le module Rapports)

function Get-Bridge { $t = 'SysInfo.Host.ModuleHost' -as [type]; if ($t -and $t::IsAvailable) { $t } else { $null } }

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
        $mod = Import-Module (Join-Path $info.Dir "$($info.Name).psm1") -PassThru -Force -Prefix "Diag$($info.Name)" -DisableNameChecking -ErrorAction Stop
        $script:Imported[$Module] = $mod
    }
    & $mod { param($c, $p) & $c @p } $command $Parameters
}

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

# Collecte d'un scénario : requêtes @{ Key; Module; Function; Parameters } → table Key → @{ Data; Error }.
# Les modules absents de ce système sont sautés. Les vues d'ensemble sont relevées à neuf (moins de 30 s).
function Get-Evidence([object[]]$Requests) {
    $available = Get-Manifests
    $wanted = @($Requests | Where-Object { $available.Contains($_.Module) })
    $results = @(Invoke-SIModules @($wanted | ForEach-Object { @{ Module = $_.Module; Function = $_.Function; Parameters = $_.Parameters ?? @{} } }) 120 30)
    $map = @{}
    for ($i = 0; $i -lt $wanted.Count; $i++) { $map[$wanted[$i].Key] = [PSCustomObject]@{ Data = Get-Prop $results[$i] 'Data'; Error = Get-Prop $results[$i] 'Error'; Module = $wanted[$i].Module } }
    $map
}

# Constats d'un résultat dont le code correspond à l'un des motifs (STO-*, SNS-TEMP-*…).
# -Serious : seulement « Attention » et « Critique » (un constat « info » n'est pas une cause de panne).
function Get-Found($Evidence, [string]$Key, [string[]]$Patterns, [switch]$Serious) {
    $e = $Evidence[$Key]
    if (-not $e -or -not $e.Data) { return @() }
    @(@(Get-Prop $e.Data 'Findings') | Where-Object { $f = $_; $_ -and ($Patterns | Where-Object { "$(Get-Prop $f 'Code')" -like $_ }) -and (-not $Serious -or "$(Get-Prop $f 'Severity')" -in 'warning', 'critical') })
}

function Get-Section($Evidence, [string]$Key, [string]$TitlePattern) {
    $e = $Evidence[$Key]
    if (-not $e -or -not $e.Data) { return $null }
    @(Get-Prop $e.Data 'Sections') | Where-Object { "$(Get-Prop $_ 'Title')" -like $TitlePattern } | Select-Object -First 1
}

function Get-Rows($Section) {
    $rows = @(Get-Prop $Section 'Rows')
    if ($rows.Count -and $rows[0] -isnot [array] -and $rows[0] -isnot [System.Collections.IList]) { $rows = , $rows }
    $rows
}

#endregion

#region Résultat d'un diagnostic

$script:Weights = @{ critical = 30; warning = 20; info = 5 }
$script:SeverityText = @{ critical = 'Critique'; warning = 'Attention'; info = 'Info' }

# Vérification : nom, état (ok, problem, unknown), résultat lisible.
function New-Check([string]$Name, [string]$State, [string]$Result) { [PSCustomObject]@{ Name = $Name; State = $State; Result = $Result } }

# Cause probable : poids (classement), gravité, code stable, cause, preuve, étape suivante.
function New-Cause([int]$Weight, [string]$Severity, [string]$Code, [string]$Cause, [string]$Evidence, [string]$Next) {
    [PSCustomObject]@{ Weight = $Weight; Severity = $Severity; Code = $Code; Cause = $Cause; Evidence = $Evidence; Next = $Next }
}

# Cause tirée d'un constat d'un module : même gravité, preuve = message du constat.
function New-CauseFrom($Finding, [string]$Code, [string]$Cause, [string]$Next, [int]$Bonus = 0) {
    $sev = "$(Get-Prop $Finding 'Severity')".ToLower()
    New-Cause ($script:Weights[$sev] + $Bonus) $sev $Code $Cause (Get-Prop $Finding 'Message') ($Next ?? (Get-Prop $Finding 'Recommendation'))
}

function New-Diagnosis([string]$Problem, $Checks, $Causes, $Evidence) {
    # Même cause vue plusieurs fois (température du paquet et des cœurs…) : une ligne, les preuves réunies.
    $causes = @(@($Causes | Where-Object { $_ }) | Group-Object { "$($_.Code)|$($_.Cause)" } | ForEach-Object {
            $first = $_.Group | Sort-Object Weight -Descending | Select-Object -First 1
            New-Cause $first.Weight $first.Severity $first.Code $first.Cause ((@($_.Group | ForEach-Object Evidence | Select-Object -Unique -First 3)) -join ' · ') $first.Next
        } | Sort-Object Weight -Descending)
    $checks = @($Checks | Where-Object { $_ })
    $errors = @($Evidence.Values | Where-Object Error | ForEach-Object { "$($_.Module) : $($_.Error)" })
    $top = $causes | Select-Object -First 1
    $conclusion = [ordered]@{
        'Problème' = $Problem
        'Cause la plus probable' = if ($top) { $top.Cause } else { 'aucune cause trouvée par SysInfo' }
        'Étape suivante' = if ($top) { $top.Next } else { 'Le problème ne vient pas de ce que SysInfo sait vérifier : décrire les symptômes précis (quand, quel programme, quel message).' }
        'Vérifications' = '{0} faite(s), {1} en défaut' -f $checks.Count, @($checks | Where-Object State -eq 'problem').Count
    }
    if ($errors) { $conclusion['Modules sans réponse'] = $errors -join ' · ' }
    $state = @{ ok = 'OK'; problem = 'en défaut'; unknown = 'inconnu' }
    [PSCustomObject]@{
        Subtitle = if ($top) { "$Problem : $($causes.Count) cause(s) probable(s), d'abord « $($top.Cause) »" } else { "$Problem : aucune cause trouvée" }
        Sections = @(
            [PSCustomObject]@{ Title = 'Conclusion'; Type = 'KeyValue'; Icon = 'search'; Items = $conclusion }
            [PSCustomObject]@{ Title = 'Causes probables'; Type = 'Table'; Icon = 'warning'; Columns = @('Rang', 'Cause', 'Gravité', 'Preuve', 'Étape suivante')
                Rows = @(for ($i = 0; $i -lt $causes.Count; $i++) { , @(($i + 1), $causes[$i].Cause, $script:SeverityText[$causes[$i].Severity], $causes[$i].Evidence, $causes[$i].Next) }) }
            [PSCustomObject]@{ Title = 'Vérifications'; Type = 'Table'; Icon = 'checkmark_circle'; Columns = @('Vérification', 'État', 'Résultat'); Rows = @($checks | ForEach-Object { , @($_.Name, $state[$_.State], $_.Result) }) }
        )
        Findings = @($causes | ForEach-Object { New-Finding $_.Severity $_.Code "$($_.Cause) : $($_.Evidence)" $_.Next })
    }
}

# Vérification d'un ensemble de constats : OK s'il n'y en a pas, sinon le premier message.
function New-FindingCheck([string]$Name, $Found, [string]$Ok, [bool]$Available = $true) {
    $Found = @($Found | Where-Object { $_ })
    if (-not $Available) { return New-Check $Name 'unknown' 'module indisponible' }
    if (@($Found).Count) { return New-Check $Name 'problem' ((@($Found) | Select-Object -First 2 | ForEach-Object { Get-Prop $_ 'Message' }) -join ' · ') }
    New-Check $Name 'ok' $Ok
}

#endregion

#region Scénarios

# diagnose_slow_pc : PC lent.
function Get-SIDiagnosisSlowPc {
    Write-Information 'Relevé : performance, processus, démarrage, stockage, capteurs, logiciels, système…'
    $ev = Get-Evidence @(
        @{ Key = 'perf'; Module = 'performance' }, @{ Key = 'top'; Module = 'performance'; Function = 'get_top_consumers'; Parameters = @{ period = '1h'; top = 5 } }
        @{ Key = 'system'; Module = 'system' }, @{ Key = 'boot'; Module = 'boot' }, @{ Key = 'storage'; Module = 'storage' }
        @{ Key = 'sensors'; Module = 'sensors' }, @{ Key = 'software'; Module = 'software' }, @{ Key = 'events'; Module = 'events' }
    )
    $causes = [System.Collections.Generic.List[object]]::new(); $checks = [System.Collections.Generic.List[object]]::new()

    $bottle = Get-Found $ev 'perf' @('PERF-BOTTLENECK-*', 'PERF-ALERT-CPU', 'PERF-ALERT-MEMORY', 'PERF-ALERT-COMMIT', 'PERF-ALERT-SWAP', 'PERF-ALERT-DISK*')
    $checks.Add((New-FindingCheck 'Ressource saturée en ce moment (processeur, mémoire, disque)' $bottle 'aucun goulot' ($null -ne $ev['perf'])))
    foreach ($f in $bottle) { $causes.Add((New-CauseFrom $f 'DIAG-SLOW-SATURATED' 'Une ressource est saturée' 'Voir les processus les plus gourmands (system_get_processes) et les fermer ou les mettre en priorité basse (system_set_priority).' 10)) }

    $memory = @(Get-Found $ev 'system' @('SYS-MEM-HIGH', 'SYS-SWAP-HIGH'))
    $checks.Add((New-FindingCheck 'Mémoire et swap' $memory 'mémoire suffisante' ($null -ne $ev['system'])))
    if ($memory) { $causes.Add((New-Cause (20 + 5 * $memory.Count) 'warning' 'DIAG-SLOW-MEMORY' 'Mémoire vive insuffisante' ((@($memory) | ForEach-Object { Get-Prop $_ 'Message' }) -join ' · ') 'Fermer les applications inutiles (navigateur aux nombreux onglets…) ; si c''est fréquent, ajouter de la mémoire (inventory : emplacements libres).')) }

    $heavy = @(Get-Rows (Get-Section $ev 'top' 'Processus les plus gourmands*') | Where-Object { [double]$_[1] -ge 20 })
    $checks.Add((New-Check 'Processus gourmands sur la dernière heure' $(if ($heavy) { 'problem' } elseif ($ev['top'].Data) { 'ok' } else { 'unknown' }) $(if ($heavy) { ($heavy | ForEach-Object { '{0} : {1} % de CPU en moyenne' -f $_[0], $_[1] }) -join ' · ' } elseif ($ev['top'].Data) { 'aucun processus au-delà de 20 % en moyenne' } else { 'historique de performance indisponible' })))
    foreach ($h in $heavy) { $causes.Add((New-Cause (15 + [int][double]$h[1] / 4) 'warning' 'DIAG-SLOW-PROCESS' "$($h[0]) consomme beaucoup de processeur" ('{0} % du processeur en moyenne sur la dernière heure (pics à {1} %)' -f $h[1], $h[2]) "Vérifier si $($h[0]) doit tourner (mise à jour, indexation, onglet bloqué) ; l'arrêter si besoin (system_stop_process).")) }

    $heat = @(Get-Found $ev 'sensors' @('SNS-CPU-THROTTLING', 'SNS-TEMP-*', 'SNS-GPU-THROTTLING'))
    $checks.Add((New-FindingCheck 'Température et bridage du processeur' $heat 'pas de surchauffe ni de bridage' ($null -ne $ev['sensors'])))
    foreach ($f in $heat) { $causes.Add((New-CauseFrom $f 'DIAG-SLOW-HEAT' 'Surchauffe : le processeur ralentit pour se protéger' 'Nettoyer les entrées d''air et les ventilateurs, vérifier qu''ils tournent (sensors_get_sensors).' 5)) }
    $capped = @(Get-Found $ev 'sensors' @('SNS-CPU-CAPPED', 'SNS-POWER-SAVER', 'SNS-TURBO-OFF'))
    foreach ($f in $capped) { $causes.Add((New-CauseFrom $f 'DIAG-SLOW-POWER' 'Processeur limité par l''économie d''énergie' 'Choisir un plan plus performant (sensors_set_power_plan).')) }
    $checks.Add((New-FindingCheck 'Plan d''alimentation et fréquence' $capped 'pas de limitation' ($null -ne $ev['sensors'])))

    $disk = @(Get-Found $ev 'storage' @('STO-VOLUME-FULL', 'STO-SMART*', 'STO-DISK*', 'STO-ERRORS', 'STO-TRIM-OFF', 'STO-RAID*') -Serious)
    $checks.Add((New-FindingCheck 'Disque (place, état SMART, erreurs)' $disk 'disques en bon état, place suffisante' ($null -ne $ev['storage'])))
    foreach ($f in $disk) { $causes.Add((New-CauseFrom $f 'DIAG-SLOW-DISK' 'Disque plein ou en difficulté' $null)) }

    $boot = @(Get-Found $ev 'boot' @('BOOT-SLOW', 'BOOT-SLOWER', 'BOOT-SLOW-UNIT'))
    $checks.Add((New-FindingCheck 'Durée du démarrage' $boot 'démarrage normal' ($null -ne $ev['boot'])))
    foreach ($f in $boot | Select-Object -First 2) { $causes.Add((New-CauseFrom $f 'DIAG-SLOW-BOOT' 'Démarrage lent' 'Voir boot_analyze et désactiver ce qui n''est pas utile au démarrage.' -5)) }

    $startup = @(Get-Rows (Get-Section $ev 'software' 'Programmes au démarrage') | Where-Object { "$($_[1])" -match '(?i)^(actif|activé|enabled|oui)' })
    # Sous Linux, le bureau (KDE, GNOME) lance lui-même une quinzaine d'entrées : seuil plus haut.
    $limit = if ($IsLinux) { 20 } else { 8 }
    $checks.Add((New-Check 'Programmes lancés à l''ouverture de session' $(if ($startup.Count -gt $limit) { 'problem' } else { 'ok' }) "$($startup.Count) programme(s) actif(s)"))
    if ($startup.Count -gt $limit) { $causes.Add((New-Cause 12 'info' 'DIAG-SLOW-STARTUP' 'Beaucoup de programmes au démarrage' "$($startup.Count) programmes lancés à l'ouverture de session" 'Désactiver ceux qui ne servent pas tout de suite (software_set_startup).')) }

    $reboot = @(Get-Found $ev 'software' @('SW-REBOOT-PENDING'))
    $crash = @(Get-Found $ev 'events' @('EVT-OOM-KILL', 'EVT-HARDWARE-ERROR'))
    foreach ($f in $reboot) { $causes.Add((New-CauseFrom $f 'DIAG-SLOW-REBOOT' 'Redémarrage en attente après des mises à jour' 'Redémarrer l''ordinateur.' -5)) }
    foreach ($f in $crash) { $causes.Add((New-CauseFrom $f 'DIAG-SLOW-ERRORS' 'Erreurs système récentes' $null)) }
    $checks.Add((New-FindingCheck 'Redémarrage en attente, erreurs matérielles, manque de mémoire' (@($reboot) + @($crash)) 'rien de signalé'))

    New-Diagnosis 'PC lent' $checks $causes $ev
}

# diagnose_no_internet : pas d'Internet ou connexion instable. Dans l'ordre : lien → adresse IP → passerelle → DNS → Internet.
function Get-SIDiagnosisNoInternet {
    $causes = [System.Collections.Generic.List[object]]::new(); $checks = [System.Collections.Generic.List[object]]::new()
    $nics = foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($nic.NetworkInterfaceType -in 'Loopback', 'Tunnel') { continue }
        if ($IsLinux -and -not (Test-Path "/sys/class/net/$($nic.Name)/device")) { continue }
        if ($IsWindows -and $nic.Description -match '(?i)virtual|hyper-v|loopback|bluetooth|wan miniport|tap-') { continue }
        $props = $nic.GetIPProperties()
        [PSCustomObject]@{ Name = $nic.Name; Up = $nic.OperationalStatus -eq 'Up'; Wifi = $nic.NetworkInterfaceType -eq 'Wireless80211' -or (Test-Path "/sys/class/net/$($nic.Name)/wireless")
            Ip = ($props.UnicastAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1).Address
            Gateway = ($props.GatewayAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1).Address }
    }
    $nics = @($nics)
    $up = @($nics | Where-Object Up)
    $primary = $up | Where-Object Gateway | Select-Object -First 1
    $fail = $null

    # 1. Lien
    $checks.Add((New-Check '1. Lien (câble branché ou Wi-Fi associé)' $(if ($up) { 'ok' } else { 'problem' }) $(if ($up) { ($up | ForEach-Object Name) -join ', ' } else { 'aucune interface active : ' + (($nics | ForEach-Object Name) -join ', ') })))
    if (-not $up) { $fail = 'link'; $causes.Add((New-Cause 60 'critical' 'DIAG-NET-NO-LINK' 'Aucune connexion physique' 'aucune carte réseau active (câble débranché, Wi-Fi coupé ou non connecté)' 'Brancher le câble ou se connecter à un réseau Wi-Fi ; vérifier le mode avion.')) }

    # 2. Adresse IP
    if (-not $fail) {
        $ip = ($up | Where-Object Ip | Select-Object -First 1).Ip
        $apipa = "$ip" -like '169.254.*'
        $state = if (-not $ip -or $apipa) { 'problem' } else { 'ok' }
        $checks.Add((New-Check '2. Adresse IP (DHCP)' $state $(if (-not $ip) { 'aucune adresse IPv4' } elseif ($apipa) { "$ip (adresse automatique : le DHCP n'a pas répondu)" } else { "$ip" })))
        if ($state -eq 'problem') { $fail = 'ip'; $causes.Add((New-Cause 55 'critical' 'DIAG-NET-NO-IP' 'Pas d''adresse IP' 'le serveur DHCP (la box, le routeur) ne donne pas d''adresse' 'Redémarrer la box ou le routeur, puis renouveler le bail (network_renew_dhcp).')) }
    }
    # 3. Passerelle
    $gw = if ($primary) { "$($primary.Gateway)" } else { $null }
    if (-not $fail) {
        if (-not $gw) { $checks.Add((New-Check '3. Passerelle (box, routeur)' 'problem' 'aucune passerelle configurée')); $fail = 'gw'; $causes.Add((New-Cause 50 'critical' 'DIAG-NET-NO-GATEWAY' 'Pas de passerelle' 'la configuration réseau n''a pas de passerelle par défaut' 'Renouveler le bail DHCP (network_renew_dhcp) ou corriger la configuration IP manuelle.')) }
        else {
            $ping = try { Invoke-SIModule 'network' 'ping' @{ target = $gw; count = 4 } 30 } catch { $null }
            $lost = @(@(Get-Prop $ping 'Findings') | Where-Object { (Get-Prop $_ 'Code') -in 'NET-HOST-UNREACHABLE', 'NET-PING-LOSS' })
            $checks.Add((New-Check "3. Passerelle ($gw)" $(if (-not $ping) { 'unknown' } elseif ($lost) { 'problem' } else { 'ok' }) $(if ($ping) { Get-Prop $ping 'Subtitle' } else { 'test impossible' })))
            if ($lost | Where-Object { (Get-Prop $_ 'Code') -eq 'NET-HOST-UNREACHABLE' }) { $fail = 'gw'; $causes.Add((New-Cause 50 'critical' 'DIAG-NET-GATEWAY-DOWN' 'La box ou le routeur ne répond pas' "$gw ne répond pas au ping" 'Redémarrer la box ou le routeur ; en Wi-Fi, se rapprocher ou essayer en câble.')) }
            elseif ($lost) { $causes.Add((New-Cause 35 'warning' 'DIAG-NET-LOCAL-LOSS' 'Connexion locale instable' (Get-Prop $lost[0] 'Message') 'En Wi-Fi : signal, canal encombré ou distance ; en câble : changer le câble ou le port.')) }
        }
    }
    # 4. DNS
    if (-not $fail) {
        $dns = try { Invoke-SIModule 'network' 'resolve_dns' @{ name = 'www.microsoft.com' } 30 } catch { $_.Exception.Message }
        $bad = $dns -is [string] -or @(@(Get-Prop $dns 'Findings') | Where-Object { (Get-Prop $_ 'Code') -in 'NET-DNS-NO-ANSWER', 'NET-DNS-FAIL' }).Count
        $checks.Add((New-Check '4. Résolution des noms (DNS)' $(if ($bad) { 'problem' } else { 'ok' }) $(if ($dns -is [string]) { $dns } else { Get-Prop $dns 'Subtitle' })))
        if ($bad) { $fail = 'dns'; $causes.Add((New-Cause 45 'critical' 'DIAG-NET-DNS' 'Les noms ne sont plus traduits en adresses (DNS)' 'www.microsoft.com ne se résout pas' 'Vider le cache DNS (network_flush_dns) ; sinon changer de serveur DNS (1.1.1.1, 9.9.9.9) ou redémarrer la box.')) }
    }
    # 5. Internet
    if (-not $fail) {
        $port = try { Invoke-SIModule 'network' 'test_port' @{ target = '1.1.1.1'; port = 443; timeoutMs = 3000 } 30 } catch { $null }
        $open = "$(Get-Prop $port 'Subtitle')" -match 'Ouvert'
        $checks.Add((New-Check '5. Accès à Internet (1.1.1.1, port 443)' $(if (-not $port) { 'unknown' } elseif ($open) { 'ok' } else { 'problem' }) $(if ($port) { Get-Prop $port 'Subtitle' } else { 'test impossible' })))
        if ($port -and -not $open) { $causes.Add((New-Cause 45 'critical' 'DIAG-NET-NO-INTERNET' 'La box est joignable mais Internet ne l''est pas' 'aucune réponse de 1.1.1.1 sur le port 443' 'Panne de l''opérateur ou de la box : redémarrer la box, vérifier ses voyants ; un pare-feu ou un proxy peut aussi bloquer.')) }
    }

    # Qualité : Wi-Fi, pertes, latence, proxy, hosts (vue d'ensemble du module Réseau).
    $ev = Get-Evidence @(@{ Key = 'network'; Module = 'network' })
    $quality = @(Get-Found $ev 'network' @('NET-WIFI-*', 'NET-PACKET-LOSS', 'NET-LATENCY-HIGH', 'NET-LINK-SLOW', 'NET-DNS-SLOW', 'NET-PROXY', 'NET-HOSTS-CUSTOM'))
    $checks.Add((New-FindingCheck 'Qualité (signal Wi-Fi, pertes, latence, proxy)' $quality 'rien de signalé' ($null -ne $ev['network'])))
    foreach ($f in $quality) { $causes.Add((New-CauseFrom $f 'DIAG-NET-QUALITY' 'Connexion de mauvaise qualité' $null)) }
    New-Diagnosis 'Pas d''Internet / connexion instable' $checks $causes $ev
}

# diagnose_crashes : écrans bleus, kernel panics, plantages d'applications.
function Get-SIDiagnosisCrashes {
    $ev = Get-Evidence @(
        @{ Key = 'events'; Module = 'events' }, @{ Key = 'timeline'; Module = 'events'; Function = 'get_timeline'; Parameters = @{ days = 14; top = 300 } }
        @{ Key = 'hardware'; Module = 'hardware' }, @{ Key = 'sensors'; Module = 'sensors' }, @{ Key = 'storage'; Module = 'storage' }, @{ Key = 'system'; Module = 'system' }
    )
    $causes = [System.Collections.Generic.List[object]]::new(); $checks = [System.Collections.Generic.List[object]]::new()
    $crashes = @(Get-Found $ev 'events' @('EVT-BSOD', 'EVT-KERNEL-PANIC', 'EVT-KERNEL-OOPS', 'EVT-UNEXPECTED-SHUTDOWN', 'EVT-APP-CRASHES'))
    $checks.Add((New-FindingCheck 'Plantages des 7 derniers jours' $crashes 'aucun plantage' ($null -ne $ev['events'])))
    $hw = @(Get-Found $ev 'events' @('EVT-HARDWARE-ERROR', 'EVT-OOM-KILL'))
    $checks.Add((New-FindingCheck 'Erreurs matérielles (WHEA / MCE) et manque de mémoire' $hw 'aucune' ($null -ne $ev['events'])))
    foreach ($f in $hw) { $causes.Add((New-CauseFrom $f 'DIAG-CRASH-HARDWARE' $(if ((Get-Prop $f 'Code') -eq 'EVT-OOM-KILL') { 'Mémoire épuisée : le système tue des programmes' } else { 'Erreur matérielle signalée par le processeur' }) $null 15)) }

    $heat = @(Get-Found $ev 'sensors' @('SNS-TEMP-*', 'SNS-CPU-THROTTLING', 'SNS-GPU-THROTTLING', 'SNS-FAN-STOPPED'))
    $checks.Add((New-FindingCheck 'Températures' $heat 'normales' ($null -ne $ev['sensors'])))
    foreach ($f in $heat) { $causes.Add((New-CauseFrom $f 'DIAG-CRASH-HEAT' 'Surchauffe' 'Nettoyer la ventilation ; une surchauffe provoque arrêts brutaux et écrans bleus.' 10)) }

    $drivers = @(Get-Found $ev 'hardware' @('HW-DEVICE-ERROR', 'HW-DRIVER-UNSIGNED', 'HW-DRIVER-OLD', 'HW-DEVICE-*') -Serious)
    $checks.Add((New-FindingCheck 'Pilotes et périphériques' $drivers 'aucun périphérique en erreur' ($null -ne $ev['hardware'])))
    foreach ($f in $drivers | Select-Object -First 3) { $causes.Add((New-CauseFrom $f 'DIAG-CRASH-DRIVER' 'Pilote ou périphérique en cause' $null)) }

    $disk = @(Get-Found $ev 'storage' @('STO-SMART*', 'STO-ERRORS', 'STO-DISK*') -Serious)
    $checks.Add((New-FindingCheck 'État des disques' $disk 'aucune erreur de disque' ($null -ne $ev['storage'])))
    foreach ($f in $disk) { $causes.Add((New-CauseFrom $f 'DIAG-CRASH-DISK' 'Disque défaillant' $null 10)) }

    # Installations dans les 48 h avant le dernier plantage : pilote ou mise à jour en cause.
    $rows = @(Get-Rows (Get-Section $ev 'timeline' '*'))
    $crashRows = @($rows | Where-Object { "$($_ -join ' ')" -match '(?i)écran bleu|panic|plantage|arrêt inattendu|crash|oops' })
    $installs = @($rows | Where-Object { "$($_ -join ' ')" -match '(?i)install|mise à jour|pilote|update' })
    $checks.Add((New-Check 'Installations (pilotes, mises à jour) juste avant un plantage' $(if ($crashRows -and $installs) { 'problem' } elseif ($ev['timeline'].Data) { 'ok' } else { 'unknown' }) $(if ($installs) { '{0} installation(s) sur 14 jours, dont : {1}' -f $installs.Count, (($installs | Select-Object -First 2 | ForEach-Object { $_ -join ' ' }) -join ' · ') } else { 'aucune installation récente' })))
    if ($crashRows -and $installs) { $causes.Add((New-Cause 22 'warning' 'DIAG-CRASH-AFTER-INSTALL' 'Plantages après une installation récente' (($installs | Select-Object -First 2 | ForEach-Object { $_ -join ' ' }) -join ' · ') 'Désinstaller ou revenir au pilote / à la mise à jour précédente (hardware_reinstall_driver, software_uninstall), ou restaurer un point de restauration.')) }

    foreach ($f in $crashes) {
        $code = Get-Prop $f 'Code'
        $label = switch ($code) { 'EVT-BSOD' { 'Écrans bleus' } { $_ -in 'EVT-KERNEL-PANIC', 'EVT-KERNEL-OOPS' } { 'Plantages du noyau' } 'EVT-UNEXPECTED-SHUTDOWN' { 'Arrêts brutaux' } default { 'Une application plante régulièrement' } }
        $causes.Add((New-CauseFrom $f 'DIAG-CRASH-OBSERVED' $label $null))
    }
    New-Diagnosis 'Écrans bleus / plantages' $checks $causes $ev
}

# diagnose_disk_full : disque plein, ce qui prend la place, ce qui peut être libéré.
function Get-SIDiagnosisDiskFull {
    $ev = Get-Evidence @(
        @{ Key = 'storage'; Module = 'storage' }, @{ Key = 'reclaim'; Module = 'storage'; Function = 'get_reclaimable_space'; Parameters = @{ timeoutSeconds = 30 } }
        @{ Key = 'maintenance'; Module = 'maintenance' }, @{ Key = 'virt'; Module = 'virtualization' }, @{ Key = 'backup'; Module = 'backup' }
    )
    $causes = [System.Collections.Generic.List[object]]::new(); $checks = [System.Collections.Generic.List[object]]::new()
    $full = @(Get-Found $ev 'storage' @('STO-VOLUME-FULL', 'STO-INODES-FULL'))
    $usage = Get-Section $ev 'storage' 'Remplissage*'
    $vols = @(@(Get-Prop $usage 'Items') | ForEach-Object { '{0} : {1} libres' -f (Get-Prop $_ 'Label'), (Get-Prop $_ 'Text') })
    $checks.Add((New-Check 'Remplissage des volumes' $(if ($full) { 'problem' } else { 'ok' }) ($(if ($vols) { ($vols | Select-Object -First 4) -join ' · ' } else { '—' }))))
    foreach ($f in $full) { $causes.Add((New-CauseFrom $f 'DIAG-DISK-FULL' 'Volume presque plein' 'Libérer de l''espace (voir ci-dessous), puis chercher les plus gros dossiers (storage_analyze_space).' 20)) }

    $reclaim = Get-Section $ev 'reclaim' '*'
    $rows = @(Get-Rows $reclaim)
    $checks.Add((New-Check 'Espace récupérable (caches, corbeille, journaux…)' $(if ($rows) { 'problem' } elseif ($ev['reclaim'].Data) { 'ok' } else { 'unknown' }) $(if ($ev['reclaim'].Data) { Get-Prop $ev['reclaim'].Data 'Subtitle' } else { 'estimation indisponible' })))
    foreach ($r in $rows | Select-Object -First 4) { $causes.Add((New-Cause 18 'info' 'DIAG-DISK-RECLAIMABLE' "Espace récupérable : $($r[0])" ($r -join ' · ') 'Nettoyer avec maintenance_cleanup (aperçu d''abord), ou à la main pour les dossiers personnels.')) }

    $docker = @(Get-Found $ev 'virt' @('VIRT-SPACE-RECLAIMABLE'))
    foreach ($f in $docker) { $causes.Add((New-CauseFrom $f 'DIAG-DISK-CONTAINERS' 'Images et cache de conteneurs inutilisés' $null 10)) }
    $checks.Add((New-FindingCheck 'Conteneurs (images et cache inutilisés)' $docker 'rien de notable' ($null -ne $ev['virt'])))
    $clean = @(Get-Found $ev 'maintenance' @('MNT-CLEANUP*'))
    foreach ($f in $clean) { $causes.Add((New-CauseFrom $f 'DIAG-DISK-CLEANUP' 'Nettoyage possible' 'maintenance_cleanup (aperçu d''abord).')) }
    $snap = @(Get-Found $ev 'backup' @('BAK-*'))
    $checks.Add((New-Check 'Sauvegarde avant de supprimer' $(if ($snap | Where-Object { (Get-Prop $_ 'Code') -in 'BAK-NONE', 'BAK-OLD' }) { 'problem' } else { 'ok' }) $(if ($ev['backup'].Data) { Get-Prop $ev['backup'].Data 'Subtitle' } else { '—' })))
    $causes.Add((New-Cause 1 'info' 'DIAG-DISK-ANALYZE' 'Chercher les plus gros dossiers et fichiers' 'les caches ne sont souvent qu''une partie de l''espace occupé' 'storage_analyze_space sur le volume plein (tâche longue).'))
    New-Diagnosis 'Disque plein' $checks $causes $ev
}

# diagnose_wake_issues : l'ordinateur ne s'éteint pas ou se réveille seul.
function Get-SIDiagnosisWake {
    $ev = Get-Evidence @(@{ Key = 'sensors'; Module = 'sensors' }, @{ Key = 'wake'; Module = 'sensors'; Function = 'get_wake_history'; Parameters = @{ days = 14 } }, @{ Key = 'tasks'; Module = 'tasks' })
    $causes = [System.Collections.Generic.List[object]]::new(); $checks = [System.Collections.Generic.List[object]]::new()
    $night = @(Get-Found $ev 'wake' @('SNS-WAKE-NIGHT'))
    $wakes = @(Get-Rows (Get-Section $ev 'wake' 'Veilles*'))
    $sources = @($wakes | ForEach-Object { "$($_[4])" } | Where-Object { $_ } | Group-Object | Sort-Object Count -Descending)
    $checks.Add((New-Check 'Réveils des 14 derniers jours' $(if ($night) { 'problem' } else { 'ok' }) ('{0} réveil(s){1}' -f $wakes.Count, $(if ($sources) { ' · sources : ' + (($sources | Select-Object -First 3 | ForEach-Object { "$($_.Name) ($($_.Count))" }) -join ', ') } else { '' }))))
    foreach ($f in $night) { $causes.Add((New-CauseFrom $f 'DIAG-WAKE-NIGHT' 'La machine se réveille la nuit' $null 20)) }
    if ($sources) { $causes.Add((New-Cause 25 'warning' 'DIAG-WAKE-SOURCE' "Source de réveil la plus fréquente : $($sources[0].Name)" "$($sources[0].Count) réveil(s) sur 14 jours" 'Si c''est un périphérique (souris, carte réseau), lui retirer le droit de réveiller ; si c''est une minuterie, la désactiver (tasks_set_enabled).')) }

    $timers = @(Get-Rows (Get-Section $ev 'wake' 'Minuteries*') | Where-Object { $_ -and "$($_[0])" })
    $checks.Add((New-Check 'Minuteries autorisées à réveiller' $(if ($timers) { 'problem' } else { 'ok' }) $(if ($timers) { ($timers | ForEach-Object { $_ -join ' ' }) -join ' · ' } else { 'aucune' })))
    foreach ($t in $timers | Select-Object -First 3) { $causes.Add((New-Cause 22 'warning' 'DIAG-WAKE-TIMER' "Minuterie qui réveille : $($t[0])" ($t -join ' · ') 'La désactiver si le réveil n''est pas voulu (tasks_set_enabled), ou retirer l''option « réveiller l''ordinateur ».')) }
    $devices = @(Get-Rows (Get-Section $ev 'wake' 'Périphériques qui peuvent réveiller'))
    $checks.Add((New-Check 'Périphériques autorisés à réveiller' 'ok' "$($devices.Count) périphérique(s) : $((@($devices | Select-Object -First 5 | ForEach-Object { $_[0] })) -join ', ')"))
    if ($devices.Count -gt 3) { $causes.Add((New-Cause 8 'info' 'DIAG-WAKE-DEVICES' 'Plusieurs périphériques peuvent réveiller la machine' "$($devices.Count) périphérique(s), dont $((@($devices | Select-Object -First 3 | ForEach-Object { $_[0] })) -join ', ')" 'Windows : Gestionnaire de périphériques › Gestion de l''alimentation ; Linux : /proc/acpi/wakeup.')) }

    $fast = @(Get-Found $ev 'sensors' @('SNS-FASTSTARTUP-ON'))
    $checks.Add((New-FindingCheck 'Démarrage rapide (Windows)' $fast 'désactivé ou sans objet' ($null -ne $ev['sensors'])))
    foreach ($f in $fast) { $causes.Add((New-CauseFrom $f 'DIAG-WAKE-FASTSTARTUP' '« Arrêter » ne fait pas un arrêt complet (démarrage rapide)' 'Désactiver le démarrage rapide (Options d''alimentation) si la machine ne s''éteint pas vraiment.' 10)) }
    New-Diagnosis 'Ne s''éteint pas / se réveille seul' $checks $causes $ev
}

# diagnose_printer : imprimante en panne.
function Get-SIDiagnosisPrinter {
    param([string]$Name)
    $requests = @(@{ Key = 'printing'; Module = 'printing' }, @{ Key = 'network'; Module = 'network' })
    $requests += @{ Key = 'printer'; Module = 'printing'; Function = 'get_printer'; Parameters = $(if ($Name) { @{ name = $Name } } else { @{} }) }
    $ev = Get-Evidence $requests
    $causes = [System.Collections.Generic.List[object]]::new(); $checks = [System.Collections.Generic.List[object]]::new()
    $spooler = @(Get-Found $ev 'printing' @('PRN-SPOOLER-*'))
    $checks.Add((New-FindingCheck 'Service d''impression (spouleur / CUPS)' $spooler 'en marche' ($null -ne $ev['printing'])))
    foreach ($f in $spooler) { $causes.Add((New-CauseFrom $f 'DIAG-PRN-SPOOLER' 'Le service d''impression est arrêté ou en erreur' 'Redémarrer le service et vider la file (maintenance_reset_print_queue).' 20)) }
    $stuck = @(Get-Found $ev 'printing' @('PRN-JOB-STUCK'))
    $checks.Add((New-FindingCheck 'File d''attente' $stuck 'aucun travail bloqué' ($null -ne $ev['printing'])))
    foreach ($f in $stuck) { $causes.Add((New-CauseFrom $f 'DIAG-PRN-STUCK' 'Un travail bloque la file d''attente' 'Vider la file (maintenance_reset_print_queue) puis relancer l''impression.' 15)) }
    $printer = $ev['printer']
    if ($printer.Error) {
        $checks.Add((New-Check 'Imprimante' 'problem' $printer.Error))
        $causes.Add((New-Cause 40 'critical' 'DIAG-PRN-NONE' 'Imprimante introuvable' $printer.Error 'Installer l''imprimante (Paramètres › Imprimantes, ou system-config-printer / CUPS http://localhost:631).'))
    }
    else {
        $problems = @(@(Get-Prop $printer.Data 'Findings') | Where-Object { $_ })
        $checks.Add((New-FindingCheck "Imprimante ($((Get-Prop $printer.Data 'Subtitle') -replace ' · .*$', ''))" $problems 'prête'))
        foreach ($f in $problems) {
            $cause = if ((Get-Prop $f 'Code') -eq 'PRN-UNREACHABLE') { 'L''imprimante ne répond pas sur le réseau' } else { 'L''imprimante signale un problème' }
            $causes.Add((New-CauseFrom $f 'DIAG-PRN-PRINTER' $cause $null 15))
        }
    }
    $net = @(Get-Found $ev 'network' @('NET-NO-CONNECTION', 'NET-WIFI-WEAK'))
    $checks.Add((New-FindingCheck 'Connexion réseau de l''ordinateur' $net 'connecté' ($null -ne $ev['network'])))
    foreach ($f in $net) { $causes.Add((New-CauseFrom $f 'DIAG-PRN-NETWORK' 'L''ordinateur n''est pas bien connecté au réseau' $null)) }
    New-Diagnosis 'Imprimante en panne' $checks $causes $ev
}

# diagnose_malware : suspicion de logiciel malveillant.
function Get-SIDiagnosisMalware {
    $ev = Get-Evidence @(
        @{ Key = 'security'; Module = 'security' }, @{ Key = 'persistence'; Module = 'security'; Function = 'find_persistence'; Parameters = @{ suspiciousOnly = $true } }
        @{ Key = 'tasks'; Module = 'tasks' }, @{ Key = 'system'; Module = 'system' }, @{ Key = 'network'; Module = 'network' }, @{ Key = 'perf'; Module = 'performance' }
    )
    $causes = [System.Collections.Generic.List[object]]::new(); $checks = [System.Collections.Generic.List[object]]::new()
    $av = @(Get-Found $ev 'security' @('SEC-AV-*'))
    $checks.Add((New-FindingCheck 'Antivirus (actif, à jour, menaces)' $av 'actif et à jour' ($null -ne $ev['security'])))
    foreach ($f in $av) { $causes.Add((New-CauseFrom $f 'DIAG-MAL-AV' $(if ((Get-Prop $f 'Code') -eq 'SEC-AV-THREAT') { 'Menace détectée par l''antivirus' } else { 'Protection antivirus insuffisante' }) $null $(if ((Get-Prop $f 'Code') -eq 'SEC-AV-THREAT') { 30 } else { 5 }))) }
    $persist = @(Get-Rows (Get-Section $ev 'persistence' '*') | Where-Object { $_ })
    $pFound = @(@(Get-Prop $ev['persistence'].Data 'Findings') | Where-Object { (Get-Prop $_ 'Code') -like 'SEC-PERSISTENCE*' })
    $checks.Add((New-Check 'Points de persistance suspects (démarrage, services, tâches…)' $(if ($pFound) { 'problem' } elseif ($ev['persistence'].Data) { 'ok' } else { 'unknown' }) $(if ($pFound) { (@($pFound) | Select-Object -First 2 | ForEach-Object { Get-Prop $_ 'Message' }) -join ' · ' } elseif ($ev['persistence'].Data) { 'aucun suspect' } else { "$($ev['persistence'].Error)" })))
    foreach ($f in $pFound | Select-Object -First 3) { $causes.Add((New-CauseFrom $f 'DIAG-MAL-PERSISTENCE' 'Programme suspect lancé automatiquement' 'Vérifier l''éditeur et le chemin ; le désactiver (software_set_startup, tasks_set_enabled) puis lancer une analyse (security_start_scan).' 20)) }
    $tasks = @(Get-Found $ev 'tasks' @('TSK-SUSPICIOUS'))
    $checks.Add((New-FindingCheck 'Tâches planifiées suspectes' $tasks 'aucune' ($null -ne $ev['tasks'])))
    foreach ($f in $tasks) { $causes.Add((New-CauseFrom $f 'DIAG-MAL-TASK' 'Tâche planifiée suspecte' $null 20)) }
    $procs = @(Get-Found $ev 'system' @('SYS-PROC-UNSIGNED'))
    $checks.Add((New-FindingCheck 'Processus non signés (Windows)' $procs 'aucun' ($null -ne $ev['system'])))
    foreach ($f in $procs) { $causes.Add((New-CauseFrom $f 'DIAG-MAL-PROCESS' 'Processus non signé hors des dossiers système' $null 10)) }
    # Connexions sortantes : processus qui parlent à beaucoup d'adresses publiques différentes.
    $conn = @(Get-Rows (Get-Section $ev 'network' 'Connexions TCP établies'))
    $public = @($conn | Where-Object { "$($_[2])" -notmatch '^(10\.|127\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|::1|fe80|\[::1\]|fd)' })
    $byProc = @($public | Group-Object { "$($_[0])" } | Sort-Object Count -Descending)
    $busy = @($byProc | Where-Object Count -ge 15)
    $checks.Add((New-Check 'Connexions sortantes inhabituelles' $(if ($busy) { 'problem' } elseif ($ev['network'].Data) { 'ok' } else { 'unknown' }) $(if ($byProc) { ($byProc | Select-Object -First 3 | ForEach-Object { "$($_.Name) : $($_.Count) connexion(s)" }) -join ' · ' } else { 'aucune connexion publique' })))
    foreach ($b in $busy) { $causes.Add((New-Cause 12 'info' 'DIAG-MAL-CONNECTIONS' "$($b.Name) ouvre beaucoup de connexions" "$($b.Count) connexions vers Internet (normal pour un navigateur ou un client de synchronisation)" 'Vérifier que ce programme est connu ; sinon l''arrêter et lancer une analyse.')) }
    $firewall = @(Get-Found $ev 'security' @('SEC-FIREWALL-OFF', 'SEC-UAC-OFF', 'SEC-ROOT-CERT-ADDED'))
    $checks.Add((New-FindingCheck 'Protections du système (pare-feu, UAC, certificats racines)' $firewall 'en place' ($null -ne $ev['security'])))
    foreach ($f in $firewall) { $causes.Add((New-CauseFrom $f 'DIAG-MAL-PROTECTION' 'Une protection a été désactivée ou modifiée' $null 8)) }
    $cpu = @(Get-Found $ev 'perf' @('PERF-ALERT-CPU', 'PERF-BOTTLENECK-CPU'))
    foreach ($f in $cpu) { $causes.Add((New-CauseFrom $f 'DIAG-MAL-CPU' 'Processeur occupé sans raison apparente (minage ?)' 'Voir les processus les plus gourmands (performance_get_top_consumers).' -5)) }
    $causes.Add((New-Cause 1 'info' 'DIAG-MAL-SCAN' 'Lancer une analyse antivirus complète' 'le diagnostic ne remplace pas une analyse' 'security_start_scan (tâche longue).'))
    New-Diagnosis 'Suspicion de logiciel malveillant' $checks $causes $ev
}

#endregion

#region Vue d'ensemble

# Scénarios et constats des modules qui s'y rattachent (lus dans les vues d'ensemble récentes, sans rien relancer).
$script:Scenarios = @(
    @{ Tool = 'diagnose_slow_pc'; Title = 'PC lent'; Modules = 'performance', 'system', 'boot', 'storage', 'sensors', 'software'; Codes = 'PERF-*', 'SYS-MEM-HIGH', 'SYS-SWAP-HIGH', 'SYS-CPU-HOT', 'SNS-CPU-THROTTLING', 'SNS-TEMP-*', 'SNS-POWER-SAVER', 'BOOT-SLOW*', 'STO-VOLUME-FULL', 'SW-REBOOT-PENDING' }
    @{ Tool = 'diagnose_no_internet'; Title = 'Pas d''Internet / Wi-Fi instable'; Modules = 'network'; Codes = 'NET-NO-CONNECTION', 'NET-DNS-*', 'NET-PACKET-LOSS', 'NET-LATENCY-HIGH', 'NET-WIFI-*', 'NET-LINK-SLOW' }
    @{ Tool = 'diagnose_crashes'; Title = 'Écrans bleus / plantages'; Modules = 'events', 'hardware', 'sensors'; Codes = 'EVT-BSOD', 'EVT-KERNEL-*', 'EVT-UNEXPECTED-SHUTDOWN', 'EVT-APP-CRASHES', 'EVT-HARDWARE-ERROR', 'HW-DEVICE-ERROR', 'SNS-TEMP-CRITICAL' }
    @{ Tool = 'diagnose_disk_full'; Title = 'Disque plein'; Modules = 'storage', 'maintenance', 'virtualization'; Codes = 'STO-VOLUME-FULL', 'STO-INODES-FULL', 'STO-RECLAIMABLE', 'MNT-CLEANUP', 'VIRT-SPACE-RECLAIMABLE' }
    @{ Tool = 'diagnose_wake_issues'; Title = 'Ne s''éteint pas / se réveille seul'; Modules = 'sensors', 'tasks'; Codes = 'SNS-FASTSTARTUP-ON', 'SNS-WAKE-*' }
    @{ Tool = 'diagnose_printer'; Title = 'Imprimante en panne'; Modules = 'printing'; Codes = 'PRN-*' }
    @{ Tool = 'diagnose_malware'; Title = 'Suspicion de logiciel malveillant'; Modules = 'security', 'tasks', 'system'; Codes = 'SEC-AV-*', 'SEC-PERSISTENCE-SUSPECT', 'TSK-SUSPICIOUS', 'SYS-PROC-UNSIGNED', 'SEC-FIREWALL-OFF' }
)

function Get-ModuleData {
    $available = Get-Manifests
    $ids = @($script:Scenarios | ForEach-Object { $_.Modules } | Sort-Object -Unique | Where-Object { $available.Contains($_) })
    $results = @(Invoke-SIModules @($ids | ForEach-Object { @{ Module = $_; Function = $null } }) 120 0)
    $byId = @{}; foreach ($r in $results) { $byId[(Get-Prop $r 'Module')] = Get-Prop $r 'Data' }
    $rows = foreach ($s in $script:Scenarios) {
        $signs = @(foreach ($m in $s.Modules) {
                foreach ($f in @(Get-Prop $byId[$m] 'Findings')) {
                    $code = "$(Get-Prop $f 'Code')"
                    if ($f -and ($s.Codes | Where-Object { $code -like $_ }) -and "$(Get-Prop $f 'Severity')" -in 'warning', 'critical') { Get-Prop $f 'Message' }
                }
            })
        , @($s.Title, $(if ($signs) { "$($signs.Count) signe(s)" } else { 'rien de signalé' }), (($signs | Select-Object -First 2) -join ' · '), $s.Tool)
    }
    $active = @($rows | Where-Object { $_[1] -ne 'rien de signalé' })
    [PSCustomObject]@{
        Subtitle = '{0} scénario(s) · {1} avec des signes en ce moment' -f $rows.Count, $active.Count
        Sections = @(
            [PSCustomObject]@{ Title = 'Scénarios'; Type = 'Table'; Icon = 'search'; Columns = @('Problème', 'Signes actuels', 'Exemples', 'Outil'); Rows = @($rows) }
            [PSCustomObject]@{ Title = 'Fonctionnement'; Type = 'KeyValue'; Icon = 'info'; Items = [ordered]@{
                    'Principe' = 'Chaque diagnostic relève les modules concernés et classe les causes probables, avec la preuve et l''étape suivante'
                    'Corrections' = 'Jamais automatiques : l''étape suivante nomme l''action du module (aperçu puis confirmation)'
                    'Avant / après une intervention' = 'reports_create_snapshot avant, reports_compare après, reports_client_report pour le client' } }
        )
        Findings = @()
    }
}

#endregion

Export-ModuleMember -Function Get-ModuleData, Get-SIDiagnosisSlowPc, Get-SIDiagnosisNoInternet, Get-SIDiagnosisCrashes, Get-SIDiagnosisDiskFull, Get-SIDiagnosisWake, Get-SIDiagnosisPrinter, Get-SIDiagnosisMalware
