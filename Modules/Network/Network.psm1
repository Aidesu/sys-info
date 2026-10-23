# Module Réseau : IP, DNS, DHCP, routes, voisins, ports, connexions TCP, Wi-Fi, proxy, hosts, partages, VPN,
# ping, traceroute, test de port, MTU, IP publique, découverte du réseau local.
#
# Sources
#   Commun  : System.Net.NetworkInformation (interfaces, adresses, passerelles, compteurs d'octets, ping),
#             System.Net.Dns (test de résolution), TcpClient (test de port), api.ipify.org (IP publique, à la demande).
#   Windows : Get-NetRoute, Get-NetNeighbor, Get-NetTCPConnection, Get-NetUDPEndpoint, Win32_NetworkAdapterConfiguration
#             (bail DHCP), Get-DnsClientGlobalSetting, Get-DnsClientCache, Get-SmbShare, Get-SmbMapping, Get-VpnConnection,
#             registre Internet Settings (proxy), netsh wlan (Wi-Fi), tracert, Test-Connection -MtuSize.
#   Linux   : /sys/class/net (interfaces physiques, Wi-Fi), ip -j route / neigh, ss, resolvectl (DNS, domaines),
#             nmcli (DHCP, Wi-Fi, VPN), findmnt -J (montages réseau), variables *_proxy, gsettings (proxy GNOME),
#             traceroute ou tracepath, ping -M do (MTU), avahi-browse (mDNS).
#
# État gardé entre deux appels ($script:) : compteurs d'octets (débit), historique des pings (perte de paquets),
# traceroute lancé en arrière-plan (processus système, relancé toutes les 10 minutes) pour ne jamais bloquer la page.

$script:Fr = [cultureinfo]::GetCultureInfo('fr-FR')
$script:Nbsp = [char]0x00A0
$script:Target = '1.1.1.1'          # cible Internet des pings et du traceroute
$script:PingTimeoutMs = 800
$script:TraceEvery = [timespan]::FromMinutes(10)

$script:PrevBytes = $null           # @{ Interface; Rx; Tx; At }
$script:PingLog = [System.Collections.Generic.Queue[bool]]::new()   # Internet : réussite des 60 derniers pings
$script:TraceProcess = $null
$script:TraceHops = $null
$script:TraceAt = $null

# Seuils de latence vers Internet (ms) : au-delà, la navigation se dégrade nettement.
$script:LatencyWarning = 100; $script:LatencyCritical = 300


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

function Format-Unit([double]$Value, [string]$Unit, [string]$Format = '0.#') {
    '{0}{1}{2}' -f $Value.ToString($Format, $script:Fr), $script:Nbsp, $Unit
}

function Format-LinkSpeed([long]$BitsPerSecond) {
    if ($BitsPerSecond -le 0 -or $BitsPerSecond -ge 1e15) { return $null }
    if ($BitsPerSecond -ge 1e9) { return Format-Unit ($BitsPerSecond / 1e9) 'Gbit/s' }
    Format-Unit ($BitsPerSecond / 1e6) 'Mbit/s' '0'
}

function Format-Mac([System.Net.NetworkInformation.PhysicalAddress]$Address) {
    $bytes = $Address.GetAddressBytes()
    if ($bytes.Count -eq 0 -or -not ($bytes | Where-Object { $_ -ne 0 })) { return $null }
    ($bytes | ForEach-Object { $_.ToString('X2') }) -join ':'
}

# Lance une commande et renvoie ses lignes, ou rien si elle n'existe pas.
function Invoke-Tool([string]$Name, [string[]]$Arguments) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) { return @() }
    & $Name @Arguments 2>$null
}

function Get-Ipv4([System.Net.NetworkInformation.IPInterfaceProperties]$Props) {
    $Props.UnicastAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
}

#endregion

#region Interfaces

# Interfaces physiques (Linux : présence de /sys/class/net/<if>/device) ; Wi-Fi reconnu par /sys/…/wireless
# ou, sous Windows, par le type Wireless80211.
function Get-Interfaces {
    $all = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
        Where-Object { $_.NetworkInterfaceType -notin 'Loopback', 'Tunnel' }

    foreach ($nic in $all) {
        if ($IsLinux) {
            $physical = Test-Path -LiteralPath "/sys/class/net/$($nic.Name)/device"
            $wifi = Test-Path -LiteralPath "/sys/class/net/$($nic.Name)/wireless"
        }
        else {
            $physical = $nic.Description -notmatch 'Virtual|Hyper-V|VMware|VirtualBox|TAP|Loopback|Bluetooth|WAN Miniport|Teredo|isatap'
            $wifi = $nic.NetworkInterfaceType -eq 'Wireless80211'
        }
        $props = $nic.GetIPProperties()
        [PSCustomObject]@{
            Nic      = $nic
            Name     = $nic.Name
            Physical = $physical
            Wifi     = $wifi
            Up       = $nic.OperationalStatus -eq 'Up'
            Ipv4     = Get-Ipv4 $props
            Ipv6     = $props.UnicastAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetworkV6' -and -not $_.Address.IsIPv6LinkLocal } | Select-Object -First 1
            Gateway  = $props.GatewayAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
            Props    = $props
        }
    }
}

# Connexion principale : interface active qui porte une passerelle IPv4 (route par défaut).
function Get-PrimaryInterface($Interfaces) {
    $Interfaces | Where-Object { $_.Up -and $_.Gateway -and $_.Ipv4 } | Select-Object -First 1
}

# Champs de nmcli -t : « : » échappé en « \: » dans les valeurs.
function Split-Nmcli([string]$Line) {
    [regex]::Split($Line, '(?<!\\):') | ForEach-Object { $_ -replace '\\:', ':' }
}

function Get-WifiBand([double]$MHz) {
    if ($MHz -ge 5925) { '6 GHz' } elseif ($MHz -ge 4900) { '5 GHz' } elseif ($MHz -gt 0) { '2,4 GHz' } else { $null }
}

# Réseau Wi-Fi connecté : SSID, signal, canal, bande, sécurité, débit.
function Get-WifiInfo([string]$Interface) {
    if ($IsLinux) {
        $line = Invoke-Tool nmcli @('-t', '-f', 'ACTIVE,SSID,SIGNAL,CHAN,FREQ,SECURITY,RATE', 'device', 'wifi', 'list', 'ifname', $Interface, '--rescan', 'no') |
            Where-Object { $_ -like 'yes:*' } | Select-Object -First 1
        if ($line) {
            $f = Split-Nmcli $line
            return [PSCustomObject]@{
                Ssid = $f[1]; Signal = [int]$f[2]; Channel = $f[3]; Band = Get-WifiBand ([double]($f[4] -replace '\D', ''))
                Security = $f[5]; Rate = $f[6]
            }
        }
        return $null
    }
    # netsh : libellés en français ou en anglais selon la langue de Windows.
    $out = Invoke-Tool netsh @('wlan', 'show', 'interfaces')
    $value = { param($Pattern) ($out | Where-Object { $_ -match "^\s*(?:$Pattern)\s*:\s*(.+)$" } | Select-Object -First 1) -replace '^[^:]*:\s*', '' }
    $ssid = & $value 'SSID'
    if (-not $ssid) { return $null }
    $signal = (& $value 'Signal') -replace '\D', ''
    $band = & $value 'Band|Bande'
    [PSCustomObject]@{
        Ssid = $ssid.Trim(); Signal = if ($signal) { [int]$signal } else { $null }
        Channel = & $value 'Channel|Canal'; Band = if ($band) { $band.Trim() } else { $null }
        Security = & $value 'Authentication|Authentification'
        Rate = (& $value 'Receive rate \(Mbps\)|Vitesse de réception \(Mbits/s\)') + ' Mbit/s'
    }
}

# Réseaux Wi-Fi visibles (sans relancer de balayage) : SSID, signal, canal, bande, sécurité.
function Get-WifiNetworks {
    if ($IsLinux) {
        return Invoke-Tool nmcli @('-t', '-f', 'IN-USE,SSID,SIGNAL,CHAN,FREQ,SECURITY', 'device', 'wifi', 'list', '--rescan', 'no') | ForEach-Object {
            $f = Split-Nmcli $_
            [PSCustomObject]@{
                Ssid = if ($f[1]) { $f[1] } else { '(masqué)' }; Signal = [int]$f[2]; Channel = [int]$f[3]
                Band = Get-WifiBand ([double]($f[4] -replace '\D', '')); Security = $(if ($f[5]) { $f[5] } else { 'Ouvert' }); Connected = $f[0] -eq '*'
            }
        }
    }
    # netsh wlan show networks mode=bssid : blocs « SSID n : nom », puis Signal / Canal / Authentification par BSSID.
    $list = [System.Collections.Generic.List[object]]::new()
    $ssid = $null; $auth = $null; $current = $null
    foreach ($line in Invoke-Tool netsh @('wlan', 'show', 'networks', 'mode=bssid')) {
        if ($line -match '^SSID \d+\s*:\s*(.*)$') { $ssid = if ($Matches[1]) { $Matches[1].Trim() } else { '(masqué)' }; continue }
        if ($line -match '^\s*(Authentication|Authentification)\s*:\s*(.+)$') { $auth = $Matches[2].Trim(); continue }
        if ($line -match '^\s*BSSID \d+') { $current = [PSCustomObject]@{ Ssid = $ssid; Signal = $null; Channel = $null; Band = $null; Security = $auth; Connected = $false }; $list.Add($current); continue }
        if (-not $current) { continue }
        if ($line -match '^\s*Signal\s*:\s*(\d+)') { $current.Signal = [int]$Matches[1] }
        elseif ($line -match '^\s*(Channel|Canal)\s*:\s*(\d+)') { $current.Channel = [int]$Matches[2] }
        elseif ($line -match '^\s*(Band|Bande)\s*:\s*(.+)$') { $current.Band = $Matches[2].Trim() }
    }
    $list
}

