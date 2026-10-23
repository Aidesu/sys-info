# Module Système : CPU, RAM, uptime, OS, processus, températures si disponibles.
#
# Sources
#   Windows : CIM (Win32_OperatingSystem, Win32_ComputerSystem, Win32_Processor, Win32_PerfFormattedData_PerfOS_Processor,
#             Win32_PerfFormattedData_PerfOS_Memory, root/wmi MSAcpi_ThermalZoneTemperature), registre (CurrentVersion,
#             W32Time), journal System (6005/6006/6008/41), Get-TimeZone, Get-WinSystemLocale, Get-Culture, Get-Process.
#   Linux   : /proc (stat, meminfo, uptime, cpuinfo), /etc/os-release, /sys (cpufreq, cache, hwmon, dmi), timedatectl,
#             localectl, systemd-detect-virt, journalctl (fin du démarrage précédent), Get-Process.
#
# Le runspace est réutilisé d'un appel à l'autre : l'état $script: sert à
#   - garder les infos fixes (modèle CPU, OS…) lues une seule fois ;
#   - calculer les pourcentages CPU (global et par processus) par différence avec l'appel précédent.
# Au tout premier appel, un échantillon de 250 ms sert de point de départ.

$script:Fr = [cultureinfo]::GetCultureInfo('fr-FR')
$script:Nbsp = [char]0x00A0   # espace insécable entre une valeur et son unité
$script:Static = $null        # infos fixes, lues au premier appel
$script:PrevCpu = $null       # Linux : compteurs /proc/stat du dernier appel
$script:PrevProc = $null      # temps CPU cumulé par PID au dernier appel
$script:PrevProcAt = $null    # instant du dernier relevé des processus

# Seuils (design system) : CPU Attention ≥ 75 %, Critique ≥ 90 % ; température 80 / 90 °C ;
# mémoire 80 / 92 % (exemple Metric « Mémoire » du design system).
$script:CpuWarning = 75; $script:CpuCritical = 90
$script:TempWarning = 80; $script:TempCritical = 90
$script:MemWarning = 0.80; $script:MemCritical = 0.92


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

#region Formatage (français : virgule décimale, espace insécable avant l'unité)

function Format-Unit([double]$Value, [string]$Unit, [string]$Format = '0.#') {
    '{0}{1}{2}' -f $Value.ToString($Format, $script:Fr), $script:Nbsp, $Unit
}

function Format-GiB([double]$Bytes) { Format-Unit ($Bytes / 1GB) 'GiB' '0.0' }

function Format-Duration([timespan]$Span) {
    $h = '{0}{1}h' -f $Span.Hours, $script:Nbsp
    $m = '{0:00}{1}min' -f $Span.Minutes, $script:Nbsp
    if ($Span.Days -gt 0) { '{0}{1}j {2} {3}' -f $Span.Days, $script:Nbsp, $h, $m } else { "$h $m" }
}

#endregion

#region Infos fixes (lues une fois)

function Format-KiB([double]$KiB) {
    if ($KiB -ge 1024) { Format-Unit ($KiB / 1024) 'MiB' '0.#' } else { Format-Unit $KiB 'KiB' '0' }
}

function Read-SysFile([string]$Path) {
    $value = Get-Content -Path $Path -TotalCount 1 -ErrorAction SilentlyContinue
    if ($value) { $value.Trim() } else { $null }
}

function Get-OsReleaseValue([string]$Key) {
    $line = Get-Content -Path /etc/os-release -ErrorAction SilentlyContinue | Where-Object { $_ -like "$Key=*" } | Select-Object -First 1
    if ($line) { ($line -replace "^$Key=", '').Trim('"') } else { $null }
}

# Windows : VM si le modèle ou le fabricant le dit ; HypervisorPresent seul = hyperviseur actif sur la machine
# (Hyper-V, VBS), pas forcément une VM.
function Get-VirtualizationWindows($ComputerSystem) {
    $id = '{0} {1}' -f $ComputerSystem.Manufacturer, $ComputerSystem.Model
    switch -Regex ($id) {
        'VMware'                         { return 'Machine virtuelle VMware' }
        'VirtualBox|innotek'             { return 'Machine virtuelle VirtualBox' }
        'Microsoft Corporation Virtual'  { return 'Machine virtuelle Hyper-V' }
        'QEMU|KVM|Bochs'                 { return 'Machine virtuelle KVM / QEMU' }
        'Xen'                            { return 'Machine virtuelle Xen' }
        'Parallels'                      { return 'Machine virtuelle Parallels' }
    }
    if ($ComputerSystem.HypervisorPresent) { 'Machine physique (hyperviseur actif : Hyper-V ou VBS)' } else { 'Machine physique' }
}

# Linux : systemd-detect-virt renvoie « none » (code 1) sur une machine physique.
function Get-VirtualizationLinux {
    if (-not (Get-Command systemd-detect-virt -ErrorAction SilentlyContinue)) { return $null }
    $kind = (& systemd-detect-virt 2>$null | Select-Object -First 1)
    if (-not $kind -or $kind -eq 'none') { return 'Machine physique' }
    $names = @{ kvm = 'KVM'; qemu = 'QEMU'; vmware = 'VMware'; oracle = 'VirtualBox'; microsoft = 'Hyper-V'; xen = 'Xen';
        wsl = 'WSL'; docker = 'conteneur Docker'; podman = 'conteneur Podman'; lxc = 'conteneur LXC'; 'systemd-nspawn' = 'conteneur nspawn' }
    $name = if ($names.ContainsKey($kind)) { $names[$kind] } else { $kind }
    if ($kind -in 'docker', 'podman', 'lxc', 'lxc-libvirt', 'systemd-nspawn', 'wsl') { "Dans un $name" } else { "Machine virtuelle $name" }
}

# Linux : domaine AD rejoint via realmd/sssd, sinon poste isolé.
function Get-LinuxDomain {
    if (Get-Command realm -ErrorAction SilentlyContinue) {
        $realm = & realm list --name-only 2>$null | Select-Object -First 1
        if ($realm) { return 'Domaine {0}' -f $realm.Trim() }
    }
    'Aucun (poste isolé)'
}

