# Module Capteurs & Énergie : températures, ventilateurs, tensions, bridage du processeur, batterie, alimentation,
# plan d'alimentation, veille et réveil, démarrage rapide, onduleur.
#
# Sources
#   Windows : compteurs PDH (Thermal Zone Information, Processor Information % Performance Limit) via
#             [SysInfo.Native.PdhQuery] ; LibreHardwareMonitor s'il tourne (WMI root/LibreHardwareMonitor, toutes les
#             sondes : CPU, GPU, disques, ventilateurs, tensions) ; nvidia-smi ; [SysInfo.Native.PowerStatus]
#             (GetSystemPowerStatus) ; Win32_Battery et root/wmi (BatteryStaticData, BatteryFullChargedCapacity,
#             BatteryCycleCount, BatteryStatus), en cache ; powercfg (/getactivescheme, /list, /a, /lastwake,
#             /devicequery wake_armed, /waketimers, /setactive, /batteryreport, /energy) ; registre (HiberbootEnabled) ;
#             journal System (Kernel-Power 42 / 107, Power-Troubleshooter 1).
#   Linux   : /sys/class/hwmon (temp, fan, in, curr, power), nvidia-smi (si la carte n'est pas en veille),
#             /sys/devices/system/cpu (cpufreq, thermal_throttle, intel_pstate), /sys/class/power_supply,
#             upower, /var/lib/upower (historique de charge), powerprofilesctl ou tuned-adm, /sys/firmware/acpi/platform_profile,
#             /sys/power, /proc/acpi/wakeup, journalctl (mises en veille), systemctl (minuteries qui réveillent),
#             upsc (NUT) et apcaccess (apcupsd) pour les onduleurs.

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

function Format-Duration([double]$Seconds) {
    $span = [timespan]::FromSeconds($Seconds)
    if ($span.TotalHours -ge 1) { return '{0}{1}h{2:00}' -f [Math]::Floor($span.TotalHours), $script:Nbsp, $span.Minutes }
    if ($span.TotalSeconds -lt 60) { return Format-Unit $span.TotalSeconds 's' '0.#' }
    Format-Unit $span.TotalMinutes 'min' '0'
}

function Format-Date($Date) {
    if (-not $Date) { return '—' }
    $d = [datetime]$Date
    if ($d.Date -eq (Get-Date).Date) { return "aujourd'hui " + $d.ToString('HH:mm', $script:Fr) }
    $d.ToString('ddd d MMM HH:mm', $script:Fr)
}

function Read-Text([string]$Path) {
    try { [System.IO.File]::ReadAllText($Path).Trim() } catch { $null }
}