#endregion

#region DNS et DHCP

function Get-DnsServers($Primary) {
    if ($IsLinux) {
        # systemd-resolved : vrais serveurs de l'interface (resolv.conf ne montre que le relais 127.0.0.53).
        $line = Invoke-Tool resolvectl @('dns', $Primary.Name) | Select-Object -First 1
        if ($line -match ':\s*(.+)$') { return @($Matches[1] -split '\s+' | Where-Object { $_ }) }
        $servers = Get-Content -Path /etc/resolv.conf -ErrorAction SilentlyContinue |
            Where-Object { $_ -match '^nameserver\s+(\S+)' } | ForEach-Object { ($_ -split '\s+')[1] }
        return @($servers)
    }
    @($Primary.Props.DnsAddresses | ForEach-Object { $_.ToString() })
}

# Suffixes de recherche DNS (domaines ajoutés aux noms courts).
function Get-DnsSuffixes($Primary) {
    if ($IsWindows) {
        $global = (Get-DnsClientGlobalSetting -ErrorAction SilentlyContinue).SuffixSearchList
        return @(@($Primary.Props.DnsSuffix) + @($global) | Where-Object { $_ } | Select-Object -Unique)
    }
    $line = Invoke-Tool resolvectl @('domain', $Primary.Name) | Select-Object -First 1
    if ($line -match ':\s*(.+)$') { return @($Matches[1] -split '\s+' | Where-Object { $_ }) }
    @(Get-Content -Path /etc/resolv.conf -ErrorAction SilentlyContinue | Where-Object { $_ -match '^search\s+' } | ForEach-Object { ($_ -split '\s+')[1..99] })
}

# Test de résolution : un nom connu, avec le temps de réponse (ms) ; $null si échec.
function Test-DnsResolution([string]$Name = 'www.microsoft.com') {
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $task = [System.Net.Dns]::GetHostAddressesAsync($Name)
    $ok = try { $task.Wait(3000) } catch { $false }
    $watch.Stop()
    [PSCustomObject]@{
        Name = $Name; Ok = $ok -and $task.IsCompletedSuccessfully -and $task.Result.Count -gt 0
        Ms = [Math]::Round($watch.Elapsed.TotalMilliseconds); Addresses = if ($ok -and $task.IsCompletedSuccessfully) { @($task.Result | ForEach-Object { "$_" }) } else { @() }
    }
}

# Nombre d'entrées dans le cache DNS local (Windows : Get-DnsClientCache). Linux : « resolvectl statistics » prend
# 2 à 3 s (appel D-Bus lent) ; on s'en passe pour ne pas bloquer le rafraîchissement.
function Get-DnsCacheSize {
    if ($IsWindows) { return @(Get-DnsClientCache -ErrorAction SilentlyContinue).Count }
    $null
}

function Get-DhcpInfo($Primary) {
    if ($IsLinux) {
        # NetworkManager : options DHCP4 de l'interface (serveur, durée et fin du bail).
        $options = @{}
        foreach ($line in Invoke-Tool nmcli @('-t', '-f', 'DHCP4', 'device', 'show', $Primary.Name)) {
            if ($line -match '^DHCP4\.OPTION\[\d+\]:(\w+) = (.*)$') { $options[$Matches[1]] = $Matches[2] }
        }
        if ($options.Count -eq 0) {
            # Sans NetworkManager : la route par défaut d'origine « dhcp » indique au moins que le DHCP est actif.
            $route = (Invoke-Tool ip @('-j', 'route', 'show', 'default')) -join '' | ConvertFrom-Json -ErrorAction SilentlyContinue |
                Where-Object { $_.dev -eq $Primary.Name } | Select-Object -First 1
            return [PSCustomObject]@{ Enabled = $route.protocol -eq 'dhcp'; Server = $null; Lease = $null; Expires = $null }
        }
        return [PSCustomObject]@{
            Enabled = $true
            Server  = $options['dhcp_server_identifier']
            Lease   = if ($options['dhcp_lease_time']) { [timespan]::FromSeconds([double]$options['dhcp_lease_time']) } else { $null }
            Expires = if ($options['expiry']) { [DateTimeOffset]::FromUnixTimeSeconds([long]$options['expiry']).LocalDateTime } else { $null }
        }
    }

    $mac = ($Primary.Nic.GetPhysicalAddress().GetAddressBytes() | ForEach-Object { $_.ToString('X2') }) -join ':'
    $config = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = True' |
        Where-Object { $_.MACAddress -eq $mac } | Select-Object -First 1
    [PSCustomObject]@{
        Enabled = [bool]$config.DHCPEnabled
        Server  = $config.DHCPServer
        Lease   = if ($config.DHCPLeaseObtained -and $config.DHCPLeaseExpires) { $config.DHCPLeaseExpires - $config.DHCPLeaseObtained } else { $null }
        Expires = $config.DHCPLeaseExpires
    }
}

function Format-Span([timespan]$Span) {
    if ($Span.TotalHours -ge 24) { return Format-Unit $Span.TotalDays 'j' '0.#' }
    if ($Span.TotalMinutes -ge 60) { return Format-Unit $Span.TotalHours 'h' '0.#' }
    Format-Unit $Span.TotalMinutes 'min' '0'
}

#endregion

#region Routes, ports, connexions

function Get-Routes {
    if ($IsLinux) {
        $json = (Invoke-Tool ip @('-j', 'route', 'show', 'table', 'main')) -join ''
        if (-not $json) { return @() }
        return $json | ConvertFrom-Json | ForEach-Object {
            [PSCustomObject]@{
                Destination = if ($_.dst -eq 'default') { 'par défaut' } else { $_.dst }
                Gateway     = $_.gateway
                Interface   = $_.dev
                Metric      = $_.metric
                Origin      = $_.protocol
                Down        = $_.flags -contains 'linkdown'
            }
        }
    }
    Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.DestinationPrefix -notlike '224.*' -and $_.DestinationPrefix -ne '255.255.255.255/32' -and $_.DestinationPrefix -notlike '*/32' } |
        ForEach-Object {
            [PSCustomObject]@{
                Destination = if ($_.DestinationPrefix -eq '0.0.0.0/0') { 'par défaut' } else { $_.DestinationPrefix }
                Gateway     = if ($_.NextHop -ne '0.0.0.0') { $_.NextHop } else { $null }
                Interface   = $_.InterfaceAlias
                Metric      = $_.RouteMetric + $_.InterfaceMetric
                Origin      = "$($_.Protocol)".ToLowerInvariant()
                Down        = $false
            }
        }
}

# Adresse « hôte:port » de ss → (adresse, port) ; gère [::]:22, *:5353, 127.0.0.53%lo:53.
function Split-Endpoint([string]$Endpoint) {
    $i = $Endpoint.LastIndexOf(':')
    $address = ($Endpoint.Substring(0, $i) -replace '%[^\]]*', '').Trim('[', ']')   # « [fe80::1]%wlo1 » → fe80::1
    if ($address -eq '*') { $address = '0.0.0.0' }
    [PSCustomObject]@{ Address = $address; Port = [int]$Endpoint.Substring($i + 1) }
}

# « adresse:port », avec crochets pour une adresse IPv6 (sinon le port se confond avec l'adresse).
function Format-Endpoint([string]$Address, [int]$Port) {
    if ($Address.Contains(':')) { return '[{0}]:{1}' -f $Address, $Port }
    '{0}:{1}' -f $Address, $Port
}

# ss : « users:(("sshd",pid=1234,fd=3)) » → « sshd (1234) » ; vide pour les processus d'autres utilisateurs.
function Get-SsProcess([string]$Text) {
    if ($Text -match '\(\("([^"]+)",pid=(\d+)') { return '{0} ({1})' -f $Matches[1], $Matches[2] }
    $null
}

$script:ProcessNames = @{}
function Get-WindowsProcessName([int]$ProcessId) {
    if (-not $script:ProcessNames.ContainsKey($ProcessId)) {
        $script:ProcessNames[$ProcessId] = (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue).ProcessName
    }
    if ($script:ProcessNames[$ProcessId]) { '{0} ({1})' -f $script:ProcessNames[$ProcessId], $ProcessId } else { $null }
}

function Get-ListeningPorts {
    if ($IsLinux) {
        $seen = @{}
        return Invoke-Tool ss @('-H', '-tulnp') | ForEach-Object {
            $f = $_ -split '\s+', 7
            $local = Split-Endpoint $f[4]
            $key = "$($f[0])/$($local.Address)/$($local.Port)"
            if ($seen.ContainsKey($key)) { return }
            $seen[$key] = $true
            [PSCustomObject]@{ Protocol = $f[0].ToUpperInvariant(); Address = $local.Address; Port = $local.Port; Process = Get-SsProcess $f[6] }
        } | Sort-Object Port, Protocol
    }
    $script:ProcessNames = @{}
    $tcp = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | ForEach-Object {
        [PSCustomObject]@{ Protocol = 'TCP'; Address = $_.LocalAddress; Port = [int]$_.LocalPort; Process = Get-WindowsProcessName $_.OwningProcess }
    }
    $udp = Get-NetUDPEndpoint -ErrorAction SilentlyContinue | ForEach-Object {
        [PSCustomObject]@{ Protocol = 'UDP'; Address = $_.LocalAddress; Port = [int]$_.LocalPort; Process = Get-WindowsProcessName $_.OwningProcess }
    }
    @($tcp) + @($udp) | Sort-Object Port, Protocol -Unique
}