function Get-StaticInfo {
    $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()

    if ($IsWindows) {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem
        $cpu = @(Get-CimInstance -ClassName Win32_Processor)
        $cv = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
        $build = if ($null -ne $cv.UBR) { '{0}.{1}' -f $os.BuildNumber, $cv.UBR } else { $os.BuildNumber }
        $caches = @()
        if ($cpu[0].L2CacheSize) { $caches += 'L2 ' + (Format-KiB $cpu[0].L2CacheSize) }
        if ($cpu[0].L3CacheSize) { $caches += 'L3 ' + (Format-KiB $cpu[0].L3CacheSize) }
        return [PSCustomObject]@{
            OsName      = $os.Caption.Trim()
            Version     = $cv.DisplayVersion
            Kernel      = 'Build {0}' -f $build
            Arch        = $arch
            InstallDate = $os.InstallDate
            Vendor      = $cs.Manufacturer
            Model       = $cs.Model
            Domain      = if ($cs.PartOfDomain) { 'Domaine {0}' -f $cs.Domain } else { 'Groupe de travail {0}' -f $cs.Workgroup }
            Virtual     = Get-VirtualizationWindows $cs
            CpuModel    = $cpu[0].Name.Trim()
            Cores       = ($cpu | Measure-Object -Property NumberOfCores -Sum).Sum
            Threads     = ($cpu | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
            MaxGHz      = $cpu[0].MaxClockSpeed / 1000
            Cache       = $caches -join ' · '
        }
    }

    if ($IsLinux) {
        $osName = 'Linux'
        $release = Get-Content -Path /etc/os-release -ErrorAction SilentlyContinue |
            Where-Object { $_ -like 'PRETTY_NAME=*' } | Select-Object -First 1
        if ($release) { $osName = ($release -replace '^PRETTY_NAME=', '').Trim('"') }

        # /proc/cpuinfo : modèle ("model name", ou "Model"/"Hardware" sur ARM) ; cœurs physiques
        # = couples (physical id, core id) distincts, sinon nombre de threads.
        $cpuinfo = Get-Content -Path /proc/cpuinfo
        $model = $cpuinfo | Where-Object { $_ -cmatch '^(model name|Model|Hardware)\s*:' } | Select-Object -First 1
        $model = if ($model) { ($model -replace '^[^:]*:\s*', '').Trim() } else { 'Inconnu' }

        $cores = [System.Collections.Generic.HashSet[string]]::new()
        $physical = '0'
        foreach ($line in $cpuinfo) {
            if ($line -match '^physical id\s*:\s*(\d+)') { $physical = $Matches[1] }
            elseif ($line -match '^core id\s*:\s*(\d+)') { [void]$cores.Add("$physical/$($Matches[1])") }
        }
        $threads = [Environment]::ProcessorCount

        $maxKHz = Get-Content -Path /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq -ErrorAction SilentlyContinue

        # Caches du cœur 0 : /sys/devices/system/cpu/cpu0/cache/index*/{level,type,size} (L3 partagé entre cœurs).
        $caches = foreach ($index in Get-ChildItem -Path /sys/devices/system/cpu/cpu0/cache -Directory -Filter 'index*' -ErrorAction SilentlyContinue) {
            $level = Read-SysFile (Join-Path $index.FullName 'level')
            $type = Read-SysFile (Join-Path $index.FullName 'type')
            $size = Read-SysFile (Join-Path $index.FullName 'size')
            if ($level -and $size) {
                $suffix = switch ($type) { 'Data' { 'd' } 'Instruction' { 'i' } default { '' } }
                $kib = if ($size -match '^(\d+)K$') { [double]$Matches[1] } elseif ($size -match '^(\d+)M$') { [double]$Matches[1] * 1024 } else { $null }
                if ($kib) { 'L{0}{1} {2}' -f $level, $suffix, (Format-KiB $kib) }
            }
        }

        # VERSION seulement s'il apporte quelque chose au nom (Fedora : déjà dans PRETTY_NAME).
        $version = Get-OsReleaseValue 'VERSION'
        if ($version -and $osName.Contains($version)) { $version = $null }
        return [PSCustomObject]@{
            OsName      = $osName
            Version     = $version
            Kernel      = (Get-Content -Path /proc/sys/kernel/osrelease).Trim()
            Arch        = $arch
            # Date de création de /etc/machine-id (écrit à l'installation) : approximation de la date d'installation.
            InstallDate = $(try { (Get-Item -Path /etc/machine-id -ErrorAction Stop).CreationTime } catch { $null })
            Vendor      = Read-SysFile /sys/class/dmi/id/sys_vendor
            Model       = Read-SysFile /sys/class/dmi/id/product_name
            Domain      = Get-LinuxDomain
            Virtual     = Get-VirtualizationLinux
            CpuModel    = $model
            Cores       = if ($cores.Count -gt 0) { $cores.Count } else { $threads }
            Threads     = $threads
            MaxGHz      = if ($maxKHz) { [double]$maxKHz / 1e6 } else { $null }
            Cache       = @($caches) -join ' · '
        }
    }

    throw 'Système non pris en charge'
}

#endregion

#region Mesures

# Utilisation CPU, en % : globale (Total) et par processeur logique (Cores, dans l'ordre).
function Get-CpuUsage {
    if ($IsWindows) {
        $all = @(Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor)
        $total = $all | Where-Object Name -eq '_Total'
        $cores = $all | Where-Object Name -ne '_Total' | Sort-Object { [int]($_.Name -split ',')[-1] } |
            ForEach-Object { [double]$_.PercentProcessorTime }
        return [PSCustomObject]@{ Total = [double]$total.PercentProcessorTime; Cores = @($cores) }
    }

    # Linux : /proc/stat, lignes "cpu" (global) et "cpuN" = user nice system idle iowait irq softirq steal
    # (guest inclus dans user). Pourcentages = différence avec l'appel précédent.
    $samples = [ordered]@{}
    foreach ($line in Get-Content -Path /proc/stat) {
        if ($line -notmatch '^cpu(\d*)\s') { if ($samples.Count -gt 0) { break } else { continue } }
        $fields = ($line -split '\s+')[1..8] | ForEach-Object { [double]$_ }
        $samples[$line.Substring(0, $line.IndexOf(' '))] = @{ Total = ($fields | Measure-Object -Sum).Sum; Idle = $fields[3] + $fields[4] }
    }
    $previous = $script:PrevCpu
    $script:PrevCpu = $samples
    if (-not $previous) { return [PSCustomObject]@{ Total = $null; Cores = @() } }

    $percent = {
        param($Key)
        $now = $samples[$Key]; $before = $previous[$Key]
        if (-not $before -or $now.Total -le $before.Total) { return $null }
        $busy = ($now.Total - $before.Total) - ($now.Idle - $before.Idle)
        [Math]::Round([Math]::Max(0, 100 * $busy / ($now.Total - $before.Total)), 1)
    }
    $cores = foreach ($key in $samples.Keys) { if ($key -ne 'cpu') { & $percent $key } }
    [PSCustomObject]@{ Total = & $percent 'cpu'; Cores = @($cores) }
}

# Fréquence actuelle moyenne, en GHz (Linux : cpufreq de chaque cœur ; Windows : Win32_Processor).
function Get-CpuFrequency {
    if ($IsWindows) {
        return (Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1).CurrentClockSpeed / 1000
    }
    $values = Get-ChildItem -Path /sys/devices/system/cpu -Directory -Filter 'cpu*' -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'cpufreq/scaling_cur_freq' } |
        Where-Object { Test-Path $_ } |
        ForEach-Object { [double](Get-Content -Path $_) }
    if (-not $values) { return $null }
    return ($values | Measure-Object -Average).Average / 1e6
}

