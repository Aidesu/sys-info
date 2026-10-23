# Module Stockage : disques, partitions, SMART, volumes, inodes, pools / RAID, TRIM, espace disponible, erreurs,
# analyse d'espace et espace récupérable.
#
# Sources
#   Windows : Get-Volume, Get-PhysicalDisk, Get-Disk, Get-Partition, Get-StorageReliabilityCounter (SMART, souvent
#             réservé aux administrateurs), Get-StoragePool, Get-VirtualDisk, fsutil (TRIM, volume « dirty » en admin),
#             tâche planifiée ScheduledDefrag, Win32_PerfFormattedData_PerfDisk_PhysicalDisk (activité),
#             journal Système (disk, Ntfs, volmgr, stornvme, storahci).
#   Linux   : lsblk et findmnt (JSON), df (inodes), /proc/diskstats (activité), udisks par D-Bus via busctl (SMART sans
#             droits root : NVMe.Controller.SmartGetAttributes, Drive.Ata), /proc/mdstat, /sys/fs/btrfs (profils,
#             compteurs d'erreurs), /sys/fs/ext4, zpool, systemctl (fstrim.timer), /sys/block/*/queue/discard_max_bytes,
#             tune2fs en root (état ext4), journalctl -k (erreurs du noyau), du / docker / journalctl (espace récupérable).
#   Commun  : analyse d'espace par une classe C# compilée au premier appel (Add-Type), même code sur les deux OS.
#
# État gardé entre deux appels ($script:) : compteurs d'octets lus/écrits (activité), SMART relu toutes les 30 s,
# erreurs du journal relues toutes les 60 s.

$script:Fr = [cultureinfo]::GetCultureInfo('fr-FR')
$script:Nbsp = [char]0x00A0
$script:PrevIo = $null
$script:Smart = $null; $script:SmartAt = $null
$script:Events = $null; $script:EventsAt = $null

# Seuils de remplissage (design system) : Attention ≥ 85 %, Critique ≥ 95 %.
$script:FillWarning = 0.85; $script:FillCritical = 0.95

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

# Octets → GiB / TiB (binaire, par défaut dans l'interface).
function Format-Bytes([double]$Bytes) {
    if ($Bytes -ge 1TB) { return Format-Unit ($Bytes / 1TB) 'TiB' '0.##' }
    if ($Bytes -ge 1GB) { return Format-Unit ($Bytes / 1GB) 'GiB' '0.#' }
    Format-Unit ($Bytes / 1MB) 'MiB' '0'
}

# Capacité commerciale d'un disque → GB / TB décimaux (ce qui est écrit sur la boîte).
function Format-Capacity([double]$Bytes) {
    if ($Bytes -ge 1e12) { return Format-Unit ($Bytes / 1e12) 'TB' '0.##' }
    Format-Unit ($Bytes / 1e9) 'GB' '0'
}

function Invoke-Tool([string]$Name, [string[]]$Arguments) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) { return @() }
    & $Name @Arguments 2>$null
}

#endregion

#region Volumes et partitions

# Volumes montés avec leur remplissage (pas de squashfs, tmpfs, etc. ; un même système de fichiers une seule fois).
function Get-Volumes {
    if ($IsWindows) {
        return Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.Size -gt 0 -and $_.DriveType -in 'Fixed', 'Removable' } |
            Sort-Object DriveLetter | ForEach-Object {
                [PSCustomObject]@{
                    Mount  = if ($_.DriveLetter) { "$($_.DriveLetter):" } else { $_.FileSystemLabel }
                    Source = $_.FileSystemLabel
                    FsType = $_.FileSystem
                    Size   = [double]$_.Size
                    Used   = [double]($_.Size - $_.SizeRemaining)
                    Free   = [double]$_.SizeRemaining
                }
            }
    }

    $json = (Invoke-Tool findmnt @('-J', '-b', '--real', '-o', 'TARGET,SOURCE,FSTYPE,SIZE,USED,AVAIL')) -join ''
    if (-not $json) { return @() }
    $flat = [System.Collections.Generic.List[object]]::new()
    $walk = { param($nodes) foreach ($n in $nodes) { $flat.Add($n); if ($n.children) { & $walk $n.children } } }
    & $walk ($json | ConvertFrom-Json).filesystems

    $seen = @{}
    foreach ($fs in $flat) {
        if ($fs.fstype -in 'squashfs', 'iso9660', 'overlay', 'tmpfs', 'devtmpfs' -or -not $fs.size) { continue }
        $device = $fs.source -replace '\[.*\]$', ''   # « /dev/nvme0n1p3[/home] » : sous-volume btrfs
        if ($seen.ContainsKey($device)) { $seen[$device].Mounts += $fs.target; continue }
        $volume = [PSCustomObject]@{
            Mount = $fs.target; Mounts = @($fs.target); Source = $device; FsType = $fs.fstype
            Size = [double]$fs.size; Used = [double]$fs.used; Free = [double]$fs.avail
        }
        $seen[$device] = $volume
        $volume
    }
}

function Get-Disks {
    if ($IsWindows) {
        $styles = @{}
        foreach ($d in Get-Disk -ErrorAction SilentlyContinue) { $styles["$($d.Number)"] = "$($d.PartitionStyle)" }
        return Get-PhysicalDisk -ErrorAction SilentlyContinue | Sort-Object DeviceId | ForEach-Object {
            [PSCustomObject]@{
                Name = "Disque $($_.DeviceId)"; Device = $_; Model = $_.FriendlyName; Serial = "$($_.SerialNumber)".Trim()
                Kind = '{0} {1}' -f $_.MediaType, $_.BusType; Size = [double]$_.Size; Removable = $_.BusType -eq 'USB'
                Health = "$($_.HealthStatus)"; Table = $styles["$($_.DeviceId)"] -replace '^RAW$', 'aucune'
                Ssd = "$($_.MediaType)" -eq 'SSD'
            }
        }
    }
    $json = (Invoke-Tool lsblk @('-J', '-b', '-d', '-e', '7,251', '-o', 'NAME,TYPE,SIZE,MODEL,SERIAL,TRAN,ROTA,RM,VENDOR,PTTYPE')) -join ''
    if (-not $json) { return @() }
    ($json | ConvertFrom-Json).blockdevices | Where-Object type -eq 'disk' | ForEach-Object {
        $kind = switch ($_.tran) {
            'nvme' { 'SSD NVMe' }
            'usb' { 'USB' }
            default { if ($_.rota) { 'HDD' } else { 'SSD' } + $(if ($_.tran) { ' ' + $_.tran.ToUpperInvariant() } else { '' }) }
        }
        [PSCustomObject]@{
            Name = $_.name; Device = "/dev/$($_.name)"
            Model = (('{0} {1}' -f $_.vendor, $_.model).Trim() -replace '\s+', ' ')
            Serial = $_.serial; Kind = $kind; Size = [double]$_.size; Removable = [bool]$_.rm; Health = $null
            Table = if ($_.pttype -eq 'dos') { 'MBR' } elseif ($_.pttype) { $_.pttype.ToUpperInvariant() } else { 'aucune' }
            Ssd = -not $_.rota
        }
    }
}