function Get-TcpConnections {
    if ($IsLinux) {
        # « state established » : colonnes Recv-Q Send-Q Local Distant Processus.
        return Invoke-Tool ss @('-H', '-tnp', 'state', 'established') | ForEach-Object {
            $f = $_ -split '\s+', 5
            $local = Split-Endpoint $f[2]; $remote = Split-Endpoint $f[3]
            [PSCustomObject]@{ Process = Get-SsProcess $f[4]; Local = Format-Endpoint $local.Address $local.Port; Remote = $remote.Address; Port = $remote.Port }
        }
    }
    Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue | ForEach-Object {
        [PSCustomObject]@{ Process = Get-WindowsProcessName $_.OwningProcess; Local = Format-Endpoint $_.LocalAddress ([int]$_.LocalPort); Remote = $_.RemoteAddress; Port = [int]$_.RemotePort }
    }
}

#endregion

#region Voisins, proxy, hosts, partages, VPN

# Table ARP / voisins IPv4 (adresses joignables récemment), hors multicast et diffusion.
function Get-Neighbors {
    if ($IsLinux) {
        $json = (Invoke-Tool ip @('-j', '-4', 'neigh')) -join ''
        if (-not $json) { return @() }
        $states = @{ REACHABLE = 'Joignable'; STALE = 'Ancienne'; DELAY = 'En vérification'; PROBE = 'En vérification'; PERMANENT = 'Statique'; FAILED = 'Injoignable'; INCOMPLETE = 'Incomplète' }
        return $json | ConvertFrom-Json | Where-Object { $_.lladdr } | ForEach-Object {
            $state = @($_.state)[0]
            [PSCustomObject]@{ Address = $_.dst; Mac = $_.lladdr.ToUpperInvariant(); Interface = $_.dev; State = $states[$state] ?? $state }
        }
    }
    $states = @{ Reachable = 'Joignable'; Stale = 'Ancienne'; Delay = 'En vérification'; Probe = 'En vérification'; Permanent = 'Statique' }
    Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.State -in 'Reachable', 'Stale', 'Delay', 'Probe', 'Permanent' -and $_.LinkLayerAddress -notin '00-00-00-00-00-00', 'FF-FF-FF-FF-FF-FF' -and $_.IPAddress -notmatch '^(22[4-9]|23\d|255)\.' } |
        ForEach-Object { [PSCustomObject]@{ Address = $_.IPAddress; Mac = $_.LinkLayerAddress -replace '-', ':'; Interface = $_.InterfaceAlias; State = $states["$($_.State)"] } }
}

# Proxy système.
# Windows : HKCU\…\Internet Settings (ProxyEnable, ProxyServer, AutoConfigURL).
# Linux   : variables http(s)_proxy / no_proxy, puis réglages GNOME (gsettings) ou KDE (kioslaverc).
function Get-ProxyInfo {
    $items = [ordered]@{}
    if ($IsWindows) {
        $settings = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
        if ($settings.ProxyEnable -eq 1 -and $settings.ProxyServer) { $items['Proxy'] = $settings.ProxyServer }
        if ($settings.AutoConfigURL) { $items['Configuration automatique'] = $settings.AutoConfigURL }
        if ($settings.ProxyOverride -and $items.Count -gt 0) { $items['Exceptions'] = $settings.ProxyOverride }
        return $items
    }
    foreach ($name in 'https_proxy', 'http_proxy', 'all_proxy', 'no_proxy') {
        $value = [Environment]::GetEnvironmentVariable($name) ?? [Environment]::GetEnvironmentVariable($name.ToUpperInvariant())
        if ($value) { $items[$name] = $value }
    }
    if (Get-Command gsettings -ErrorAction SilentlyContinue) {
        $mode = (& gsettings get org.gnome.system.proxy mode 2>$null) -replace "'", ''
        if ($mode -eq 'manual') {
            $proxyHost = (& gsettings get org.gnome.system.proxy.https host 2>$null) -replace "'", ''
            $port = & gsettings get org.gnome.system.proxy.https port 2>$null
            if ($proxyHost) { $items['Proxy (GNOME)'] = "${proxyHost}:$port" }
        }
        elseif ($mode -eq 'auto') { $items['Proxy (GNOME)'] = 'Configuration automatique : ' + ((& gsettings get org.gnome.system.proxy autoconfig-url 2>$null) -replace "'", '') }
    }
    $kde = Join-Path $HOME '.config/kioslaverc'
    if (Test-Path $kde) {
        $type = Get-Content $kde | Where-Object { $_ -match '^ProxyType=(\d)' } | Select-Object -First 1
        $kinds = @{ '1' = 'manuel'; '2' = 'script PAC'; '3' = 'détection automatique'; '4' = 'variables d''environnement' }
        if ($type -match '=(\d)' -and $kinds.ContainsKey($Matches[1])) { $items['Proxy (KDE)'] = $kinds[$Matches[1]] }
    }
    $items
}

# Entrées ajoutées au fichier hosts (hors localhost et entrées IPv6 standard).
function Get-HostsEntries {
    $path = if ($IsWindows) { Join-Path $env:SystemRoot 'System32\drivers\etc\hosts' } else { '/etc/hosts' }
    Get-Content -Path $path -ErrorAction SilentlyContinue | ForEach-Object {
        $line = ($_ -replace '#.*$', '').Trim()
        if (-not $line) { return }
        $f = $line -split '\s+'
        $names = @($f | Select-Object -Skip 1 | Where-Object { $_ -notmatch '^(localhost|localhost\.localdomain|localhost4|localhost6|ip6-\w+|localhost[46]?\.localdomain[46]?)$' })
        if ($names.Count -eq 0) { return }
        [PSCustomObject]@{ Address = $f[0]; Names = $names -join ' ' }
    }
}

# Partages : dossiers partagés par cette machine, lecteurs et montages réseau.
# Windows : Get-SmbShare (hors partages administratifs C$, IPC$…), Get-SmbMapping.
# Linux   : findmnt -J (cifs, smb3, nfs, nfs4, sshfs) ; partages Samba utilisateur (net usershare list).
function Get-NetworkShares {
    if ($IsWindows) {
        $local = Get-SmbShare -ErrorAction SilentlyContinue | Where-Object { -not $_.Special } | ForEach-Object {
            [PSCustomObject]@{ Kind = 'Partagé par cette machine'; Name = $_.Name; Source = $_.Path; Target = $null; State = $null }
        }
        $mapped = Get-SmbMapping -ErrorAction SilentlyContinue | ForEach-Object {
            [PSCustomObject]@{ Kind = 'Lecteur réseau'; Name = $_.LocalPath; Source = $_.RemotePath; Target = $_.LocalPath; State = "$($_.Status)" }
        }
        return @($local) + @($mapped)
    }
    $mounts = (Invoke-Tool findmnt @('-J', '-t', 'cifs,smb3,nfs,nfs4,fuse.sshfs', '-o', 'TARGET,SOURCE,FSTYPE')) -join ''
    $list = @()
    if ($mounts) {
        $list += ($mounts | ConvertFrom-Json).filesystems | ForEach-Object {
            [PSCustomObject]@{ Kind = "Montage $($_.fstype)"; Name = Split-Path -Leaf $_.target; Source = $_.source; Target = $_.target; State = 'Monté' }
        }
    }
    $list += Invoke-Tool net @('usershare', 'list') | Where-Object { $_ } | ForEach-Object {
        [PSCustomObject]@{ Kind = 'Partagé par cette machine'; Name = $_; Source = $null; Target = $null; State = $null }
    }
    $list
}

# VPN actifs.
# Windows : Get-VpnConnection (utilisateur et tous les utilisateurs) + cartes WireGuard / OpenVPN / TAP actives.
# Linux   : connexions NetworkManager de type vpn / wireguard actives + interfaces tunnel actives (wg*, tun*, ppp*,
#           tailscale*, proton*, nordlynx, zt*).
function Get-VpnConnections($Interfaces) {
    $list = [System.Collections.Generic.List[object]]::new()
    if ($IsWindows) {
        foreach ($v in @(Get-VpnConnection -ErrorAction SilentlyContinue) + @(Get-VpnConnection -AllUserConnection -ErrorAction SilentlyContinue)) {
            if ($v.ConnectionStatus -eq 'Connected') { $list.Add([PSCustomObject]@{ Name = $v.Name; Kind = "$($v.TunnelType)"; Server = $v.ServerAddress; Interface = $null }) }
        }
        foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($nic.OperationalStatus -eq 'Up' -and $nic.Description -match 'WireGuard|OpenVPN|TAP-Windows|Wintun|Tailscale|NordLynx|ProtonVPN|Cisco AnyConnect|FortiClient') {
                $list.Add([PSCustomObject]@{ Name = $nic.Name; Kind = $nic.Description; Server = $null; Interface = $nic.Name })
            }
        }
        return $list
    }
    $seen = @{}
    foreach ($line in Invoke-Tool nmcli @('-t', '-f', 'NAME,TYPE,DEVICE', 'connection', 'show', '--active')) {
        $f = Split-Nmcli $line
        if ($f[1] -in 'vpn', 'wireguard') {
            $list.Add([PSCustomObject]@{ Name = $f[0]; Kind = $f[1]; Server = $null; Interface = $f[2] })
            if ($f[2]) { $seen[$f[2]] = $true }
        }
    }
    foreach ($i in $Interfaces | Where-Object { $_.Up -and $_.Name -match '^(wg|tun\d|ppp|tailscale|proton|nordlynx|zt|ipsec)' }) {
        if (-not $seen.ContainsKey($i.Name)) { $list.Add([PSCustomObject]@{ Name = $i.Name; Kind = 'tunnel'; Server = $null; Interface = $i.Name }) }
    }
    $list
}

