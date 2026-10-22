# Module Réseau : IP, DNS, DHCP, routes, ports, connexions TCP, ping, traceroute.
#
# Sources
#   Commun  : System.Net.NetworkInformation (interfaces, adresses, passerelles, compteurs d'octets, ping).
#   Windows : Get-NetRoute, Get-NetTCPConnection, Get-NetUDPEndpoint, Win32_NetworkAdapterConfiguration (bail DHCP),
#             netsh wlan (Wi-Fi), tracert.
#   Linux   : /sys/class/net (interfaces physiques, Wi-Fi), ip -j route, ss, resolvectl (DNS), nmcli (DHCP, Wi-Fi),
#             traceroute ou tracepath.
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

function Get-WifiInfo([string]$Interface) {
    if ($IsLinux) {
        $line = Invoke-Tool nmcli @('-t', '-f', 'ACTIVE,SSID,SIGNAL', 'device', 'wifi', 'list', 'ifname', $Interface) |
            Where-Object { $_ -like 'yes:*' } | Select-Object -First 1
        if ($line) {
            $parts = $line -split ':'
            return [PSCustomObject]@{ Ssid = $parts[1]; Signal = [int]$parts[-1] }
        }
        return $null
    }
    # netsh : « SSID : … », « Signal : 92 % » (libellés identiques en français et en anglais).
    $out = Invoke-Tool netsh @('wlan', 'show', 'interfaces')
    $ssid = ($out | Where-Object { $_ -match '^\s*SSID\s*:\s*(.+)$' } | Select-Object -First 1) -replace '^\s*SSID\s*:\s*', ''
    $signal = ($out | Where-Object { $_ -match '^\s*Signal\s*:\s*(\d+)' } | Select-Object -First 1) -replace '\D', ''
    if ($ssid) { return [PSCustomObject]@{ Ssid = $ssid.Trim(); Signal = if ($signal) { [int]$signal } else { $null } } }
    $null
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
    $errors = [ordered]@{}

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
            }
        }
        if ($speed) { $items['Vitesse du lien'] = $speed }
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

        # DNS
        Invoke-Block 'DNS' {
            $servers = Get-Cached 'dns' 10 { Get-DnsServers $primary }
            $dns = [ordered]@{ 'Serveurs' = if ($servers) { $servers -join ', ' } else { 'Aucun' } }
            if ($IsLinux -and (Get-Command resolvectl -ErrorAction SilentlyContinue)) { $dns['Résolveur'] = 'systemd-resolved (relais local 127.0.0.53)' }
            $sections.Add([PSCustomObject]@{ Title = 'DNS'; Type = 'KeyValue'; Icon = 'globe'; Items = $dns })
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

    [PSCustomObject]@{ Subtitle = $subtitle; Sections = $sections.ToArray() }
}

Export-ModuleMember -Function Get-ModuleData