function Get-Partitions {
    if ($IsWindows) {
        return Get-Partition -ErrorAction SilentlyContinue | Sort-Object DiskNumber, PartitionNumber | ForEach-Object {
            $volume = if ($_.DriveLetter) { Get-Volume -DriveLetter $_.DriveLetter -ErrorAction SilentlyContinue } else { $null }
            [PSCustomObject]@{
                Name = 'Disque {0} · partition {1}' -f $_.DiskNumber, $_.PartitionNumber; Disk = "Disque $($_.DiskNumber)"
                Size = [double]$_.Size; FsType = $volume.FileSystem; Label = $volume.FileSystemLabel
                Mount = if ($_.DriveLetter) { "$($_.DriveLetter):" } else { $null }; Role = "$($_.Type)"
                Aligned = ([double]$_.Offset % 1MB) -eq 0
            }
        }
    }
    $json = (Invoke-Tool lsblk @('-J', '-b', '-e', '7,251', '-o', 'NAME,TYPE,SIZE,FSTYPE,LABEL,MOUNTPOINTS,PKNAME,PARTTYPENAME')) -join ''
    if (-not $json) { return @() }
    foreach ($disk in ($json | ConvertFrom-Json).blockdevices) {
        foreach ($part in @($disk.children | Where-Object type -eq 'part')) {
            # Début de la partition en secteurs de 512 octets (/sys/class/block/<part>/start) : aligné sur 1 MiB ?
            $start = Get-Content -LiteralPath "/sys/class/block/$($part.name)/start" -ErrorAction SilentlyContinue
            [PSCustomObject]@{
                Name = $part.name; Disk = $disk.name; Size = [double]$part.size; FsType = $part.fstype; Label = $part.label
                Mount = (@($part.mountpoints | Where-Object { $_ }) -join ', '); Role = $part.parttypename
                Aligned = if ($start) { ([double]$start * 512 % 1MB) -eq 0 } else { $null }
            }
        }
    }
}

# Inodes par système de fichiers (Linux ; btrfs et vfat n'ont pas de nombre fixe d'inodes → ignorés).
function Get-Inodes {
    if (-not $IsLinux) { return @() }
    Invoke-Tool df @('--output=target,fstype,itotal,iused', '-x', 'tmpfs', '-x', 'devtmpfs', '-x', 'squashfs', '-x', 'overlay', '-x', 'efivarfs') |
        Select-Object -Skip 1 | ForEach-Object {
            $f = $_.Trim() -split '\s+'
            if ($f.Count -ge 4 -and [double]$f[2] -gt 0) { [PSCustomObject]@{ Mount = $f[0]; FsType = $f[1]; Total = [double]$f[2]; Used = [double]$f[3] } }
        }
}

# Pools et RAID.
# Windows : Get-StoragePool (hors pool primordial) et ses disques virtuels (résilience, état).
# Linux   : /proc/mdstat (RAID logiciel), btrfs multi-périphériques (/sys/fs/btrfs/<uuid>/devices, profil des données),
#           volumes LVM (lsblk TYPE=lvm), zpool list.
function Get-Pools {
    if ($IsWindows) {
        return Get-StoragePool -IsPrimordial $false -ErrorAction SilentlyContinue | ForEach-Object {
            $virtual = @($_ | Get-VirtualDisk -ErrorAction SilentlyContinue)
            [PSCustomObject]@{
                Name = $_.FriendlyName; Kind = 'Espaces de stockage · ' + (($virtual.ResiliencySettingName | Select-Object -Unique) -join ', ')
                Size = [double]$_.Size; State = "$($_.HealthStatus)"; Members = @($_ | Get-PhysicalDisk -ErrorAction SilentlyContinue).Count
                Degraded = "$($_.HealthStatus)" -ne 'Healthy' -or ($virtual | Where-Object { "$($_.HealthStatus)" -ne 'Healthy' })
            }
        }
    }

    $list = [System.Collections.Generic.List[object]]::new()
    # mdstat : « md0 : active raid1 sdb1[1] sda1[0] » puis « … blocks [2/2] [UU] » (un « _ » = membre absent).
    $lines = @(Get-Content -Path /proc/mdstat -ErrorAction SilentlyContinue)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^(md\d+)\s*:\s*(\S+)\s+(\S+)\s+(.*)$') {
            $name = $Matches[1]; $state = $Matches[2]; $level = $Matches[3]; $members = @($Matches[4] -split '\s+').Count
            $status = if ($i + 1 -lt $lines.Count -and $lines[$i + 1] -match '\[([U_]+)\]') { $Matches[1] } else { '' }
            $size = [double](Get-Content "/sys/block/$name/size" -ErrorAction SilentlyContinue) * 512
            $list.Add([PSCustomObject]@{
                    Name = "/dev/$name"; Kind = "RAID logiciel $level"; Size = $size; Members = $members
                    State = if ($status -match '_') { "Dégradé ($status)" } elseif ($state -eq 'active') { 'Actif' } else { $state }
                    Degraded = $status -match '_'
                })
        }
    }
    foreach ($fs in Get-ChildItem -Path /sys/fs/btrfs -Directory -ErrorAction SilentlyContinue | Where-Object Name -Match '^[0-9a-f-]{36}$') {
        $devices = @(Get-ChildItem -Path (Join-Path $fs.FullName 'devices') -ErrorAction SilentlyContinue)
        if ($devices.Count -lt 2) { continue }
        $dataProfile = (Get-ChildItem -Path (Join-Path $fs.FullName 'allocation/data') -Directory -ErrorAction SilentlyContinue | Select-Object -First 1).Name
        $label = Get-Content (Join-Path $fs.FullName 'label') -ErrorAction SilentlyContinue
        $total = [double](Get-Content (Join-Path $fs.FullName 'allocation/data/total_bytes') -ErrorAction SilentlyContinue)
        $list.Add([PSCustomObject]@{ Name = "btrfs $(if ($label) { $label } else { $fs.Name.Substring(0, 8) })"; Kind = "Btrfs $dataProfile"; Size = $total; Members = $devices.Count; State = 'Monté'; Degraded = $false })
    }
    $json = (Invoke-Tool lsblk @('-J', '-b', '-o', 'NAME,TYPE,SIZE')) -join ''
    if ($json) {
        $walk = { param($nodes) foreach ($n in $nodes) { if ($n.type -eq 'lvm') { $n }; if ($n.children) { & $walk $n.children } } }
        foreach ($lv in & $walk ($json | ConvertFrom-Json).blockdevices | Sort-Object name -Unique) {
            $list.Add([PSCustomObject]@{ Name = $lv.name; Kind = 'Volume logique LVM'; Size = [double]$lv.size; Members = $null; State = 'Actif'; Degraded = $false })
        }
    }
    foreach ($line in Invoke-Tool zpool @('list', '-H', '-p', '-o', 'name,size,health')) {
        $f = $line -split '\t'
        $list.Add([PSCustomObject]@{ Name = $f[0]; Kind = 'Pool ZFS'; Size = [double]$f[1]; Members = $null; State = $f[2]; Degraded = $f[2] -ne 'ONLINE' })
    }
    $list
}