#endregion

#region Débit, latence, traceroute

# Débit de l'interface principale en Mbit/s, par différence avec l'appel précédent.
function Get-Throughput($Primary) {
    $stats = $Primary.Nic.GetIPStatistics()
    $now = [DateTime]::UtcNow
    $previous = $script:PrevBytes
    $script:PrevBytes = @{ Interface = $Primary.Name; Rx = $stats.BytesReceived; Tx = $stats.BytesSent; At = $now }
    if (-not $previous -or $previous.Interface -ne $Primary.Name) { return $null }
    $seconds = ($now - $previous.At).TotalSeconds
    if ($seconds -le 0) { return $null }
    [PSCustomObject]@{
        Down = [Math]::Round([Math]::Max(0, $stats.BytesReceived - $previous.Rx) * 8 / 1e6 / $seconds, 2)
        Up   = [Math]::Round([Math]::Max(0, $stats.BytesSent - $previous.Tx) * 8 / 1e6 / $seconds, 2)
    }
}

# Deux pings en parallèle (Internet, passerelle) : temps aller-retour en ms, ou $null si perdu.
function Get-Latency([string]$Gateway) {
    $targets = @($script:Target) + @($Gateway | Where-Object { $_ })
    $tasks = foreach ($t in $targets) { [System.Net.NetworkInformation.Ping]::new().SendPingAsync($t, $script:PingTimeoutMs) }
    try { [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]$tasks, $script:PingTimeoutMs + 200) } catch { }
    $results = foreach ($task in $tasks) {
        if ($task.IsCompletedSuccessfully -and $task.Result.Status -eq 'Success') { [double]$task.Result.RoundtripTime } else { $null }
    }
    $internet = $results[0]
    $script:PingLog.Enqueue($null -ne $internet)
    while ($script:PingLog.Count -gt 60) { [void]$script:PingLog.Dequeue() }
    [PSCustomObject]@{ Internet = $internet; Gateway = if ($targets.Count -gt 1) { $results[1] } else { $null } }
}

# Traceroute en arrière-plan : lancé ici, relu aux appels suivants une fois terminé.
function Update-Traceroute {
    if ($script:TraceProcess) {
        if (-not $script:TraceProcess.HasExited) { return }
        $script:TraceHops = @(ConvertFrom-Traceroute ($script:TraceProcess.StandardOutput.ReadToEnd() -split "`r?`n"))
        $script:TraceAt = Get-Date
        $script:TraceProcess.Dispose()
        $script:TraceProcess = $null
        return
    }
    if ($script:TraceAt -and ((Get-Date) - $script:TraceAt) -lt $script:TraceEvery) { return }

    # Parenthèses : dans @(a, b + c), la virgule passe avant le +.

    $command = if ($IsWindows) { @('tracert', ('-d -h 15 -w 800 ' + $script:Target)) }
               elseif (Get-Command traceroute -ErrorAction SilentlyContinue) { @('traceroute', ('-n -q 1 -w 1 -m 15 ' + $script:Target)) }
               elseif (Get-Command tracepath -ErrorAction SilentlyContinue) { @('tracepath', ('-n -m 15 ' + $script:Target)) }
               else { $null }
    if (-not $command) { $script:TraceHops = @(); $script:TraceAt = Get-Date; return }

    $info = [System.Diagnostics.ProcessStartInfo]::new($command[0], $command[1])
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $script:TraceProcess = [System.Diagnostics.Process]::Start($info)
}

# Sorties de traceroute (Linux), tracepath (Linux) et tracert (Windows) → sauts (numéro, adresse, ms).
function ConvertFrom-Traceroute([string[]]$Lines) {
    $hops = [ordered]@{}
    foreach ($line in $Lines) {
        if ($line -notmatch '^\s*(\d+):?\s+(.*)$') { continue }
        $hop = [int]$Matches[1]; $rest = $Matches[2]
        $key = "$hop"   # clé texte : sur un OrderedDictionary, une clé entière serait lue comme une position
        if ($hops.Contains($key) -and $hops[$key].Address) { continue }   # tracepath répète les sauts
        $address = [regex]::Match($rest, '(\d{1,3}(\.\d{1,3}){3}|[0-9a-f]*:[0-9a-f:]+)').Value
        $times = [regex]::Matches($rest, '<?([\d.]+)\s*ms') | ForEach-Object { [double]::Parse($_.Groups[1].Value, [cultureinfo]::InvariantCulture) }
        $hops[$key] = [PSCustomObject]@{
            Hop     = $hop
            Address = if ($address) { $address } else { $null }
            Ms      = if ($times) { [Math]::Round(($times | Measure-Object -Average).Average, 1) } else { $null }
        }
    }
    $hops.Values
}

#endregion

