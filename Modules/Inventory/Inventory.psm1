# Module Inventaire : fiche machine en un appel (fabricant, modèle, n° de série, processeur, mémoire, disques, carte
# graphique, système, réseau, utilisateurs), garantie (lien vers le site du fabricant), capacités d'évolution (mémoire,
# emplacements), compatibilité Windows 11, étiquette d'inventaire avec QR code.
#
# Sources
#   Windows : CIM Win32_ComputerSystem, Win32_BIOS, Win32_SystemEnclosure, Win32_Processor, Win32_PhysicalMemory,
#             Win32_PhysicalMemoryArray, Win32_SystemSlot, Win32_VideoController, Win32_OperatingSystem, MSFT_PhysicalDisk,
#             tpmtool (TPM), Confirm-SecureBootUEFI ; en cache 1 h (ce qui change rarement).
#   Linux   : /sys/class/dmi/id (n° de série : root), udev (barrettes mémoire : MEMORY_DEVICE_*, sans root),
#             /proc/cpuinfo, /sys/block, lspci, /etc/os-release, /sys/class/tpm, /sys/firmware/efi, mokutil, dmidecode
#             (emplacements, root).
#   Partout : NetworkInterface (.NET) pour les adresses ; [SysInfo.Native.QrCode] pour l'étiquette.
# Les fiches de garantie ne sont pas interrogées en ligne : SysInfo donne le lien du fabricant.

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