# Mémoire et fichier d'échange, en octets.
function Get-MemoryInfo {
    if ($IsWindows) {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        # Engagée et en cache (comme le Gestionnaire des tâches : en attente + modifiée).
        $perf = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Memory -ErrorAction SilentlyContinue
        $cached = if ($perf) {
            [double]$perf.StandbyCacheCoreBytes + [double]$perf.StandbyCacheNormalPriorityBytes +
            [double]$perf.StandbyCacheReserveBytes + [double]$perf.ModifiedPageListBytes
        } else { $null }
        return [PSCustomObject]@{
            Total       = [double]$os.TotalVisibleMemorySize * 1KB
            Available   = [double]$os.FreePhysicalMemory * 1KB
            SwapTotal   = [double]$os.SizeStoredInPagingFiles * 1KB
            SwapFree    = [double]$os.FreeSpaceInPagingFiles * 1KB
            SwapLabel   = "Fichier d'échange"
            Committed   = if ($perf) { [double]$perf.CommittedBytes } else { $null }
            CommitLimit = if ($perf) { [double]$perf.CommitLimit } else { $null }
            Cached      = $cached
            BootTime    = $os.LastBootUpTime
        }
    }

    $info = @{}
    foreach ($line in Get-Content -Path /proc/meminfo) {
        if ($line -match '^(\w+):\s+(\d+)') { $info[$Matches[1]] = [double]$Matches[2] * 1KB }
    }
    $uptime = [double]((Get-Content -Path /proc/uptime) -split '\s+')[0]
    return [PSCustomObject]@{
        Total       = $info.MemTotal
        Available   = if ($info.ContainsKey('MemAvailable')) { $info.MemAvailable } else { $info.MemFree }
        SwapTotal   = $info.SwapTotal
        SwapFree    = $info.SwapFree
        SwapLabel   = 'Swap'
        Committed   = $info.Committed_AS
        # Linux ne fait respecter CommitLimit qu'en mode overcommit strict (vm.overcommit_memory = 2).
        CommitLimit = if ((Read-SysFile /proc/sys/vm/overcommit_memory) -eq '2') { $info.CommitLimit } else { $null }
        Cached      = [double]$info.Cached + [double]$info.Buffers + [double]$info.SReclaimable
        BootTime    = (Get-Date).AddSeconds(-$uptime)
    }
}

# Processus : nombre total et les 15 plus gourmands (CPU % depuis l'appel précédent, puis mémoire).
function Get-ProcessSnapshot {
    $now = [DateTime]::UtcNow
    $processes = Get-Process
    $cpuTimes = @{}
    foreach ($p in $processes) {
        # Windows sans droits : TotalProcessorTime illisible pour les processus système → ignoré.
        try { $cpuTimes[$p.Id] = $p.TotalProcessorTime.TotalMilliseconds } catch { }
    }

    $elapsed = if ($script:PrevProcAt) { ($now - $script:PrevProcAt).TotalMilliseconds } else { 0 }
    $previous = $script:PrevProc
    $script:PrevProc = $cpuTimes
    $script:PrevProcAt = $now
    $logical = [Environment]::ProcessorCount

    $rows = foreach ($p in $processes) {
        $cpu = $null
        if ($previous -and $elapsed -gt 0 -and $cpuTimes.ContainsKey($p.Id) -and $previous.ContainsKey($p.Id)) {
            $delta = $cpuTimes[$p.Id] - $previous[$p.Id]
            $cpu = [Math]::Round([Math]::Max(0, 100 * $delta / ($elapsed * $logical)), 1)
        }
        # Linux : certains noms arrivent avec toute la ligne de commande (« chrome --type=renderer … »).
        $name = ($p.ProcessName -split ' --', 2)[0]
        [PSCustomObject]@{ Name = $name; Id = $p.Id; Cpu = $cpu; Memory = $p.WorkingSet64 }
    }

    [PSCustomObject]@{
        Count = $processes.Count
        All   = @($rows)
        Top   = $rows | Sort-Object -Property @{ Expression = { [double]$_.Cpu }; Descending = $true },
                                              @{ Expression = 'Memory'; Descending = $true } |
                Select-Object -First 15
    }
}

# Date, heure et synchronisation.
# Windows : Get-TimeZone, registre W32Time (serveur NTP, type), état du service W32Time.
# Linux   : timedatectl show (Timezone, NTP, NTPSynchronized) ; serveur via timedatectl show-timesync si timesyncd,
#           sinon chronyc -n tracking.
function Get-TimeInfo {
    $info = [ordered]@{ Zone = $null; Ntp = $null; Synced = $null; Server = $null }
    if ($IsWindows) {
        $tz = Get-TimeZone
        $info.Zone = $tz.DisplayName
        $params = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters' -ErrorAction SilentlyContinue
        $service = Get-Service -Name W32Time -ErrorAction SilentlyContinue
        $info.Ntp = $service -and $service.Status -eq 'Running' -and $params.Type -ne 'NoSync'
        if ($params.NtpServer) { $info.Server = ($params.NtpServer -split '\s+' | ForEach-Object { ($_ -split ',')[0] }) -join ', ' }
        if ($params.Type -eq 'NT5DS') { $info.Server = 'Contrôleur de domaine' }
        return [PSCustomObject]$info
    }

    $values = @{}
    foreach ($line in & timedatectl show 2>$null) { if ($line -match '^(\w+)=(.*)$') { $values[$Matches[1]] = $Matches[2] } }
    $info.Zone = $values.Timezone
    $info.Ntp = $values.NTP -eq 'yes'
    $info.Synced = $values.NTPSynchronized -eq 'yes'
    $server = & timedatectl show-timesync --property=ServerName --value 2>$null
    if (-not $server -and (Get-Command chronyc -ErrorAction SilentlyContinue)) {
        # chronyc -n tracking : « Reference ID    : C0A80101 (192.168.1.1) »
        $ref = & chronyc -n tracking 2>$null | Where-Object { $_ -like 'Reference ID*' } | Select-Object -First 1
        if ($ref -match '\(([^)]+)\)') { $server = $Matches[1] }
    }
    if ($server) { $info.Server = "$server".Trim() }
    [PSCustomObject]$info
}