function Get-ModuleData {
    $sections = [System.Collections.Generic.List[object]]::new()
    $findings = [System.Collections.Generic.List[object]]::new()
    $errors = [ordered]@{}
    function Add-Finding([string]$Severity, [string]$Code, [string]$Message, [string]$Recommendation) {
        $findings.Add([PSCustomObject]@{ Severity = $Severity; Code = $Code; Message = $Message; Recommendation = $Recommendation })
    }

    # Chaque bloc est indépendant ; il renvoie sa valeur (une affectation dans le bloc ne remonterait pas).
    function Invoke-Block([string]$Name, [scriptblock]$Block) {
        try { & $Block } catch { $errors[$Name] = $_.Exception.Message; $null }
    }

    $interfaces = @(Invoke-Block 'Interfaces' { Get-Interfaces })
    $primary = Get-PrimaryInterface $interfaces
    Invoke-Block 'Traceroute' { Update-Traceroute }

    # Premier appel : point de départ du débit, puis un court échantillon.
    if ($primary -and -not $script:PrevBytes) {
        [void](Invoke-Block 'Débit' { Get-Throughput $primary })
        Start-Sleep -Milliseconds 250
    }

    $subtitle = 'Aucune connexion réseau'
    if (-not $primary) {
        Add-Finding 'critical' 'NET-NO-CONNECTION' 'Aucune connexion réseau avec une passerelle' `
            'Vérifier le câble ou le Wi-Fi, puis que l''interface obtient une adresse (DHCP).'
    }
    if ($primary) {
        $subtitle = '{0} · {1} · passerelle {2}' -f $primary.Name, $primary.Ipv4.Address, $primary.Gateway.Address

        # Débit et latence : deux graphiques à deux séries (Metric + Secondary)
        $traffic = Invoke-Block 'Débit' { Get-Throughput $primary }
        $speed = Format-LinkSpeed $primary.Nic.Speed
        $sections.Add([PSCustomObject]@{
                Title = 'Débit'; Type = 'Metric'; Icon = 'top_speed'; Unit = 'Mbit/s'
                Label = 'Réception'; Value = $traffic.Down
                Secondary = [PSCustomObject]@{ Label = 'Émission'; Value = $traffic.Up }
                Detail = ('Interface {0}{1}' -f $primary.Name, $(if ($speed) { " · lien à $speed" } else { '' }))
            })

        $latency = Invoke-Block 'Latence' { Get-Latency $primary.Gateway.Address.ToString() }
        if ($latency) {
            $lost = @($script:PingLog | Where-Object { -not $_ }).Count
            $loss = 100 * $lost / [Math]::Max(1, $script:PingLog.Count)
            $sections.Add([PSCustomObject]@{
                    Title = 'Latence'; Type = 'Metric'; Icon = 'timer'; Unit = 'ms'
                    Label = "Internet ($($script:Target))"; Value = $latency.Internet
                    Secondary = [PSCustomObject]@{ Label = "Passerelle ($($primary.Gateway.Address))"; Value = $latency.Gateway }
                    Warning = $script:LatencyWarning; Critical = $script:LatencyCritical
                    Detail = ('Perte de paquets vers Internet : {0} sur les {1} derniers pings' -f (Format-Unit $loss '%' '0'), $script:PingLog.Count)
                })

            # Constats après au moins 10 pings, pour ne pas alerter sur un seul paquet perdu au démarrage.
            if ($script:PingLog.Count -ge 10 -and $loss -ge 10) {
                Add-Finding $(if ($loss -ge 50) { 'critical' } else { 'warning' }) 'NET-PACKET-LOSS' `
                    ('Perte de {0} des pings vers Internet ({1} derniers)' -f (Format-Unit $loss '%' '0'), $script:PingLog.Count) `
                    $(if ($null -eq $latency.Gateway) { 'La passerelle ne répond pas non plus : problème local (câble, Wi-Fi, box).' } else { 'La passerelle répond : problème côté box ou fournisseur d''accès.' })
            }
            if ($null -ne $latency.Internet -and $latency.Internet -ge $script:LatencyWarning) {
                Add-Finding $(if ($latency.Internet -ge $script:LatencyCritical) { 'critical' } else { 'warning' }) 'NET-LATENCY-HIGH' `
                    ('Latence vers Internet : {0}' -f (Format-Unit $latency.Internet 'ms' '0')) `
                    'Vérifier les téléchargements en cours et la qualité de la connexion (Wi-Fi, box).'
            }
        }

        # Connexion principale
        $items = [ordered]@{
            'Interface' = $primary.Name
            'Type'      = if ($primary.Wifi) { 'Wi-Fi' } else { 'Ethernet' }
        }
        if ($primary.Wifi) {
            $wifi = Invoke-Block 'Wi-Fi' { Get-Cached 'wifi' 10 { Get-WifiInfo $primary.Name } }
            if ($wifi) {
                $items['Réseau Wi-Fi'] = $wifi.Ssid
                if ($null -ne $wifi.Signal) { $items['Signal'] = Format-Unit $wifi.Signal '%' '0' }
                $radio = @($wifi.Band, $(if ($wifi.Channel) { "canal $($wifi.Channel)" })) | Where-Object { $_ }
                if ($radio) { $items['Bande'] = $radio -join ' · ' }
                if ($wifi.Security) { $items['Sécurité'] = $wifi.Security }
                if ($wifi.Rate -and $wifi.Rate -ne ' Mbit/s') { $items['Débit radio'] = $wifi.Rate }
                if ($null -ne $wifi.Signal -and $wifi.Signal -lt 40) {
                    Add-Finding 'warning' 'NET-WIFI-WEAK' ('Signal Wi-Fi faible : {0} sur {1}' -f (Format-Unit $wifi.Signal '%' '0'), $wifi.Ssid) `
                        'Se rapprocher du point d''accès, préférer la bande 5 GHz ou un câble Ethernet.'
                }
            }
        }
        if ($speed) { $items['Vitesse du lien'] = $speed }
        if (-not $primary.Wifi -and $primary.Nic.Speed -gt 0 -and $primary.Nic.Speed -lt 1e9) {
            Add-Finding 'info' 'NET-LINK-SLOW' ('Lien Ethernet à {0}' -f $speed) `
                'Un lien sous 1 Gbit/s indique souvent un câble abîmé ou de catégorie insuffisante (Cat 5e minimum).'
        }
        $items['Adresse IPv4'] = '{0}/{1}' -f $primary.Ipv4.Address, $primary.Ipv4.PrefixLength
        if ($primary.Ipv6) { $items['Adresse IPv6'] = '{0}/{1}' -f $primary.Ipv6.Address, $primary.Ipv6.PrefixLength }
        $items['Passerelle'] = "$($primary.Gateway.Address)"
        $mac = Format-Mac $primary.Nic.GetPhysicalAddress()
        if ($mac) { $items['Adresse MAC'] = $mac }
        $virtual = @($interfaces | Where-Object { -not $_.Physical }).Count
        if ($virtual -gt 0) { $items['Interfaces virtuelles'] = '{0} (conteneurs, VM, ponts)' -f $virtual }
        $sections.Add([PSCustomObject]@{
                Title = 'Connexion principale'; Type = 'KeyValue'; Icon = $(if ($primary.Wifi) { 'wifi_1' } else { 'plug_connected' })
                Items = $items
            })

        # DNS : serveurs, suffixes, test de résolution (toutes les 30 s), cache local
        Invoke-Block 'DNS' {
            $servers = Get-Cached 'dns' 10 { Get-DnsServers $primary }
            $dns = [ordered]@{ 'Serveurs' = if ($servers) { $servers -join ', ' } else { 'Aucun' } }
            if ($IsLinux -and (Get-Command resolvectl -ErrorAction SilentlyContinue)) { $dns['Résolveur'] = 'systemd-resolved (relais local 127.0.0.53)' }
            $suffixes = @(Get-Cached 'suffixes' 30 { Get-DnsSuffixes $primary })
            if ($suffixes.Count -gt 0) { $dns['Suffixes de recherche'] = $suffixes -join ', ' }
            $test = Get-Cached 'resolve' 30 { Test-DnsResolution }
            $dns['Test de résolution'] = if ($test.Ok) { '{0} résolu en {1}' -f $test.Name, (Format-Unit $test.Ms 'ms' '0') } else { "Échec pour $($test.Name)" }
            $cache = Get-Cached 'dnscache' 60 { Get-DnsCacheSize }
            if ($null -ne $cache) { $dns['Cache local'] = '{0} entrée(s)' -f $cache }
            $sections.Add([PSCustomObject]@{ Title = 'DNS'; Type = 'KeyValue'; Icon = 'globe'; Items = $dns })

            if (-not $test.Ok) {
                Add-Finding $(if ($latency -and $null -ne $latency.Internet) { 'critical' } else { 'warning' }) 'NET-DNS-FAIL' `
                    ('La résolution de {0} échoue' -f $test.Name) `
                    $(if ($latency -and $null -ne $latency.Internet) { 'Internet répond mais pas le DNS : changer de serveur DNS (ex. 1.1.1.1) ou redémarrer la box.' } else { 'Vérifier d''abord la connexion à Internet.' })
            }
            elseif ($test.Ms -ge 500) {
                Add-Finding 'info' 'NET-DNS-SLOW' ('Résolution DNS lente : {0}' -f (Format-Unit $test.Ms 'ms' '0')) 'Un serveur DNS plus proche ou plus rapide accélère la navigation.'
            }
        }

        # DHCP
        Invoke-Block 'DHCP' {
            $dhcp = Get-Cached 'dhcp' 10 { Get-DhcpInfo $primary }
            $lease = [ordered]@{ 'État' = if ($dhcp.Enabled) { 'Activé' } else { 'Désactivé (adresse fixe)' } }
            if ($dhcp.Server) { $lease['Serveur DHCP'] = $dhcp.Server }
            if ($dhcp.Lease) { $lease['Durée du bail'] = Format-Span $dhcp.Lease }
            if ($dhcp.Expires) {
                $lease['Fin du bail'] = $dhcp.Expires.ToString('dd/MM/yyyy HH:mm', $script:Fr)
                $left = $dhcp.Expires - (Get-Date)
                if ($left.TotalSeconds -gt 0) { $lease['Temps restant'] = Format-Span $left }
            }
            $sections.Add([PSCustomObject]@{ Title = 'DHCP'; Type = 'KeyValue'; Icon = 'router'; Items = $lease })
        }
    }

    # Interfaces physiques
    $physical = @($interfaces | Where-Object Physical)
    if ($physical.Count -gt 0) {
        $rows = foreach ($i in $physical | Sort-Object { -not $_.Up }, Name) {
            , @($i.Name, $(if ($i.Wifi) { 'Wi-Fi' } else { 'Ethernet' }), $(if ($i.Up) { 'Connectée' } else { 'Déconnectée' }),
                $(if ($i.Ipv4) { "$($i.Ipv4.Address)" } else { $null }), (Format-Mac $i.Nic.GetPhysicalAddress()),
                $(if ($i.Up -and $i.Nic.Speed -gt 0 -and $i.Nic.Speed -lt 1e15) { [Math]::Round($i.Nic.Speed / 1e6) } else { $null }))
        }
        $sections.Add([PSCustomObject]@{
                Title = 'Interfaces physiques'; Type = 'Table'; Icon = 'link'
                Columns = @('Interface', 'Type', 'État', 'IPv4', 'Adresse MAC', 'Vitesse (Mbit/s)')
                Rows = @($rows)
            })
    }

    # Wi-Fi : réseaux visibles (seulement s'il y a une carte Wi-Fi ; pas de nouveau balayage)
    if ($interfaces | Where-Object Wifi) {
        Invoke-Block 'Réseaux Wi-Fi' {
            $networks = @(Get-Cached 'wifinetworks' 30 { Get-WifiNetworks })
            if ($networks.Count -gt 0) {
                $rows = foreach ($n in $networks | Sort-Object { -not $_.Connected }, { -$_.Signal } | Select-Object -First 40) {
                    , @($n.Ssid, $n.Signal, $n.Channel, $n.Band, $n.Security, $(if ($n.Connected) { 'Oui' } else { $null }))
                }
                $sections.Add([PSCustomObject]@{
                        Title = 'Réseaux Wi-Fi visibles'; Type = 'Table'; Icon = 'wifi_1'
                        Columns = @('Réseau', 'Signal (%)', 'Canal', 'Bande', 'Sécurité', 'Connecté')
                        Rows = @($rows)
                    })
                foreach ($n in $networks | Where-Object { $_.Connected -and $_.Security -match 'WEP|Ouvert|^$|--' }) {
                    Add-Finding 'warning' 'NET-WIFI-INSECURE' ('Connecté au réseau Wi-Fi {0} sans chiffrement sûr ({1})' -f $n.Ssid, $n.Security) `
                        'Utiliser un VPN ou un réseau WPA2 / WPA3.'
                }
            }
        }
    }

    # Voisins (table ARP)
    Invoke-Block 'Voisins' {
        $neighbors = @(Get-Cached 'neighbors' 10 { Get-Neighbors })
        if ($neighbors.Count -gt 0) {
            $rows = foreach ($n in $neighbors | Sort-Object Interface, { [version]($_.Address -replace '[^\d.]', '') }) { , @($n.Address, $n.Mac, $n.Interface, $n.State) }
            $sections.Add([PSCustomObject]@{
                    Title = 'Voisins (table ARP)'; Type = 'Table'; Icon = 'router'
                    Columns = @('Adresse IP', 'Adresse MAC', 'Interface', 'État'); Rows = @($rows)
                })
        }
    }

    # Routes IPv4
    Invoke-Block 'Routes' {
        $routes = @(Get-Cached 'routes' 10 { Get-Routes })
        if ($routes.Count -gt 0) {
            $rows = foreach ($r in $routes) {
                , @($r.Destination, $r.Gateway, $r.Interface, $r.Metric, $(if ($r.Down) { "$($r.Origin) · lien coupé" } else { $r.Origin }))
            }
            $sections.Add([PSCustomObject]@{
                    Title = 'Routes IPv4'; Type = 'Table'; Icon = 'arrow_routing'
                    Columns = @('Destination', 'Passerelle', 'Interface', 'Métrique', 'Origine')
                    Rows = @($rows)
                })
        }
    }

    # Ports en écoute : une ligne par port et protocole, les adresses d'écoute regroupées
    Invoke-Block 'Ports' {
        $groups = @(Get-Cached 'ports' 10 { Get-ListeningPorts } | Group-Object Port, Protocol)
        if ($groups.Count -gt 0) {
            $rows = foreach ($g in $groups) {
                $first = $g.Group[0]
                $addresses = $g.Group.Address | Select-Object -Unique
                $where = if ($addresses -contains '0.0.0.0' -or $addresses -contains '::') { 'toutes les interfaces' } else { $addresses -join ', ' }
                $process = ($g.Group.Process | Where-Object { $_ } | Select-Object -Unique) -join ', '
                , @($first.Port, $first.Protocol, $where, $(if ($process) { $process } else { $null }))
            }
            $sections.Add([PSCustomObject]@{
                    Title = 'Ports en écoute'; Type = 'Table'; Icon = 'server'
                    Columns = @('Port', 'Protocole', 'Écoute sur', 'Processus')
                    Rows = @($rows)
                })
        }
    }

    # Connexions TCP établies
    Invoke-Block 'Connexions' {
        $connections = @(Get-Cached 'connections' 10 { Get-TcpConnections })
        $rows = foreach ($c in $connections | Sort-Object Process, Remote | Select-Object -First 200) {
            , @($c.Process, $c.Local, $c.Remote, $c.Port)
        }
        if ($connections.Count -gt 0) {
            $sections.Add([PSCustomObject]@{
                    Title = 'Connexions TCP établies'; Type = 'Table'; Icon = 'arrow_swap'
                    Columns = @('Processus', 'Adresse locale', 'Adresse distante', 'Port distant')
                    Rows = @($rows)
                })
        }
    }

    # VPN, partages, proxy et hosts
    Invoke-Block 'VPN' {
        $vpn = @(Get-Cached 'vpn' 10 { Get-VpnConnections $interfaces })
        if ($vpn.Count -gt 0) {
            $rows = foreach ($v in $vpn) { , @($v.Name, $v.Kind, $v.Server, $v.Interface) }
            $sections.Add([PSCustomObject]@{ Title = 'VPN actifs'; Type = 'Table'; Icon = 'lock_closed'; Columns = @('Connexion', 'Type', 'Serveur', 'Interface'); Rows = @($rows) })
        }
        else {
            $sections.Add([PSCustomObject]@{ Title = 'VPN actifs'; Type = 'KeyValue'; Icon = 'lock_closed'; Items = [ordered]@{ 'État' = 'Aucun VPN actif' } })
        }
    }

    Invoke-Block 'Partages' {
        $shares = @(Get-Cached 'shares' 30 { Get-NetworkShares })
        if ($shares.Count -gt 0) {
            $rows = foreach ($sh in $shares) { , @($sh.Kind, $sh.Name, $sh.Source, $sh.Target, $sh.State) }
            $sections.Add([PSCustomObject]@{
                    Title = 'Partages et lecteurs réseau'; Type = 'Table'; Icon = 'hard_drive'
                    Columns = @('Type', 'Nom', 'Source', 'Point de montage', 'État'); Rows = @($rows)
                })
        }
    }

    Invoke-Block 'Proxy et hosts' {
        $proxy = Get-Cached 'proxy' 30 { Get-ProxyInfo }
        $hosts = @(Get-Cached 'hosts' 30 { Get-HostsEntries })
        $items = [ordered]@{}
        if ($proxy.Count -gt 0) { foreach ($k in $proxy.Keys) { $items[$k] = $proxy[$k] } } else { $items['Proxy'] = 'Aucun (connexion directe)' }
        $items['Fichier hosts'] = if ($hosts.Count -gt 0) { '{0} entrée(s) ajoutée(s)' -f $hosts.Count } else { 'Aucune entrée ajoutée' }
        $sections.Add([PSCustomObject]@{ Title = 'Proxy et fichier hosts'; Type = 'KeyValue'; Icon = 'settings'; Items = $items })
        if ($hosts.Count -gt 0) {
            $rows = foreach ($h in $hosts | Select-Object -First 100) { , @($h.Address, $h.Names) }
            $sections.Add([PSCustomObject]@{ Title = 'Entrées du fichier hosts'; Type = 'Table'; Icon = 'globe'; Columns = @('Adresse', 'Noms'); Rows = @($rows) })
            Add-Finding 'info' 'NET-HOSTS-CUSTOM' ('{0} entrée(s) ajoutée(s) au fichier hosts' -f $hosts.Count) `
                'Normal pour du développement ; sinon, vérifier qu''aucun site connu n''est redirigé (signe de logiciel malveillant).'
        }
        if ($proxy.Count -gt 0) {
            Add-Finding 'info' 'NET-PROXY' ('Proxy configuré : {0}' -f (@($proxy.Values) -join ' · ')) 'Si la navigation échoue, vérifier que ce proxy est attendu et joignable.'
        }
    }

    # Traceroute
    if ($script:TraceHops -and $script:TraceHops.Count -gt 0) {
        $rows = foreach ($h in $script:TraceHops) { , @($h.Hop, $(if ($h.Address) { $h.Address } else { 'pas de réponse' }), $h.Ms) }
        $sections.Add([PSCustomObject]@{
                Title = ('Traceroute vers {0} · relevé à {1}' -f $script:Target, $script:TraceAt.ToString('HH:mm', $script:Fr))
                Type = 'Table'; Icon = 'network_check'
                Columns = @('Saut', 'Adresse', 'Latence (ms)')
                Rows = @($rows)
            })
    }
    else {
        $state = if ($script:TraceProcess) { 'En cours… (résultat au prochain rafraîchissement)' }
                 elseif ($script:TraceHops) { 'Aucun saut relevé (traceroute indisponible ou bloqué)' }
                 else { 'En attente' }
        $sections.Add([PSCustomObject]@{
                Title = "Traceroute vers $($script:Target)"; Type = 'KeyValue'; Icon = 'network_check'
                Items = [ordered]@{ 'État' = $state }
            })
    }

    if ($errors.Count -gt 0) {
        $sections.Add([PSCustomObject]@{ Title = 'Erreurs'; Type = 'KeyValue'; Icon = 'warning'; Items = $errors })
    }

    [PSCustomObject]@{ Subtitle = $subtitle; Sections = $sections.ToArray(); Findings = $findings.ToArray() }
}

#region Fonctions ciblées (module.json › functions)

function New-Result([string]$Subtitle, [object[]]$Sections, [object[]]$Findings = @()) {
    [PSCustomObject]@{ Subtitle = $Subtitle; Sections = @($Sections); Findings = @($Findings) }
}

function New-Finding([string]$Severity, [string]$Code, [string]$Message, [string]$Recommendation) {
    [PSCustomObject]@{ Severity = $Severity; Code = $Code; Message = $Message; Recommendation = $Recommendation }
}

# Nom ou adresse → première adresse IP (IPv4 de préférence).
function Resolve-Target([string]$Target) {
    $ip = $null
    if ([System.Net.IPAddress]::TryParse($Target, [ref]$ip)) { return $ip }
    $addresses = [System.Net.Dns]::GetHostAddresses($Target)
    ($addresses | Where-Object AddressFamily -eq 'InterNetwork' | Select-Object -First 1) ?? ($addresses | Select-Object -First 1)
}

# network_ping : N pings ICMP vers une cible, avec temps, TTL et statistiques.
function Get-SIPing {
    param(
        [Parameter(Mandatory)][string]$Target,
        [ValidateRange(1, 20)][int]$Count = 4,
        [ValidateRange(100, 5000)][int]$TimeoutMs = 1000
    )
    $address = Resolve-Target $Target
    $ping = [System.Net.NetworkInformation.Ping]::new()
    $rows = for ($i = 1; $i -le $Count; $i++) {
        $reply = try { $ping.Send($address, $TimeoutMs) } catch { $null }
        $ok = $reply -and $reply.Status -eq 'Success'
        , @($i, $(if ($ok) { 'Oui' } else { "Non ($($reply.Status ?? 'erreur'))" }), $(if ($ok) { [double]$reply.RoundtripTime } else { $null }), $(if ($ok -and $reply.Options) { $reply.Options.Ttl } else { $null }))
        if ($i -lt $Count) { Start-Sleep -Milliseconds 200 }
    }
    $ping.Dispose()
    $times = @($rows | ForEach-Object { $_[2] } | Where-Object { $null -ne $_ })
    $loss = 100 * ($Count - $times.Count) / $Count
    $summary = [ordered]@{ 'Cible' = $Target; 'Adresse' = "$address"; 'Envoyés' = $Count; 'Reçus' = $times.Count; 'Perte' = Format-Unit $loss '%' '0' }
    if ($times.Count -gt 0) {
        $m = $times | Measure-Object -Minimum -Maximum -Average
        $summary['Temps (min / moy / max)'] = '{0} / {1} / {2}' -f (Format-Unit $m.Minimum 'ms' '0'), (Format-Unit $m.Average 'ms' '0.#'), (Format-Unit $m.Maximum 'ms' '0')
    }
    $findings = @()
    if ($times.Count -eq 0) { $findings += New-Finding 'warning' 'NET-HOST-UNREACHABLE' "$Target ne répond pas au ping" 'Beaucoup de serveurs et de pare-feu bloquent le ping : tester aussi un port (network_test_port).' }
    elseif ($loss -gt 0) { $findings += New-Finding 'warning' 'NET-PING-LOSS' ('{0} de perte vers {1}' -f (Format-Unit $loss '%' '0'), $Target) 'Pertes intermittentes : Wi-Fi, câble ou saturation de la connexion.' }

    New-Result ('Ping vers {0} ({1})' -f $Target, $address) @(
        [PSCustomObject]@{ Title = 'Résumé'; Type = 'KeyValue'; Icon = 'network_check'; Items = $summary }
        [PSCustomObject]@{ Title = 'Réponses'; Type = 'Table'; Icon = 'timer'; Columns = @('N°', 'Réponse', 'Temps (ms)', 'TTL'); Rows = @($rows) }
    ) $findings
}

# network_traceroute : chemin vers une cible (tracert sous Windows ; traceroute ou tracepath sous Linux).
function Get-SITraceroute {
    param(
        [Parameter(Mandatory)][string]$Target,
        [ValidateRange(1, 30)][int]$MaxHops = 20
    )
    $address = Resolve-Target $Target
    $command = if ($IsWindows) { @('tracert', "-d -h $MaxHops -w 800 $address") }
               elseif (Get-Command traceroute -ErrorAction SilentlyContinue) { @('traceroute', "-n -q 1 -w 1 -m $MaxHops $address") }
               elseif (Get-Command tracepath -ErrorAction SilentlyContinue) { @('tracepath', "-n -m $MaxHops $address") }
               else { throw 'Aucun outil de traceroute (installer traceroute ou iputils-tracepath)' }
    $info = [System.Diagnostics.ProcessStartInfo]::new($command[0], $command[1])
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true; $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $process = [System.Diagnostics.Process]::Start($info)
    $output = $process.StandardOutput.ReadToEndAsync()
    if (-not $process.WaitForExit($MaxHops * 3000)) { $process.Kill(); throw "Traceroute interrompu après $($MaxHops * 3) s" }
    $hops = @(ConvertFrom-Traceroute ($output.Result -split "`r?`n"))
    $rows = foreach ($h in $hops) { , @($h.Hop, $(if ($h.Address) { $h.Address } else { 'pas de réponse' }), $h.Ms) }
    $reached = [bool]($hops | Where-Object Address -eq "$address")
    $findings = @()
    if (-not $reached) { $findings += New-Finding 'info' 'NET-TRACE-INCOMPLETE' "La cible $Target n'a pas été atteinte en $MaxHops sauts" 'Les derniers routeurs ou la cible ignorent peut-être les paquets de traceroute ; ce n''est pas forcément une panne.' }
    New-Result ('Traceroute vers {0} ({1}) · {2} saut(s)' -f $Target, $address, $hops.Count) @(
        [PSCustomObject]@{ Title = 'Sauts'; Type = 'Table'; Icon = 'arrow_routing'; Columns = @('Saut', 'Adresse', 'Latence (ms)'); Rows = @($rows) }
    ) $findings
}

# network_test_port : connexion TCP vers hôte:port (ouvert, fermé ou filtré), avec le temps de connexion.
function Test-SIPort {
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$Port,
        [ValidateRange(100, 10000)][int]$TimeoutMs = 3000
    )
    $address = Resolve-Target $Target
    $client = [System.Net.Sockets.TcpClient]::new($address.AddressFamily)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $task = $client.ConnectAsync($address, $Port)
    $done = try { $task.Wait($TimeoutMs) } catch { $true }
    $watch.Stop()
    $state = if (-not $done) { 'Filtré (pas de réponse)' }
             elseif ($task.IsCompletedSuccessfully -and $client.Connected) { 'Ouvert' }
             else { $socket = $task.Exception.InnerException; if ($socket -and $socket.SocketErrorCode -eq 'ConnectionRefused') { 'Fermé (connexion refusée)' } else { "Erreur ($($socket.SocketErrorCode ?? $socket.Message))" } }
    $client.Dispose()
    $items = [ordered]@{ 'Cible' = $Target; 'Adresse' = "$address"; 'Port' = $Port; 'État' = $state }
    if ($state -eq 'Ouvert') { $items['Temps de connexion'] = Format-Unit $watch.Elapsed.TotalMilliseconds 'ms' '0' }
    New-Result ('Port {0} sur {1} : {2}' -f $Port, $Target, $state) @(
        [PSCustomObject]@{ Title = 'Test de port TCP'; Type = 'KeyValue'; Icon = 'plug_connected'; Items = $items }
    )
}

# network_test_mtu : plus grand paquet qui passe sans fragmentation vers une cible.
# Windows : Test-Connection -MtuSize. Linux : ping -M do (ne pas fragmenter), recherche par dichotomie.
function Get-SIPathMtu {
    param([string]$Target = '1.1.1.1')
    $address = Resolve-Target $Target
    if ($IsWindows) {
        $mtu = (Test-Connection -TargetName "$address" -MtuSize -TimeoutSeconds 2 -ErrorAction Stop).MtuSize
    }
    else {
        if (-not (Get-Command ping -ErrorAction SilentlyContinue)) { throw 'Commande ping absente' }
        $passes = { param([int]$Payload) & ping -M do -n -c 1 -W 1 -s $Payload "$address" *> $null; $LASTEXITCODE -eq 0 }
        if (-not (& $passes 0)) { throw "$Target ne répond pas au ping" }
        $low = 0; $high = 1472   # charge utile ; MTU = charge + 28 (en-têtes IP et ICMP)
        if (& $passes $high) { $low = $high }
        while ($high - $low -gt 1) { $mid = [int](($low + $high) / 2); if (& $passes $mid) { $low = $mid } else { $high = $mid } }
        $mtu = $low + 28
    }
    $items = [ordered]@{ 'Cible' = "$Target ($address)"; 'MTU du chemin' = '{0} octets' -f $mtu }
    $findings = @()
    if ($mtu -lt 1500) {
        $findings += New-Finding 'info' 'NET-MTU-LOW' ('MTU du chemin vers {0} : {1} octets' -f $Target, $mtu) `
            $(if ($mtu -ge 1400) { 'Normal derrière un VPN ou une connexion PPPoE (1492).' } else { 'MTU très bas : des sites peuvent ne pas charger ; vérifier le VPN ou la box.' })
    }
    New-Result ('MTU vers {0} : {1} octets' -f $Target, $mtu) @(
        [PSCustomObject]@{ Title = 'MTU'; Type = 'KeyValue'; Icon = 'arrow_swap'; Items = $items }
    ) $findings
}