# TRIM : le système signale-t-il les blocs libérés aux SSD ?
# Windows : fsutil behavior query DisableDeleteNotify (0 = activé) et tâche planifiée d'optimisation.
# Linux   : option de montage discard, ou fstrim.timer activé ; support matériel via discard_max_bytes.
function Get-TrimInfo($Disks) {
    if ($IsWindows) {
        $line = Invoke-Tool fsutil @('behavior', 'query', 'DisableDeleteNotify') | Where-Object { $_ -match 'NTFS' } | Select-Object -First 1
        $enabled = if ($line -match '=\s*(\d)') { $Matches[1] -eq '0' } else { $null }
        $task = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -ErrorAction SilentlyContinue
        return [PSCustomObject]@{
            Enabled = $enabled
            Mode = if ($enabled -eq $false) { 'Désactivé (DisableDeleteNotify = 1)' } elseif ($task -and $task.State -ne 'Disabled') { 'Activé · optimisation planifiée' } elseif ($enabled) { 'Activé · optimisation planifiée désactivée' } else { 'Inconnu' }
        }
    }
    $supported = @($Disks | Where-Object { [double](Get-Content "/sys/block/$($_.Name)/queue/discard_max_bytes" -ErrorAction SilentlyContinue) -gt 0 })
    $discard = @((Invoke-Tool findmnt @('-n', '-l', '-o', 'TARGET,OPTIONS', '--real')) | Where-Object { $_ -match '(^|,|\s)discard' } | ForEach-Object { ($_ -split '\s+')[0] })
    $timer = (Invoke-Tool systemctl @('is-enabled', 'fstrim.timer')) -eq 'enabled'
    $modes = @()
    if ($discard.Count -gt 0) { $modes += 'en continu (option discard : {0})' -f ($discard -join ', ') }
    if ($timer) { $modes += 'planifié (fstrim.timer)' }
    [PSCustomObject]@{
        Enabled = $modes.Count -gt 0
        Mode = if ($modes) { 'Activé · ' + ($modes -join ' · ') } else { 'Désactivé' }
        Supported = $supported.Count
    }
}

# Volumes marqués « à vérifier » (dirty) : seulement avec les droits administrateur / root.
# Windows : fsutil dirty query X:. Linux : tune2fs -l (ext2/3/4 : « Filesystem state »).
function Get-DirtyVolumes($Volumes) {
    if (-not [Environment]::IsPrivilegedProcess) { return $null }
    foreach ($v in $Volumes) {
        if ($IsWindows) {
            if ($v.Mount -notmatch '^[A-Z]:$') { continue }
            $out = Invoke-Tool fsutil @('dirty', 'query', $v.Mount)
            # « Le volume C: n'est PAS incorrect » / « Volume - C: is NOT Dirty » : la négation en majuscules.
            [PSCustomObject]@{ Mount = $v.Mount; Dirty = -not ($out -cmatch 'NOT|PAS') }
        }
        elseif ($v.FsType -like 'ext*') {
            $state = Invoke-Tool tune2fs @('-l', $v.Source) | Where-Object { $_ -like 'Filesystem state:*' } | Select-Object -First 1
            if ($state) { [PSCustomObject]@{ Mount = $v.Mount; Dirty = $state -notmatch 'clean' } }
        }
    }
}

#endregion

#region SMART

# Linux : udisks (D-Bus) donne le SMART sans droits root. NVMe : SmartGetAttributes ; SATA : Drive.Ata.
function Get-BusProperty([string]$Path, [string]$Interface, [string[]]$Names) {
    $lines = Invoke-Tool busctl (@('--system', '--json=short', 'get-property', 'org.freedesktop.UDisks2', $Path, $Interface) + $Names)
    $values = @{}
    $i = 0
    foreach ($line in $lines) {
        if ($i -ge $Names.Count) { break }
        try { $values[$Names[$i]] = ($line | ConvertFrom-Json).data } catch { }
        $i++
    }
    $values
}

function Get-LinuxSmart($Disk) {
    $drive = (Get-BusProperty "/org/freedesktop/UDisks2/block_devices/$($Disk.Name)" 'org.freedesktop.UDisks2.Block' @('Drive'))['Drive']
    if (-not $drive -or $drive -eq '/') { return $null }

    if ($Disk.Kind -eq 'SSD NVMe') {
        $json = (Invoke-Tool busctl @('--system', '--json=short', 'call', 'org.freedesktop.UDisks2', $drive,
                'org.freedesktop.UDisks2.NVMe.Controller', 'SmartGetAttributes', 'a{sv}', '0')) -join ''
        if (-not $json) { return $null }
        $raw = ($json | ConvertFrom-Json).data[0]
        $a = @{}
        foreach ($p in $raw.PSObject.Properties) { $a[$p.Name] = $p.Value.data }
        $c = Get-BusProperty $drive 'org.freedesktop.UDisks2.NVMe.Controller' @('SmartCriticalWarning', 'SmartPowerOnHours', 'SmartSelftestStatus')
        $warnings = @($c['SmartCriticalWarning'])
        return [PSCustomObject]@{
            Failing        = $warnings.Count -gt 0 -or $a['media_errors'] -gt 0 -or $a['avail_spare'] -le $a['spare_thresh']
            Warnings       = $warnings
            Temperature    = if ($a['temp_sensors']) { [double]$a['temp_sensors'][0] - 273 } else { $null }   # kelvins
            Wear           = $a['percent_used']
            Spare          = $a['avail_spare']
            SpareThreshold = $a['spare_thresh']
            Hours          = $c['SmartPowerOnHours']
            PowerCycles    = $a['power_cycles']
            UnsafeShutdowns = $a['unsafe_shutdowns']
            Read           = $a['total_data_read']
            Written        = $a['total_data_written']
            MediaErrors    = $a['media_errors']
            ErrorLog       = $a['num_err_log_entries']
            HotMinutes     = $a['warning_temp_time']
            BadSectors     = $null
            SelfTest       = $c['SmartSelftestStatus']
        }
    }

    $ata = Get-BusProperty $drive 'org.freedesktop.UDisks2.Drive.Ata' @('SmartSupported', 'SmartEnabled', 'SmartFailing',
        'SmartPowerOnSeconds', 'SmartTemperature', 'SmartNumBadSectors', 'SmartSelftestStatus')
    if (-not $ata['SmartSupported'] -or -not $ata['SmartEnabled']) { return $null }
    [PSCustomObject]@{
        Failing = [bool]$ata['SmartFailing']; Warnings = @()
        Temperature = if ($ata['SmartTemperature'] -gt 0) { [double]$ata['SmartTemperature'] - 273.15 } else { $null }
        Wear = $null; Spare = $null; SpareThreshold = $null
        Hours = if ($ata['SmartPowerOnSeconds']) { [Math]::Round($ata['SmartPowerOnSeconds'] / 3600) } else { $null }
        PowerCycles = $null; UnsafeShutdowns = $null; Read = $null; Written = $null; MediaErrors = $null; ErrorLog = $null
        HotMinutes = $null; BadSectors = $ata['SmartNumBadSectors']; SelfTest = $ata['SmartSelftestStatus']
    }
}

function Get-WindowsSmart($Disk) {
    # Compteurs de fiabilité : la plupart des champs demandent les droits administrateur.
    $r = $Disk.Device | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
    [PSCustomObject]@{
        Failing = $Disk.Health -notin 'Healthy', ''; Warnings = @()
        Temperature = $r.Temperature; Wear = $r.Wear; Spare = $null; SpareThreshold = $null
        Hours = $r.PowerOnHours; PowerCycles = $r.StartStopCycleCount; UnsafeShutdowns = $null
        Read = $null; Written = $null
        MediaErrors = if ($null -ne $r.ReadErrorsUncorrected) { $r.ReadErrorsUncorrected + $r.WriteErrorsUncorrected } else { $null }
        ErrorLog = $null; HotMinutes = $null; BadSectors = $null; SelfTest = $null
    }
}