# Langue du système, formats régionaux, clavier.
# Windows : Get-WinSystemLocale, Get-Culture, Get-WinUserLanguageList (méthodes de saisie).
# Linux   : localectl status (System Locale, VC Keymap, X11 Layout), culture .NET pour les formats.
function Get-RegionInfo {
    $info = [ordered]@{ System = $null; Formats = (Get-Culture).DisplayName; Keyboard = $null }
    if ($IsWindows) {
        $info.System = (Get-WinSystemLocale).DisplayName
        $languages = Get-WinUserLanguageList -ErrorAction SilentlyContinue
        if ($languages) { $info.Keyboard = ($languages | ForEach-Object { '{0} ({1})' -f $_.LocalizedName, ($_.InputMethodTips -join ', ') }) -join ' · ' }
        return [PSCustomObject]$info
    }

    $status = @{}
    foreach ($line in & localectl status 2>$null) { if ($line -match '^\s*([^:]+):\s*(.+)$') { $status[$Matches[1].Trim()] = $Matches[2].Trim() } }
    if ($status['System Locale'] -match 'LANG=(\S+)') { $info.System = $Matches[1] }
    $keyboard = @()
    if ($status['X11 Layout']) { $keyboard += $status['X11 Layout'] + $(if ($status['X11 Variant']) { " ($($status['X11 Variant']))" } else { '' }) }
    if ($status['VC Keymap'] -and $status['VC Keymap'] -ne $status['X11 Layout']) { $keyboard += 'console : ' + $status['VC Keymap'] }
    $info.Keyboard = $keyboard -join ' · '
    [PSCustomObject]$info
}

# Fin du démarrage précédent : arrêt propre ou inattendu, avec sa date.
# Windows : dernier événement System 6006 (arrêt propre), 6008 (arrêt inattendu) ou 41 Kernel-Power, avant le démarrage actuel.
# Linux   : dernières lignes du journal du démarrage précédent ; « Journal stopped » = journald arrêté proprement.
function Get-LastShutdown([datetime]$BootTime) {
    if ($IsWindows) {
        $events = Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 6006, 6008, 41; EndTime = $BootTime } -MaxEvents 1 -ErrorAction SilentlyContinue
        $last = $events | Select-Object -First 1
        if (-not $last) { return $null }
        return [PSCustomObject]@{ Clean = $last.Id -eq 6006; Time = $last.TimeCreated }
    }

    if (-not (Get-Command journalctl -ErrorAction SilentlyContinue)) { return $null }
    $lines = @(& journalctl -b -1 -n 20 -o json -q --no-pager 2>$null | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } })
    if ($lines.Count -eq 0) { return $null }
    $clean = [bool]($lines | Where-Object { $_.MESSAGE -match 'Journal stopped|systemd-shutdown|Reached target.*(Power-Off|Reboot|Shutdown)' })
    $time = [DateTimeOffset]::FromUnixTimeMilliseconds([long]($lines[-1].__REALTIME_TIMESTAMP) / 1000).LocalDateTime
    [PSCustomObject]@{ Clean = $clean; Time = $time }
}

# Capteurs de température : liste (Capteur, °C) et, si on le reconnaît, celui du processeur.
function Get-Temperatures {
    $sensors = [System.Collections.Generic.List[object]]::new()
    $cpuSensor = $null

    if ($IsLinux) {
        # /sys/class/hwmon/hwmon*/ : name, temp<N>_input (millidegrés), temp<N>_label facultatif.
        foreach ($hwmon in Get-ChildItem -Path /sys/class/hwmon -ErrorAction SilentlyContinue) {
            $chip = (Get-Content -Path (Join-Path $hwmon.FullName 'name') -ErrorAction SilentlyContinue)
            if (-not $chip) { continue }
            foreach ($input in Get-ChildItem -Path $hwmon.FullName -Filter 'temp*_input' -ErrorAction SilentlyContinue) {
                $raw = Get-Content -Path $input.FullName -ErrorAction SilentlyContinue
                if (-not $raw) { continue }
                $base = $input.Name -replace '_input$', ''
                $labelPath = Join-Path $hwmon.FullName "${base}_label"
                $label = if (Test-Path $labelPath) { (Get-Content -Path $labelPath).Trim() } else { $base }
                $sensor = [PSCustomObject]@{ Chip = $chip; Label = $label; Celsius = [Math]::Round([double]$raw / 1000, 1) }
                $sensors.Add($sensor)

                # Capteur global du processeur : Intel coretemp « Package id 0 », AMD k10temp/zenpower « Tctl »/« Tdie »,
                # Raspberry Pi cpu_thermal.
                if (-not $cpuSensor -and (
                        ($chip -eq 'coretemp' -and $label -like 'Package id*') -or
                        ($chip -in 'k10temp', 'zenpower' -and $label -in 'Tctl', 'Tdie') -or
                        ($chip -eq 'cpu_thermal'))) {
                    $cpuSensor = $sensor
                }
            }
        }
        $reason = 'Aucun capteur trouvé dans /sys/class/hwmon'
    }
    elseif ($IsWindows) {
        # Zones thermiques ACPI : souvent réservées aux administrateurs, parfois absentes.
        try {
            foreach ($zone in Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop) {
                $sensors.Add([PSCustomObject]@{
                        Chip    = 'ACPI'
                        Label   = ($zone.InstanceName -split '\\')[-1]
                        Celsius = [Math]::Round($zone.CurrentTemperature / 10 - 273.15, 1)
                    })
            }
            $reason = "Aucune zone thermique exposée par l'ACPI"
        }
        catch {
            $reason = 'Capteurs non accessibles (droits administrateur requis sous Windows)'
        }
    }

    [PSCustomObject]@{ Sensors = $sensors; Cpu = $cpuSensor; Reason = $reason }
}

#endregion