# network_get_public_ip : adresses publiques IPv4 / IPv6 vues d'Internet (service api.ipify.org) et leur nom inverse.
function Get-SIPublicIp {
    $items = [ordered]@{}
    foreach ($entry in @(@{ Label = 'IPv4 publique'; Url = 'https://api.ipify.org?format=json' }, @{ Label = 'IPv6 publique'; Url = 'https://api6.ipify.org?format=json' })) {
        $ip = try { (Invoke-RestMethod -Uri $entry.Url -TimeoutSec 5 -ErrorAction Stop).ip } catch { $null }
        $items[$entry.Label] = $ip ?? 'Aucune (ou service injoignable)'
        if ($ip) {
            $reverse = [System.Net.Dns]::GetHostEntryAsync($ip)
            if ($(try { $reverse.Wait(2000) } catch { $false }) -and $reverse.IsCompletedSuccessfully) { $items["Nom inverse ($($entry.Label -replace ' publique', ''))"] = $reverse.Result.HostName }
        }
    }
    $items['Source'] = 'api.ipify.org'
    New-Result ('IPv4 publique : {0}' -f $items['IPv4 publique']) @(
        [PSCustomObject]@{ Title = 'Adresse publique'; Type = 'KeyValue'; Icon = 'globe'; Items = $items }
    )
}

