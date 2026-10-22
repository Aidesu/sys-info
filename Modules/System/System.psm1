# Module Système : CPU, RAM, uptime, OS, processus, températures si disponibles.
#
# Sources
#   Windows : CIM (Win32_OperatingSystem, Win32_Processor, Win32_PerfFormattedData_PerfOS_Processor,
#             root/wmi MSAcpi_ThermalZoneTemperature), Get-Process.
#   Linux   : /proc (stat, meminfo, uptime, cpuinfo), /etc/os-release, /sys (cpufreq, hwmon), Get-Process.
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

function Get-StaticInfo {
    $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()

    if ($IsWindows) {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        $cpu = @(Get-CimInstance -ClassName Win32_Processor)
        return [PSCustomObject]@{
            OsName   = $os.Caption.Trim()
            Kernel   = 'Build {0}' -f $os.BuildNumber
            Arch     = $arch
            CpuModel = $cpu[0].Name.Trim()
            Cores    = ($cpu | Measure-Object -Property NumberOfCores -Sum).Sum
            Threads  = ($cpu | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
            MaxGHz   = $cpu[0].MaxClockSpeed / 1000
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

        return [PSCustomObject]@{
            OsName   = $osName
            Kernel   = (Get-Content -Path /proc/sys/kernel/osrelease).Trim()
            Arch     = $arch
            CpuModel = $model
            Cores    = if ($cores.Count -gt 0) { $cores.Count } else { $threads }
            Threads  = $threads
            MaxGHz   = if ($maxKHz) { [double]$maxKHz / 1e6 } else { $null }
        }
    }

    throw 'Système non pris en charge'
}

#endregion

#region Mesures

# Utilisation CPU globale, en %.
function Get-CpuUsage {
    if ($IsWindows) {
        $total = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'"
        return [double]$total.PercentProcessorTime
    }

    # Linux : /proc/stat, ligne "cpu" = user nice system idle iowait irq softirq steal (guest inclus dans user).
    $fields = ((Get-Content -Path /proc/stat -TotalCount 1) -split '\s+')[1..8] | ForEach-Object { [double]$_ }
    $sample = [PSCustomObject]@{
        Total = ($fields | Measure-Object -Sum).Sum
        Idle  = $fields[3] + $fields[4]
    }
    $previous = $script:PrevCpu
    $script:PrevCpu = $sample
    if (-not $previous -or $sample.Total -le $previous.Total) { return $null }

    $busy = ($sample.Total - $previous.Total) - ($sample.Idle - $previous.Idle)
    return [Math]::Round(100 * $busy / ($sample.Total - $previous.Total), 1)
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
        return [PSCustomObject]@{
            Total     = [double]$os.TotalVisibleMemorySize * 1KB
            Available = [double]$os.FreePhysicalMemory * 1KB
            SwapTotal = [double]$os.SizeStoredInPagingFiles * 1KB
            SwapFree  = [double]$os.FreeSpaceInPagingFiles * 1KB
            SwapLabel = "Fichier d'échange"
            BootTime  = $os.LastBootUpTime
        }
    }

    $info = @{}
    foreach ($line in Get-Content -Path /proc/meminfo) {
        if ($line -match '^(\w+):\s+(\d+)') { $info[$Matches[1]] = [double]$Matches[2] * 1KB }
    }
    $uptime = [double]((Get-Content -Path /proc/uptime) -split '\s+')[0]
    return [PSCustomObject]@{
        Total     = $info.MemTotal
        Available = if ($info.ContainsKey('MemAvailable')) { $info.MemAvailable } else { $info.MemFree }
        SwapTotal = $info.SwapTotal
        SwapFree  = $info.SwapFree
        SwapLabel = 'Swap'
        BootTime  = (Get-Date).AddSeconds(-$uptime)
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
        Top   = $rows | Sort-Object -Property @{ Expression = { [double]$_.Cpu }; Descending = $true },
                                              @{ Expression = 'Memory'; Descending = $true } |
                Select-Object -First 15
    }
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
            if ($IsLinux) { [void](Get-CpuUsage) }
            [void](Get-ProcessSnapshot)
            Start-Sleep -Milliseconds 250
        }
    }

    $memory = Invoke-Block 'Mémoire' { Get-MemoryInfo }
    $processes = Invoke-Block 'Processus' { Get-Cached 'processes' 6 { Get-ProcessSnapshot } }
    $temps = Invoke-Block 'Températures' { Get-Temperatures }

    $frequency = Invoke-Block 'Fréquence' { Get-CpuFrequency }

    # Métriques : processeur, mémoire, température du processeur (Detail = ligne sous la valeur)
    Invoke-Block 'Utilisation CPU' {
        $usage = Get-CpuUsage
        $detail = @()
        if ($frequency) { $detail += Format-Unit $frequency 'GHz' '0.00' }
        if ($static) { $detail += '{0} threads' -f $static.Threads }
        $sections.Add([PSCustomObject]@{
                Title = 'Utilisation du processeur'; Type = 'Metric'; Icon = 'developer_board'; Value = $usage; Unit = '%'; Max = 100
                Warning = $script:CpuWarning; Critical = $script:CpuCritical
                Detail = $detail -join ' · '
            })
    }

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

    if ($temps -and $temps.Cpu) {
        $sections.Add([PSCustomObject]@{
                Title = 'Température du processeur'; Type = 'Metric'; Icon = 'temperature'; Value = $temps.Cpu.Celsius; Unit = '°C'
                Warning = $script:TempWarning; Critical = $script:TempCritical
                Detail = ('Capteur {0} · {1}' -f $temps.Cpu.Chip, $temps.Cpu.Label)
            })
    }

    # Système d'exploitation
    if ($static -and $memory) {
        $items = [ordered]@{
            'Système'        = $static.OsName
            'Noyau'          = $static.Kernel
            'Architecture'   = $static.Arch
            'Machine'        = [Environment]::MachineName
            'Utilisateur'    = [Environment]::UserName
            'Démarré le'     = $memory.BootTime.ToString('dd/MM/yyyy HH:mm', $script:Fr)
            'Temps de fonctionnement' = Format-Duration ((Get-Date) - $memory.BootTime)
        }
        if ($processes) { $items['Processus'] = $processes.Count }
        $sections.Add([PSCustomObject]@{ Title = "Système d'exploitation"; Type = 'KeyValue'; Icon = 'desktop'; Items = $items })
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
        $sections.Add([PSCustomObject]@{ Title = 'Processeur'; Type = 'KeyValue'; Icon = 'developer_board'; Items = $items })
    }

    # Mémoire (détail)
    if ($memory) {
        $items = [ordered]@{
            'Totale'      = Format-GiB $memory.Total
            'Utilisée'    = Format-GiB ($memory.Total - $memory.Available)
            'Disponible'  = Format-GiB $memory.Available
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

    [PSCustomObject]@{ Subtitle = $subtitle -join ' · '; Sections = $sections.ToArray() }
}

Export-ModuleMember -Function Get-ModuleData