function Get-ModuleData {
    $sections = [System.Collections.Generic.List[object]]::new()
    $findings = [System.Collections.Generic.List[object]]::new()
    $errors = [ordered]@{}

    # Chaque bloc est indépendant : un échec est signalé dans la section « Erreurs », le reste s'affiche.
    # Le bloc renvoie sa valeur (une affectation faite dans le bloc ne remonterait pas ici).
    function Invoke-Block([string]$Name, [scriptblock]$Block) {
        try { & $Block } catch { $errors[$Name] = $_.Exception.Message; $null }
    }

    Invoke-Block 'Infos fixes' { if (-not $script:Static) { $script:Static = Get-StaticInfo } }
    $static = $script:Static

    # Premier appel : point de départ des pourcentages CPU, puis un court échantillon.
    if (($IsLinux -and -not $script:PrevCpu) -or -not $script:PrevProc) {
        Invoke-Block 'Échantillon initial' {
            if ($IsLinux) { [void](Get-CpuUsage) }  # point de départ global et par thread
            [void](Get-ProcessSnapshot)
            Start-Sleep -Milliseconds 250
        }
    }

    $memory = Invoke-Block 'Mémoire' { Get-MemoryInfo }
    $processes = Invoke-Block 'Processus' { Get-Cached 'processes' 6 { Get-ProcessSnapshot } }
    $temps = Invoke-Block 'Températures' { Get-Temperatures }

    $frequency = Invoke-Block 'Fréquence' { Get-CpuFrequency }

    # Changent peu : relus toutes les 30 s ; l'arrêt précédent ne change pas pendant le démarrage.
    $time = Invoke-Block 'Heure' { Get-Cached 'time' 30 { Get-TimeInfo } }
    $region = Invoke-Block 'Région' { Get-Cached 'region' 30 { Get-RegionInfo } }
    $shutdown = if ($memory) { Invoke-Block 'Dernier arrêt' { Get-Cached 'shutdown' 86400 { Get-LastShutdown $memory.BootTime } } }

    # Métriques : processeur, mémoire, température du processeur (Detail = ligne sous la valeur)
    $cpuLoad = Invoke-Block 'Utilisation CPU' { Get-CpuUsage }
    $detail = @()
    if ($frequency) { $detail += Format-Unit $frequency 'GHz' '0.00' }
    if ($static) { $detail += '{0} threads' -f $static.Threads }
    $sections.Add([PSCustomObject]@{
            Title = 'Utilisation du processeur'; Type = 'Metric'; Icon = 'developer_board'; Value = $cpuLoad.Total; Unit = '%'; Max = 100
            Warning = $script:CpuWarning; Critical = $script:CpuCritical
            Detail = $detail -join ' · '
        })

    if ($memory) {
        $totalGiB = [Math]::Round($memory.Total / 1GB, 1)
        $sections.Add([PSCustomObject]@{
                Title = 'Mémoire utilisée'; Type = 'Metric'; Icon = 'ram'
                Value = [Math]::Round(($memory.Total - $memory.Available) / 1GB, 1); Unit = 'GiB'; Max = $totalGiB
                Warning = [Math]::Round($totalGiB * $script:MemWarning, 1)
                Critical = [Math]::Round($totalGiB * $script:MemCritical, 1)
                Detail = ('{0} disponibles sur {1}' -f (Format-GiB $memory.Available), (Format-GiB $memory.Total))
            })
    }

    if ($memory) {
        $ratio = ($memory.Total - $memory.Available) / $memory.Total
        if ($ratio -ge $script:MemWarning) {
            $findings.Add([PSCustomObject]@{
                    Severity = $(if ($ratio -ge $script:MemCritical) { 'critical' } else { 'warning' })
                    Code = 'SYS-MEM-HIGH'
                    Message = ('Mémoire utilisée à {0} % ({1} disponibles)' -f [Math]::Round(100 * $ratio), (Format-GiB $memory.Available))
                    Recommendation = 'Fermer les applications les plus gourmandes (voir les processus les plus actifs).'
                })
        }
    }

    if ($memory -and $memory.SwapTotal -gt 0 -and ($memory.SwapTotal - $memory.SwapFree) / $memory.SwapTotal -ge 0.8) {
        $findings.Add([PSCustomObject]@{
                Severity = 'warning'; Code = 'SYS-SWAP-HIGH'
                Message = ('{0} utilisé à {1} % ({2} sur {3})' -f $memory.SwapLabel, [Math]::Floor(100 * ($memory.SwapTotal - $memory.SwapFree) / $memory.SwapTotal),
                    (Format-GiB ($memory.SwapTotal - $memory.SwapFree)), (Format-GiB $memory.SwapTotal))
                Recommendation = 'La mémoire vive manque : le système ralentit en écrivant sur le disque. Fermer des applications ou ajouter de la RAM.'
            })
    }

    if ($temps -and $temps.Cpu -and $temps.Cpu.Celsius -ge $script:TempWarning) {
        $findings.Add([PSCustomObject]@{
                Severity = $(if ($temps.Cpu.Celsius -ge $script:TempCritical) { 'critical' } else { 'warning' })
                Code = 'SYS-CPU-HOT'
                Message = ('Processeur à {0}' -f (Format-Unit $temps.Cpu.Celsius '°C' '0'))
                Recommendation = 'Vérifier la ventilation et la charge du processeur.'
            })
    }

    if ($temps -and $temps.Cpu) {
        $sections.Add([PSCustomObject]@{
                Title = 'Température du processeur'; Type = 'Metric'; Icon = 'temperature'; Value = $temps.Cpu.Celsius; Unit = '°C'
                Warning = $script:TempWarning; Critical = $script:TempCritical
                Detail = ('Capteur {0} · {1}' -f $temps.Cpu.Chip, $temps.Cpu.Label)
            })
    }

    # Système d'exploitation
    if ($static -and $memory) {
        $items = [ordered]@{ 'Système' = $static.OsName }
        if ($static.Version) { $items['Version'] = $static.Version }
        $items['Noyau'] = $static.Kernel
        $items['Architecture'] = $static.Arch
        if ($static.InstallDate) {
            $items['Installé le'] = $static.InstallDate.ToString('dd/MM/yyyy', $script:Fr) + $(if ($IsLinux) { ' (approx.)' } else { '' })
        }
        $items['Démarré le'] = $memory.BootTime.ToString('dd/MM/yyyy HH:mm', $script:Fr)
        $items['Temps de fonctionnement'] = Format-Duration ((Get-Date) - $memory.BootTime)
        if ($shutdown) {
            $items['Arrêt précédent'] = '{0} le {1}' -f $(if ($shutdown.Clean) { 'Propre' } else { 'Inattendu' }), $shutdown.Time.ToString('dd/MM/yyyy HH:mm', $script:Fr)
        }
        if ($processes) { $items['Processus'] = $processes.Count }
        $sections.Add([PSCustomObject]@{ Title = "Système d'exploitation"; Type = 'KeyValue'; Icon = 'desktop'; Items = $items })

        if ($shutdown -and -not $shutdown.Clean) {
            $findings.Add([PSCustomObject]@{
                    Severity = 'warning'; Code = 'SYS-UNEXPECTED-SHUTDOWN'
                    Message = ('Le démarrage précédent s''est terminé sans arrêt propre ({0})' -f $shutdown.Time.ToString('dd/MM/yyyy HH:mm', $script:Fr))
                    Recommendation = 'Coupure de courant, plantage ou arrêt forcé : voir le module Événements si cela se répète.'
                })
        }
    }

    # Machine : identité, domaine, virtualisation
    if ($static) {
        $items = [ordered]@{ 'Nom' = [Environment]::MachineName; 'Utilisateur' = [Environment]::UserName }
        if ($static.Vendor) { $items['Fabricant'] = $static.Vendor }
        if ($static.Model) { $items['Modèle'] = $static.Model }
        if ($static.Domain) { $items['Domaine'] = $static.Domain }
        if ($static.Virtual) { $items['Virtualisation'] = $static.Virtual }
        $sections.Add([PSCustomObject]@{ Title = 'Machine'; Type = 'KeyValue'; Icon = 'server'; Items = $items })
    }

    # Processeur
    if ($static) {
        $items = [ordered]@{
            'Modèle'  = $static.CpuModel
            'Cœurs'   = $static.Cores
            'Threads' = $static.Threads
        }
        if ($frequency) { $items['Fréquence actuelle'] = Format-Unit $frequency 'GHz' '0.00' }
        if ($static.MaxGHz) { $items['Fréquence maximale'] = Format-Unit $static.MaxGHz 'GHz' '0.00' }
        if ($static.Cache) { $items['Cache'] = $static.Cache }
        $sections.Add([PSCustomObject]@{ Title = 'Processeur'; Type = 'KeyValue'; Icon = 'developer_board'; Items = $items })
    }

    # Charge par processeur logique : une jauge par thread, sans seuil (un thread à 100 % est normal)
    if ($cpuLoad -and $cpuLoad.Cores.Count -gt 0) {
        $i = 0
        $items = foreach ($core in $cpuLoad.Cores) {
            [PSCustomObject]@{ Label = 'Thread {0}' -f $i++; Value = $core; Max = 100; Unit = '%' }
        }
        $sections.Add([PSCustomObject]@{ Title = 'Charge par thread'; Type = 'Usage'; Icon = 'pulse'; Items = @($items) })
    }

    # Mémoire (détail)
    if ($memory) {
        $items = [ordered]@{
            'Totale'      = Format-GiB $memory.Total
            'Utilisée'    = Format-GiB ($memory.Total - $memory.Available)
            'Disponible'  = Format-GiB $memory.Available
        }
        if ($memory.Cached) { $items['En cache'] = Format-GiB $memory.Cached }
        if ($memory.Committed) {
            $items['Engagée'] = if ($memory.CommitLimit) { '{0} sur {1} (limite)' -f (Format-GiB $memory.Committed), (Format-GiB $memory.CommitLimit) }
                                else { Format-GiB $memory.Committed }
        }
        $items["$($memory.SwapLabel) utilisé"] = if ($memory.SwapTotal -gt 0) {
            '{0} sur {1}' -f (Format-GiB ($memory.SwapTotal - $memory.SwapFree)), (Format-GiB $memory.SwapTotal)
        } else { 'Aucun' }
        $sections.Add([PSCustomObject]@{ Title = 'Mémoire'; Type = 'KeyValue'; Icon = 'ram'; Items = $items })
    }

    # Processus les plus actifs (nombres bruts : l'interface formate et trie)
    if ($processes) {
        $rows = foreach ($p in $processes.Top) {
            , @($p.Name, $p.Id, $p.Cpu, [Math]::Round($p.Memory / 1MB, 1))
        }
        $sections.Add([PSCustomObject]@{
                Title = 'Processus les plus actifs'; Type = 'Table'; Icon = 'apps_list'
                Columns = @('Nom', 'PID', 'CPU %', 'Mémoire (MiB)')
                Rows = @($rows)
            })
    }

    # Date et heure
    if ($time) {
        $items = [ordered]@{ 'Heure locale' = (Get-Date).ToString('dd/MM/yyyy HH:mm:ss', $script:Fr) }
        if ($time.Zone) { $items['Fuseau horaire'] = $time.Zone }
        $items['Synchronisation'] = if ($time.Ntp) { 'Activée' } else { 'Désactivée' }
        if ($null -ne $time.Synced) { $items['Synchronisée'] = if ($time.Synced) { 'Oui' } else { 'Non' } }
        if ($time.Server) { $items['Serveur de temps'] = $time.Server }
        $sections.Add([PSCustomObject]@{ Title = 'Date et heure'; Type = 'KeyValue'; Icon = 'timer'; Items = $items })

        if (-not $time.Ntp -or $time.Synced -eq $false) {
            $findings.Add([PSCustomObject]@{
                    Severity = 'warning'; Code = 'SYS-TIME-NOT-SYNCED'
                    Message = $(if (-not $time.Ntp) { "La synchronisation de l'heure est désactivée" } else { "L'horloge n'est pas synchronisée" })
                    Recommendation = 'Une heure fausse casse TLS, Kerberos et les journaux : activer la synchronisation NTP.'
                })
        }
    }

    # Langue et région
    if ($region) {
        $items = [ordered]@{}
        if ($region.System) { $items['Langue du système'] = $region.System }
        if ($region.Formats) { $items['Formats régionaux'] = $region.Formats }
        if ($region.Keyboard) { $items['Clavier'] = $region.Keyboard }
        if ($items.Count -gt 0) { $sections.Add([PSCustomObject]@{ Title = 'Langue et région'; Type = 'KeyValue'; Icon = 'globe'; Items = $items }) }
    }

    # Températures, si disponibles
    if ($temps) {
        if ($temps.Sensors.Count -gt 0) {
            $rows = foreach ($s in $temps.Sensors) { , @(('{0} · {1}' -f $s.Chip, $s.Label), $s.Celsius) }
            $sections.Add([PSCustomObject]@{
                    Title = 'Températures'; Type = 'Table'; Icon = 'temperature'
                    Columns = @('Capteur', 'Température (°C)')
                    Rows = @($rows)
                })
        }
        else {
            $sections.Add([PSCustomObject]@{
                    Title = 'Températures'; Type = 'KeyValue'; Icon = 'temperature'
                    Items = [ordered]@{ 'Capteurs' = $temps.Reason }
                })
        }
    }

    if ($errors.Count -gt 0) {
        $sections.Add([PSCustomObject]@{ Title = 'Erreurs'; Type = 'KeyValue'; Icon = 'warning'; Items = $errors })
    }

    # Sous-titre de l'en-tête : système, machine, temps de fonctionnement
    $subtitle = @()
    if ($static) { $subtitle += $static.OsName }
    $subtitle += [Environment]::MachineName
    if ($memory) { $subtitle += 'en marche depuis {0}' -f (Format-Duration ((Get-Date) - $memory.BootTime)) }

    [PSCustomObject]@{ Subtitle = $subtitle -join ' · '; Sections = $sections.ToArray(); Findings = $findings.ToArray() }
}