function Get-SmartState($Smart) {
    if (-not $Smart) { return 'Non disponible' }
    if ($Smart.Failing) { return 'Défaillance signalée' }
    if ($Smart.Wear -ge 90) { return 'Usure avancée' }
    'Bon'
}

#endregion

#region Activité et erreurs

# Octets lus / écrits par seconde, tous disques physiques confondus, par différence avec l'appel précédent.
function Get-DiskActivity($Disks) {
    $now = [DateTime]::UtcNow
    if ($IsWindows) {
        $total = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'"
        return [PSCustomObject]@{ Read = [double]$total.DiskReadBytesPersec; Write = [double]$total.DiskWriteBytesPersec }
    }
    # /proc/diskstats : champ 6 = secteurs lus, champ 10 = secteurs écrits (secteurs de 512 octets).
    $names = @($Disks.Name)
    $read = 0.0; $write = 0.0
    foreach ($line in Get-Content -Path /proc/diskstats) {
        $f = $line.Trim() -split '\s+'
        if ($f[2] -in $names) { $read += [double]$f[5] * 512; $write += [double]$f[9] * 512 }
    }
    $previous = $script:PrevIo
    $script:PrevIo = @{ Read = $read; Write = $write; At = $now }
    if (-not $previous) { return $null }
    $seconds = ($now - $previous.At).TotalSeconds
    if ($seconds -le 0) { return $null }
    [PSCustomObject]@{ Read = [Math]::Max(0, $read - $previous.Read) / $seconds; Write = [Math]::Max(0, $write - $previous.Write) / $seconds }
}

# Erreurs de stockage des 7 derniers jours.
function Get-StorageEvents {
    $since = (Get-Date).AddDays(-7)
    if ($IsWindows) {
        $filter = @{ LogName = 'System'; ProviderName = 'disk', 'Ntfs', 'Microsoft-Windows-Ntfs', 'volmgr', 'stornvme', 'storahci', 'iaStorA'; Level = 1, 2, 3; StartTime = $since }
        return Get-WinEvent -FilterHashtable $filter -MaxEvents 50 -ErrorAction SilentlyContinue | ForEach-Object {
            [PSCustomObject]@{ Time = $_.TimeCreated; Source = $_.ProviderName; Message = ($_.Message -split "`r?`n")[0] }
        }
    }
    $pattern = '(I/O error|blk_update_request|EXT4-fs error|BTRFS (error|warning|critical)|nvme.*(timeout|reset|error)|ata[0-9.]+:.*(failed|error)|critical medium error|Buffer I/O|XFS .*(error|corruption))'
    Invoke-Tool journalctl @('-k', '-p', 'warning', '--since=-7d', '-o', 'short-iso', '--no-pager', '-q', '-g', $pattern) |
        Select-Object -Last 50 | ForEach-Object {
            if ($_ -match '^(\S+)\s+\S+\s+kernel:\s*(.*)$') {
                $message = $Matches[2]
                [PSCustomObject]@{
                    Time = [DateTime]::Parse($Matches[1], [cultureinfo]::InvariantCulture)
                    Source = ($message -split '[:\s]', 2)[0]
                    Message = $message
                }
            }
        }
}

# Compteurs d'erreurs des systèmes de fichiers (Linux) : btrfs (par périphérique) et ext4.
function Get-FsErrorCounters {
    if (-not $IsLinux) { return @() }
    foreach ($stats in Get-ChildItem -Path '/sys/fs/btrfs/*/devinfo/*/error_stats' -ErrorAction SilentlyContinue) {
        $total = 0
        foreach ($line in Get-Content -LiteralPath $stats.FullName) { if ($line -match '\s(\d+)$') { $total += [int]$Matches[1] } }
        $uuid = $stats.FullName.Split('/')[4]
        $label = (Get-Content -LiteralPath "/sys/fs/btrfs/$uuid/label" -ErrorAction SilentlyContinue)
        [PSCustomObject]@{ Name = "btrfs $(if ($label) { $label } else { $uuid.Substring(0, 8) })"; Errors = $total }
    }
    foreach ($dir in Get-ChildItem -Path /sys/fs/ext4 -Directory -ErrorAction SilentlyContinue) {
        $count = Get-Content -LiteralPath (Join-Path $dir.FullName 'errors_count') -ErrorAction SilentlyContinue
        if ($null -ne $count) { [PSCustomObject]@{ Name = "ext4 $($dir.Name)"; Errors = [int]$count } }
    }
}

#endregion