# Types de service mDNS courants → libellé.
$script:MdnsServices = @{
    '_ipp._tcp' = 'Imprimante'; '_ipps._tcp' = 'Imprimante'; '_printer._tcp' = 'Imprimante'; '_pdl-datastream._tcp' = 'Imprimante'
    '_uscan._tcp' = 'Scanner'; '_scanner._tcp' = 'Scanner'; '_smb._tcp' = 'Partage SMB'; '_afpovertcp._tcp' = 'Partage AFP'
    '_nfs._tcp' = 'Partage NFS'; '_ssh._tcp' = 'SSH'; '_sftp-ssh._tcp' = 'SFTP'; '_http._tcp' = 'Web'; '_https._tcp' = 'Web'
    '_airplay._tcp' = 'AirPlay'; '_raop._tcp' = 'AirPlay audio'; '_googlecast._tcp' = 'Chromecast'; '_spotify-connect._tcp' = 'Spotify Connect'
    '_hap._tcp' = 'HomeKit'; '_homekit._tcp' = 'HomeKit'; '_matter._tcp' = 'Matter'; '_home-assistant._tcp' = 'Home Assistant'
    '_device-info._tcp' = $null; '_workstation._tcp' = 'Poste de travail'; '_companion-link._tcp' = 'Appareil Apple'; '_sonos._tcp' = 'Sonos'
    '_daap._tcp' = 'Bibliothèque musicale'; '_adisk._tcp' = 'Time Machine'; '_rdp._tcp' = 'Bureau à distance'
}