function Read-Number([string]$Path) {
    $text = Read-Text $Path
    $value = 0.0
    if ($text -and [double]::TryParse($text, [System.Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$value)) { return $value }
    $null
}

# Présence d'un outil externe : Get-Command parcourt le PATH (~30 ms pour un outil absent), gardé 10 min.
$script:Tools = @{}
function Test-Tool([string]$Name) {
    $entry = $script:Tools[$Name]
    if (-not $entry -or ((Get-Date) - $entry.At).TotalMinutes -ge 10) {
        $entry = @{ At = Get-Date; Found = [bool](Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue) }
        $script:Tools[$Name] = $entry
    }
    $entry.Found
}

function Invoke-Tool([string]$Name, [string[]]$Arguments) {
    if (-not (Test-Tool $Name)) { return @() }
    & $Name @Arguments 2>$null
}

function New-Finding([string]$Severity, [string]$Code, [string]$Message, [string]$Recommendation) {
    [PSCustomObject]@{ Severity = $Severity; Code = $Code; Message = $Message; Recommendation = $Recommendation }
}

function New-ActionResult([string]$Subtitle, [object[]]$Sections, [object[]]$Findings, [object[]]$Changes, [string]$Blocked, $Undo) {
    $result = [ordered]@{
        Subtitle = $Subtitle
        Sections = @($Sections | Where-Object { $_ })
        Findings = @($Findings | Where-Object { $_ })
        Changes  = @($Changes | Where-Object { $_ })
        Blocked  = $Blocked
    }
    if ($Undo) { $result.Undo = $Undo }
    [PSCustomObject]$result
}

function New-Change([string]$Target, [string]$Property, $Before, $After) {
    [PSCustomObject]@{ Target = $Target; Property = $Property; Before = $Before; After = $After }
}

#endregion

#region Capteurs

# Composant d'une puce hwmon (Linux) et seuils par défaut (°C) quand la puce n'en donne pas.
function Get-ChipKind([string]$Chip) {
    switch -Regex ($Chip) {
        '^(coretemp|k10temp|zenpower|cpu_thermal|via_cputemp)$' { return @{ Kind = 'cpu'; Label = 'Processeur'; Warning = 80; Critical = 90 } }
        '^(amdgpu|nouveau|radeon|i915|xe)$' { return @{ Kind = 'gpu'; Label = 'Carte graphique'; Warning = 85; Critical = 95 } }
        '^nvme$' { return @{ Kind = 'disk'; Label = 'SSD NVMe'; Warning = 70; Critical = 80 } }
        '^drivetemp$' { return @{ Kind = 'disk'; Label = 'Disque'; Warning = 50; Critical = 60 } }
        '^acpitz$' { return @{ Kind = 'board'; Label = 'Zone ACPI'; Warning = 80; Critical = 95 } }
        '^pch_' { return @{ Kind = 'board'; Label = 'Chipset'; Warning = 80; Critical = 95 } }
        '^iwlwifi' { return @{ Kind = 'other'; Label = 'Wi-Fi'; Warning = 80; Critical = 95 } }
        '^(nct|it87|f71|w83|asus|dell|thinkpad|hp)' { return @{ Kind = 'board'; Label = 'Carte mère'; Warning = 80; Critical = 95 } }
        '^(BAT|battery)' { return @{ Kind = 'battery'; Label = 'Batterie'; Warning = 45; Critical = 55 } }
        default { return @{ Kind = 'other'; Label = $Chip; Warning = 80; Critical = 95 } }
    }
}

$script:SysFs = [bool]('SysInfo.Native.SysFs' -as [type])

# Linux : sondes de /sys/class/hwmon. Liste (chemins, libellés, seuils) relue toutes les 60 s, valeurs à chaque appel.
function Get-HwmonSensors {
    $list = Get-Cached 'hwmon' 60 {
        foreach ($hwmon in [System.IO.Directory]::GetDirectories('/sys/class/hwmon')) {
            $chip = Read-Text "$hwmon/name"
            if (-not $chip) { continue }
            $kind = Get-ChipKind $chip
            $device = $kind.Label
            # NVMe : modèle du SSD ; plusieurs puces du même type : numéro.
            $model = Read-Text "$hwmon/device/model"
            if ($model) { $device = "$device $model" }
            foreach ($input in [System.IO.Directory]::GetFiles($hwmon, '*_input')) {
                $base = [System.IO.Path]::GetFileName($input) -replace '_input$', ''
                if ($base -notmatch '^(temp|fan|in|curr|power)\d+$') { continue }
                $type = $Matches[1]
                $label = Read-Text "$hwmon/${base}_label"
                if (-not $label) { $label = $base }
                $scale = @{ temp = 1000; fan = 1; in = 1000; curr = 1000; power = 1000000 }[$type]
                $limit = { param($suffix) $v = Read-Number "$hwmon/${base}_$suffix"; if ($null -ne $v -and $v / $scale -lt 200 -and $v -gt 0) { $v / $scale } else { $null } }
                [PSCustomObject]@{
                    Path = $input; Chip = $chip; Kind = $kind.Kind; Device = $device; Label = $label; Type = $type; Scale = $scale
                    Max = & $limit 'max'; Crit = & $limit 'crit'; Min = & $limit 'min'
                    DefaultWarning = $kind.Warning; DefaultCritical = $kind.Critical
                }
            }
        }
    }
    # Valeurs lues d'un coup par l'application (~0,5 ms) ; seul dans pwsh, fichier par fichier.
    $list = @($list)
    $raws = if ($script:SysFs) { [SysInfo.Native.SysFs]::ReadNumbers([string[]]@($list.Path)) } else { @($list | ForEach-Object { Read-Number $_.Path ?? [double]::NaN }) }
    for ($i = 0; $i -lt $list.Count; $i++) {
        $s = $list[$i]; $raw = $raws[$i]
        if ([double]::IsNaN($raw)) { continue }
        $value = $raw / $s.Scale
        if ($s.Type -eq 'temp' -and ($value -le -40 -or $value -ge 200)) { continue }   # sonde absente ou valeur aberrante
        [PSCustomObject]@{ Device = $s.Device; Kind = $s.Kind; Label = $s.Label; Type = $s.Type; Value = [Math]::Round($value, 2)
            Max = $s.Max; Crit = $s.Crit; Min = $s.Min; DefaultWarning = $s.DefaultWarning; DefaultCritical = $s.DefaultCritical; Source = "hwmon ($($s.Chip))" }
    }
}

# Carte NVIDIA : nvidia-smi (toutes les 10 s), sauf si la carte est en veille (portable : la réveiller coûte de l'énergie).
function Get-NvidiaSensors {
    if (-not (Test-Tool nvidia-smi)) { return @() }
    if ($IsLinux) {
        $asleep = Get-Cached 'nvidiaAsleep' 15 {
            $nv = @(Get-ChildItem /sys/bus/pci/devices -ErrorAction SilentlyContinue | Where-Object { (Read-Text "$($_.FullName)/vendor") -eq '0x10de' -and (Read-Text "$($_.FullName)/class") -like '0x03*' })
            $nv.Count -gt 0 -and -not ($nv | Where-Object { (Read-Text "$($_.FullName)/power/runtime_status") -ne 'suspended' })
        }
        if ($asleep) { return @([PSCustomObject]@{ Asleep = $true }) }
    }
    Get-Cached 'nvidia' 20 {
        foreach ($line in Invoke-Tool nvidia-smi @('--query-gpu=name,temperature.gpu,fan.speed,power.draw,power.limit,clocks.sm,clocks.max.sm,clocks_throttle_reasons.active', '--format=csv,noheader,nounits')) {
            $f = $line -split ',\s*'
            if ($f.Count -lt 8) { continue }
            $num = { param($t) $v = 0.0; if ([double]::TryParse($t, [System.Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$v)) { $v } else { $null } }
            [PSCustomObject]@{ Asleep = $false; Name = $f[0]; Temp = & $num $f[1]; Fan = & $num $f[2]; Power = & $num $f[3]; PowerLimit = & $num $f[4]
                Clock = & $num $f[5]; MaxClock = & $num $f[6]; Reasons = [Convert]::ToInt64(($f[7] -replace '^0x', ''), 16) }
        }
    }
}

# Raisons de bridage NVIDIA (bits de clocks_throttle_reasons) → texte ; l'inactivité (bit 0) n'en est pas une.
function Get-NvidiaReasons([long]$Bits) {
    $names = [ordered]@{ 0x4 = 'consigne applicative'; 0x8 = 'freinage matériel'; 0x20 = 'ralentissement logiciel'; 0x40 = 'ralentissement matériel (température)'
        0x80 = 'frein d''alimentation'; 0x100 = 'limite d''énergie'; 0x2 = 'limite de puissance' }
    @($names.Keys | Where-Object { $Bits -band $_ } | ForEach-Object { $names[$_] })
}

# Windows : compteurs PDH (zones thermiques, limite de performance du processeur), une requête gardée par runspace.
$script:Pdh = $null
function Get-WindowsCounters {
    if (-not ('SysInfo.Native.PdhQuery' -as [type])) { return $null }
    if (-not $script:Pdh) {
        $script:Pdh = [SysInfo.Native.PdhQuery]::new([string[]]@(
                '\Processor Information(_Total)\% Performance Limit',
                '\Processor Information(_Total)\% Processor Performance',
                '\Thermal Zone Information(*)\High Precision Temperature'))
    }
    $v = $script:Pdh.Collect()
    $zones = $script:Pdh.Instances(2)
    [PSCustomObject]@{ PerfLimit = $v[0]; Performance = $v[1]; Zones = $zones }
}

# Windows : sondes de LibreHardwareMonitor s'il tourne (WMI, en cache 10 s).
function Get-LhmSensors {
    Get-Cached 'lhm' 10 {
        $items = Get-CimInstance -Namespace root/LibreHardwareMonitor -ClassName Sensor -ErrorAction SilentlyContinue
        if (-not $items) { $items = Get-CimInstance -Namespace root/OpenHardwareMonitor -ClassName Sensor -ErrorAction SilentlyContinue }
        $types = @{ Temperature = 'temp'; Fan = 'fan'; Voltage = 'in'; Current = 'curr'; Power = 'power' }
        foreach ($s in $items) {
            $type = $types["$($s.SensorType)"]
            if (-not $type) { continue }
            $parent = "$($s.Parent)"
            $kind = switch -Regex ($parent) { 'cpu' { 'cpu' } 'gpu' { 'gpu' } '(hdd|nvme|ssd|storage)' { 'disk' } 'battery' { 'battery' } default { 'board' } }
            $defaults = @{ cpu = @(80, 90); gpu = @(85, 95); disk = @(60, 70); battery = @(45, 55); board = @(80, 95) }[$kind]
            [PSCustomObject]@{ Device = ($parent -replace '^/', '' -replace '/\d+$', ''); Kind = $kind; Label = $s.Name; Type = $type; Value = [Math]::Round([double]$s.Value, 2)
                Max = $null; Crit = $null; Min = $null; DefaultWarning = $defaults[0]; DefaultCritical = $defaults[1]; Source = 'LibreHardwareMonitor' }
        }
    }
}

# Toutes les sondes de la machine (même forme sous Windows et Linux).
function Get-AllSensors {
    $sensors = [System.Collections.Generic.List[object]]::new()
    $notes = [System.Collections.Generic.List[string]]::new()
    if ($IsLinux) {
        foreach ($s in Get-HwmonSensors) { $sensors.Add($s) }
        if (-not $sensors.Count) { $notes.Add('Aucune sonde dans /sys/class/hwmon (machine virtuelle, ou pilote lm-sensors à charger : sensors-detect).') }
    }
    else {
        $lhm = @(Get-LhmSensors)
        foreach ($s in $lhm) { $sensors.Add($s) }
        if (-not $lhm.Count) {
            $counters = Get-WindowsCounters
            if ($counters) {
                foreach ($zone in $counters.Zones.Keys) {
                    $c = [Math]::Round($counters.Zones[$zone] / 10 - 273.15, 1)
                    if ($c -gt -40 -and $c -lt 150) {
                        $sensors.Add([PSCustomObject]@{ Device = 'Zone thermique'; Kind = 'board'; Label = ($zone -replace '^\\_TZ\.', ''); Type = 'temp'; Value = $c
                                Max = $null; Crit = $null; Min = $null; DefaultWarning = 80; DefaultCritical = 95; Source = 'compteur Thermal Zone' })
                    }
                }
            }
            $notes.Add('Windows ne donne que les zones thermiques ACPI : lancer LibreHardwareMonitor pour lire processeur, carte graphique, disques, ventilateurs et tensions.')
        }
    }
    $nvidia = @(Get-NvidiaSensors)
    foreach ($g in $nvidia | Where-Object { -not $_.Asleep }) {
        if ($null -ne $g.Temp -and -not ($sensors | Where-Object { $_.Kind -eq 'gpu' -and $_.Type -eq 'temp' -and $_.Source -eq 'LibreHardwareMonitor' })) {
            $sensors.Add([PSCustomObject]@{ Device = $g.Name; Kind = 'gpu'; Label = 'GPU'; Type = 'temp'; Value = $g.Temp; Max = $null; Crit = $null; Min = $null; DefaultWarning = 85; DefaultCritical = 95; Source = 'nvidia-smi' })
        }
        if ($null -ne $g.Fan) { $sensors.Add([PSCustomObject]@{ Device = $g.Name; Kind = 'gpu'; Label = 'Ventilateur (%)'; Type = 'fanpct'; Value = $g.Fan; Max = $null; Crit = $null; Min = $null; Source = 'nvidia-smi' }) }
        if ($null -ne $g.Power) { $sensors.Add([PSCustomObject]@{ Device = $g.Name; Kind = 'gpu'; Label = 'Consommation'; Type = 'power'; Value = $g.Power; Max = $g.PowerLimit; Crit = $null; Min = $null; Source = 'nvidia-smi' }) }
    }
    # Processeur, carte graphique, disques, carte mère, reste ; « Core 10 » après « Core 9 ».
    $order = @{ cpu = 0; gpu = 1; disk = 2; board = 3; battery = 4; other = 5 }
    $sorted = @($sensors | Sort-Object { $order[$_.Kind] }, Device, { [regex]::Replace($_.Label, '\d+', { $args[0].Value.PadLeft(4, '0') }) })
    [PSCustomObject]@{ Sensors = $sorted; Notes = $notes; Nvidia = $nvidia }
}

# Seuils d'une sonde de température : ceux de la puce (max = Attention, crit = Critique), sinon ceux du composant.
function Get-Thresholds($Sensor) {
    $warning = $Sensor.Max ?? $Sensor.DefaultWarning
    $critical = $Sensor.Crit ?? $Sensor.DefaultCritical
    if ($Sensor.Max -and -not $Sensor.Crit) { $critical = [Math]::Max($warning + 5, $Sensor.DefaultCritical) }
    if ($critical -le $warning) { $warning = $critical - 5 }
    @($warning, $critical)
}

#endregion

#region Processeur : fréquence et bridage

$script:Throttle = $null   # Linux : compteurs thermal_throttle du relevé précédent

function Get-CpuThrottling {
    $limits = if ('SysInfo.Native.CpuSampler' -as [type]) { [SysInfo.Native.CpuSampler]::Limits() } else { $null }
    $r = [ordered]@{ Current = $limits.CurrentGHz; Max = $limits.MaxGHz; Limit = $limits.LimitGHz; Governor = $null; Epp = $null; Turbo = $null
        Events = $null; EventsNow = 0; ThrottledMs = $null; PerfLimit = $null; Performance = $null }
    if ($IsLinux) {
        $r.Governor = Read-Text /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
        $r.Epp = Read-Text /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference
        $noTurbo = Read-Text /sys/devices/system/cpu/intel_pstate/no_turbo
        $boost = Read-Text /sys/devices/system/cpu/cpufreq/boost
        $r.Turbo = if ($noTurbo) { $noTurbo -eq '0' } elseif ($boost) { $boost -eq '1' } else { $null }
        # Intel : épisodes de bridage thermique depuis le démarrage (paquet + cœurs, cpu0 de chaque paquet suffit pour le paquet).
        $files = Get-Cached 'throttleFiles' 3600 {
            @(foreach ($dir in [System.IO.Directory]::GetDirectories('/sys/devices/system/cpu', 'cpu*')) {
                    if ([System.IO.File]::Exists("$dir/thermal_throttle/core_throttle_count")) {
                        "$dir/thermal_throttle/core_throttle_count"; "$dir/thermal_throttle/package_throttle_count"; "$dir/thermal_throttle/core_throttle_total_time_ms"
                    }
                })
        }
        $found = $files.Count -gt 0
        $events = 0.0; $ms = 0.0
        $values = if ($script:SysFs) { [SysInfo.Native.SysFs]::ReadNumbers([string[]]$files) } else { @($files | ForEach-Object { Read-Number $_ ?? [double]::NaN }) }
        for ($i = 0; $i + 2 -lt $values.Count; $i += 3) {
            if (-not [double]::IsNaN($values[$i])) { $events += $values[$i] }
            if (-not [double]::IsNaN($values[$i + 1])) { $events += $values[$i + 1] }
            if (-not [double]::IsNaN($values[$i + 2])) { $ms += $values[$i + 2] }
        }
        if ($found) {
            $r.Events = $events; $r.ThrottledMs = $ms
            if ($script:Throttle) { $r.EventsNow = $events - $script:Throttle }
            $script:Throttle = $events
        }
    }
    elseif ($IsWindows) {
        $c = Get-WindowsCounters
        if ($c) { $r.PerfLimit = $c.PerfLimit; $r.Performance = $c.Performance }
    }
    [PSCustomObject]$r
}

#endregion

#region Batterie et alimentation

# Linux : /sys/class/power_supply. Batteries du portable (scope ≠ Device), batteries des périphériques, secteur, onduleurs.
function Get-LinuxPowerSupplies {
    $batteries = @(); $devices = @(); $ac = $null; $ups = @()
    foreach ($dir in [System.IO.Directory]::GetDirectories('/sys/class/power_supply')) {
        $name = [System.IO.Path]::GetFileName($dir)
        $type = Read-Text "$dir/type"
        $scope = Read-Text "$dir/scope"
        if ($type -eq 'Mains') { $online = Read-Text "$dir/online"; if ($null -ne $online) { $ac = $ac -or $online -eq '1' }; continue }
        if ($type -notin 'Battery', 'UPS') { continue }
        $num = { param($f) Read-Number "$dir/$f" }
        $status = Read-Text "$dir/status"
        $capacity = & $num 'capacity'
        if ($scope -eq 'Device') {
            $devices += [PSCustomObject]@{ Name = (Read-Text "$dir/model_name") ?? $name; Capacity = $capacity; Level = Read-Text "$dir/capacity_level"; Status = $status }
            continue
        }
        # Énergie en µWh (energy_*) ou charge en µAh (charge_*) × tension.
        $volt = (& $num 'voltage_min_design') ?? (& $num 'voltage_now')
        $toWh = { param($energy, $charge) if ($null -ne $energy) { $energy / 1e6 } elseif ($null -ne $charge -and $volt) { $charge / 1e6 * $volt / 1e6 } else { $null } }
        $now = & $toWh (& $num 'energy_now') (& $num 'charge_now')
        $full = & $toWh (& $num 'energy_full') (& $num 'charge_full')
        $design = & $toWh (& $num 'energy_full_design') (& $num 'charge_full_design')
        $power = & $num 'power_now'
        $watts = if ($null -ne $power) { $power / 1e6 } else { $c = & $num 'current_now'; $v = & $num 'voltage_now'; if ($null -ne $c -and $null -ne $v) { $c / 1e6 * $v / 1e6 } else { $null } }
        $b = [PSCustomObject]@{
            Name = $name; Model = Read-Text "$dir/model_name"; Manufacturer = Read-Text "$dir/manufacturer"; Technology = Read-Text "$dir/technology"
            Status = $status; Percent = $capacity; NowWh = $now; FullWh = $full; DesignWh = $design; Watts = $watts
            Cycles = & $num 'cycle_count'; Health = if ($full -and $design) { [Math]::Round(100 * $full / $design, 1) } else { $null }
            SecondsLeft = if ($status -eq 'Discharging' -and $watts -gt 0.5 -and $now) { 3600 * $now / $watts } elseif ($status -eq 'Charging' -and $watts -gt 0.5 -and $full -and $now) { 3600 * ($full - $now) / $watts } else { $null }
            Ups = $type -eq 'UPS'
        }
        if ($b.Ups) { $ups += $b } else { $batteries += $b }
    }
    [PSCustomObject]@{ Batteries = $batteries; Devices = $devices; OnAc = $ac; Ups = $ups }
}

# Windows : batterie (charge en direct par GetSystemPowerStatus, capacités en cache 60 s).
function Get-WindowsPower {
    $live = if ('SysInfo.Native.PowerStatus' -as [type]) { [SysInfo.Native.PowerStatus]::Read() } else { $null }
    $static = Get-Cached 'battery' 60 {
        $wmi = { param($class) @(Get-CimInstance -Namespace root/wmi -ClassName $class -ErrorAction SilentlyContinue) }
        $design = & $wmi 'BatteryStaticData'; $full = & $wmi 'BatteryFullChargedCapacity'; $cycles = & $wmi 'BatteryCycleCount'; $status = & $wmi 'BatteryStatus'
        $i = 0
        foreach ($b in @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)) {
            $d = if ($design.Count -gt $i) { [double]$design[$i].DesignedCapacity / 1000 } else { $null }
            $f = if ($full.Count -gt $i) { [double]$full[$i].FullChargedCapacity / 1000 } else { $null }
            $s = if ($status.Count -gt $i) { $status[$i] } else { $null }
            $watts = if ($s) { if ($s.DischargeRate -gt 0) { $s.DischargeRate / 1000 } elseif ($s.ChargeRate -gt 0) { $s.ChargeRate / 1000 } else { 0 } } else { $null }
            $isUps = "$($b.Name) $($b.DeviceID)" -match 'UPS|APC|Eaton|CyberPower|Back-UPS|Smart-UPS'
            [PSCustomObject]@{
                Name = $b.Name; Model = $b.Name; Manufacturer = if ($design.Count -gt $i) { $design[$i].ManufactureName } else { $null }
                Technology = @{ 1 = 'Autre'; 2 = 'Inconnue'; 3 = 'Plomb'; 4 = 'NiCd'; 5 = 'NiMH'; 6 = 'Li-ion'; 7 = 'Zinc-air'; 8 = 'Li-polymère' }[[int]$b.Chemistry]
                Status = @{ 1 = 'Discharging'; 2 = 'AC'; 3 = 'Full'; 6 = 'Charging'; 7 = 'Charging'; 8 = 'Charging'; 9 = 'Charging' }[[int]$b.BatteryStatus] ?? 'Unknown'
                Percent = $b.EstimatedChargeRemaining; NowWh = if ($s) { [double]$s.RemainingCapacity / 1000 } else { $null }; FullWh = $f; DesignWh = $d; Watts = $watts
                Cycles = if ($cycles.Count -gt $i) { $cycles[$i].CycleCount } else { $null }; Health = if ($f -and $d) { [Math]::Round(100 * $f / $d, 1) } else { $null }
                SecondsLeft = if ($b.EstimatedRunTime -and $b.EstimatedRunTime -lt 71582788) { 60 * $b.EstimatedRunTime } else { $null }
                Ups = $isUps
            }
            $i++
        }
    }
    $batteries = @($static | Where-Object { -not $_.Ups })
    if ($live -and $live.Percent -and $batteries.Count -eq 1) {
        $batteries[0].Percent = $live.Percent
        if ($live.SecondsLeft) { $batteries[0].SecondsLeft = $live.SecondsLeft }
        $batteries[0].Status = if ($live.Charging) { 'Charging' } elseif ($live.OnAc) { 'Not charging' } else { 'Discharging' }
    }
    [PSCustomObject]@{ Batteries = $batteries; Devices = @(); OnAc = $live.OnAc; Ups = @($static | Where-Object Ups); Saver = $live.BatterySaver }
}

function Get-PowerSupplies { if ($IsWindows) { Get-WindowsPower } else { Get-LinuxPowerSupplies } }

# Onduleurs gérés par NUT (upsc) ou apcupsd (apcaccess), en cache 15 s.
function Get-UpsTools {
    Get-Cached 'ups' 15 {
        foreach ($name in Invoke-Tool upsc @('-l')) {
            $v = @{}
            foreach ($line in Invoke-Tool upsc @($name)) { if ($line -match '^([\w.]+):\s*(.*)$') { $v[$Matches[1]] = $Matches[2] } }
            if (-not $v.Count) { continue }
            $status = "$($v['ups.status'])"
            [PSCustomObject]@{ Name = "$name ($($v['device.mfr']) $($v['device.model']))".Trim(); OnBattery = $status -match '\bOB\b'; Low = $status -match '\bLB\b'; Replace = $status -match '\bRB\b'
                Percent = $v['battery.charge']; SecondsLeft = $v['battery.runtime']; Load = $v['ups.load']; Status = $status; Source = 'NUT (upsc)' }
        }
        $apc = @(Invoke-Tool apcaccess @('status'))
        if ($apc.Count) {
            $v = @{}
            foreach ($line in $apc) { if ($line -match '^(\w+)\s*:\s*(.*)$') { $v[$Matches[1]] = $Matches[2].Trim() } }
            $num = { param($t) if ($t -match '^([\d.]+)') { [double]$Matches[1] } else { $null } }
            [PSCustomObject]@{ Name = "$($v['MODEL'])"; OnBattery = "$($v['STATUS'])" -match 'ONBATT'; Low = "$($v['STATUS'])" -match 'LOWBATT'; Replace = "$($v['STATUS'])" -match 'REPLACEBATT'
                Percent = & $num $v['BCHARGE']; SecondsLeft = if ($null -ne (& $num $v['TIMELEFT'])) { 60 * (& $num $v['TIMELEFT']) } else { $null }; Load = & $num $v['LOADPCT']; Status = $v['STATUS']; Source = 'apcupsd (apcaccess)' }
        }
    }
}

$script:StatusText = @{ Charging = 'En charge'; Discharging = 'Sur batterie'; Full = 'Chargée'; 'Not charging' = 'Branchée, sans charge'; AC = 'Sur secteur'; Unknown = 'Inconnu' }

#endregion

#region Plan d'alimentation

$script:WindowsOverlays = @{ 'ded574b5-45a0-4f42-8737-46345c09c238' = 'Meilleures performances'; '961cc777-2547-4f9d-8174-7d86181b8a7a' = 'Meilleure efficacité énergétique'
    '3af9b8d9-7c97-431d-ad78-34a8bfea439f' = 'Meilleures performances'; '00000000-0000-0000-0000-000000000000' = 'Équilibré' }

# Plans disponibles et plan actif. Windows : powercfg ; Linux : power-profiles-daemon, sinon tuned, sinon profil ACPI.
function Get-PowerPlans {
    Get-Cached 'plans' 30 {
        if ($IsWindows) {
            $plans = foreach ($line in Invoke-Tool powercfg @('/list')) {
                if ($line -match '([0-9a-f]{8}-[0-9a-f-]{27})\s+\((.+?)\)(\s*\*)?') { [PSCustomObject]@{ Id = $Matches[1]; Name = $Matches[2]; Active = [bool]$Matches[3] } }
            }
            $mode = $null
            $overlay = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' -ErrorAction SilentlyContinue).ActiveOverlayAcPowerScheme
            if ($overlay) { $mode = $script:WindowsOverlays["$overlay"] }
            return [PSCustomObject]@{ Tool = 'powercfg'; Plans = @($plans); Active = ($plans | Where-Object Active | Select-Object -First 1).Name; Mode = $mode }
        }
        if (Test-Tool powerprofilesctl) {
            $active = "$(Invoke-Tool powerprofilesctl @('get'))".Trim()
            $names = foreach ($line in Invoke-Tool powerprofilesctl @('list')) { if ($line -match '^\s*\*?\s*([\w-]+):\s*$') { $Matches[1] } }
            return [PSCustomObject]@{ Tool = 'powerprofilesctl'; Plans = @($names | ForEach-Object { [PSCustomObject]@{ Id = $_; Name = $_; Active = $_ -eq $active } }); Active = $active; Mode = $null }
        }
        if (Test-Tool tuned-adm) {
            # tuned : profil actif dans /etc/tuned/active_profile, profils = dossiers (tuned-adm coûte ~150 ms par appel).
            $active = Read-Text /etc/tuned/active_profile
            if (-not $active) { $active = ("$(Invoke-Tool tuned-adm @('active'))" -replace '^.*:\s*', '').Trim() }
            $names = Get-Cached 'tunedProfiles' 600 {
                $dirs = foreach ($root in '/usr/lib/tuned/profiles', '/usr/lib/tuned', '/etc/tuned/profiles', '/etc/tuned') {
                    if ([System.IO.Directory]::Exists($root)) { [System.IO.Directory]::GetDirectories($root) | Where-Object { [System.IO.File]::Exists("$_/tuned.conf") } | ForEach-Object { [System.IO.Path]::GetFileName($_) } }
                }
                @($dirs | Sort-Object -Unique)
            }
            return [PSCustomObject]@{ Tool = 'tuned-adm'; Plans = @($names | ForEach-Object { [PSCustomObject]@{ Id = $_; Name = $_; Active = $_ -eq $active } }); Active = $active; Mode = $null }
        }
        $profile = Read-Text /sys/firmware/acpi/platform_profile
        if ($profile) {
            $choices = (Read-Text /sys/firmware/acpi/platform_profile_choices) -split '\s+'
            return [PSCustomObject]@{ Tool = 'platform_profile'; Plans = @($choices | ForEach-Object { [PSCustomObject]@{ Id = $_; Name = $_; Active = $_ -eq $profile } }); Active = $profile; Mode = $null }
        }
        [PSCustomObject]@{ Tool = $null; Plans = @(); Active = $null; Mode = $null }
    }
}

function Test-PowerSaver([string]$Name) { $Name -match 'power-saver|powersave|économi|economi|saver|battery|efficacité' }

#endregion

#region Veille et réveil

function Get-SleepInfo {
    Get-Cached 'sleep' 300 {
        $r = [ordered]@{ Modes = $null; LastSleep = $null; LastWake = $null; WakeSource = $null; WakeDevices = @(); FastStartup = $null; Hibernate = $null }
        if ($IsLinux) {
            $mem = Read-Text /sys/power/mem_sleep
            $state = Read-Text /sys/power/state
            $modes = @()
            if ($mem -match '\[deep\]') { $modes += 'veille S3 (deep)' } elseif ($mem -match '\[s2idle\]') { $modes += 'veille moderne (s2idle)' }
            if ($state -match '\bdisk\b') { $modes += 'hibernation' }
            $r.Modes = $modes -join ', '
            $r.Hibernate = $state -match '\bdisk\b'
            foreach ($line in Invoke-Tool journalctl @('-k', '-b', '0', '-o', 'short-iso', '--no-pager', '-q', '-g', 'PM: suspend (entry|exit)')) {
                if ($line -match '^(\S+)\s.*PM: suspend (entry|exit)') {
                    $t = [datetime]::Parse($Matches[1], [cultureinfo]::InvariantCulture)
                    if ($Matches[2] -eq 'entry') { $r.LastSleep = $t } else { $r.LastWake = $t }
                }
            }
            $irq = Read-Text /sys/power/pm_wakeup_irq
            if ($irq) { $r.WakeSource = "IRQ $irq" }
            $armed = foreach ($line in [System.IO.File]::ReadAllLines('/proc/acpi/wakeup') | Select-Object -Skip 1) {
                $f = $line -split '\s+'
                if ($f.Count -ge 4 -and $f[2] -eq '*enabled') { [PSCustomObject]@{ Name = $f[0]; Node = $f[3] } }
            }
            $r.WakeDevices = @($armed | Sort-Object Node -Unique)
        }
        elseif ($IsWindows) {
            $a = @(Invoke-Tool powercfg @('/a'))
            $available = @(); foreach ($line in $a) { if ($line -match '^\s*$') { break }; if ($line -match '^\s+(\S.*)$') { $available += $Matches[1].Trim() } }
            $r.Modes = $available -join ', '
            $r.Hibernate = ($a -join ' ') -match 'Hibernat|Mise en veille prolongée' -and $available -match 'Hibernat|prolongée'
            $power = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction SilentlyContinue
            if ($null -ne $power.HiberbootEnabled) { $r.FastStartup = $power.HiberbootEnabled -eq 1 }
            $sleep = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 42 } -MaxEvents 1 -ErrorAction SilentlyContinue
            if ($sleep) { $r.LastSleep = $sleep.TimeCreated }
            $wake = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Power-Troubleshooter'; Id = 1 } -MaxEvents 1 -ErrorAction SilentlyContinue
            if ($wake) {
                $r.LastWake = $wake.TimeCreated
                if ($wake.Message -match '(Source de sortie de veille|Wake Source)\s*:\s*(.+)') { $r.WakeSource = $Matches[2].Trim() }
            }
            $r.WakeDevices = @(Invoke-Tool powercfg @('/devicequery', 'wake_armed') | Where-Object { $_ -and $_ -notmatch '^(NONE|AUCUN)' } | ForEach-Object { [PSCustomObject]@{ Name = $_.Trim(); Node = '' } })
        }
        [PSCustomObject]$r
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

    $all = Invoke-Block 'Capteurs' { Get-AllSensors }
    $sensors = @($all.Sensors)
    $temps = @($sensors | Where-Object Type -eq 'temp')

    # Températures en direct : processeur et carte graphique (graphique), puis une jauge par sonde.
    $cpu = $temps | Where-Object { $_.Kind -eq 'cpu' -and $_.Label -match '^(Package|Tctl|Tdie|CPU Package|Core \(Tctl/Tdie\))' } | Select-Object -First 1
    if (-not $cpu) { $cpu = $temps | Where-Object Kind -eq 'cpu' | Sort-Object Value -Descending | Select-Object -First 1 }
    $gpu = $temps | Where-Object Kind -eq 'gpu' | Sort-Object Value -Descending | Select-Object -First 1
    if ($cpu -or $gpu) {
        $main = $cpu ?? $gpu
        $th = Get-Thresholds $main
        $metric = [ordered]@{ Title = 'Températures'; Type = 'Metric'; Icon = 'temperature'; Unit = '°C'; Label = $(if ($cpu) { 'Processeur' } else { 'Carte graphique' }); Value = $main.Value; Warning = $th[0]; Critical = $th[1]
            Detail = '{0}{1}' -f $main.Device, $(if ($cpu -and $gpu) { " · $($gpu.Device)" } else { '' }) }
        if ($cpu -and $gpu) { $metric.Secondary = [PSCustomObject]@{ Label = 'Carte graphique'; Value = $gpu.Value } }
        $sections.Add([PSCustomObject]$metric)
    }

    if ($temps.Count) {
        # Cœurs d'un même processeur regroupés en une ligne (le plus chaud) ; détail complet dans sensors_get_sensors.
        $rows = [System.Collections.Generic.List[object]]::new()
        foreach ($group in $temps | Group-Object Device) {
            $cores = @($group.Group | Where-Object { $_.Kind -eq 'cpu' -and $_.Label -match '^Core \d+$' })
            foreach ($s in $group.Group | Where-Object { $_ -notin $cores }) { $rows.Add([PSCustomObject]@{ S = $s; Label = $s.Label; Text = $null }) }
            if ($cores.Count) {
                $hot = $cores | Sort-Object Value -Descending | Select-Object -First 1
                $min = ($cores | Measure-Object Value -Minimum).Minimum
                $rows.Add([PSCustomObject]@{ S = $hot; Label = "Cœurs ($($cores.Count))"; Text = ('{0} à {1}' -f (Format-Unit $min '°C' '0'), (Format-Unit $hot.Value '°C' '0')) })
            }
        }
        $items = foreach ($row in $rows) {
            $s = $row.S; $th = Get-Thresholds $s
            [PSCustomObject]@{ Label = '{0} · {1}' -f $s.Device, $row.Label; Detail = $s.Source; Value = $s.Value; Max = [Math]::Max($th[1] + 10, 100); Unit = '°C'
                Warning = $th[0]; Critical = $th[1]; Text = $row.Text ?? ('Attention à {0}, critique à {1}' -f (Format-Unit $th[0] '°C' '0'), (Format-Unit $th[1] '°C' '0')) }
            if ($s.Value -ge $th[1]) {
                $findings.Add((New-Finding 'critical' 'SNS-TEMP-CRITICAL' ('{0} · {1} à {2} (critique à {3})' -f $s.Device, $row.Label, (Format-Unit $s.Value '°C' '0'), (Format-Unit $th[1] '°C' '0')) 'Vérifier la ventilation : poussière, ventilateur arrêté, pâte thermique, pièce trop chaude ; réduire la charge.'))
            }
            elseif ($s.Value -ge $th[0]) {
                $findings.Add((New-Finding 'warning' 'SNS-TEMP-HIGH' ('{0} · {1} à {2} (attention à {3})' -f $s.Device, $row.Label, (Format-Unit $s.Value '°C' '0'), (Format-Unit $th[0] '°C' '0')) 'Normal sous forte charge ; en continu, nettoyer les entrées d''air et vérifier les ventilateurs.'))
            }
        }
        $sections.Add([PSCustomObject]@{ Title = 'Sondes de température'; Type = 'Usage'; Icon = 'temperature'; Items = @($items) })
    }

    $fans = @($sensors | Where-Object { $_.Type -in 'fan', 'fanpct' })
    if ($fans.Count) {
        $sections.Add([PSCustomObject]@{ Title = 'Ventilateurs'; Type = 'Table'; Icon = 'arrow_clockwise'; Columns = @('Composant', 'Ventilateur', 'Vitesse', 'Unité', 'Minimum')
                Rows = @($fans | ForEach-Object { , @($_.Device, $_.Label, $_.Value, $(if ($_.Type -eq 'fan') { 'tr/min' } else { '%' }), $_.Min) }) })
        foreach ($f in $fans | Where-Object { $_.Type -eq 'fan' -and $_.Value -eq 0 -and $_.Min -gt 0 }) {
            $findings.Add((New-Finding 'warning' 'SNS-FAN-STOPPED' ('{0} · {1} arrêté (minimum {2} tr/min)' -f $f.Device, $f.Label, $f.Min) 'Vérifier que le ventilateur tourne et n''est pas bloqué ou débranché.'))
        }
    }
    $electric = @($sensors | Where-Object { $_.Type -in 'in', 'curr', 'power' })
    if ($electric.Count) {
        $units = @{ in = 'V'; curr = 'A'; power = 'W' }
        $sections.Add([PSCustomObject]@{ Title = 'Tensions et consommation'; Type = 'Table'; Icon = 'plug_connected'; Columns = @('Composant', 'Sonde', 'Valeur', 'Unité', 'Limite')
                Rows = @($electric | ForEach-Object { , @($_.Device, $_.Label, $_.Value, $units[$_.Type], $_.Max) }) })
    }

    # Processeur : fréquence et bridage
    $th = Invoke-Block 'Bridage' { Get-CpuThrottling }
    if ($th) {
        $items = [ordered]@{}
        if ($th.Current) { $items['Fréquence actuelle'] = Format-Unit $th.Current 'GHz' '0.00' }
        if ($th.Max) { $items['Fréquence maximale'] = Format-Unit $th.Max 'GHz' '0.00' }
        $capped = $th.Max -and $th.Limit -and $th.Limit -lt 0.95 * $th.Max
        if ($th.Limit) { $items['Limite actuelle'] = '{0}{1}' -f (Format-Unit $th.Limit 'GHz' '0.00'), $(if ($capped) { ' (bridée)' } else { '' }) }
        if ($null -ne $th.PerfLimit) { $items['Limite de performance'] = Format-Unit $th.PerfLimit '%' '0' }
        if ($null -ne $th.Performance) { $items['Performance (par rapport au nominal)'] = Format-Unit $th.Performance '%' '0' }
        if ($th.Governor) { $items['Gouverneur'] = $th.Governor }
        if ($th.Epp) { $items['Préférence énergie / performance'] = $th.Epp }
        if ($null -ne $th.Turbo) { $items['Turbo'] = if ($th.Turbo) { 'activé' } else { 'désactivé' } }
        if ($null -ne $th.Events) {
            $items['Bridage thermique depuis le démarrage'] = '{0} épisode(s), {1}' -f $th.Events, (Format-Duration ($th.ThrottledMs / 1000))
            $items['Bridage en ce moment'] = if ($th.EventsNow -gt 0) { "oui ($($th.EventsNow) nouvel(s) épisode(s))" } else { 'non' }
        }
        $sections.Add([PSCustomObject]@{ Title = 'Processeur : fréquence et bridage'; Type = 'KeyValue'; Icon = 'top_speed'; Items = $items })
        if ($th.EventsNow -gt 0 -or ($null -ne $th.PerfLimit -and $th.PerfLimit -lt 90)) {
            $findings.Add((New-Finding 'warning' 'SNS-CPU-THROTTLING' $(if ($th.EventsNow -gt 0) { "Le processeur vient d'être bridé pour cause de température ($($th.EventsNow) épisode(s) depuis le dernier relevé)." } else { 'Le processeur est limité à {0} de ses performances (température, alimentation ou plan d''alimentation).' -f (Format-Unit $th.PerfLimit '%' '0') }) 'Vérifier les températures et la ventilation ; sur portable, brancher le secteur et choisir un plan plus performant.'))
        }
        if ($capped) {
            $findings.Add((New-Finding 'info' 'SNS-CPU-CAPPED' ('Fréquence maximale limitée à {0} sur {1}.' -f (Format-Unit $th.Limit 'GHz' '0.0'), (Format-Unit $th.Max 'GHz' '0.0')) 'Limite posée par le plan d''alimentation ou un réglage d''économie : la lever si la machine doit être plus rapide.'))
        }
        if ($th.Turbo -eq $false) { $findings.Add((New-Finding 'info' 'SNS-TURBO-OFF' 'Le turbo du processeur est désactivé : fréquence plafonnée à la valeur de base.' 'Réactiver le turbo (plan d''alimentation ou /sys/devices/system/cpu/intel_pstate/no_turbo).')) }
    }

    # Carte graphique NVIDIA : bridage
    foreach ($g in @($all.Nvidia)) {
        if ($g.Asleep) { continue }
        $reasons = @(Get-NvidiaReasons $g.Reasons)
        $items = [ordered]@{ 'Carte' = $g.Name }
        if ($null -ne $g.Clock) { $items['Fréquence'] = '{0} sur {1}' -f (Format-Unit $g.Clock 'MHz' '0'), (Format-Unit $g.MaxClock 'MHz' '0') }
        if ($null -ne $g.Power) { $items['Consommation'] = '{0}{1}' -f (Format-Unit $g.Power 'W' '0'), $(if ($g.PowerLimit) { ' sur ' + (Format-Unit $g.PowerLimit 'W' '0') } else { '' }) }
        $items['Bridage'] = if ($reasons) { $reasons -join ', ' } else { 'aucun' }
        $sections.Add([PSCustomObject]@{ Title = 'Carte graphique : bridage'; Type = 'KeyValue'; Icon = 'developer_board'; Items = $items })
        if ($g.Reasons -band 0x48) { $findings.Add((New-Finding 'warning' 'SNS-GPU-THROTTLING' "$($g.Name) est bridée pour cause de température." 'Vérifier la ventilation du boîtier et de la carte graphique.')) }
    }
    if (@($all.Nvidia | Where-Object Asleep).Count) { $sections.Add([PSCustomObject]@{ Title = 'Carte graphique : bridage'; Type = 'KeyValue'; Icon = 'developer_board'; Items = [ordered]@{ 'État' = 'en veille (non interrogée, pour ne pas la réveiller)' } }) }

    # Batterie et alimentation
    $power = Invoke-Block 'Alimentation' { Get-PowerSupplies }
    foreach ($b in @($power.Batteries)) {
        $label = (@($b.Manufacturer, $b.Model) | Where-Object { $_ }) -join ' '
        $state = $script:StatusText["$($b.Status)"] ?? "$($b.Status)"
        $text = $state
        if ($b.SecondsLeft) { $text += ' · ' + (Format-Duration $b.SecondsLeft) + $(if ($b.Status -eq 'Charging') { ' avant la charge complète' } else { ' restantes' }) }
        $sections.Add([PSCustomObject]@{ Title = 'Batterie'; Type = 'Usage'; Icon = 'plug_connected'; Items = @([PSCustomObject]@{
                        Label = $(if ($label) { $label } else { $b.Name }); Detail = $b.Technology; Value = $b.Percent; Max = 100; Unit = '%'; Text = $text }) })
        $items = [ordered]@{ 'État' = $state }
        if ($null -ne $b.Watts) { $items['Puissance'] = Format-Unit $b.Watts 'W' '0.0' }
        if ($b.FullWh) { $items['Capacité actuelle'] = Format-Unit $b.FullWh 'Wh' '0.0' }
        if ($b.DesignWh) { $items["Capacité d'origine"] = Format-Unit $b.DesignWh 'Wh' '0.0' }
        if ($null -ne $b.Health) { $items['Santé (capacité restante)'] = Format-Unit $b.Health '%' '0' }
        if ($b.Cycles) { $items['Cycles de charge'] = $b.Cycles }
        $sections.Add([PSCustomObject]@{ Title = 'Batterie : santé'; Type = 'KeyValue'; Icon = 'info'; Items = $items })
        if ($null -ne $b.Health -and $b.Health -lt 80) {
            $findings.Add((New-Finding $(if ($b.Health -lt 60) { 'warning' } else { 'info' }) 'SNS-BATTERY-WORN' ('Batterie usée : {0} de sa capacité d''origine ({1} cycles).' -f (Format-Unit $b.Health '%' '0'), ($b.Cycles ?? '?')) 'Prévoir son remplacement si l''autonomie ne suffit plus.'))
        }
        if ($b.Status -eq 'Discharging' -and $null -ne $b.Percent -and $b.Percent -le 15) {
            $findings.Add((New-Finding $(if ($b.Percent -le 5) { 'critical' } else { 'warning' }) 'SNS-BATTERY-LOW' ('Batterie faible : {0}.' -f (Format-Unit $b.Percent '%' '0')) 'Brancher le chargeur et enregistrer le travail en cours.'))
        }
    }
    if (@($power.Devices).Count) {
        $sections.Add([PSCustomObject]@{ Title = 'Périphériques sans fil'; Type = 'Table'; Icon = 'plug_disconnected'; Columns = @('Appareil', 'Charge %', 'Niveau', 'État')
                Rows = @($power.Devices | ForEach-Object { , @($_.Name, $_.Capacity, $_.Level, ($script:StatusText["$($_.Status)"] ?? $_.Status)) }) })
    }

    # Onduleur
    $ups = @(@($power.Ups | ForEach-Object { [PSCustomObject]@{ Name = $_.Model ?? $_.Name; OnBattery = $_.Status -eq 'Discharging'; Low = $false; Replace = $false; Percent = $_.Percent; SecondsLeft = $_.SecondsLeft; Load = $null; Status = $script:StatusText["$($_.Status)"]; Source = 'système' } }) + @(Invoke-Block 'Onduleur' { Get-UpsTools }) | Where-Object { $_ })
    if ($ups.Count) {
        $sections.Add([PSCustomObject]@{ Title = 'Onduleur'; Type = 'Table'; Icon = 'plug_connected'; Columns = @('Onduleur', 'Alimentation', 'Charge %', 'Autonomie', 'Charge de sortie %', 'Source')
                Rows = @($ups | ForEach-Object { , @($_.Name, $(if ($_.OnBattery) { 'sur batterie' } else { 'secteur' }), $_.Percent, $(if ($_.SecondsLeft) { Format-Duration ([double]$_.SecondsLeft) } else { $null }), $_.Load, $_.Source) }) })
        foreach ($u in $ups) {
            if ($u.OnBattery) {
                $findings.Add((New-Finding $(if ($u.Low -or ($null -ne $u.Percent -and [double]$u.Percent -lt 30)) { 'critical' } else { 'warning' }) 'SNS-UPS-ON-BATTERY' ('{0} fonctionne sur batterie (coupure secteur) : {1}{2}.' -f $u.Name, $(if ($null -ne $u.Percent) { Format-Unit ([double]$u.Percent) '%' '0' } else { 'charge inconnue' }), $(if ($u.SecondsLeft) { ', ' + (Format-Duration ([double]$u.SecondsLeft)) + ' d''autonomie' } else { '' })) 'Enregistrer le travail et préparer l''arrêt si le courant ne revient pas.'))
            }
            if ($u.Replace) { $findings.Add((New-Finding 'warning' 'SNS-UPS-REPLACE-BATTERY' "$($u.Name) demande le remplacement de sa batterie." 'Remplacer la batterie de l''onduleur : il ne protégerait plus d''une coupure.')) }
        }
    }

    # Plan d'alimentation
    $plans = Invoke-Block "Plan d'alimentation" { Get-PowerPlans }
    $items = [ordered]@{}
    if ($null -ne $power.OnAc) { $items['Alimentation'] = if ($power.OnAc) { 'secteur' } else { 'batterie' } }
    if ($plans.Tool) {
        $items['Plan actif'] = $plans.Active ?? '—'
        if ($plans.Mode) { $items['Mode d''alimentation'] = $plans.Mode }
        $items['Plans disponibles'] = ($plans.Plans | ForEach-Object Name) -join ', '
        $items['Outil'] = $plans.Tool
    }
    else { $items["Plan d'alimentation"] = 'aucun outil (power-profiles-daemon, tuned, profil ACPI)' }
    if ($power.Saver) { $items["Économiseur de batterie"] = 'activé' }
    $sections.Add([PSCustomObject]@{ Title = "Plan d'alimentation"; Type = 'KeyValue'; Icon = 'settings'; Items = $items })
    if ($power.OnAc -and (Test-PowerSaver "$($plans.Active) $($plans.Mode)")) {
        $findings.Add((New-Finding 'info' 'SNS-POWER-SAVER' "Plan d'économie d'énergie actif alors que la machine est sur secteur ($($plans.Active)) : performances réduites." 'Passer en plan équilibré ou performances (sensors_set_power_plan).'))
    }

    # Veille et réveil
    $sleep = Invoke-Block 'Veille' { Get-SleepInfo }
    if ($sleep) {
        $items = [ordered]@{ 'Modes disponibles' = $sleep.Modes ?? '—'; 'Dernière mise en veille' = Format-Date $sleep.LastSleep; 'Dernier réveil' = Format-Date $sleep.LastWake }
        if ($sleep.WakeSource) { $items['Source du dernier réveil'] = $sleep.WakeSource }
        if ($null -ne $sleep.FastStartup) { $items['Démarrage rapide'] = if ($sleep.FastStartup) { 'activé' } else { 'désactivé' } }
        $items['Périphériques qui peuvent réveiller'] = if ($sleep.WakeDevices.Count) { (($sleep.WakeDevices | Select-Object -First 8 | ForEach-Object { if ($_.Node) { "$($_.Name) ($($_.Node))" } else { $_.Name } }) -join ', ') + $(if ($sleep.WakeDevices.Count -gt 8) { " … ($($sleep.WakeDevices.Count))" } else { '' }) } else { 'aucun' }
        $sections.Add([PSCustomObject]@{ Title = 'Veille et réveil'; Type = 'KeyValue'; Icon = 'timer'; Items = $items })
        if ($sleep.FastStartup) {
            $findings.Add((New-Finding 'info' 'SNS-FASTSTARTUP-ON' "Le démarrage rapide est activé : « Arrêter » met Windows en veille prolongée, ce n'est pas un vrai redémarrage." 'Utiliser « Redémarrer » après une mise à jour de pilote ; le désactiver en cas de double démarrage ou de périphérique non reconnu au démarrage.'))
        }
    }

    foreach ($note in @($all.Notes)) { $errors['Remarque'] = $note }
    if ($errors.Count) { $sections.Add([PSCustomObject]@{ Title = 'Remarques et erreurs de collecte'; Type = 'KeyValue'; Icon = 'info'; Items = $errors }) }
    if ($IsWindows -and @($all.Notes).Count) {
        $findings.Add((New-Finding 'info' 'SNS-LHM-MISSING' 'Températures limitées aux zones ACPI : processeur, carte graphique, disques et ventilateurs ne sont pas lisibles sans LibreHardwareMonitor.' 'Installer et lancer LibreHardwareMonitor (libre, MPL-2.0) : SysInfo lit alors toutes ses sondes.'))
    }

    $parts = @()
    if ($cpu) { $parts += 'processeur {0}' -f (Format-Unit $cpu.Value '°C' '0') }
    if ($gpu) { $parts += 'carte graphique {0}' -f (Format-Unit $gpu.Value '°C' '0') }
    $battery = @($power.Batteries) | Select-Object -First 1
    if ($battery) { $parts += 'batterie {0}' -f (Format-Unit $battery.Percent '%' '0') } elseif ($null -ne $power.OnAc) { $parts += if ($power.OnAc) { 'secteur' } else { 'sur batterie' } }
    if ($plans.Active) { $parts += "plan $($plans.Active)" }
    [PSCustomObject]@{ Subtitle = $parts -join ' · '; Sections = $sections.ToArray(); Findings = $findings.ToArray() }
}

#endregion

#region Fonctions ciblées

# sensors_get_sensors : toutes les sondes, avec leurs limites.
function Get-SISensors {
    param([ValidateSet('all', 'temperature', 'fan', 'voltage', 'power')][string]$Type = 'all')
    $all = Get-AllSensors
    $types = @{ all = @('temp', 'fan', 'fanpct', 'in', 'curr', 'power'); temperature = @('temp'); fan = @('fan', 'fanpct'); voltage = @('in', 'curr'); power = @('power') }[$Type]
    $units = @{ temp = '°C'; fan = 'tr/min'; fanpct = '%'; in = 'V'; curr = 'A'; power = 'W' }
    $names = @{ temp = 'Température'; fan = 'Ventilateur'; fanpct = 'Ventilateur'; in = 'Tension'; curr = 'Courant'; power = 'Puissance' }
    $rows = foreach ($s in $all.Sensors | Where-Object { $_.Type -in $types }) {
        $th = if ($s.Type -eq 'temp') { Get-Thresholds $s } else { @($s.Max, $s.Crit) }
        , @($s.Device, $s.Label, $names[$s.Type], $s.Value, $units[$s.Type], $s.Min, $th[0], $th[1], $s.Source)
    }
    $findings = @(foreach ($n in $all.Notes) { New-Finding 'info' 'SNS-SENSORS-LIMITED' $n $null })
    [PSCustomObject]@{
        Subtitle = '{0} sonde(s)' -f @($rows).Count
        Sections = @([PSCustomObject]@{ Title = 'Sondes'; Type = 'Table'; Icon = 'temperature'; Columns = @('Composant', 'Sonde', 'Type', 'Valeur', 'Unité', 'Minimum', 'Attention', 'Critique', 'Source'); Rows = @($rows) })
        Findings = $findings
    }
}

# sensors_get_battery : détail des batteries, historique de charge (Linux : upower) ou rapport de batterie (Windows).
function Get-SIBattery {
    param([ValidateRange(1, 30)][int]$Days = 2)
    $power = Get-PowerSupplies
    $sections = [System.Collections.Generic.List[object]]::new()
    $findings = @()
    foreach ($b in @($power.Batteries) + @($power.Ups)) {
        $items = [ordered]@{ 'Nom' = $b.Name; 'Fabricant' = $b.Manufacturer ?? '—'; 'Modèle' = $b.Model ?? '—'; 'Technologie' = $b.Technology ?? '—'
            'État' = $script:StatusText["$($b.Status)"] ?? "$($b.Status)"; 'Charge' = if ($null -ne $b.Percent) { Format-Unit $b.Percent '%' '0' } else { '—' } }
        if ($b.NowWh) { $items['Énergie restante'] = Format-Unit $b.NowWh 'Wh' '0.0' }
        if ($b.FullWh) { $items['Capacité actuelle'] = Format-Unit $b.FullWh 'Wh' '0.0' }
        if ($b.DesignWh) { $items["Capacité d'origine"] = Format-Unit $b.DesignWh 'Wh' '0.0' }
        if ($null -ne $b.Health) { $items['Santé'] = Format-Unit $b.Health '%' '0' }
        if ($b.Cycles) { $items['Cycles'] = $b.Cycles }
        if ($null -ne $b.Watts) { $items['Puissance'] = Format-Unit $b.Watts 'W' '0.0' }
        if ($b.SecondsLeft) { $items['Temps estimé'] = Format-Duration $b.SecondsLeft }
        $sections.Add([PSCustomObject]@{ Title = $(if ($b.Ups) { "Onduleur $($b.Name)" } else { "Batterie $($b.Name)" }); Type = 'KeyValue'; Icon = 'plug_connected'; Items = $items })
    }

    if ($IsLinux) {
        # upower garde l'historique de charge : /var/lib/upower/history-charge-<modèle>-<capacité>-<série>.dat (horodatage, %, état).
        $since = [DateTimeOffset]::new((Get-Date).AddDays(-$Days)).ToUnixTimeSeconds()
        foreach ($file in Get-ChildItem /var/lib/upower -Filter 'history-charge-*.dat' -ErrorAction SilentlyContinue) {
            $points = foreach ($line in [System.IO.File]::ReadAllLines($file.FullName)) {
                $f = $line -split '\t'
                if ($f.Count -ge 2 -and [double]$f[0] -ge $since) { , @([double]$f[0], [double]$f[1]) }
            }
            if (@($points).Count -lt 2) { continue }
            $name = $file.BaseName -replace '^history-charge-', ''
            $sections.Add([PSCustomObject]@{ Title = "Charge · $Days jours"; Type = 'Metric'; Icon = 'timer'; Unit = '%'; Max = 100; Label = 'Charge'; Value = @($points)[-1][1]; Detail = "upower · $name"
                    History = [PSCustomObject]@{ Window = $Days * 86400; Points = @($points) } })
        }
    }
    elseif ($IsWindows -and @($power.Batteries).Count) {
        $xml = Join-Path ([System.IO.Path]::GetTempPath()) ('sysinfo-battery-{0}.xml' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
        try {
            [void](Invoke-Tool powercfg @('/batteryreport', '/xml', '/output', $xml))
            if (Test-Path -LiteralPath $xml) {
                [xml]$report = Get-Content -LiteralPath $xml -Raw
                $history = @($report.BatteryReport.History.HistoryEntry)
                if ($history.Count) {
                    $sections.Add([PSCustomObject]@{ Title = 'Évolution de la capacité'; Type = 'Table'; Icon = 'timer'; Columns = @('Début', 'Capacité (Wh)', "Capacité d'origine (Wh)", 'Santé %', 'Cycles')
                            Rows = @($history | Select-Object -Last 30 | ForEach-Object {
                                    $full = [double]$_.FullChargeCapacity / 1000; $design = [double]$_.DesignCapacity / 1000
                                    , @(([datetime]$_.StartDate).ToString('d MMM yyyy', $script:Fr), [Math]::Round($full, 1), [Math]::Round($design, 1), $(if ($design) { [Math]::Round(100 * $full / $design, 1) } else { $null }), $_.CycleCount) }) })
                }
                $usage = @($report.BatteryReport.RecentUsage.UsageEntry | Where-Object { [datetime]$_.Timestamp -ge (Get-Date).AddDays(-$Days) })
                if ($usage.Count -ge 2) {
                    $sections.Add([PSCustomObject]@{ Title = "Charge · $Days jours"; Type = 'Metric'; Icon = 'timer'; Unit = '%'; Max = 100; Label = 'Charge'; Detail = 'powercfg /batteryreport'
                            Value = [Math]::Round(100 * [double]$usage[-1].ChargeCapacity / [double]$usage[-1].FullChargeCapacity)
                            History = [PSCustomObject]@{ Window = $Days * 86400; Points = @($usage | ForEach-Object { if ([double]$_.FullChargeCapacity -gt 0) { , @(([datetime]$_.Timestamp).ToString('o'), [Math]::Round(100 * [double]$_.ChargeCapacity / [double]$_.FullChargeCapacity, 1)) } }) } })
                }
            }
        }
        catch { $findings += New-Finding 'info' 'SNS-BATTERY-REPORT' "Rapport de batterie illisible : $($_.Exception.Message)" $null }
        finally { Remove-Item -LiteralPath $xml -ErrorAction SilentlyContinue }
    }
    if (-not @($power.Batteries).Count -and -not @($power.Ups).Count) { $findings += New-Finding 'info' 'SNS-NO-BATTERY' 'Aucune batterie : ordinateur de bureau, ou batterie non détectée.' $null }
    foreach ($b in @($power.Batteries) | Where-Object { $null -ne $_.Health -and $_.Health -lt 80 }) {
        $findings += New-Finding $(if ($b.Health -lt 60) { 'warning' } else { 'info' }) 'SNS-BATTERY-WORN' ('Batterie usée : {0} de sa capacité d''origine.' -f (Format-Unit $b.Health '%' '0')) 'Prévoir son remplacement si l''autonomie ne suffit plus.'
    }
    [PSCustomObject]@{ Subtitle = '{0} batterie(s)' -f (@($power.Batteries).Count + @($power.Ups).Count); Sections = $sections.ToArray(); Findings = $findings }
}

# sensors_get_wake_history : mises en veille et réveils, sources de réveil, périphériques et minuteries qui réveillent.
function Get-SIWakeHistory {
    param([ValidateRange(1, 60)][int]$Days = 7)
    $sections = [System.Collections.Generic.List[object]]::new()
    $events = [System.Collections.Generic.List[object]]::new()
    if ($IsLinux) {
        $sleepAt = $null
        foreach ($line in Invoke-Tool journalctl @('-k', "--since=-$($Days)d", '-o', 'short-iso', '--no-pager', '-q', '-g', 'PM: suspend (entry|exit)|PM: hibernation (entry|exit)|ACPI: PM: Waking up|PM: Triggering wakeup from IRQ|Wakeup pending|PM: wakeup')) {
            if ($line -notmatch '^(\S+)\s+\S+\s+kernel:\s*(.*)$') { continue }
            $t = [datetime]::Parse($Matches[1], [cultureinfo]::InvariantCulture); $msg = $Matches[2]
            if ($msg -match 'PM: (suspend|hibernation) entry') { $sleepAt = $t; $kind = $Matches[1] }
            elseif ($msg -match 'PM: (suspend|hibernation) exit') {
                $events.Add([PSCustomObject]@{ Sleep = $sleepAt; Wake = $t; Kind = $(if ($Matches[1] -eq 'hibernation') { 'hibernation' } else { 'veille' }); Source = $script:LastIrq }); $sleepAt = $null; $script:LastIrq = $null
            }
            elseif ($msg -match 'wakeup from IRQ (\d+)|Triggering wakeup from IRQ (\d+)') { $script:LastIrq = "IRQ $($Matches[1] ?? $Matches[2])" }
        }
        $timers = @(foreach ($line in Invoke-Tool systemctl @('list-units', '--type=timer', '--all', '--no-legend', '--plain')) {
                $unit = ($line -split '\s+')[0]
                if ($unit -and (Invoke-Tool systemctl @('show', '-P', 'WakeSystem', $unit)) -eq 'yes') { [PSCustomObject]@{ Name = $unit; Next = "$(Invoke-Tool systemctl @('show', '-P', 'NextElapseUSecRealtime', $unit))" } }
            })
        $sections.Add([PSCustomObject]@{ Title = 'Minuteries qui réveillent la machine'; Type = 'Table'; Icon = 'timer'; Columns = @('Minuterie', 'Prochain déclenchement'); Rows = @($timers | ForEach-Object { , @($_.Name, $_.Next) }) })
    }
    elseif ($IsWindows) {
        $since = (Get-Date).AddDays(-$Days)
        $sleepAt = $null
        $raw = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power', 'Microsoft-Windows-Power-Troubleshooter'; Id = 42, 1; StartTime = $since } -ErrorAction SilentlyContinue | Sort-Object TimeCreated)
        foreach ($e in $raw) {
            if ($e.Id -eq 42) { $sleepAt = $e.TimeCreated; continue }
            $source = if ($e.Message -match '(Source de sortie de veille|Wake Source)\s*:\s*(.+)') { $Matches[2].Trim() } else { $null }
            $events.Add([PSCustomObject]@{ Sleep = $sleepAt; Wake = $e.TimeCreated; Kind = 'veille'; Source = $source }); $sleepAt = $null
        }
        $timers = @(Invoke-Tool powercfg @('/waketimers') | Where-Object { $_ -match '\S' })
        $sections.Add([PSCustomObject]@{ Title = 'Minuteries qui réveillent la machine'; Type = 'KeyValue'; Icon = 'timer'; Items = [ordered]@{ 'powercfg /waketimers' = $(if ($timers) { $timers -join ' ' } else { 'aucune (ou droits administrateur requis)' }) } })
        $last = @(Invoke-Tool powercfg @('/lastwake') | Where-Object { $_ -match '\S' })
        if ($last) { $sections.Add([PSCustomObject]@{ Title = 'Dernier réveil (powercfg)'; Type = 'KeyValue'; Icon = 'info'; Items = [ordered]@{ 'Détail' = $last -join ' ' } }) }
    }
    $rows = foreach ($e in $events | Sort-Object Wake -Descending) {
        , @((Format-Date $e.Sleep), (Format-Date $e.Wake), $(if ($e.Sleep) { Format-Duration ($e.Wake - $e.Sleep).TotalSeconds } else { $null }), $e.Kind, $e.Source)
    }
    $sections.Insert(0, [PSCustomObject]@{ Title = "Veilles des $Days derniers jours"; Type = 'Table'; Icon = 'timer'; Columns = @('Mise en veille', 'Réveil', 'Durée', 'Type', 'Source du réveil'); Rows = @($rows) })
    $sleep = Get-SleepInfo
    $sections.Add([PSCustomObject]@{ Title = 'Périphériques qui peuvent réveiller'; Type = 'Table'; Icon = 'plug_connected'; Columns = @('Périphérique', 'Emplacement'); Rows = @($sleep.WakeDevices | ForEach-Object { , @($_.Name, $_.Node) }) })
    $findings = @()
    $night = @($events | Where-Object { $_.Wake.Hour -ge 1 -and $_.Wake.Hour -lt 6 })
    if ($night.Count) { $findings += New-Finding 'info' 'SNS-WAKE-NIGHT' ('{0} réveil(s) entre 1 h et 6 h sur {1} jours : une minuterie ou un périphérique réveille la machine.' -f $night.Count, $Days) 'Voir la source du réveil ; désactiver le réveil par minuterie ou par la souris / le réseau si ce n''est pas voulu.' }
    [PSCustomObject]@{ Subtitle = '{0} veille(s) sur {1} jours' -f $events.Count, $Days; Sections = $sections.ToArray(); Findings = $findings }
}

# sensors_get_energy_report : rapport d'efficacité énergétique de Windows (powercfg /energy, 60 s d'observation, admin).
function Get-SIEnergyReport {
    param([ValidateRange(10, 300)][int]$Duration = 60)
    if (-not $IsWindows) { throw 'Rapport énergétique : Windows uniquement.' }
    $xml = Join-Path ([System.IO.Path]::GetTempPath()) ('sysinfo-energy-{0}.xml' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        Write-Information "powercfg /energy pendant $Duration s"
        $out = & powercfg /energy /xml /output $xml /duration $Duration 2>&1
        if (-not (Test-Path -LiteralPath $xml)) { throw "powercfg /energy a échoué : $($out -join ' ')" }
        [xml]$report = Get-Content -LiteralPath $xml -Raw
        $entries = @($report.SelectNodes("//*[local-name()='LogEntry']"))
        $severities = @{ 'Error' = 'Erreur'; 'Warning' = 'Avertissement'; 'Informational' = 'Information' }
        $rows = foreach ($e in $entries) {
            $sev = "$($e.Severity)"
            if ($sev -eq 'Informational') { continue }
            , @(($severities[$sev] ?? $sev), "$($e.Name)", ("$($e.Description)" -replace '\s+', ' ').Trim())
        }
        $errorsCount = @($entries | Where-Object { "$($_.Severity)" -eq 'Error' }).Count
        $warnings = @($entries | Where-Object { "$($_.Severity)" -eq 'Warning' }).Count
        $findings = @()
        if ($errorsCount) { $findings += New-Finding 'warning' 'SNS-ENERGY-ERRORS' "$errorsCount erreur(s) d'efficacité énergétique (périphérique qui empêche la veille, plan mal réglé…)." 'Voir le tableau : chaque ligne nomme le réglage ou le périphérique en cause.' }
        [PSCustomObject]@{
            Subtitle = '{0} erreur(s), {1} avertissement(s)' -f $errorsCount, $warnings
            Sections = @([PSCustomObject]@{ Title = 'Problèmes relevés'; Type = 'Table'; Icon = 'warning'; Columns = @('Gravité', 'Problème', 'Détail'); Rows = @($rows) })
            Findings = $findings
        }
    }
    finally { Remove-Item -LiteralPath $xml -ErrorAction SilentlyContinue }
}

# sensors_set_power_plan : change de plan d'alimentation. Windows : powercfg /setactive ; Linux : powerprofilesctl set,
# sinon tuned-adm profile.
function Set-SIPowerPlan {
    param(
        [Parameter(Mandatory)][string]$Plan,
        [switch]$DryRun
    )
    $script:Cache.Remove('plans')
    $plans = Get-PowerPlans
    $blocked = $null
    $target = $plans.Plans | Where-Object { $_.Id -eq $Plan -or $_.Name -eq $Plan } | Select-Object -First 1
    if (-not $plans.Tool -or $plans.Tool -eq 'platform_profile') { $blocked = $(if ($plans.Tool) { 'Profil ACPI : à changer avec power-profiles-daemon (non installé), pas directement.' } else { "Aucun outil de plan d'alimentation (Windows : powercfg ; Linux : power-profiles-daemon ou tuned)." }) }
    elseif (-not $target) { $blocked = "Plan inconnu : « $Plan ». Plans disponibles : $(($plans.Plans | ForEach-Object Name) -join ', ')." }
    elseif ($target.Name -eq $plans.Active) { $blocked = "Le plan « $($target.Name) » est déjà actif." }
    $section = [PSCustomObject]@{ Title = "Plan d'alimentation"; Type = 'KeyValue'; Icon = 'settings'; Items = [ordered]@{ 'Actuel' = $plans.Active ?? '—'; 'Nouveau' = $target.Name ?? $Plan; 'Outil' = $plans.Tool ?? '—'; 'Disponibles' = ($plans.Plans | ForEach-Object Name) -join ', ' } }
    $findings = @()
    if ($target -and (Test-PowerSaver $target.Name)) { $findings += New-Finding 'info' 'SNS-PLAN-SLOWER' 'Plan d''économie : la machine sera plus lente mais chauffera et consommera moins.' $null }
    $change = New-Change "Plan d'alimentation" 'Plan actif' $plans.Active ($target.Name ?? $Plan)
    if ($DryRun -or $blocked) { return New-ActionResult "Le plan d'alimentation passera à « $($target.Name ?? $Plan) »" @($section) $findings @($change) $blocked $null }

    $previous = $plans.Plans | Where-Object { $_.Name -eq $plans.Active } | Select-Object -First 1
    $out = switch ($plans.Tool) {
        'powercfg' { & powercfg /setactive $target.Id 2>&1 }
        'powerprofilesctl' { & powerprofilesctl set $target.Id 2>&1 }
        'tuned-adm' { & tuned-adm profile $target.Id 2>&1 }
    }
    if ($LASTEXITCODE -ne 0) { throw "Changement de plan refusé : $(($out | Where-Object { $_ }) -join ' ')" }
    $script:Cache.Remove('plans')
    $after = (Get-PowerPlans).Active
    if ($after -ne $target.Name) { throw "Le plan actif est « $after » au lieu de « $($target.Name) »." }
    $undo = if ($previous) { @{ Function = 'set_power_plan'; Parameters = @{ plan = $previous.Id } } } else { $null }
    New-ActionResult "Plan d'alimentation : $after" @($section) @() @(New-Change "Plan d'alimentation" 'Plan actif' $plans.Active $after) $null $undo
}

#endregion

Export-ModuleMember -Function Get-ModuleData, Get-SISensors, Get-SIBattery, Get-SIWakeHistory, Get-SIEnergyReport, Set-SIPowerPlan