#region Fonctions ciblées (module.json › functions)

# Ligne de commande sans secrets évidents (--password=…, token …) : le MCP ne doit jamais exposer de mot de passe.
function Hide-Secrets([string]$CommandLine) {
    if (-not $CommandLine) { return $null }
    $masked = $CommandLine -replace '(?i)((?:--?|/)?(?:pass(?:word|wd)?|pwd|token|secret|api[-_]?key|auth)[=:\s]+)("[^"]*"|\S+)', '$1***'
    if ($masked.Length -gt 300) { $masked.Substring(0, 300) + '…' } else { $masked }
}

# Parent de chaque processus (PID → PID parent), en un seul relevé.
# Windows : Win32_Process.ParentProcessId. Linux : 4e champ de /proc/<pid>/stat (après le nom entre parenthèses).
function Get-ParentMap {
    $map = @{}
    if ($IsWindows) {
        foreach ($p in Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId) { $map[[int]$p.ProcessId] = [int]$p.ParentProcessId }
        return $map
    }
    foreach ($dir in [System.IO.Directory]::GetDirectories('/proc')) {
        $name = [System.IO.Path]::GetFileName($dir)
        if ($name -notmatch '^\d+$') { continue }
        try {
            $stat = [System.IO.File]::ReadAllText("$dir/stat")
            $fields = $stat.Substring($stat.LastIndexOf(')') + 2) -split ' '
            $map[[int]$name] = [int]$fields[1]
        }
        catch { }
    }
    $map
}

