# Module Stockage : disques, partitions, SMART, volumes, espace disponible, erreurs.
#
# Sources
#   Windows : Get-Volume, Get-PhysicalDisk, Get-Disk, Get-Partition, Get-StorageReliabilityCounter (SMART, souvent
#             réservé aux administrateurs), Win32_PerfFormattedData_PerfDisk_PhysicalDisk (activité),
#             journal Système (disk, Ntfs, volmgr, stornvme, storahci).
#   Linux   : lsblk et findmnt (JSON), /proc/diskstats (activité), udisks par D-Bus via busctl (SMART sans droits
#             root : NVMe.Controller.SmartGetAttributes, Drive.Ata), /sys/fs/btrfs et /sys/fs/ext4 (compteurs
#             d'erreurs), journalctl -k (erreurs du noyau).
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
        return Get-PhysicalDisk -ErrorAction SilentlyContinue | Sort-Object DeviceId | ForEach-Object {
            [PSCustomObject]@{
                Name = "Disque $($_.DeviceId)"; Device = $_; Model = $_.FriendlyName; Serial = "$($_.SerialNumber)".Trim()
                Kind = '{0} {1}' -f $_.MediaType, $_.BusType; Size = [double]$_.Size; Removable = $_.BusType -eq 'USB'
                Health = "$($_.HealthStatus)"
            }
        }
    }
    $json = (Invoke-Tool lsblk @('-J', '-b', '-d', '-e', '7,251', '-o', 'NAME,TYPE,SIZE,MODEL,SERIAL,TRAN,ROTA,RM,VENDOR')) -join ''
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
            }
        }
    }
    $json = (Invoke-Tool lsblk @('-J', '-b', '-e', '7,251', '-o', 'NAME,TYPE,SIZE,FSTYPE,LABEL,MOUNTPOINTS,PKNAME,PARTTYPENAME')) -join ''
    if (-not $json) { return @() }
    foreach ($disk in ($json | ConvertFrom-Json).blockdevices) {
        foreach ($part in @($disk.children | Where-Object type -eq 'part')) {
            [PSCustomObject]@{
                Name = $part.name; Disk = $disk.name; Size = [double]$part.size; FsType = $part.fstype; Label = $part.label
                Mount = (@($part.mountpoints | Where-Object { $_ }) -join ', '); Role = $part.parttypename
            }
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
            , @($d.Name, $d.Model, $d.Kind, (Format-Capacity $d.Size), (Get-SmartState $s),
                $(if ($s -and $null -ne $s.Temperature) { [Math]::Round($s.Temperature) } else { $null }),
                $(if ($s) { $s.Wear } else { $null }), $(if ($s) { $s.Hours } else { $null }))
        }
        $sections.Add([PSCustomObject]@{
                Title = 'Disques physiques'; Type = 'Table'; Icon = 'hard_drive'
                Columns = @('Disque', 'Modèle', 'Type', 'Capacité', 'État SMART', 'Température (°C)', 'Usure (%)', 'Heures')
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

    # Partitions
    Invoke-Block 'Partitions' {
        $partitions = @(Get-Partitions)
        if ($partitions.Count -gt 0) {
            $rows = foreach ($p in $partitions) {
                , @($p.Name, $p.Disk, [Math]::Round($p.Size / 1GB, 1), $p.FsType, $p.Label, $(if ($p.Mount) { $p.Mount } else { $null }), $p.Role)
            }
            $sections.Add([PSCustomObject]@{
                    Title = 'Partitions'; Type = 'Table'; Icon = 'board'
                    Columns = @('Partition', 'Disque', 'Taille (GiB)', 'Système de fichiers', 'Étiquette', 'Montage', 'Rôle')
                    Rows = @($rows)
                })
        }
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

Export-ModuleMember -Function Get-ModuleData