function Format-Bytes([double]$Bytes) {
    if ($Bytes -ge 1TB) { return Format-Unit ($Bytes / 1TB) 'TiB' '0.#' }
    if ($Bytes -ge 1GB) { return Format-Unit ($Bytes / 1GB) 'GiB' '0' }
    Format-Unit ($Bytes / 1MB) 'MiB' '0'
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

function New-Change([string]$Target, [string]$Property, $Before, $After) {
    [PSCustomObject]@{ Target = $Target; Property = $Property; Before = $Before; After = $After }
}

# Valeur DMI de remplissage (« To be filled by O.E.M. », « Default string », « System Serial Number »…) = inconnue.
function Get-RealValue([string]$Value) {
    if (-not $Value) { return $null }
    $v = $Value.Trim()
    if ($v -match '(?i)^(to be filled|default string|system (serial number|product name|manufacturer)|not specified|not applicable|none|n/a|0+|1234567890|chassis serial number|o\.e\.m\.?|base board serial number|\s*)$|to be filled by o\.e\.m') { return $null }
    $v
}

# Dossier des exports : Documents/SysInfo/Exports (jamais un fichier écrasé).
function Get-ExportDir { Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'SysInfo/Exports' }

#endregion

#region Fiche machine

$script:ChassisTypes = @{ 3 = 'Ordinateur de bureau'; 4 = 'Ordinateur de bureau'; 5 = 'Ordinateur de bureau'; 6 = 'Mini-tour'; 7 = 'Tour'; 8 = 'Portable'; 9 = 'Portable'; 10 = 'Portable'
    11 = 'Appareil de poche'; 12 = 'Station d''accueil'; 13 = 'Tout-en-un'; 14 = 'Portable'; 15 = 'Ordinateur compact'; 16 = 'Valise'; 17 = 'Serveur'; 23 = 'Serveur en baie'
    30 = 'Tablette'; 31 = 'Convertible'; 32 = 'Détachable'; 35 = 'Mini PC'; 36 = 'Clé PC' }

function Get-MachineFacts {
    Get-Cached 'machine' 3600 {
        $f = [ordered]@{ Manufacturer = $null; Model = $null; Serial = $null; SerialDenied = $false; Board = $null; Bios = $null; BiosDate = $null; Chassis = $null; Virtual = $false
            Cpu = $null; Cores = $null; Threads = [Environment]::ProcessorCount; CpuGHz = $null; Ram = $null; Slots = @(); SlotsTotal = $null; RamMax = $null
            Disks = @(); Gpus = @(); Os = $null; OsVersion = $null; Build = $null; InstallDate = $null; Arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
            Host = [Environment]::MachineName; Domain = $null; Users = @(); ExpansionSlots = @(); SlotsDenied = $false }
        if ($IsWindows) {
            $cs = Get-CimInstance Win32_ComputerSystem; $bios = Get-CimInstance Win32_BIOS; $enc = Get-CimInstance Win32_SystemEnclosure | Select-Object -First 1
            $board = Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue | Select-Object -First 1
            $f.Manufacturer = Get-RealValue $cs.Manufacturer; $f.Model = Get-RealValue $cs.Model
            $f.Serial = (Get-RealValue $bios.SerialNumber) ?? (Get-RealValue $enc.SerialNumber)
            $f.Board = ('{0} {1}' -f $board.Manufacturer, $board.Product).Trim()
            $f.Bios = '{0} {1}' -f $bios.Manufacturer, $bios.SMBIOSBIOSVersion; $f.BiosDate = $bios.ReleaseDate
            $f.Chassis = $script:ChassisTypes[[int]@($enc.ChassisTypes)[0]] ?? 'Autre'
            $f.Virtual = "$($cs.Model) $($cs.Manufacturer)" -match '(?i)virtual|vmware|kvm|qemu|hyper-v|xen|virtualbox|parallels'
            $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
            $f.Cpu = $cpu.Name.Trim(); $f.Cores = (Get-CimInstance Win32_Processor | Measure-Object NumberOfCores -Sum).Sum; $f.CpuGHz = $cpu.MaxClockSpeed / 1000
            $mem = @(Get-CimInstance Win32_PhysicalMemory)
            $f.Ram = ($mem | Measure-Object Capacity -Sum).Sum
            $f.Slots = @($mem | ForEach-Object { [PSCustomObject]@{ Slot = $_.DeviceLocator; Size = [double]$_.Capacity; Speed = $_.ConfiguredClockSpeed ?? $_.Speed; Maker = Get-RealValue $_.Manufacturer; Part = (Get-RealValue $_.PartNumber) } })
            $array = Get-CimInstance Win32_PhysicalMemoryArray | Select-Object -First 1
            $f.SlotsTotal = $array.MemoryDevices; $f.RamMax = if ($array.MaxCapacityEx) { [double]$array.MaxCapacityEx * 1KB } elseif ($array.MaxCapacity) { [double]$array.MaxCapacity * 1KB } else { $null }
            $f.ExpansionSlots = @(Get-CimInstance Win32_SystemSlot -ErrorAction SilentlyContinue | ForEach-Object { [PSCustomObject]@{ Name = $_.SlotDesignation; Type = "$($_.ConnectorType)"; Used = $_.CurrentUsage -eq 4; Free = $_.CurrentUsage -eq 3 } })
            $f.Disks = @(Get-CimInstance -Namespace root/Microsoft/Windows/Storage -ClassName MSFT_PhysicalDisk -ErrorAction SilentlyContinue | ForEach-Object {
                    [PSCustomObject]@{ Model = $_.FriendlyName; Size = [double]$_.Size; Kind = @{ 3 = 'HDD'; 4 = 'SSD'; 5 = 'SCM' }[[int]$_.MediaType] ?? '—'; Bus = @{ 7 = 'USB'; 8 = 'RAID'; 11 = 'SATA'; 17 = 'NVMe'; 10 = 'SAS'; 6 = 'Fibre' }[[int]$_.BusType] ?? "$($_.BusType)"; Serial = $_.SerialNumber.Trim() } })
            $f.Gpus = @(Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Remote|Basic Display|Mirror' } | ForEach-Object Name)
            $os = Get-CimInstance Win32_OperatingSystem
            $f.Os = $os.Caption; $f.OsVersion = $os.Version; $f.Build = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).DisplayVersion; $f.InstallDate = $os.InstallDate
            $f.Domain = if ($cs.PartOfDomain) { "domaine $($cs.Domain)" } else { "groupe de travail $($cs.Workgroup)" }
            $f.Users = @(Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue | Where-Object Name -notin 'Public', 'Default', 'Default User', 'All Users' | Sort-Object LastWriteTime -Descending | ForEach-Object Name)
            if ($cs.UserName) { $f.Users = @(($cs.UserName -split '\\')[-1]) + @($f.Users | Where-Object { $_ -ne ($cs.UserName -split '\\')[-1] }) }
        }
        else {
            $dmi = { param($n) Get-RealValue (Read-Text "/sys/class/dmi/id/$n") }
            $f.Manufacturer = & $dmi 'sys_vendor'; $f.Model = (@((& $dmi 'product_name'), (& $dmi 'product_version')) | Where-Object { $_ }) -join ' '
            $f.Serial = & $dmi 'product_serial'
            if (-not $f.Serial) { $f.Serial = & $dmi 'board_serial' }
            $f.SerialDenied = -not $f.Serial -and -not [Environment]::IsPrivilegedProcess -and (Test-Path /sys/class/dmi/id/product_serial)
            $f.Board = ('{0} {1}' -f (& $dmi 'board_vendor'), (& $dmi 'board_name')).Trim()
            $f.Bios = ('{0} {1}' -f (& $dmi 'bios_vendor'), (& $dmi 'bios_version')).Trim()
            $date = Read-Text /sys/class/dmi/id/bios_date
            if ($date) { $d = [datetime]::MinValue; if ([datetime]::TryParseExact($date, 'MM/dd/yyyy', [cultureinfo]::InvariantCulture, 'None', [ref]$d)) { $f.BiosDate = $d } }
            $f.Chassis = $script:ChassisTypes[[int](Read-Text /sys/class/dmi/id/chassis_type)] ?? 'Autre'
            $f.Virtual = "$(Invoke-Tool systemd-detect-virt @('--vm'))".Trim() -notin '', 'none'
            $info = [System.IO.File]::ReadAllText('/proc/cpuinfo')
            $f.Cpu = if ($info -match '(?m)^model name\s*:\s*(.+)$') { $Matches[1].Trim() } elseif ($info -match '(?m)^Model\s*:\s*(.+)$') { $Matches[1].Trim() } else { $null }
            $cores = @([regex]::Matches($info, '(?m)^physical id\s*:\s*(\d+)\s*$') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique).Count
            $perSocket = if ($info -match '(?m)^cpu cores\s*:\s*(\d+)') { [int]$Matches[1] } else { $null }
            $f.Cores = if ($perSocket) { $perSocket * [Math]::Max(1, $cores) } else { $null }
            $max = Read-Text /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq
            if ($max) { $f.CpuGHz = [double]$max / 1e6 }
            if ([System.IO.File]::ReadAllText('/proc/meminfo') -match 'MemTotal:\s+(\d+)') { $f.Ram = [double]$Matches[1] * 1KB }
            # Barrettes : udev lit la table SMBIOS au démarrage et l'expose sans droits (MEMORY_DEVICE_<n>_…).
            $props = @{}
            foreach ($line in Invoke-Tool udevadm @('info', '-q', 'property', '-p', '/sys/devices/virtual/dmi/id')) { $i = $line.IndexOf('='); if ($i -gt 0) { $props[$line.Substring(0, $i)] = $line.Substring($i + 1) } }
            if ($props.MEMORY_ARRAY_MAX_CAPACITY) { $f.RamMax = [double]$props.MEMORY_ARRAY_MAX_CAPACITY }
            $count = [int]($props.MEMORY_ARRAY_NUM_DEVICES ?? 0)
            if (-not $count) { $count = @($props.Keys | Where-Object { $_ -match '^MEMORY_DEVICE_(\d+)_LOCATOR$' }).Count }
            $f.SlotsTotal = if ($count) { $count } else { $null }
            $f.Slots = @(for ($n = 0; $n -lt $count; $n++) {
                    $size = $props["MEMORY_DEVICE_$($n)_SIZE"]
                    if ($props["MEMORY_DEVICE_$($n)_PRESENT"] -eq '0' -or -not $size) { continue }
                    [PSCustomObject]@{ Slot = $props["MEMORY_DEVICE_$($n)_LOCATOR"]; Size = [double]$size; Speed = $props["MEMORY_DEVICE_$($n)_CONFIGURED_SPEED_MTS"] ?? $props["MEMORY_DEVICE_$($n)_SPEED_MTS"]
                        Maker = Get-RealValue $props["MEMORY_DEVICE_$($n)_MANUFACTURER"]; Part = Get-RealValue $props["MEMORY_DEVICE_$($n)_PART_NUMBER"] }
                })
            if ([Environment]::IsPrivilegedProcess -and (Test-Tool dmidecode)) {
                $cur = $null
                $f.ExpansionSlots = @(foreach ($line in Invoke-Tool dmidecode @('-t', '9')) {
                        if ($line -match '^\s*Designation:\s*(.+)$') { $cur = @{ Name = $Matches[1].Trim() } }
                        elseif ($cur -and $line -match '^\s*Type:\s*(.+)$') { $cur.Type = $Matches[1].Trim() }
                        elseif ($cur -and $line -match '^\s*Current Usage:\s*(.+)$') { [PSCustomObject]@{ Name = $cur.Name; Type = $cur.Type; Used = $Matches[1] -match 'In Use'; Free = $Matches[1] -match 'Available' }; $cur = $null }
                    })
            }
            else { $f.SlotsDenied = $true }
            $f.Disks = @(foreach ($b in [System.IO.Directory]::GetDirectories('/sys/block')) {
                    $name = [System.IO.Path]::GetFileName($b)
                    if ($name -match '^(loop|ram|zram|dm-|md|sr)' -or -not (Test-Path "$b/device")) { continue }
                    $path = (Get-Item -LiteralPath $b).Target ?? $b
                    $bus = if ($name -like 'nvme*') { 'NVMe' } elseif ("$path" -match '/usb') { 'USB' } elseif ("$path" -match '/ata') { 'SATA' } else { '—' }
                    [PSCustomObject]@{ Model = (Read-Text "$b/device/model") ?? $name; Size = [double](Read-Text "$b/size") * 512; Kind = if ((Read-Text "$b/queue/rotational") -eq '1' -and $bus -ne 'USB') { 'HDD' } elseif ($bus -eq 'USB') { 'clé / disque USB' } else { 'SSD' }; Bus = $bus; Serial = Read-Text "$b/device/serial" }
                })
            $f.Gpus = @(Invoke-Tool lspci @('-mm') | Where-Object { $_ -match '"(VGA compatible controller|3D controller|Display controller)"' } | ForEach-Object {
                    $p = [regex]::Matches($_, '"([^"]*)"') | ForEach-Object { $_.Groups[1].Value }
                    '{0} {1}' -f ($p[1] -replace ' Corporation| Inc\.|, Inc\.| \[AMD/ATI\]', ''), $p[2] })
            $osr = @{}
            foreach ($line in [System.IO.File]::ReadAllLines('/etc/os-release')) { if ($line -match '^(\w+)=(.*)$') { $osr[$Matches[1]] = $Matches[2].Trim('"') } }
            $f.Os = $osr.PRETTY_NAME; $f.OsVersion = Read-Text /proc/sys/kernel/osrelease; $f.Build = $osr.VERSION_ID
            # Installation : création des plus anciens fichiers écrits par l'installateur (/etc/hostname, /etc/machine-id),
            # sinon le journal de l'installateur Debian / Ubuntu.
            $dates = foreach ($p in '/etc/hostname', '/etc/machine-id', '/var/log/installer/syslog', '/etc/fstab') {
                $item = Get-Item -LiteralPath $p -ErrorAction SilentlyContinue
                if ($item) { @($item.CreationTime, $item.LastWriteTime) | Where-Object { $_.Year -gt 2000 } }
            }
            $f.InstallDate = $dates | Sort-Object | Select-Object -First 1
            $f.Domain = "$(Invoke-Tool realm @('list') | Select-Object -First 1)".Trim()
            if (-not $f.Domain) { $f.Domain = 'aucun domaine' }
            $f.Users = @([System.IO.File]::ReadAllLines('/etc/passwd') | ForEach-Object { $p = $_ -split ':'; if ([int]$p[2] -ge 1000 -and [int]$p[2] -lt 60000 -and $p[6] -notmatch 'nologin|false') { $p[0] } })
            $me = [Environment]::UserName
            if ($f.Users -contains $me) { $f.Users = @($me) + @($f.Users | Where-Object { $_ -ne $me }) }
        }
        [PSCustomObject]$f
    }
}

# Interfaces physiques : nom, type, MAC, IPv4 (la connexion principale d'abord : celle qui a une passerelle).
function Get-NetworkFacts {
    Get-Cached 'network' 300 {
        $list = foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($nic.NetworkInterfaceType -in 'Loopback', 'Tunnel') { continue }
            if ($IsLinux -and -not (Test-Path "/sys/class/net/$($nic.Name)/device")) { continue }
            if ($IsWindows -and $nic.Description -match '(?i)virtual|hyper-v|vpn|loopback|bluetooth|wan miniport|tap-') { continue }
            $props = $nic.GetIPProperties()
            $ip = ($props.UnicastAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1).Address
            $mac = ($nic.GetPhysicalAddress().GetAddressBytes() | ForEach-Object { $_.ToString('X2') }) -join ':'
            [PSCustomObject]@{ Name = $nic.Name; Type = if ($nic.NetworkInterfaceType -eq 'Wireless80211' -or (Test-Path "/sys/class/net/$($nic.Name)/wireless")) { 'Wi-Fi' } else { 'Ethernet' }
                Mac = $mac; Ip = "$ip"; Up = $nic.OperationalStatus -eq 'Up'; Primary = [bool]($props.GatewayAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' }) }
        }
        @($list | Sort-Object { -not $_.Primary }, { -not $_.Up }, Name)
    }
}

# Lien de vérification de garantie selon le fabricant (le n° de série est inséré quand le site l'accepte dans l'adresse).
function Get-WarrantyLink([string]$Manufacturer, [string]$Serial) {
    $s = [uri]::EscapeDataString("$Serial")
    switch -Regex ("$Manufacturer") {
        'Dell' { if ($Serial) { "https://www.dell.com/support/home/fr-fr/product-support/servicetag/$s/overview" } else { 'https://www.dell.com/support/home/fr-fr' }; break }
        'Lenovo' { if ($Serial) { "https://pcsupport.lenovo.com/fr/fr/products/$s/warranty" } else { 'https://pcsupport.lenovo.com/fr/fr/warrantylookup' }; break }
        'HP|Hewlett' { 'https://support.hp.com/fr-fr/check-warranty'; break }
        'Microsoft' { 'https://mybusinessservice.surface.com/fr-FR/CheckWarranty/CheckWarranty'; break }
        'Apple' { 'https://checkcoverage.apple.com/fr/fr/'; break }
        'ASUS' { 'https://www.asus.com/fr/support/warranty-status-inquiry/'; break }
        'Acer' { 'https://www.acer.com/fr-fr/support/warranty'; break }
        'Micro-Star|MSI' { 'https://fr.msi.com/support/warranty'; break }
        'Fujitsu' { 'https://support.ts.fujitsu.com/IndexWarranty.asp'; break }
        'Toshiba|Dynabook' { 'https://support.dynabook.com/warranty'; break }
        'Gigabyte' { 'https://www.gigabyte.com/fr/Support'; break }
        default { $null }
    }
}

#endregion

#region Compatibilité Windows 11

# Processeur pris en charge (règle simplifiée de la liste Microsoft) : Intel Core 8e génération et suivantes,
# Core Ultra, AMD Ryzen 2000 et suivants (hors APU Ryzen 2000), Ryzen Threadripper 2000+, EPYC 2e génération+,
# Qualcomm Snapdragon 8cx / X. Le reste : « à vérifier ».
function Test-Win11Cpu([string]$Cpu) {
    if ($Cpu -match '(?i)Core\(TM\)\s*Ultra|Core Ultra') { return $true }
    if ($Cpu -match '(?i)Core\(TM\)\s*i[3579][-\s](\d{4,5})|Core i[3579][-\s](\d{4,5})') {
        $num = $Matches[1] ?? $Matches[2]
        $gen = if ($num.Length -eq 5) { [int]$num.Substring(0, 2) } else { [int]$num.Substring(0, 1) }
        return $gen -ge 8
    }
    if ($Cpu -match '(?i)Ryzen\s+(Threadripper\s+)?\d\s*(PRO\s*)?(\d)(\d)\d\d(\w*)') {
        $series = [int]$Matches[3]
        if ($series -ge 3) { return $true }
        if ($series -eq 2) { return $Matches[5] -notmatch '^G' -and $Matches[4] -ne '2' }   # 2200G/2400G (Zen) non pris en charge
        return $false
    }
    if ($Cpu -match '(?i)Ryzen\s+(AI|Z\d)') { return $true }
    if ($Cpu -match '(?i)Snapdragon.*(8cx|X Elite|X Plus|7c)') { return $true }
    if ($Cpu -match '(?i)Core\(TM\)?\s*2|Pentium\(R\) (Dual|4)|Athlon|Phenom|FX-|A\d+-\d{4}|Celeron\(R\) (N\d{4}|J\d{4})') { return $false }
    $null
}

function Get-Win11Compatibility($Facts) {
    Get-Cached 'win11' 3600 {
        $tpm = $null; $sb = $null
        $uefi = if ($IsWindows) { $env:firmware_type -eq 'UEFI' -or (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State') } else { Test-Path /sys/firmware/efi }
        if ($IsWindows) {
            $out = (Invoke-Tool tpmtool @('getdeviceinformation')) -join "`n"
            if ($out -match '(?i)TPM Version:\s*([\d.]+)|Version du module de plateforme sécurisée\s*:\s*([\d.]+)') { $tpm = [double](($Matches[1] ?? $Matches[2]) -replace ',', '.') }
            elseif ($out -match '(?i)TPM Present:\s*False') { $tpm = 0 }
            $sb = try { Confirm-SecureBootUEFI -ErrorAction Stop } catch { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -ErrorAction SilentlyContinue).UEFISecureBootEnabled -eq 1 }
        }
        else {
            $major = Read-Text /sys/class/tpm/tpm0/tpm_version_major
            $tpm = if ($major) { [double]$major } elseif (Test-Path /sys/class/tpm/tpm0) { 1.2 } else { 0 }
            $state = "$(Invoke-Tool mokutil @('--sb-state') | Select-Object -First 1)"
            $sb = if ($state) { $state -match 'enabled' } else { $null }
        }
        $cpuOk = Test-Win11Cpu $Facts.Cpu
        $system = @($Facts.Disks | Where-Object { $_.Bus -ne 'USB' } | Sort-Object Size -Descending | Select-Object -First 1)
        $checks = @(
            [PSCustomObject]@{ Name = 'Processeur'; Need = 'pris en charge (Intel 8e gén.+, AMD Ryzen 2000+…), 2 cœurs, 1 GHz, 64 bits'; Have = $Facts.Cpu; Ok = $(if ($Facts.Arch -notmatch '64') { $false } else { $cpuOk }) }
            [PSCustomObject]@{ Name = 'Mémoire'; Need = '4 Go'; Have = Format-Bytes $Facts.Ram; Ok = $Facts.Ram -ge 3.8GB }
            [PSCustomObject]@{ Name = 'Stockage'; Need = '64 Go'; Have = if ($system) { Format-Bytes $system[0].Size } else { '—' }; Ok = if ($system) { $system[0].Size -ge 64e9 } else { $null } }
            [PSCustomObject]@{ Name = 'Micrologiciel'; Need = 'UEFI'; Have = if ($uefi) { 'UEFI' } else { 'BIOS (Legacy)' }; Ok = [bool]$uefi }
            [PSCustomObject]@{ Name = 'Démarrage sécurisé'; Need = 'compatible (UEFI)'; Have = if ($null -eq $sb) { '—' } elseif ($sb) { 'activé' } else { 'désactivé (activable)' }; Ok = [bool]$uefi }
            [PSCustomObject]@{ Name = 'TPM'; Need = '2.0'; Have = if ($null -eq $tpm) { 'inconnu' } elseif ($tpm -eq 0) { 'absent ou désactivé' } else { $tpm.ToString('0.0', [cultureinfo]::InvariantCulture) }; Ok = if ($null -eq $tpm) { $null } else { $tpm -ge 2 } }
        )
        [PSCustomObject]@{ Checks = $checks; Compatible = -not ($checks | Where-Object { $_.Ok -eq $false }); Unknown = [bool]($checks | Where-Object { $null -eq $_.Ok }) }
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

    $f = Invoke-Block 'Fiche machine' { Get-MachineFacts }
    $net = @(Invoke-Block 'Réseau' { Get-NetworkFacts })
    $primary = $net | Select-Object -First 1
    if ($f) {
        $serial = if ($f.Serial) { $f.Serial } elseif ($f.SerialDenied) { 'lisible en root (sudo)' } else { 'non renseigné par le fabricant' }
        $items = [ordered]@{
            'Nom' = $f.Host; 'Type' = if ($f.Virtual) { 'Machine virtuelle' } else { $f.Chassis }
            'Fabricant' = $f.Manufacturer ?? '—'; 'Modèle' = $f.Model ?? '—'; 'N° de série' = $serial
            'Carte mère' = $f.Board ?? '—'; 'BIOS / UEFI' = '{0}{1}' -f $f.Bios, $(if ($f.BiosDate) { ' du ' + ([datetime]$f.BiosDate).ToString('d MMM yyyy', $script:Fr) } else { '' })
            'Processeur' = '{0} · {1} cœurs, {2} threads{3}' -f $f.Cpu, ($f.Cores ?? '?'), $f.Threads, $(if ($f.CpuGHz) { ', ' + (Format-Unit $f.CpuGHz 'GHz' '0.0') } else { '' })
            'Mémoire' = if (@($f.Slots).Count) { '{0} ({1} barrette(s))' -f (Format-Bytes ($f.Slots | Measure-Object Size -Sum).Sum), @($f.Slots).Count } else { Format-Bytes $f.Ram }
            'Disques' = (@($f.Disks | ForEach-Object { '{0} ({1}, {2})' -f $_.Model, (Format-Bytes $_.Size), $_.Kind }) -join ' · ')
            'Carte graphique' = ($f.Gpus -join ' · ')
            'Système' = '{0}{1} · {2}' -f $f.Os, $(if ($f.Build -and $f.Os -notmatch [regex]::Escape("$($f.Build)")) { " ($($f.Build))" } else { '' }), $f.OsVersion
            'Installé le' = if ($f.InstallDate) { ([datetime]$f.InstallDate).ToString('d MMMM yyyy', $script:Fr) } else { '—' }
            'Adresse IP' = if ($primary) { "$($primary.Ip) ($($primary.Name))" } else { '—' }
            'Adresse MAC' = if ($primary) { $primary.Mac } else { '—' }
            'Domaine' = $f.Domain
            'Utilisateur principal' = ($f.Users | Select-Object -First 1) ?? '—'
        }
        $sections.Add([PSCustomObject]@{ Title = 'Fiche machine'; Type = 'KeyValue'; Icon = 'desktop'; Items = $items })

        # Garantie
        $link = Get-WarrantyLink $f.Manufacturer $f.Serial
        $w = [ordered]@{ 'Fabricant' = $f.Manufacturer ?? '—'; 'Vérifier la garantie' = $link ?? 'fabricant non reconnu : voir son site d''assistance avec le n° de série' }
        if ($f.BiosDate) { $w['Âge estimé'] = 'BIOS de {0} (la machine a au moins cet âge si le BIOS d''origine n''a pas été mis à jour)' -f ([datetime]$f.BiosDate).ToString('MMMM yyyy', $script:Fr) }
        $sections.Add([PSCustomObject]@{ Title = 'Garantie'; Type = 'KeyValue'; Icon = 'shield_checkmark'; Items = $w })

        # Évolution
        $used = @($f.Slots).Count
        $installed = if ($used) { ($f.Slots | Measure-Object Size -Sum).Sum } else { $f.Ram }
        $ev = [ordered]@{ 'Mémoire installée' = Format-Bytes $installed }
        if ($f.RamMax) { $ev['Mémoire maximale prise en charge'] = Format-Bytes $f.RamMax }
        if ($f.SlotsTotal) { $ev['Emplacements mémoire'] = '{0} occupé(s) sur {1}, {2} libre(s)' -f $used, $f.SlotsTotal, ($f.SlotsTotal - $used) }
        if ($f.ExpansionSlots.Count) { $ev['Emplacements d''extension libres'] = '{0} sur {1}' -f @($f.ExpansionSlots | Where-Object Free).Count, $f.ExpansionSlots.Count }
        elseif ($f.SlotsDenied) { $ev['Emplacements d''extension (PCIe, M.2)'] = 'lisibles en root (dmidecode)' }
        $sections.Add([PSCustomObject]@{ Title = 'Capacités d''évolution'; Type = 'KeyValue'; Icon = 'ram'; Items = $ev })
        if ($used) {
            $sections.Add([PSCustomObject]@{ Title = 'Barrettes mémoire'; Type = 'Table'; Icon = 'ram'; Columns = @('Emplacement', 'Taille (GiB)', 'Vitesse (MT/s)', 'Fabricant', 'Référence')
                    Rows = @($f.Slots | ForEach-Object { , @($_.Slot, [Math]::Round($_.Size / 1GB, 1), $(if ($_.Speed) { [double]$_.Speed } else { $null }), $_.Maker, $_.Part) }) })
        }
        if ($f.ExpansionSlots.Count) {
            $sections.Add([PSCustomObject]@{ Title = 'Emplacements d''extension'; Type = 'Table'; Icon = 'developer_board'; Columns = @('Emplacement', 'Type', 'État')
                    Rows = @($f.ExpansionSlots | ForEach-Object { , @($_.Name, $_.Type, $(if ($_.Used) { 'occupé' } elseif ($_.Free) { 'libre' } else { '—' })) }) })
        }
        if ($f.SlotsTotal -and $used -lt $f.SlotsTotal -and $f.RamMax -and $installed -lt $f.RamMax) {
            $findings.Add((New-Finding 'info' 'INV-RAM-UPGRADABLE' ('Mémoire extensible : {0} emplacement(s) libre(s), jusqu''à {1} au total.' -f ($f.SlotsTotal - $used), (Format-Bytes $f.RamMax)) 'Ajouter une barrette identique (même type, même vitesse) à celles installées.'))
        }
        if ($f.SerialDenied) { $findings.Add((New-Finding 'info' 'INV-SERIAL-DENIED' 'N° de série lisible avec les droits root seulement.' 'Lancer SysInfo avec sudo pour le lire (étiquette d''inventaire, garantie).')) }

        # Windows 11
        $w11 = Invoke-Block 'Windows 11' { Get-Win11Compatibility $f }
        if ($w11) {
            $sections.Add([PSCustomObject]@{ Title = 'Compatibilité Windows 11'; Type = 'Table'; Icon = 'checkmark_circle'; Columns = @('Critère', 'Exigence', 'Cette machine', 'Conforme')
                    Rows = @($w11.Checks | ForEach-Object { , @($_.Name, $_.Need, $_.Have, $(if ($null -eq $_.Ok) { 'à vérifier' } elseif ($_.Ok) { 'oui' } else { 'non' })) }) })
            $missing = @($w11.Checks | Where-Object { $_.Ok -eq $false } | ForEach-Object Name)
            $isWin10 = $IsWindows -and $f.Os -match 'Windows 10'
            if ($missing) {
                $findings.Add((New-Finding $(if ($isWin10) { 'warning' } else { 'info' }) 'INV-WIN11-INCOMPATIBLE' ("Incompatible avec Windows 11 : {0}." -f ($missing -join ', ')) $(if ($isWin10) { 'Windows 10 n''a plus de mises à jour de sécurité gratuites depuis octobre 2025 : prévoir le remplacement (ou ESU), sauf si un réglage du BIOS suffit (TPM, UEFI).' } else { 'Si un réglage manque (TPM, UEFI), il s''active souvent dans le BIOS.' })))
            }
            elseif ($isWin10) { $findings.Add((New-Finding 'warning' 'INV-WIN10' 'Windows 10 n''a plus de mises à jour de sécurité gratuites depuis octobre 2025, et cette machine est compatible Windows 11.' 'Passer à Windows 11 (Windows Update ou Assistant d''installation).')) }
        }
    }

    if ($net.Count) {
        $sections.Add([PSCustomObject]@{ Title = 'Cartes réseau'; Type = 'Table'; Icon = 'router'; Columns = @('Interface', 'Type', 'Adresse MAC', 'Adresse IPv4', 'État')
                Rows = @($net | ForEach-Object { , @($_.Name, $_.Type, $_.Mac, $_.Ip, $(if ($_.Primary) { 'connexion principale' } elseif ($_.Up) { 'active' } else { 'inactive' })) }) })
    }
    if ($f.Users.Count) { $sections.Add([PSCustomObject]@{ Title = 'Comptes utilisateurs'; Type = 'KeyValue'; Icon = 'info'; Items = [ordered]@{ 'Comptes' = $f.Users -join ', ' } }) }
    if ($errors.Count) { $sections.Add([PSCustomObject]@{ Title = 'Erreurs de collecte'; Type = 'KeyValue'; Icon = 'error_circle'; Items = $errors }) }

    $model = (@($f.Manufacturer, $f.Model) | Where-Object { $_ }) -join ' '
    $parts = @($f.Host, $model)
    if ($f.Serial) { $parts += "n° $($f.Serial)" }
    [PSCustomObject]@{ Subtitle = ($parts | Where-Object { $_ }) -join ' · '; Sections = $sections.ToArray(); Findings = $findings.ToArray() }
}

#endregion

#region Fonctions ciblées

# inventory_create_label : étiquette d'inventaire (SVG imprimable) avec QR code, dans Documents/SysInfo/Exports.
function New-SIInventoryLabel {
    param([string]$AssetTag, [string]$Owner, [switch]$DryRun)
    $f = Get-MachineFacts
    $primary = Get-NetworkFacts | Select-Object -First 1
    $blocked = $null
    if (-not ('SysInfo.Native.QrCode' -as [type])) { $blocked = "L'étiquette (QR code) n'est disponible que dans SysInfo (classe de l'application)." }
    $lines = [ordered]@{ 'Machine' = $f.Host; 'Modèle' = (@($f.Manufacturer, $f.Model) | Where-Object { $_ }) -join ' '; 'N° de série' = $f.Serial ?? '—' }
    if ($AssetTag) { $lines['N° d''inventaire'] = $AssetTag }
    if ($Owner) { $lines['Attribué à'] = $Owner }
    $lines['MAC'] = $primary.Mac
    $lines['Relevé le'] = (Get-Date).ToString('d MMMM yyyy', $script:Fr)
    # Contenu du QR code : texte simple lisible par n'importe quel lecteur.
    $qrText = (@("SYSINFO", "HOST:$($f.Host)", "MODEL:$($lines['Modèle'])", "SN:$($f.Serial)", "MAC:$($primary.Mac)") + $(if ($AssetTag) { "TAG:$AssetTag" }) + $(if ($Owner) { "OWNER:$Owner" })) -join "`n"
    if ([System.Text.Encoding]::UTF8.GetByteCount($qrText) -gt 200) { $blocked = 'Texte de l''étiquette trop long pour le QR code : raccourcir le n° d''inventaire ou le nom.' }

    $dir = Get-ExportDir
    $name = 'etiquette-{0}-{1:yyyyMMdd-HHmmss}.svg' -f ($f.Host -replace '[^\w.-]', '_'), (Get-Date)
    $path = Join-Path $dir $name
    $section = [PSCustomObject]@{ Title = 'Étiquette'; Type = 'KeyValue'; Icon = 'desktop'; Items = $lines }
    $findings = @()
    if (-not $f.Serial) { $findings += New-Finding 'info' 'INV-LABEL-NO-SERIAL' "Pas de n° de série sur l'étiquette$(if ($f.SerialDenied) { ' (lisible en root : relancer SysInfo avec sudo)' })." $null }
    $change = New-Change $path 'Fichier' 'absent' 'étiquette SVG créée'
    if ($DryRun -or $blocked) { return [PSCustomObject]@{ Subtitle = "Étiquette créée dans $dir"; Sections = @($section); Findings = $findings; Changes = @($change); Blocked = $blocked } }

    $qr = [SysInfo.Native.QrCode]::Encode($qrText)
    $esc = { param($t) [System.Security.SecurityElement]::Escape("$t") }
    $text = [System.Text.StringBuilder]::new()
    $y = 34
    foreach ($k in $lines.Keys) {
        [void]$text.Append(('<text x="186" y="{0}" font-size="11" fill="#555">{1}</text><text x="186" y="{2}" font-size="14" font-weight="600">{3}</text>' -f $y, (& $esc $k), ($y + 16), (& $esc $lines[$k])))
        $y += 36
    }
    $height = [Math]::Max(190, $y)
    $svg = @"
<svg xmlns="http://www.w3.org/2000/svg" width="560" height="$height" viewBox="0 0 560 $height" font-family="Segoe UI, Cantarell, Arial, sans-serif">
<rect x="1" y="1" width="558" height="$($height - 2)" rx="10" fill="#fff" stroke="#222" stroke-width="2"/>
<g transform="translate(12,15)">$($qr.ToSvg(160) -replace '^<svg ', '<svg x="0" y="0" ')</g>
$text
</svg>
"@
    [void][System.IO.Directory]::CreateDirectory($dir)
    [System.IO.File]::WriteAllText($path, $svg)
    [PSCustomObject]@{ Subtitle = "Étiquette créée : $path"; Sections = @($section); Findings = @(New-Finding 'info' 'INV-LABEL-PRINT' "Ouvrir le fichier dans un navigateur pour l'imprimer (format 56 × $([Math]::Round($height / 10)) mm à l'échelle 1:10)." $null); Changes = @(New-Change $path 'Fichier' 'absent' 'étiquette SVG créée'); Blocked = $null }
}

#endregion

Export-ModuleMember -Function Get-ModuleData, New-SIInventoryLabel