# Octets lus / écrits depuis le lancement, par PID.
# Windows : Win32_Process ReadTransferCount / WriteTransferCount (toutes les E/S, réseau compris).
# Linux   : /proc/<pid>/io read_bytes / write_bytes (E/S disque ; lisible pour ses propres processus, tous en root).
function Get-ProcessIo([int[]]$Ids) {
    $io = @{}
    if ($IsWindows) {
        $filter = if ($Ids.Count -gt 0 -and $Ids.Count -le 200) { ($Ids | ForEach-Object { "ProcessId=$_" }) -join ' OR ' } else { $null }
        $procs = if ($filter) { Get-CimInstance -ClassName Win32_Process -Filter $filter -Property ProcessId, ReadTransferCount, WriteTransferCount }
                 else { Get-CimInstance -ClassName Win32_Process -Property ProcessId, ReadTransferCount, WriteTransferCount }
        foreach ($p in $procs) { $io[[int]$p.ProcessId] = @{ Read = [double]$p.ReadTransferCount; Write = [double]$p.WriteTransferCount } }
        return $io
    }
    foreach ($id in $Ids) {
        try {
            $values = @{}
            foreach ($line in [System.IO.File]::ReadAllLines("/proc/$id/io")) {
                if ($line -match '^(read_bytes|write_bytes):\s+(\d+)') { $values[$Matches[1]] = [double]$Matches[2] }
            }
            $io[$id] = @{ Read = $values.read_bytes; Write = $values.write_bytes }
        }
        catch { }
    }
    $io
}

# Windows : signature Authenticode de l'exécutable (mise en cache par chemin, coûteuse).
$script:Signatures = @{}
function Get-SignatureText([string]$Path) {
    if (-not $IsWindows -or -not $Path) { return $null }
    if (-not $script:Signatures.ContainsKey($Path)) {
        $text = try {
            $sig = Get-AuthenticodeSignature -FilePath $Path -ErrorAction Stop
            switch ($sig.Status) {
                'Valid' { 'Signé · ' + (($sig.SignerCertificate.Subject -split ',')[0] -replace '^CN=', '').Trim('"') }
                'NotSigned' { 'Non signé' }
                default { "Signature invalide ($($sig.Status))" }
            }
        } catch { $null }
        $script:Signatures[$Path] = $text
    }
    $script:Signatures[$Path]
}

# Pourcentages CPU : il faut un relevé précédent (appel isolé depuis le MCP).
function Get-ProcessSnapshotReady {
    if (-not $script:PrevProc) {
        [void](Get-ProcessSnapshot)
        Start-Sleep -Milliseconds 250
    }
    Get-Cached 'processes' 6 { Get-ProcessSnapshot }
}