function Get-ModuleData {
    $sections = [System.Collections.Generic.List[object]]::new()
    $errors = [ordered]@{}

    # Chaque bloc est indépendant ; il renvoie sa valeur (une affectation dans le bloc ne remonterait pas).
    function Invoke-Block([string]$Name, [scriptblock]$Block) {
        try { & $Block } catch { $errors[$Name] = $_.Exception.Message; $null }
    }

    $volumes = @(Invoke-Block 'Volumes' { Get-Volumes })
    $disks = @(Invoke-Block 'Disques' { Get-Disks })

    # Remplissage des volumes (section Usage : une jauge par volume)
    if ($volumes.Count -gt 0) {
        $items = foreach ($v in $volumes) {
            $sizeGiB = [Math]::Round($v.Size / 1GB, 1)
            $mounts = if ($v.Mounts.Count -gt 1) { ' · aussi ' + (($v.Mounts | Select-Object -Skip 1) -join ', ') } else { '' }
            [PSCustomObject]@{
                Label = $v.Mount
                Detail = ('{0} · {1}{2}' -f $v.FsType, ($v.Source -replace '^/dev/', ''), $mounts)
                Value = [Math]::Round($v.Used / 1GB, 1); Max = $sizeGiB; Unit = 'GiB'
                Warning = [Math]::Round($sizeGiB * $script:FillWarning, 1); Critical = [Math]::Round($sizeGiB * $script:FillCritical, 1)
                Text = ('{0} libres sur {1}' -f (Format-Bytes $v.Free), (Format-Bytes $v.Size))
            }
        }
        $sections.Add([PSCustomObject]@{ Title = 'Remplissage des volumes'; Type = 'Usage'; Icon = 'hard_drive'; Items = @($items) })
    }

    # Activité des disques : un graphique large, lecture et écriture
    if ($disks.Count -gt 0 -and $IsLinux -and -not $script:PrevIo) {
        [void](Invoke-Block 'Activité' { Get-DiskActivity $disks })
        Start-Sleep -Milliseconds 250
    }
    $io = Invoke-Block 'Activité' { Get-DiskActivity $disks }
    $sections.Add([PSCustomObject]@{
            Title = 'Activité des disques'; Type = 'Metric'; Icon = 'arrow_swap'; Unit = 'MiB/s'
            Label = 'Lecture'; Value = if ($io) { [Math]::Round($io.Read / 1MB, 2) } else { $null }
            Secondary = [PSCustomObject]@{ Label = 'Écriture'; Value = if ($io) { [Math]::Round($io.Write / 1MB, 2) } else { $null } }
            Detail = ('Tous disques physiques : {0}' -f (($disks | ForEach-Object { $_.Name }) -join ', '))
        })

    # SMART (relu toutes les 30 s)
    if (-not $script:SmartAt -or ((Get-Date) - $script:SmartAt).TotalSeconds -ge 30) {
        $script:Smart = @{}
        foreach ($d in $disks) {
            $script:Smart[$d.Name] = Invoke-Block "SMART $($d.Name)" { if ($IsWindows) { Get-WindowsSmart $d } else { Get-LinuxSmart $d } }
        }
        $script:SmartAt = Get-Date
    }

    # Disques physiques
    if ($disks.Count -gt 0) {
        $rows = foreach ($d in $disks) {
            $s = $script:Smart[$d.Name]
            , @($d.Name, $d.Model, $d.Kind, (Format-Capacity $d.Size), $d.Table, (Get-SmartState $s),
                $(if ($s -and $null -ne $s.Temperature) { [Math]::Round($s.Temperature) } else { $null }),
                $(if ($s) { $s.Wear } else { $null }), $(if ($s) { $s.Hours } else { $null }), $d.Serial)
        }
        $sections.Add([PSCustomObject]@{
                Title = 'Disques physiques'; Type = 'Table'; Icon = 'hard_drive'
                Columns = @('Disque', 'Modèle', 'Type', 'Capacité', 'Table', 'État SMART', 'Température (°C)', 'Usure (%)', 'Heures', 'N° de série')
                Rows = @($rows)
            })
    }

    # Détail SMART par disque
    foreach ($d in $disks) {
        $s = $script:Smart[$d.Name]
        if (-not $s) { continue }
        $items = [ordered]@{ 'État' = Get-SmartState $s }
        if ($s.Warnings.Count -gt 0) { $items['Avertissements'] = $s.Warnings -join ', ' }
        if ($null -ne $s.Temperature) { $items['Température'] = Format-Unit $s.Temperature '°C' '0' }
        if ($null -ne $s.Wear) { $items['Usure'] = Format-Unit $s.Wear '%' '0' }
        if ($null -ne $s.Spare) { $items['Réserve disponible'] = '{0} (seuil {1})' -f (Format-Unit $s.Spare '%' '0'), (Format-Unit $s.SpareThreshold '%' '0') }
        if ($null -ne $s.Hours) { $items['Heures de fonctionnement'] = '{0} h ({1} j)' -f $s.Hours.ToString('#,##0', $script:Fr), [Math]::Round($s.Hours / 24).ToString('#,##0', $script:Fr) }
        if ($null -ne $s.PowerCycles) { $items['Cycles d''alimentation'] = $s.PowerCycles }
        if ($null -ne $s.UnsafeShutdowns) { $items['Arrêts non propres'] = $s.UnsafeShutdowns }
        # NVMe : unités de 512 000 octets déjà converties en octets par udisks.
        if ($null -ne $s.Read) { $items['Données lues'] = Format-Capacity $s.Read }
        if ($null -ne $s.Written) { $items['Données écrites'] = Format-Capacity $s.Written }
        if ($null -ne $s.MediaErrors) { $items['Erreurs média'] = $s.MediaErrors }
        if ($null -ne $s.BadSectors) { $items['Secteurs défectueux'] = $s.BadSectors }
        if ($null -ne $s.ErrorLog) { $items["Entrées du journal d'erreurs"] = $s.ErrorLog }
        if ($s.HotMinutes) { $items['Temps au-dessus du seuil de température'] = Format-Unit $s.HotMinutes 'min' '0' }
        if ($s.SelfTest) { $items['Dernier autotest'] = if ($s.SelfTest -eq 'success') { 'Réussi' } else { $s.SelfTest } }
        $sections.Add([PSCustomObject]@{
                Title = "SMART · $($d.Model)"; Type = 'KeyValue'
                Icon = $(if ($s.Failing) { 'warning' } else { 'shield_checkmark' })
                Items = $items
            })
    }
    $withoutSmart = @($disks | Where-Object { -not $script:Smart[$_.Name] })

    # Partitions (relues toutes les 30 s)
    $partitions = @(Invoke-Block 'Partitions' { Get-Cached 'partitions' 30 { Get-Partitions } } | Where-Object { $_ })
    if ($partitions.Count -gt 0) {
        $rows = foreach ($p in $partitions) {
            , @($p.Name, $p.Disk, [Math]::Round($p.Size / 1GB, 1), $p.FsType, $p.Label, $(if ($p.Mount) { $p.Mount } else { $null }), $p.Role,
                $(if ($null -eq $p.Aligned) { $null } elseif ($p.Aligned) { 'Oui' } else { 'Non' }))
        }
        $sections.Add([PSCustomObject]@{
                Title = 'Partitions'; Type = 'Table'; Icon = 'board'
                Columns = @('Partition', 'Disque', 'Taille (GiB)', 'Système de fichiers', 'Étiquette', 'Montage', 'Rôle', 'Alignée (1 MiB)')
                Rows = @($rows)
            })
    }

    # Inodes (Linux) : une jauge par système de fichiers à nombre d'inodes fixe
    $inodes = @(Invoke-Block 'Inodes' { Get-Cached 'inodes' 30 { Get-Inodes } } | Where-Object { $_ })
    if ($inodes.Count -gt 0) {
        $items = foreach ($i in $inodes) {
            [PSCustomObject]@{
                Label = $i.Mount; Detail = $i.FsType; Value = $i.Used; Max = $i.Total; Unit = 'inodes'
                Warning = [Math]::Round($i.Total * 0.85); Critical = [Math]::Round($i.Total * 0.95)
                Text = '{0} libres' -f ($i.Total - $i.Used).ToString('#,##0', $script:Fr)
            }
        }
        $sections.Add([PSCustomObject]@{ Title = 'Inodes'; Type = 'Usage'; Icon = 'board'; Items = @($items) })
    }

    # Pools et RAID (seulement s'il y en a)
    $pools = @(Invoke-Block 'Pools' { Get-Cached 'pools' 30 { Get-Pools } } | Where-Object { $_ })
    if ($pools.Count -gt 0) {
        $rows = foreach ($p in $pools) { , @($p.Name, $p.Kind, $(if ($p.Size) { Format-Bytes $p.Size } else { $null }), $p.Members, $p.State) }
        $sections.Add([PSCustomObject]@{
                Title = 'Pools, RAID et volumes logiques'; Type = 'Table'; Icon = 'server'
                Columns = @('Nom', 'Type', 'Taille', 'Membres', 'État'); Rows = @($rows)
            })
    }

    # TRIM et volumes à vérifier
    $trim = Invoke-Block 'TRIM' { Get-Cached 'trim' 60 { Get-TrimInfo $disks } }
    $dirty = @(Invoke-Block 'Volumes à vérifier' { Get-Cached 'dirty' 300 { Get-DirtyVolumes $volumes } } | Where-Object { $_ })
    if ($trim -or $dirty.Count -gt 0) {
        $items = [ordered]@{}
        if ($trim) {
            $items['TRIM'] = $trim.Mode
            if ($IsLinux) { $items['Disques compatibles'] = '{0} sur {1}' -f $trim.Supported, $disks.Count }
        }
        $items['Volumes à vérifier'] = if (-not [Environment]::IsPrivilegedProcess) { 'Lecture réservée aux administrateurs' }
            elseif (($dirty | Where-Object Dirty).Count -gt 0) { ($dirty | Where-Object Dirty | ForEach-Object Mount) -join ', ' }
            else { 'Aucun' }
        $sections.Add([PSCustomObject]@{ Title = 'Entretien'; Type = 'KeyValue'; Icon = 'settings'; Items = $items })
    }

    # Erreurs : journal (relu toutes les 60 s) et compteurs des systèmes de fichiers
    if (-not $script:EventsAt -or ((Get-Date) - $script:EventsAt).TotalSeconds -ge 60) {
        $script:Events = @(Invoke-Block 'Journal' { Get-StorageEvents })
        $script:EventsAt = Get-Date
    }
    $counters = @(Invoke-Block 'Compteurs' { Get-FsErrorCounters })
    $summary = [ordered]@{
        'Journal système (7 jours)' = if ($script:Events.Count -gt 0) { '{0} erreur(s) ou avertissement(s)' -f $script:Events.Count } else { 'Aucune erreur de stockage' }
    }
    foreach ($c in $counters) { $summary["Compteur $($c.Name)"] = if ($c.Errors -gt 0) { '{0} erreur(s)' -f $c.Errors } else { 'Aucune erreur' } }
    if ($withoutSmart.Count -gt 0) {
        $summary['SMART non disponible'] = ($withoutSmart | ForEach-Object { '{0} ({1})' -f $_.Name, $_.Kind }) -join ', '
    }
    $clean = $script:Events.Count -eq 0 -and -not ($counters | Where-Object Errors -gt 0)
    $sections.Add([PSCustomObject]@{
            Title = 'Erreurs'; Type = 'KeyValue'; Icon = $(if ($clean) { 'checkmark_circle' } else { 'warning' }); Items = $summary
        })
    if ($script:Events.Count -gt 0) {
        $rows = foreach ($e in $script:Events | Sort-Object Time -Descending) {
            , @($e.Time.ToString('dd/MM HH:mm', $script:Fr), $e.Source, $e.Message)
        }
        $sections.Add([PSCustomObject]@{
                Title = 'Journal des erreurs de stockage'; Type = 'Table'; Icon = 'warning'
                Columns = @('Date', 'Source', 'Message')
                Rows = @($rows)
            })
    }

    if ($errors.Count -gt 0) {
        $sections.Add([PSCustomObject]@{ Title = 'Erreurs du module'; Type = 'KeyValue'; Icon = 'error_circle'; Items = $errors })
    }

    # Constats (Findings) : ce qui demande une action, avec un code stable pour l'IA
    $findings = [System.Collections.Generic.List[object]]::new()
    function Add-Finding([string]$Severity, [string]$Code, [string]$Message, [string]$Recommendation) {
        $findings.Add([PSCustomObject]@{ Severity = $Severity; Code = $Code; Message = $Message; Recommendation = $Recommendation })
    }
    foreach ($v in $volumes) {
        if ($v.Size -le 0) { continue }
        $ratio = $v.Used / $v.Size
        if ($ratio -ge $script:FillWarning) {
            Add-Finding $(if ($ratio -ge $script:FillCritical) { 'critical' } else { 'warning' }) 'STO-VOLUME-FULL' `
                ('{0} rempli à {1} % ({2} libres)' -f $v.Mount, [Math]::Floor(100 * $ratio), (Format-Bytes $v.Free)) `
                'Libérer de l''espace : fichiers temporaires, corbeille, caches, gros dossiers.'
        }
    }
    foreach ($d in $disks) {
        $s = $script:Smart[$d.Name]
        if (-not $s) { continue }
        if ($s.Failing) {
            Add-Finding 'critical' 'STO-SMART-FAILING' ('{0} ({1}) : SMART signale une défaillance' -f $d.Name, $d.Model) `
                'Sauvegarder les données sans attendre, puis remplacer le disque.'
        }
        $bad = [long]$s.MediaErrors + [long]$s.BadSectors
        if ($bad -gt 0) {
            Add-Finding 'warning' 'STO-SMART-MEDIA' ('{0} ({1}) : {2} erreur(s) média ou secteur(s) défectueux' -f $d.Name, $d.Model, $bad) `
                'Sauvegarder, puis surveiller : un nombre qui augmente annonce une panne.'
        }
        if ($null -ne $s.Wear -and $s.Wear -ge 90) {
            Add-Finding $(if ($s.Wear -ge 100) { 'critical' } else { 'warning' }) 'STO-SSD-WEAR' ('{0} ({1}) usé à {2} %' -f $d.Name, $d.Model, [Math]::Round($s.Wear)) `
                'Prévoir le remplacement du SSD.'
        }
    }
    foreach ($p in $partitions | Where-Object { $_.Aligned -eq $false -and $_.Size -gt 1GB }) {
        Add-Finding 'warning' 'STO-PART-MISALIGNED' ('Partition {0} non alignée sur 1 MiB' -f $p.Name) `
            'Sur un SSD, une partition mal alignée réduit les performances et use davantage le disque.'
    }
    foreach ($i in $inodes | Where-Object { $_.Used / $_.Total -ge 0.85 }) {
        Add-Finding $(if ($i.Used / $i.Total -ge 0.95) { 'critical' } else { 'warning' }) 'STO-INODES-FULL' `
            ('{0} : {1} % des inodes utilisés' -f $i.Mount, [Math]::Floor(100 * $i.Used / $i.Total)) `
            'Trop de petits fichiers : plus aucun fichier ne pourra être créé même avec de l''espace libre. Nettoyer caches et fichiers temporaires.'
    }
    foreach ($p in $pools | Where-Object Degraded) {
        Add-Finding 'critical' 'STO-RAID-DEGRADED' ('{0} ({1}) : {2}' -f $p.Name, $p.Kind, $p.State) `
            'Un membre manque ou est en panne : remplacer le disque et reconstruire avant qu''un second ne lâche.'
    }
    if ($trim -and $trim.Enabled -eq $false -and ($disks | Where-Object Ssd)) {
        Add-Finding 'warning' 'STO-TRIM-OFF' 'TRIM désactivé alors qu''un SSD est présent' `
            $(if ($IsWindows) { 'Réactiver : fsutil behavior set DisableDeleteNotify 0.' } else { 'Activer fstrim.timer (systemctl enable --now fstrim.timer).' })
    }
    foreach ($v in $dirty | Where-Object Dirty) {
        Add-Finding 'warning' 'STO-VOLUME-DIRTY' ('{0} est marqué « à vérifier »' -f $v.Mount) `
            'Lancer une vérification du système de fichiers (chkdsk / fsck) au prochain redémarrage.'
    }
    foreach ($c in $counters | Where-Object Errors -gt 0) {
        Add-Finding 'warning' 'STO-FS-ERRORS' ('{0} : {1} erreur(s) de système de fichiers' -f $c.Name, $c.Errors) `
            'Vérifier le système de fichiers (fsck / chkdsk) au prochain redémarrage.'
    }
    if ($script:Events.Count -gt 0) {
        Add-Finding 'info' 'STO-LOG-ERRORS' ('{0} erreur(s) ou avertissement(s) de stockage dans le journal (7 jours)' -f $script:Events.Count) $null
    }
    foreach ($d in $withoutSmart) {
        Add-Finding 'info' 'STO-SMART-UNAVAILABLE' ('SMART non lisible pour {0} ({1})' -f $d.Name, $d.Kind) `
            $(if ($d.Kind -eq 'USB') { 'Disque USB : la plupart des boîtiers ne transmettent pas SMART.' }
              elseif ($IsLinux) { 'Installer smartmontools (smartctl) ou udisks2 pour lire l''état du disque.' }
              else { 'Disque derrière un contrôleur qui ne transmet pas SMART.' })
    }

    # Sous-titre : nombre de disques, capacité totale, volume racine
    $root = $volumes | Select-Object -First 1
    $subtitle = @('{0} disque(s) · {1}' -f $disks.Count, (Format-Capacity (($disks | Measure-Object -Property Size -Sum).Sum)))
    if ($root) { $subtitle += '{0} : {1} libres' -f $root.Mount, (Format-Bytes $root.Free) }

    [PSCustomObject]@{ Subtitle = $subtitle -join ' · '; Sections = $sections.ToArray(); Findings = $findings.ToArray() }
}

#region Fonctions ciblées (module.json › functions)

# Taille d'arborescences sans boucle PowerShell (trop lente sur des centaines de milliers de fichiers) :
# classe C# compilée une fois par runspace. Ignore les dossiers illisibles et les liens symboliques ; s'arrête
# à l'échéance (résultat partiel signalé) ; ne descend pas dans les chemins exclus (autres montages, /proc…).
if (-not ('SysInfo.Storage.DirectorySizer' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;

namespace SysInfo.Storage
{
    public sealed class SizedEntry
    {
        public string Path;
        public long Bytes;
        public long Files;
    }

    public sealed class SizeReport
    {
        public List<SizedEntry> Folders = new List<SizedEntry>();
        public List<SizedEntry> LargestFiles = new List<SizedEntry>();
        public long TotalBytes;
        public long TotalFiles;
        public bool TimedOut;
    }

    public static class DirectorySizer
    {
        public static SizeReport Analyze(string root, int topFiles, int timeoutMs, string[] excluded)
        {
            var report = new SizeReport();
            var watch = Stopwatch.StartNew();
            var skip = new HashSet<string>(excluded ?? new string[0], StringComparer.Ordinal);
            var largest = new SortedSet<(long, string)>();
            var options = new EnumerationOptions { IgnoreInaccessible = true, AttributesToSkip = FileAttributes.ReparsePoint, RecurseSubdirectories = false };

            // Fichiers directement à la racine : comptés dans le total, comme une pseudo-entrée.
            var rootFiles = new SizedEntry { Path = Path.Combine(root, "(fichiers à la racine)") };
            foreach (var file in new DirectoryInfo(root).EnumerateFiles("*", options)) { Add(file, rootFiles, largest, topFiles); }
            if (rootFiles.Files > 0) report.Folders.Add(rootFiles);

            foreach (var dir in new DirectoryInfo(root).EnumerateDirectories("*", options))
            {
                if (skip.Contains(dir.FullName)) continue;
                var entry = new SizedEntry { Path = dir.FullName };
                var stack = new Stack<DirectoryInfo>();
                stack.Push(dir);
                while (stack.Count > 0)
                {
                    if (watch.ElapsedMilliseconds > timeoutMs) { report.TimedOut = true; break; }
                    var current = stack.Pop();
                    try
                    {
                        foreach (var file in current.EnumerateFiles("*", options)) Add(file, entry, largest, topFiles);
                        foreach (var sub in current.EnumerateDirectories("*", options)) if (!skip.Contains(sub.FullName)) stack.Push(sub);
                    }
                    catch (Exception) { }
                }
                report.Folders.Add(entry);
                if (report.TimedOut) break;
            }

            foreach (var f in report.Folders) { report.TotalBytes += f.Bytes; report.TotalFiles += f.Files; }
            report.Folders.Sort((a, b) => b.Bytes.CompareTo(a.Bytes));
            foreach (var item in largest.Reverse()) report.LargestFiles.Add(new SizedEntry { Path = item.Item2, Bytes = item.Item1, Files = 1 });
            return report;
        }

        private static void Add(FileInfo file, SizedEntry entry, SortedSet<(long, string)> largest, int top)
        {
            long length;
            try { length = file.Length; } catch (Exception) { return; }
            entry.Bytes += length;
            entry.Files++;
            if (top <= 0) return;
            if (largest.Count < top) { largest.Add((length, file.FullName)); }
            else if (length > largest.Min.Item1) { largest.Remove(largest.Min); largest.Add((length, file.FullName)); }
        }

        // Taille d'un seul dossier (récursive), 0 s'il n'existe pas.
        public static long Size(string path, int timeoutMs)
        {
            if (!Directory.Exists(path)) return 0;
            var parent = Path.GetDirectoryName(path.TrimEnd(Path.DirectorySeparatorChar)) ?? path;
            var options = new EnumerationOptions { IgnoreInaccessible = true, AttributesToSkip = FileAttributes.ReparsePoint, RecurseSubdirectories = true };
            long total = 0;
            var watch = Stopwatch.StartNew();
            try
            {
                foreach (var file in new DirectoryInfo(path).EnumerateFiles("*", options))
                {
                    try { total += file.Length; } catch (Exception) { }
                    if (watch.ElapsedMilliseconds > timeoutMs) break;
                }
            }
            catch (Exception) { }
            return total;
        }
    }
}
'@
}

function New-Finding([string]$Severity, [string]$Code, [string]$Message, [string]$Recommendation) {
    [PSCustomObject]@{ Severity = $Severity; Code = $Code; Message = $Message; Recommendation = $Recommendation }
}

# Chemins à ne pas parcourir sous Linux : systèmes de fichiers virtuels et montages réseau.
function Get-ExcludedMounts {
    if (-not $IsLinux) { return @() }
    $real = 'ext2', 'ext3', 'ext4', 'btrfs', 'xfs', 'vfat', 'exfat', 'ntfs', 'ntfs3', 'f2fs', 'zfs', 'jfs', 'reiserfs', 'bcachefs'
    @(Invoke-Tool findmnt @('-n', '-l', '-o', 'TARGET,FSTYPE') | ForEach-Object {
            $f = $_ -split '\s+', 2
            if ($f[1] -notin $real) { $f[0] }
        }) + @('/proc', '/sys', '/dev', '/run')
}

# storage_analyze_space : plus gros dossiers (un niveau sous le chemin, tailles cumulées) et plus gros fichiers.
function Get-SISpaceUsage {
    param(
        [string]$Path,
        [ValidateRange(1, 100)][int]$Top = 20,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 30
    )
    if (-not $Path) { $Path = if ($IsWindows) { $env:SystemDrive + '\' } else { $HOME } }
    $Path = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Dossier introuvable : $Path" }

    $report = [SysInfo.Storage.DirectorySizer]::Analyze($Path, $Top, $TimeoutSeconds * 1000, [string[]](Get-ExcludedMounts))
    $folders = foreach ($f in $report.Folders | Select-Object -First $Top) {
        , @($f.Path, [Math]::Round($f.Bytes / 1GB, 2), $f.Files, $(if ($report.TotalBytes -gt 0) { [Math]::Round(100 * $f.Bytes / $report.TotalBytes, 1) } else { 0 }))
    }
    $files = foreach ($f in $report.LargestFiles) { , @($f.Path, [Math]::Round($f.Bytes / 1GB, 2)) }

    $subtitle = '{0} · {1} dans {2} fichier(s)' -f $Path, (Format-Bytes $report.TotalBytes), $report.TotalFiles.ToString('#,##0', $script:Fr)
    $findings = @()
    if ($report.TimedOut) {
        $subtitle += ' · résultat partiel'
        $findings += New-Finding 'info' 'STO-SCAN-PARTIAL' ("Analyse arrêtée après $TimeoutSeconds s : les tailles sont sous-estimées") 'Relancer sur un sous-dossier, ou avec un délai plus long.'
    }
    [PSCustomObject]@{
        Subtitle = $subtitle
        Sections = @(
            [PSCustomObject]@{ Title = 'Plus gros dossiers'; Type = 'Table'; Icon = 'hard_drive'; Columns = @('Dossier', 'Taille (GiB)', 'Fichiers', 'Part (%)'); Rows = @($folders) }
            [PSCustomObject]@{ Title = 'Plus gros fichiers'; Type = 'Table'; Icon = 'search'; Columns = @('Fichier', 'Taille (GiB)'); Rows = @($files) }
        )
        Findings = $findings
    }
}

# storage_get_reclaimable_space : estimation de l'espace libérable par catégorie, sans rien supprimer.
# Windows : Temp (utilisateur, Windows), corbeille de l'utilisateur, cache Windows Update, journaux CBS, miniatures,
#           caches des navigateurs, vidages mémoire.
# Linux   : /tmp, /var/tmp, corbeille, ~/.cache, cache des paquets (dnf, apt, pacman), journal systemd,
#           Docker (docker system df), Flatpak inutilisés non comptés.
function Get-SIReclaimableSpace {
    param([ValidateRange(5, 120)][int]$TimeoutSeconds = 30)
    $budget = [System.Diagnostics.Stopwatch]::StartNew()
    $left = { [Math]::Max(500, $TimeoutSeconds * 1000 - $budget.ElapsedMilliseconds) }
    $size = { param([string]$Path) [SysInfo.Storage.DirectorySizer]::Size($Path, (& $left)) }

    $rows = [System.Collections.Generic.List[object]]::new()
    # Sous 10 MiB : sans intérêt, la ligne est omise.
    $add = { param($Category, $Bytes, $Where, $How) if ($Bytes -ge 10MB) { $rows.Add(@($Category, [Math]::Round($Bytes / 1GB, 2), $Where, $How)) } }

    if ($IsWindows) {
        $local = $env:LOCALAPPDATA
        & $add 'Fichiers temporaires (utilisateur)' (& $size $env:TEMP) $env:TEMP 'Nettoyage de disque, ou supprimer le contenu'
        & $add 'Fichiers temporaires (Windows)' (& $size "$env:WINDIR\Temp") "$env:WINDIR\Temp" 'Nettoyage de disque (administrateur)'
        $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $bins = Get-PSDrive -PSProvider FileSystem | ForEach-Object { Join-Path $_.Root "`$Recycle.Bin\$sid" }
        & $add 'Corbeille' (($bins | ForEach-Object { & $size $_ } | Measure-Object -Sum).Sum) 'Corbeille' 'Vider la corbeille'
        & $add 'Cache Windows Update' (& $size "$env:WINDIR\SoftwareDistribution\Download") "$env:WINDIR\SoftwareDistribution\Download" 'Nettoyage de disque › Nettoyage de Windows Update'
        & $add 'Journaux de maintenance (CBS)' (& $size "$env:WINDIR\Logs\CBS") "$env:WINDIR\Logs\CBS" 'Nettoyage de disque (administrateur)'
        & $add 'Vidages mémoire' ((& $size "$env:WINDIR\Minidump") + $(if (Test-Path "$env:WINDIR\MEMORY.DMP") { (Get-Item "$env:WINDIR\MEMORY.DMP").Length } else { 0 })) "$env:WINDIR\Minidump, MEMORY.DMP" 'Garder si un écran bleu est en cours d''analyse'
        & $add 'Miniatures' ((Get-ChildItem "$local\Microsoft\Windows\Explorer" -Filter 'thumbcache_*.db' -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum) "$local\Microsoft\Windows\Explorer" 'Nettoyage de disque › Miniatures'
        foreach ($browser in @(@('Chrome', "$local\Google\Chrome\User Data\Default\Cache"), @('Edge', "$local\Microsoft\Edge\User Data\Default\Cache"), @('Firefox', "$local\Mozilla\Firefox\Profiles"))) {
            & $add "Cache $($browser[0])" (& $size $browser[1]) $browser[1] 'Effacer le cache depuis le navigateur'
        }
    }
    else {
        & $add 'Fichiers temporaires' ((& $size '/tmp') + (& $size '/var/tmp')) '/tmp, /var/tmp' 'Vidés au redémarrage (/tmp) ou par systemd-tmpfiles'
        & $add 'Corbeille' (& $size "$HOME/.local/share/Trash") "$HOME/.local/share/Trash" 'Vider la corbeille'
        & $add 'Cache utilisateur' (& $size "$HOME/.cache") "$HOME/.cache" 'Supprimable : les applications le recréent'
        foreach ($pkg in @(@('dnf', '/var/cache/dnf', 'sudo dnf clean all'), @('apt', '/var/cache/apt/archives', 'sudo apt clean'), @('pacman', '/var/cache/pacman/pkg', 'sudo paccache -r'))) {
            & $add "Cache des paquets ($($pkg[0]))" (& $size $pkg[1]) $pkg[1] $pkg[2]
        }
        $journal = Invoke-Tool journalctl @('--disk-usage') | Select-Object -First 1
        if ($journal -match 'take up ([\d.]+)([KMGT])') {
            $bytes = [double]::Parse($Matches[1], [cultureinfo]::InvariantCulture) * @{ K = 1KB; M = 1MB; G = 1GB; T = 1TB }[$Matches[2]]
            & $add 'Journal systemd' $bytes '/var/log/journal' 'sudo journalctl --vacuum-time=4weeks (garder l''historique récent)'
        }
        foreach ($line in Invoke-Tool docker @('system', 'df', '--format', '{{json .}}')) {
            $d = $line | ConvertFrom-Json
            if ($d.Reclaimable -match '^([\d.]+)([kMGT]?B)') {
                $bytes = [double]::Parse($Matches[1], [cultureinfo]::InvariantCulture) * @{ B = 1; kB = 1e3; MB = 1e6; GB = 1e9; TB = 1e12 }[$Matches[2]]
                & $add "Docker : $($d.Type)" $bytes 'docker system df' 'docker system prune (vérifier avant : supprime images et volumes inutilisés)'
            }
        }
    }

    $total = ($rows | ForEach-Object { $_[1] } | Measure-Object -Sum).Sum
    $sorted = $rows | Sort-Object { $_[1] } -Descending
    $findings = @()
    if ($total -ge 10) {
        $findings += New-Finding 'info' 'STO-RECLAIMABLE' ('{0} GiB récupérables (temporaires, caches, corbeille…)' -f ([double]$total).ToString('0.#', $script:Fr)) `
            'Les actions de nettoyage du module Maintenance (à venir) les libéreront avec confirmation.'
    }
    [PSCustomObject]@{
        Subtitle = 'Environ {0} GiB récupérables · estimation, rien n''est supprimé' -f ([double]$total).ToString('0.##', $script:Fr)
        Sections = @([PSCustomObject]@{ Title = 'Espace récupérable'; Type = 'Table'; Icon = 'hard_drive'; Columns = @('Catégorie', 'Taille (GiB)', 'Emplacement', 'Comment libérer'); Rows = @($sorted) })
        Findings = $findings
    }
}

#endregion

Export-ModuleMember -Function Get-ModuleData, Get-SISpaceUsage, Get-SIReclaimableSpace