# network_discover_lan : appareils du réseau local (ping de tout le sous-réseau, table ARP, noms DNS et mDNS).
function Get-SILanDevices {
    param([ValidateRange(100, 3000)][int]$TimeoutMs = 600)

    $primary = Get-PrimaryInterface @(Get-Interfaces)
    if (-not $primary) { throw 'Aucune connexion réseau active' }
    $own = $primary.Ipv4.Address
    $prefix = [Math]::Max(24, $primary.Ipv4.PrefixLength)   # au plus un /24 (254 adresses)
    $bytes = $own.GetAddressBytes(); [array]::Reverse($bytes)
    $value = [BitConverter]::ToUInt32($bytes, 0)
    $mask = [uint32]((4294967295L -shl (32 - $prefix)) -band 4294967295L)   # 0xFFFFFFFF serait lu comme -1
    $network = $value -band $mask
    $count = [Math]::Pow(2, 32 - $prefix) - 2
    $targets = for ($i = 1; $i -le $count; $i++) {
        $b = [BitConverter]::GetBytes([uint32]($network + $i)); [array]::Reverse($b); [System.Net.IPAddress]::new($b)
    }

    # Pings en parallèle (un objet Ping par cible), puis attente commune.
    $pings = foreach ($t in $targets) { [PSCustomObject]@{ Address = "$t"; Task = [System.Net.NetworkInformation.Ping]::new().SendPingAsync($t, $TimeoutMs) } }
    try { [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($pings.Task), $TimeoutMs + 1000) } catch { }
    $alive = @{}
    foreach ($p in $pings) { if ($p.Task.IsCompletedSuccessfully -and $p.Task.Result.Status -eq 'Success') { $alive[$p.Address] = [double]$p.Task.Result.RoundtripTime } }

    # Table ARP après le balayage : aussi les appareils qui ignorent le ping mais ont répondu en ARP.
    $macs = @{}
    foreach ($n in Get-Neighbors | Where-Object Interface -eq $primary.Name) { $macs[$n.Address] = $n.Mac }
    $addresses = @($alive.Keys) + @($macs.Keys) + @("$own") | Select-Object -Unique

    # mDNS (Linux, avahi-browse, 4 s au plus) : « =;iface;IPv4;nom;type;domaine;hôte;adresse;port;txt ».
    $mdns = @{}
    if ($IsLinux -and (Get-Command avahi-browse -ErrorAction SilentlyContinue) -and (Test-Path /usr/bin/timeout)) {
        foreach ($line in & /usr/bin/timeout 4 avahi-browse -a -r -p -t 2>$null) {
            $f = $line -split ';'
            if ($f[0] -ne '=' -or $f[2] -ne 'IPv4' -or $f.Count -lt 8) { continue }
            $entry = $mdns[$f[7]] ?? @{ Host = ($f[6] -replace '\.local$', ''); Services = [System.Collections.Generic.HashSet[string]]::new() }
            $label = $script:MdnsServices[$f[4]]
            if ($label) { [void]$entry.Services.Add($label) }
            $mdns[$f[7]] = $entry
        }
    }

    # Noms DNS inverses en parallèle (2 s au plus en tout).
    $lookups = foreach ($a in $addresses) { [PSCustomObject]@{ Address = $a; Task = [System.Net.Dns]::GetHostEntryAsync($a) } }
    try { [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($lookups.Task), 2000) } catch { }
    $names = @{}
    foreach ($l in $lookups) { if ($l.Task.IsCompletedSuccessfully -and $l.Task.Result.HostName -ne $l.Address) { $names[$l.Address] = $l.Task.Result.HostName } }

    $gateway = "$($primary.Gateway.Address)"
    $rows = foreach ($a in $addresses | Sort-Object { [version]$_ }) {
        $role = if ($a -eq "$own") { 'Cette machine' } elseif ($a -eq $gateway) { 'Passerelle (box)' } else { $null }
        $name = $(if ($names[$a] -and $names[$a] -ne '_gateway') { $names[$a] } elseif ($mdns[$a]) { $mdns[$a].Host } else { $null })
        $services = if ($mdns[$a]) { ($mdns[$a].Services | Sort-Object) -join ', ' } else { $null }
        , @($a, $name, $(if ($a -eq "$own") { Format-Mac $primary.Nic.GetPhysicalAddress() } else { $macs[$a] }), $role, $services, $alive[$a])
    }
    New-Result ('{0} appareil(s) sur {1}/{2} ({3})' -f @($rows).Count, ([System.Net.IPAddress]::new([byte[]]([BitConverter]::GetBytes([uint32]$network)[3..0]))), $prefix, $primary.Name) @(
        [PSCustomObject]@{
            Title = 'Appareils du réseau local'; Type = 'Table'; Icon = 'router'
            Columns = @('Adresse IP', 'Nom', 'Adresse MAC', 'Rôle', 'Services (mDNS)', 'Ping (ms)'); Rows = @($rows)
        }
    )
}

# network_resolve_dns : requête DNS d'un type donné, éventuellement vers un serveur précis.
# Windows : Resolve-DnsName. Linux : dig si présent, sinon résolution système (A / AAAA seulement).
function Resolve-SIDns {
    param(
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('A', 'AAAA', 'CNAME', 'MX', 'NS', 'TXT', 'SOA', 'PTR', 'SRV')][string]$RecordType = 'A',
        [string]$Server
    )
    # PTR d'une adresse IP : nom inverse (1.2.3.4 → 4.3.2.1.in-addr.arpa).
    $ip = $null
    if ($RecordType -eq 'PTR' -and [System.Net.IPAddress]::TryParse($Name, [ref]$ip) -and $ip.AddressFamily -eq 'InterNetwork') {
        $Name = (($Name -split '\.')[3..0] -join '.') + '.in-addr.arpa'
    }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $records = @()
    if ($IsWindows) {
        $query = @{ Name = $Name; Type = $RecordType; DnsOnly = $true; ErrorAction = 'Stop' }
        if ($Server) { $query.Server = $Server }
        $records = Resolve-DnsName @query | Where-Object { "$($_.Type)" -eq $RecordType -or $RecordType -eq 'A' -and "$($_.Type)" -eq 'CNAME' } | ForEach-Object {
            $data = $_.IPAddress ?? $_.NameHost ?? $_.NameExchange ?? ($_.Strings -join ' ') ?? $_.PrimaryServer ?? $_.NameTarget
            if ($_.Preference) { $data = "$($_.Preference) $data" }
            [PSCustomObject]@{ Name = $_.Name; Type = "$($_.Type)"; Ttl = $_.TTL; Data = $data }
        }
    }
    elseif (Get-Command dig -ErrorAction SilentlyContinue) {
        $digArgs = @('+noall', '+answer', '+time=3', '+tries=1', $Name, $RecordType)
        if ($Server) { $digArgs = @("@$Server") + $digArgs }
        $records = & dig @digArgs 2>$null | Where-Object { $_ -and $_ -notmatch '^;' } | ForEach-Object {
            $f = $_ -split '\s+', 5
            [PSCustomObject]@{ Name = $f[0].TrimEnd('.'); Type = $f[3]; Ttl = [int]$f[1]; Data = $f[4].Trim() }
        }
    }
    else {
        if ($RecordType -notin 'A', 'AAAA' -or $Server) { throw 'Installer dig (bind-utils / dnsutils) pour ce type de requête ou un serveur précis' }
        $family = if ($RecordType -eq 'A') { 'InterNetwork' } else { 'InterNetworkV6' }
        $records = [System.Net.Dns]::GetHostAddresses($Name) | Where-Object AddressFamily -eq $family | ForEach-Object { [PSCustomObject]@{ Name = $Name; Type = $RecordType; Ttl = $null; Data = "$_" } }
    }
    $watch.Stop()
    $rows = foreach ($r in $records) { , @($r.Name, $r.Type, $r.Ttl, $r.Data) }
    $subtitle = '{0} {1} · {2} réponse(s) en {3}' -f $Name, $RecordType, @($records).Count, (Format-Unit $watch.Elapsed.TotalMilliseconds 'ms' '0')
    if ($Server) { $subtitle += " · serveur $Server" }
    $findings = @()
    if (@($records).Count -eq 0) { $findings += New-Finding 'info' 'NET-DNS-NO-ANSWER' "Aucun enregistrement $RecordType pour $Name" $null }
    New-Result $subtitle @(
        [PSCustomObject]@{ Title = 'Enregistrements'; Type = 'Table'; Icon = 'globe'; Columns = @('Nom', 'Type', 'TTL (s)', 'Valeur'); Rows = @($rows) }
    ) $findings
}

#endregion

Export-ModuleMember -Function Get-ModuleData, Get-SIPing, Get-SITraceroute, Test-SIPort, Get-SIPathMtu, Get-SIPublicIp, Get-SILanDevices, Resolve-SIDns