# system_get_processes : liste des processus, triée et filtrée, avec utilisateur, chemin, ligne de commande,
# E/S cumulées et (Windows) signature de l'exécutable.
# Windows : Get-Process (-IncludeUserName exige les droits administrateur, sinon colonne vide), CommandLine via CIM.
# Linux   : Get-Process (/proc/<pid>/status, cmdline, exe), /proc/<pid>/io.
function Get-SIProcesses {
    param(
        [ValidateRange(1, 500)][int]$Top = 20,
        [ValidateSet('cpu', 'memory', 'io', 'name')][string]$SortBy = 'cpu',
        [string]$Filter
    )

    $snapshot = Get-ProcessSnapshotReady
    $rows = $snapshot.All
    if ($Filter) { $rows = $rows | Where-Object Name -Like "*$Filter*" }

    $io = $null
    if ($SortBy -eq 'io') {
        $io = Get-ProcessIo @($rows.Id)
        $sorted = $rows | Sort-Object @{ Expression = { $x = $io[$_.Id]; if ($x) { [double]$x.Read + [double]$x.Write } else { -1 } }; Descending = $true }
    }
    else {
        $sorted = switch ($SortBy) {
            'memory' { $rows | Sort-Object Memory -Descending }
            'name'   { $rows | Sort-Object Name, Id }
            default  { $rows | Sort-Object @{ Expression = { [double]$_.Cpu }; Descending = $true }, @{ Expression = 'Memory'; Descending = $true } }
        }
    }
    $selected = @($sorted | Select-Object -First $Top)
    $ids = @($selected.Id)
    if (-not $io) { $io = Get-ProcessIo $ids }

    # Détails lus seulement pour les processus retenus (coûteux : ~0,7 ms par processus sous Linux).
    $details = @{}
    if ($ids.Count -gt 0) {
        $procs = try { Get-Process -Id $ids -IncludeUserName -ErrorAction SilentlyContinue } catch { Get-Process -Id $ids -ErrorAction SilentlyContinue }
        foreach ($p in $procs) { $details[$p.Id] = $p }
    }
    $parents = Get-ParentMap

    $tableRows = foreach ($r in $selected) {
        $p = $details[$r.Id]
        $user = $path = $cmd = $started = $null
        if ($p) {
            try { $user = $p.UserName } catch { }
            try { $path = $p.Path } catch { }
            try { $cmd = Hide-Secrets $p.CommandLine } catch { }
            try { $started = $p.StartTime.ToString('dd/MM/yyyy HH:mm', $script:Fr) } catch { }
        }
        $x = $io[$r.Id]
        $row = @($r.Name, $r.Id, $parents[$r.Id], $r.Cpu, [Math]::Round($r.Memory / 1MB, 1),
            $(if ($x -and $null -ne $x.Read) { [Math]::Round($x.Read / 1MB, 1) } else { $null }),
            $(if ($x -and $null -ne $x.Write) { [Math]::Round($x.Write / 1MB, 1) } else { $null }),
            $user, $started, $path)
        if ($IsWindows) { $row += Get-SignatureText $path }
        $row += $cmd
        , $row
    }

    $columns = @('Nom', 'PID', 'PID parent', 'CPU %', 'Mémoire (MiB)', 'Lu (MiB)', 'Écrit (MiB)', 'Utilisateur', 'Démarré le', 'Chemin')
    if ($IsWindows) { $columns += 'Signature' }
    $columns += 'Ligne de commande'

    $order = @{ cpu = 'CPU'; memory = 'mémoire'; io = 'entrées/sorties'; name = 'nom' }[$SortBy]
    $subtitle = '{0} processus · {1} affichés · tri par {2}' -f @($rows).Count, $selected.Count, $order
    if ($Filter) { $subtitle += " · filtre « $Filter »" }

    $findings = @()
    if ($IsWindows) {
        $unsigned = @($tableRows | Where-Object { $_[10] -eq 'Non signé' -and $_[9] -and $_[9] -notlike "$env:WINDIR*" })
        foreach ($u in $unsigned) {
            $findings += [PSCustomObject]@{
                Severity = 'info'; Code = 'SYS-PROC-UNSIGNED'
                Message = ('{0} (PID {1}) : exécutable non signé, {2}' -f $u[0], $u[1], $u[9])
                Recommendation = 'Vérifier que ce programme est connu et attendu.'
            }
        }
    }

    [PSCustomObject]@{
        Subtitle = $subtitle
        Sections = @(
            [PSCustomObject]@{ Title = 'Processus'; Type = 'Table'; Icon = 'apps_list'; Columns = $columns; Rows = @($tableRows) }
        )
        Findings = $findings
    }
}

# system_get_process_tree : arbre des processus (parent → enfants), depuis un PID ou depuis les racines.
function Get-SIProcessTree {
    param(
        [int]$ProcessId = 0,
        [ValidateRange(1, 30)][int]$MaxDepth = 10,
        [ValidateRange(1, 2000)][int]$Top = 300
    )

    $snapshot = Get-ProcessSnapshotReady
    $byId = @{}
    foreach ($r in $snapshot.All) { $byId[$r.Id] = $r }
    $parents = Get-ParentMap
    $children = @{}
    foreach ($id in $byId.Keys) {
        $parent = $parents[$id]
        # Racine : pas de parent connu, ou parent disparu (Windows réutilise les PID : parent plus récent = racine).
        if ($null -eq $parent -or -not $byId.ContainsKey($parent) -or $parent -eq $id) { $parent = -1 }
        if (-not $children.ContainsKey($parent)) { $children[$parent] = [System.Collections.Generic.List[int]]::new() }
        $children[$parent].Add($id)
    }

    if ($ProcessId -ne 0 -and -not $byId.ContainsKey($ProcessId)) { throw "Aucun processus avec le PID $ProcessId" }
    $roots = if ($ProcessId -ne 0) { @($ProcessId) } else { @($children[-1]) }

    $rows = [System.Collections.Generic.List[object]]::new()
    $walk = {
        param([int]$Id, [int]$Depth)
        if ($rows.Count -ge $Top) { return }
        $r = $byId[$Id]
        $label = ('    ' * $Depth) + $(if ($Depth -gt 0) { '└ ' } else { '' }) + $r.Name
        $count = if ($children.ContainsKey($Id)) { $children[$Id].Count } else { 0 }
        $rows.Add(@($label, $r.Id, $(if ($parents[$Id]) { $parents[$Id] } else { $null }), $count, $r.Cpu, [Math]::Round($r.Memory / 1MB, 1)))
        if ($Depth + 1 -ge $MaxDepth -or $count -eq 0) { return }
        foreach ($child in ($children[$Id] | Sort-Object { $byId[$_].Name }, { $_ })) { & $walk $child ($Depth + 1) }
    }
    foreach ($root in ($roots | Sort-Object { $_ })) { & $walk $root 0 }

    $subtitle = if ($ProcessId -ne 0) { 'Sous-arbre de {0} (PID {1})' -f $byId[$ProcessId].Name, $ProcessId } else { '{0} processus' -f $byId.Count }
    if ($rows.Count -ge $Top) { $subtitle += " · limité à $Top lignes" }

    [PSCustomObject]@{
        Subtitle = $subtitle
        Sections = @(
            [PSCustomObject]@{
                Title = 'Arbre des processus'; Type = 'Table'; Icon = 'apps_list'
                Columns = @('Processus', 'PID', 'PID parent', 'Enfants', 'CPU %', 'Mémoire (MiB)')
                Rows = $rows.ToArray()
            }
        )
        Findings = @()
    }
}

#endregion

Export-ModuleMember -Function Get-ModuleData, Get-SIProcesses, Get-SIProcessTree
