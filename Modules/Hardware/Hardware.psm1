# Module Matériel : carte mère, BIOS/UEFI, TPM, GPU, écrans, audio, USB/Bluetooth, RAM, pilotes,
# périphériques en erreur.
#
# Sources
#   Windows : CIM (Win32_BaseBoard, Win32_ComputerSystem, Win32_BIOS, Win32_VideoController,
#             Win32_PhysicalMemory, Win32_PhysicalMemoryArray, Win32_PnPSignedDriver, Win32_PnPEntity, Win32_Tpm,
#             root/wmi WmiMonitorID + WmiMonitorBasicDisplayParams + WmiMonitorConnectionParams),
#             Get-PnpDevice (AudioEndpoint, Bluetooth, SecurityDevices), registre (SecureBoot\State,
#             classe Display : HardwareInformation.qwMemorySize), nvidia-smi.
#   Linux   : /sys/class/dmi/id, /sys/firmware/efi, /sys/class/tpm, /sys/class/drm (connecteurs, EDID, modes),
#             udev (udevadm info : barrettes mémoire sans droits root, sinon dmidecode en root),
#             lspci + /sys/bus/pci/devices (pilotes), /sys/module (versions, taint), /sys/bus/usb/devices,
#             pactl (PipeWire / PulseAudio) ou /proc/asound, bluetoothctl, nvidia-smi (NVIDIA) ou /sys/class/drm (AMD).
#
# Les infos fixes (carte mère, BIOS, RAM, cartes graphiques, pilotes sous Windows) sont lues au premier appel
# puis gardées dans $script: ; chaque rafraîchissement relit seulement le GPU et les périphériques en erreur.

$script:Fr = [cultureinfo]::GetCultureInfo('fr-FR')
$script:Nbsp = [char]0x00A0
$script:Static = $null

# Seuils (design system) : température 80 / 90 °C ; mémoire vidéo 90 / 95 %.
$script:TempWarning = 80; $script:TempCritical = 90
$script:VramWarning = 0.90; $script:VramCritical = 0.95


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

function Format-GiB([double]$Bytes) { Format-Unit ($Bytes / 1GB) 'GiB' '0.#' }

# Valeurs DMI de remplissage laissées par les fabricants : à ignorer.
function Get-CleanText([object]$Value) {
    $text = "$Value".Trim()
    if (-not $text -or $text -in 'Default string', 'To Be Filled By O.E.M.', 'To be filled by O.E.M.', 'Not Specified',
        'Unknown', 'None', 'System Product Name', 'System manufacturer', 'Not Applicable', '0') { return $null }
    $text
}

# Ajoute une entrée seulement si la valeur est connue.
function Add-Item([System.Collections.Specialized.OrderedDictionary]$Items, [string]$Key, [object]$Value) {
    $clean = Get-CleanText $Value
    if ($clean) { $Items[$Key] = $clean }
}

function Read-SysFile([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        try { return (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop).Trim() } catch { }
    }
    $null
}

# Codes fabricant JEDEC fréquents (SPD des barrettes) → nom lisible.
$script:Jedec = @{
    '029E' = 'Corsair'; '04CD' = 'G.Skill'; '0198' = 'Kingston'; '859B' = 'Crucial'; '059B' = 'Crucial'
    '80CE' = 'Samsung'; 'CE00' = 'Samsung'; '80AD' = 'SK Hynix'; 'AD00' = 'SK Hynix'; '802C' = 'Micron'
    '2C00' = 'Micron'; '04EF' = 'Team Group'; '0EF7' = 'Team Group'; '0194' = 'Smart Modular'
    '8551' = 'Qimonda'; '0443' = 'Ramaxel'; '02FE' = 'Elpida'; '0783' = 'Transcend'; '0B4C' = 'Patriot'
}

function Get-MemoryVendor([string]$Raw) {
    $clean = Get-CleanText $Raw
    if (-not $clean) { return $null }
    $key = ($clean -replace '^0x', '').ToUpperInvariant()
    if ($script:Jedec.ContainsKey($key)) { return $script:Jedec[$key] }
    $clean
}

# Classe PCI (2 premiers chiffres hexadécimaux) → catégorie en français.
$script:PciClasses = @{
    '01' = 'Stockage'; '02' = 'Réseau'; '03' = 'Affichage'; '04' = 'Multimédia'; '05' = 'Mémoire'
    '06' = 'Pont'; '07' = 'Communication'; '08' = 'Périphérique système'; '09' = 'Entrée'; '0c' = 'Bus série'
    '0d' = 'Sans fil'; '11' = 'Acquisition de signal'; '12' = 'Accélérateur'
}

# Codes d'erreur du Gestionnaire de périphériques (ConfigManagerErrorCode) les plus courants.
$script:PnpErrors = @{
    1 = 'Mal configuré'; 3 = 'Pilote endommagé ou mémoire insuffisante'; 10 = 'Ne peut pas démarrer'
    12 = 'Ressources insuffisantes'; 14 = 'Redémarrage nécessaire'; 18 = 'Pilotes à réinstaller'
    19 = 'Configuration du registre endommagée'; 21 = 'En cours de suppression'; 22 = 'Désactivé'
    24 = 'Absent ou mal installé'; 28 = 'Pilote non installé'; 29 = 'Désactivé par le micrologiciel'
    31 = 'Ne fonctionne pas correctement'; 32 = 'Service du pilote désactivé'; 37 = "Échec d'initialisation du pilote"
    39 = 'Pilote endommagé ou absent'; 41 = 'Pilote chargé mais matériel introuvable'; 43 = 'Arrêté (a signalé des problèmes)'
    45 = 'Non connecté'; 48 = 'Pilote bloqué (incompatible)'; 52 = 'Signature du pilote non vérifiée'
}

#endregion

#region Linux

function Get-LinuxPciDevices {
    # lspci -mm -D : "domaine:bus:slot.fn" "classe" "fabricant" "périphérique" … ; noms lisibles.
    $names = @{}
    if (Get-Command lspci -ErrorAction SilentlyContinue) {
        foreach ($line in & lspci -mm -D 2>$null) {
            $fields = [regex]::Matches($line, '"([^"]*)"') | ForEach-Object { $_.Groups[1].Value }
            $slot = ($line -split ' ', 2)[0]
            if ($fields.Count -ge 3) { $names[$slot] = [PSCustomObject]@{ Vendor = $fields[1]; Device = $fields[2] } }
        }
    }

    $kernel = Read-SysFile '/proc/sys/kernel/osrelease'
    foreach ($dir in Get-ChildItem -Path /sys/bus/pci/devices -ErrorAction SilentlyContinue) {
        $slot = $dir.Name
        $class = (Read-SysFile (Join-Path $dir.FullName 'class')) -replace '^0x', ''
        $driverLink = Join-Path $dir.FullName 'driver'
        $driver = if (Test-Path -LiteralPath $driverLink) { Split-Path -Leaf (Get-Item -LiteralPath $driverLink).Target } else { $null }
        $version = $null
        $taint = $null
        if ($driver) {
            # Version du module si elle est publiée, sinon pilote intégré au noyau.
            $module = $driver -replace '-', '_'
            $version = Read-SysFile "/sys/module/$module/version"
            if (-not $version) { $version = "noyau $kernel" }
            # taint : P propriétaire, O hors de l'arbre du noyau, E non signé ; vide = module du noyau.
            $taint = Read-SysFile "/sys/module/$module/taint"
        }
        $name = $names[$slot]
        [PSCustomObject]@{
            Slot     = $slot
            Class    = $class
            Category = $script:PciClasses[$class.Substring(0, [Math]::Min(2, $class.Length))] ?? 'Autre'
            Vendor   = $name.Vendor
            Name     = if ($name) { $name.Device } else { "Périphérique $slot" }
            Driver   = $driver
            Version  = $version
            Taint    = $taint
        }
    }
}

# Origine d'un module Linux d'après son taint, et s'il est signé (E = non signé).
function Get-ModuleOrigin([string]$Taint) {
    $parts = @()
    if ($Taint -match 'O') { $parts += 'hors noyau' }
    if ($Taint -match 'P') { $parts += 'propriétaire' }
    [PSCustomObject]@{
        Origin = if ($parts) { 'Module ' + ($parts -join ', ') } else { 'Noyau' }
        Signed = $Taint -notmatch 'E'
    }
}

function Get-LinuxMemoryModules {
    # udev (systemd ≥ 253) publie les barrettes de la table SMBIOS sans droits root ; sinon dmidecode en root.
    $props = @{}
    if (Get-Command udevadm -ErrorAction SilentlyContinue) {
        foreach ($line in & udevadm info -p /devices/virtual/dmi/id 2>$null) {
            if ($line -match '^E: (MEMORY_[A-Z0-9_]+)=(.*)$') { $props[$Matches[1]] = $Matches[2] }
        }
    }

    if ($props.Count -gt 0) {
        $count = ($props.Keys | Where-Object { $_ -match '^MEMORY_DEVICE_(\d+)_' } |
                  ForEach-Object { [int]($_ -replace '^MEMORY_DEVICE_(\d+)_.*$', '$1') } | Measure-Object -Maximum).Maximum + 1
        $modules = for ($i = 0; $i -lt $count; $i++) {
            $p = "MEMORY_DEVICE_${i}_"
            [PSCustomObject]@{
                Slot     = $props["${p}LOCATOR"]
                Size     = if ($props["${p}SIZE"]) { [double]$props["${p}SIZE"] } else { 0 }
                Type     = Get-CleanText $props["${p}TYPE"]
                Speed    = if ($props["${p}CONFIGURED_SPEED_MTS"]) { [int]$props["${p}CONFIGURED_SPEED_MTS"] } elseif ($props["${p}SPEED_MTS"]) { [int]$props["${p}SPEED_MTS"] } else { $null }
                Vendor   = Get-MemoryVendor $props["${p}MANUFACTURER"]
                Part     = Get-CleanText $props["${p}PART_NUMBER"]
            }
        }
        return [PSCustomObject]@{
            Modules     = @($modules)
            MaxCapacity = if ($props['MEMORY_ARRAY_MAX_CAPACITY']) { [double]$props['MEMORY_ARRAY_MAX_CAPACITY'] } else { $null }
            Note        = $null
        }
    }

    if ([Environment]::IsPrivilegedProcess -and (Get-Command dmidecode -ErrorAction SilentlyContinue)) {
        $modules = [System.Collections.Generic.List[object]]::new()
        $current = $null
        foreach ($line in & dmidecode -t 17 2>$null) {
            if ($line -match '^Memory Device') { $current = @{}; continue }
            if ($null -eq $current) { continue }
            if ($line -match '^\s+([^:]+):\s*(.*)$') { $current[$Matches[1]] = $Matches[2] }
            elseif (-not $line.Trim() -and $current.Count -gt 0) {
                $size = 0
                if ($current['Size'] -match '^(\d+)\s*(GB|MB)') { $size = [double]$Matches[1] * $(if ($Matches[2] -eq 'GB') { 1GB } else { 1MB }) }
                $modules.Add([PSCustomObject]@{
                        Slot   = $current['Locator']; Size = $size; Type = Get-CleanText $current['Type']
                        Speed  = if ($current['Configured Memory Speed'] -match '^(\d+)') { [int]$Matches[1] } else { $null }
                        Vendor = Get-MemoryVendor $current['Manufacturer']; Part = Get-CleanText $current['Part Number']
                    })
                $current = $null
            }
        }
        return [PSCustomObject]@{ Modules = $modules.ToArray(); MaxCapacity = $null; Note = $null }
    }

    [PSCustomObject]@{ Modules = @(); MaxCapacity = $null; Note = 'Détail des barrettes indisponible (udev sans données SMBIOS ; dmidecode demande les droits root)' }
}

function Get-LinuxStatic {
    $dmi = '/sys/class/dmi/id'
    $board = [ordered]@{}
    Add-Item $board 'Fabricant' (Read-SysFile "$dmi/board_vendor")
    Add-Item $board 'Modèle' (Read-SysFile "$dmi/board_name")
    Add-Item $board 'Version' (Read-SysFile "$dmi/board_version")
    Add-Item $board 'N° de série' (Read-SysFile "$dmi/board_serial")   # lisible en root seulement
    Add-Item $board 'Système' (('{0} {1}' -f (Read-SysFile "$dmi/sys_vendor"), (Read-SysFile "$dmi/product_name")).Trim())

    $bios = [ordered]@{}
    Add-Item $bios 'Fabricant' (Read-SysFile "$dmi/bios_vendor")
    Add-Item $bios 'Version' (Read-SysFile "$dmi/bios_version")
    $date = Read-SysFile "$dmi/bios_date"   # MM/DD/YYYY
    if ($date -match '^(\d{2})/(\d{2})/(\d{4})$') { $date = '{0}/{1}/{2}' -f $Matches[2], $Matches[1], $Matches[3] }
    Add-Item $bios 'Date' $date
    Add-Item $bios 'Révision' (Read-SysFile "$dmi/bios_release")
    $uefi = Test-Path -LiteralPath /sys/firmware/efi
    $bios['Mode de démarrage'] = if ($uefi) { 'UEFI' } else { 'BIOS hérité' }
    if ($uefi) {
        # efivars SecureBoot-… : 4 octets d'attributs, puis la valeur (1 = actif).
        $var = Get-ChildItem -Path /sys/firmware/efi/efivars -Filter 'SecureBoot-*' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($var) {
            $bytes = Get-Content -LiteralPath $var.FullName -AsByteStream -ErrorAction SilentlyContinue
            if ($bytes.Count -ge 5) { $bios['Secure Boot'] = if ($bytes[4] -eq 1) { 'Activé' } else { 'Désactivé' } }
        }
    }

    [PSCustomObject]@{ Board = $board; Bios = $bios; Memory = Get-LinuxMemoryModules; Drivers = $null }
}

#endregion

#region Windows

function Get-WindowsStatic {
    $baseboard = Get-CimInstance -ClassName Win32_BaseBoard
    $system = Get-CimInstance -ClassName Win32_ComputerSystem
    $board = [ordered]@{}
    Add-Item $board 'Fabricant' $baseboard.Manufacturer
    Add-Item $board 'Modèle' $baseboard.Product
    Add-Item $board 'Version' $baseboard.Version
    Add-Item $board 'N° de série' $baseboard.SerialNumber
    Add-Item $board 'Système' (('{0} {1}' -f $system.Manufacturer, $system.Model).Trim())

    $biosInfo = Get-CimInstance -ClassName Win32_BIOS
    $bios = [ordered]@{}
    Add-Item $bios 'Fabricant' $biosInfo.Manufacturer
    Add-Item $bios 'Version' $biosInfo.SMBIOSBIOSVersion
    if ($biosInfo.ReleaseDate) { $bios['Date'] = $biosInfo.ReleaseDate.ToString('dd/MM/yyyy', $script:Fr) }
    # La clé SecureBoot\State n'existe que sur une machine démarrée en UEFI ; lisible sans droits.
    $state = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -ErrorAction SilentlyContinue
    $bios['Mode de démarrage'] = if ($state) { 'UEFI' } else { 'BIOS hérité' }
    if ($state) { $bios['Secure Boot'] = if ($state.UEFISecureBootEnabled -eq 1) { 'Activé' } else { 'Désactivé' } }

    # SMBIOSMemoryType → génération de DDR.
    $types = @{ 20 = 'DDR'; 21 = 'DDR2'; 24 = 'DDR3'; 26 = 'DDR4'; 30 = 'LPDDR4'; 34 = 'DDR5'; 35 = 'LPDDR5' }
    $modules = foreach ($m in Get-CimInstance -ClassName Win32_PhysicalMemory) {
        [PSCustomObject]@{
            Slot   = $m.DeviceLocator
            Size   = [double]$m.Capacity
            Type   = $types[[int]$m.SMBIOSMemoryType]
            Speed  = if ($m.ConfiguredClockSpeed) { [int]$m.ConfiguredClockSpeed } else { [int]$m.Speed }
            Vendor = Get-MemoryVendor $m.Manufacturer
            Part   = Get-CleanText $m.PartNumber
        }
    }
    $array = Get-CimInstance -ClassName Win32_PhysicalMemoryArray | Select-Object -First 1
    $slots = $array.MemoryDevices
    # Les emplacements vides n'apparaissent pas dans Win32_PhysicalMemory : on les ajoute pour le décompte.
    $memory = [PSCustomObject]@{
        Modules     = @($modules)
        MaxCapacity = if ($array.MaxCapacityEx) { [double]$array.MaxCapacityEx * 1KB } elseif ($array.MaxCapacity) { [double]$array.MaxCapacity * 1KB } else { $null }
        Slots       = $slots
        Note        = $null
    }

    # Pilotes des périphériques principaux (requête lente : lue une seule fois).
    $classes = 'DISPLAY', 'NET', 'MEDIA', 'SCSIADAPTER', 'HDCONTROLLER', 'USB', 'BLUETOOTH', 'SYSTEM', 'AUDIOENDPOINT'
    $drivers = Get-CimInstance -ClassName Win32_PnPSignedDriver |
        Where-Object { $_.DeviceName -and $_.DeviceClass -in $classes } |
        Sort-Object DeviceClass, DeviceName |
        ForEach-Object {
            [PSCustomObject]@{
                Name     = $_.DeviceName
                Category = $_.DeviceClass
                Driver   = $_.DriverProviderName
                Version  = $_.DriverVersion
                Date     = $_.DriverDate
                Signed   = [bool]$_.IsSigned
                Origin   = $null
            }
        }

    [PSCustomObject]@{ Board = $board; Bios = $bios; Memory = $memory; Drivers = @($drivers) }
}

#endregion

#region TPM, écrans, audio, USB, Bluetooth

# TPM : présence, version, fabricant, état.
# Windows : Win32_Tpm (root/cimv2/Security/MicrosoftTpm, droits administrateur), sinon Get-PnpDevice SecurityDevices.
# Linux   : /sys/class/tpm/tpm0 (tpm_version_major), fabricant via /sys/class/tpm/tpm0/device/firmware_node ou description.
function Get-TpmInfo {
    $items = [ordered]@{}
    if ($IsWindows) {
        $tpm = try { Get-CimInstance -Namespace root/cimv2/Security/MicrosoftTpm -ClassName Win32_Tpm -ErrorAction Stop } catch { $null }
        if ($tpm) {
            $items['Présent'] = 'Oui'
            $items['Version'] = ($tpm.SpecVersion -split ',')[0].Trim()
            Add-Item $items 'Fabricant' $tpm.ManufacturerIdTxt
            $items['Activé'] = if ($tpm.IsEnabled_InitialValue) { 'Oui' } else { 'Non' }
            $items['Prêt'] = if ($tpm.IsActivated_InitialValue -and $tpm.IsOwned_InitialValue) { 'Oui' } else { 'Non' }
            return [PSCustomObject]@{ Present = $true; Major = [int](($tpm.SpecVersion -split '[,.]')[0]); Items = $items }
        }
        $device = Get-PnpDevice -Class SecurityDevices -PresentOnly -ErrorAction SilentlyContinue | Where-Object FriendlyName -like '*Trusted Platform*' | Select-Object -First 1
        if ($device) {
            $items['Présent'] = 'Oui'
            $items['Périphérique'] = $device.FriendlyName
            $items['Détail'] = 'Version et état lisibles avec les droits administrateur'
            $major = if ($device.FriendlyName -match '(\d)\.\d') { [int]$Matches[1] } else { $null }
            return [PSCustomObject]@{ Present = $true; Major = $major; Items = $items }
        }
        $items['Présent'] = 'Non détecté'
        return [PSCustomObject]@{ Present = $false; Major = $null; Items = $items }
    }

    $tpm = Get-ChildItem -Path /sys/class/tpm -ErrorAction SilentlyContinue | Where-Object Name -Match '^tpm\d+$' | Select-Object -First 1
    if (-not $tpm) {
        $items['Présent'] = 'Non détecté'
        return [PSCustomObject]@{ Present = $false; Major = $null; Items = $items }
    }
    $major = Read-SysFile (Join-Path $tpm.FullName 'tpm_version_major')
    $items['Présent'] = 'Oui'
    $items['Version'] = if ($major) { "$major.0" } else { 'Inconnue' }
    $hid = Read-SysFile (Join-Path $tpm.FullName 'device/firmware_node/hid')
    if ($hid) { $items['Interface'] = $hid -replace '^MSFT0101$', 'TPM 2.0 (ACPI MSFT0101)' }
    $items['Périphérique'] = '/dev/' + $tpm.Name
    [PSCustomObject]@{ Present = $true; Major = if ($major) { [int]$major } else { $null }; Items = $items }
}

# Identifiants PNP des fabricants d'écrans les plus courants (EDID) → nom.
$script:MonitorVendors = @{
    ACR = 'Acer'; AOC = 'AOC'; AUS = 'ASUS'; BNQ = 'BenQ'; DEL = 'Dell'; ENC = 'Eizo'; GSM = 'LG'; HWP = 'HP'; IVM = 'Iiyama'
    LEN = 'Lenovo'; MSI = 'MSI'; NEC = 'NEC'; PHL = 'Philips'; SAM = 'Samsung'; SEC = 'Samsung'; SNY = 'Sony'; VSC = 'ViewSonic'
    APP = 'Apple'; AUO = 'AU Optronics'; BOE = 'BOE'; CMN = 'Chimei Innolux'; LGD = 'LG Display'; SHP = 'Sharp'; GBT = 'Gigabyte'
}

# Décode un bloc EDID (128 octets) : fabricant (3 lettres), nom (descripteur 0xFC), taille (cm), année.
function ConvertFrom-Edid([byte[]]$Edid) {
    if (-not $Edid -or $Edid.Count -lt 128) { return $null }
    $id = ([int]$Edid[8] -shl 8) -bor $Edid[9]
    $vendor = -join @([char](64 + (($id -shr 10) -band 31)), [char](64 + (($id -shr 5) -band 31)), [char](64 + ($id -band 31)))
    $name = $null
    foreach ($offset in 54, 72, 90, 108) {
        if ($Edid[$offset] -eq 0 -and $Edid[$offset + 1] -eq 0) {
            $text = ([System.Text.Encoding]::ASCII.GetString($Edid, $offset + 5, 13) -split "`n")[0].Trim()
            if ($Edid[$offset + 3] -eq 0xFC) { $name = $text }
        }
    }
    $widthCm = $Edid[21]; $heightCm = $Edid[22]
    [PSCustomObject]@{
        Vendor = $script:MonitorVendors[$vendor] ?? $vendor
        Name   = $name
        Inches = if ($widthCm -gt 0 -and $heightCm -gt 0) { [Math]::Round([Math]::Sqrt($widthCm * $widthCm + $heightCm * $heightCm) / 2.54, 1) } else { $null }
        Year   = if ($Edid[17] -gt 0) { 1990 + $Edid[17] } else { $null }
    }
}

# Écrans connectés.
# Windows : WmiMonitorID (nom, fabricant, année), WmiMonitorBasicDisplayParams (taille), WmiMonitorConnectionParams
#           (connectique) ; définition et fréquence de l'affichage principal via Win32_VideoController.
# Linux   : /sys/class/drm/card*-<connecteur>/ : status, edid, modes (le premier = définition native).
function Get-Displays {
    if ($IsWindows) {
        $outputs = @{ -2 = 'Autre'; -1 = 'Autre'; 0 = 'VGA'; 4 = 'DVI'; 5 = 'HDMI'; 10 = 'DisplayPort'; 11 = 'DisplayPort (intégré)'; 2147483648L = 'Écran interne' }
        $ids = @(Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorID -ErrorAction SilentlyContinue)
        $sizes = @{}; foreach ($b in Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorBasicDisplayParams -ErrorAction SilentlyContinue) { $sizes[$b.InstanceName] = $b }
        $links = @{}; foreach ($c in Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorConnectionParams -ErrorAction SilentlyContinue) { $links[$c.InstanceName] = $c }
        $decode = { param($chars) if ($chars) { (-join ($chars | Where-Object { $_ -gt 0 } | ForEach-Object { [char]$_ })).Trim() } }
        $list = foreach ($m in $ids) {
            $size = $sizes[$m.InstanceName]
            $inches = if ($size -and $size.MaxHorizontalImageSize -gt 0) {
                [Math]::Round([Math]::Sqrt([Math]::Pow($size.MaxHorizontalImageSize, 2) + [Math]::Pow($size.MaxVerticalImageSize, 2)) / 2.54, 1)
            } else { $null }
            $tech = $links[$m.InstanceName].VideoOutputTechnology
            [PSCustomObject]@{
                Name = & $decode $m.UserFriendlyName; Vendor = & $decode $m.ManufacturerName
                Connector = if ($null -ne $tech -and $outputs.ContainsKey([long]$tech)) { $outputs[[long]$tech] } else { $null }
                Mode = $null; Inches = $inches; Year = if ($m.YearOfManufacture -gt 0) { [int]$m.YearOfManufacture } else { $null }
            }
        }
        return $list
    }

    foreach ($connector in Get-ChildItem -Path /sys/class/drm -ErrorAction SilentlyContinue | Where-Object Name -Match '^card\d+-') {
        if ((Read-SysFile (Join-Path $connector.FullName 'status')) -ne 'connected') { continue }
        $edid = try { [System.IO.File]::ReadAllBytes((Join-Path $connector.FullName 'edid')) } catch { $null }
        $info = ConvertFrom-Edid $edid
        $mode = Get-Content -LiteralPath (Join-Path $connector.FullName 'modes') -TotalCount 1 -ErrorAction SilentlyContinue
        [PSCustomObject]@{
            Name = $info.Name; Vendor = $info.Vendor
            Connector = ($connector.Name -replace '^card\d+-', '') -replace '-A-', '-'
            Mode = $mode; Inches = $info.Inches; Year = $info.Year
        }
    }
}

# Résolution et fréquence de l'affichage principal (Windows seulement : une ligne par carte graphique active).
function Get-WindowsDisplayModes {
    Get-CimInstance -ClassName Win32_VideoController | Where-Object CurrentHorizontalResolution | ForEach-Object {
        '{0} × {1} à {2} Hz ({3})' -f $_.CurrentHorizontalResolution, $_.CurrentVerticalResolution, $_.CurrentRefreshRate, $_.Name
    }
}

# Périphériques audio.
# Windows : points de terminaison (Get-PnpDevice AudioEndpoint) ; le périphérique par défaut n'est pas exposé sans COM.
# Linux   : pactl --format=json list sinks / sources (PipeWire ou PulseAudio) + périphériques par défaut ;
#           sinon cartes ALSA (/proc/asound/cards).
function Get-AudioDevices {
    if ($IsWindows) {
        return Get-PnpDevice -Class AudioEndpoint -PresentOnly -ErrorAction SilentlyContinue | ForEach-Object {
            [PSCustomObject]@{ Name = $_.FriendlyName; Kind = $null; Default = $null; State = if ($_.Status -eq 'OK') { 'Disponible' } else { $_.Status } }
        }
    }

    if (Get-Command pactl -ErrorAction SilentlyContinue) {
        $defaultSink = & pactl get-default-sink 2>$null
        $defaultSource = & pactl get-default-source 2>$null
        $states = @{ RUNNING = 'En cours'; IDLE = 'Inactif'; SUSPENDED = 'En veille' }
        $list = foreach ($kind in 'sinks', 'sources') {
            $json = & pactl --format=json list $kind 2>$null
            if (-not $json) { continue }
            foreach ($d in ($json | ConvertFrom-Json)) {
                if ($kind -eq 'sources' -and $d.name -like '*.monitor') { continue }   # retour des sorties : pas un micro
                [PSCustomObject]@{
                    Name    = $d.description
                    Kind    = if ($kind -eq 'sinks') { 'Sortie' } else { 'Entrée' }
                    Default = ($d.name -in @($defaultSink, $defaultSource))
                    State   = $states[$d.state] ?? $d.state
                }
            }
        }
        if ($list) { return $list }
    }

    Get-Content -Path /proc/asound/cards -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\s*\d+ \[' } | ForEach-Object {
        [PSCustomObject]@{ Name = ($_ -replace '^\s*\d+ \[[^\]]*\]:\s*', '').Trim(); Kind = 'Carte'; Default = $null; State = $null }
    }
}

# Périphériques USB connectés (hors concentrateurs).
# Windows : Win32_PnPEntity dont l'identifiant commence par USB\VID_ (périphérique racine, pas ses interfaces).
# Linux   : /sys/bus/usb/devices/<bus>-<port> : idVendor, idProduct, manufacturer, product, speed, bDeviceClass.
function Get-UsbDevices {
    if ($IsWindows) {
        return Get-CimInstance -ClassName Win32_PnPEntity -Filter "PNPDeviceID LIKE 'USB\\VID%' AND NOT PNPDeviceID LIKE '%&MI[_]%'" -ErrorAction SilentlyContinue |
            Where-Object { $_.PNPClass -ne 'USB' -or $_.Name -notmatch 'hub|concentrateur' } | ForEach-Object {
                $vidpid = if ($_.PNPDeviceID -match 'VID_([0-9A-F]{4})&PID_([0-9A-F]{4})') { '{0}:{1}' -f $Matches[1].ToLower(), $Matches[2].ToLower() } else { $null }
                [PSCustomObject]@{ Name = $_.Name; Vendor = $_.Manufacturer; Id = $vidpid; Speed = $null; Category = $_.PNPClass }
            }
    }

    $speeds = @{ '1.5' = 'USB 1 (1,5 Mbit/s)'; '12' = 'USB 1 (12 Mbit/s)'; '480' = 'USB 2'; '5000' = 'USB 3 (5 Gbit/s)'; '10000' = 'USB 3 (10 Gbit/s)'; '20000' = 'USB 3 (20 Gbit/s)' }
    foreach ($dir in Get-ChildItem -Path /sys/bus/usb/devices -ErrorAction SilentlyContinue | Where-Object Name -Match '^\d+-[\d.]+$') {
        $class = Read-SysFile (Join-Path $dir.FullName 'bDeviceClass')
        if ($class -eq '09') { continue }   # concentrateur
        $vendorId = Read-SysFile (Join-Path $dir.FullName 'idVendor')
        $speed = Read-SysFile (Join-Path $dir.FullName 'speed')
        [PSCustomObject]@{
            Name     = (Read-SysFile (Join-Path $dir.FullName 'product')) ?? "Périphérique $($dir.Name)"
            Vendor   = Read-SysFile (Join-Path $dir.FullName 'manufacturer')
            Id       = '{0}:{1}' -f $vendorId, (Read-SysFile (Join-Path $dir.FullName 'idProduct'))
            Speed    = $speeds[$speed] ?? $speed
            Category = $null
        }
    }
}

# Appareils Bluetooth connectés.
# Windows : Get-PnpDevice -Class Bluetooth (appareils BTHENUM présents, hors services et adaptateur).
# Linux   : bluetoothctl devices Connected (BlueZ ≥ 5.65), limité à 2 s.
function Get-BluetoothDevices {
    if ($IsWindows) {
        return Get-PnpDevice -Class Bluetooth -PresentOnly -ErrorAction SilentlyContinue |
            Where-Object { $_.InstanceId -like 'BTHENUM\DEV_*' -or $_.InstanceId -like 'BTHLE\DEV_*' } |
            ForEach-Object { [PSCustomObject]@{ Name = $_.FriendlyName; Address = ($_.InstanceId -replace '^.*DEV_([0-9A-F]{12}).*$', '$1') } }
    }
    if (-not (Get-Command bluetoothctl -ErrorAction SilentlyContinue) -or -not (Test-Path /usr/bin/timeout)) { return @() }
    & /usr/bin/timeout 2 bluetoothctl devices Connected 2>$null | Where-Object { $_ -match '^Device ([0-9A-F:]{17}) (.+)$' } | ForEach-Object {
        [PSCustomObject]@{ Name = $Matches[2]; Address = $Matches[1] }
    }
}

#endregion

#region GPU

# Mémoire vidéo de chaque carte.
#   Windows : registre de la classe Display (HardwareInformation.qwMemorySize, 64 bits), sinon AdapterRAM (limité à 4 GiB).
#   Linux   : nvidia-smi (par adresse PCI) ou /sys/bus/pci/devices/<slot>/mem_info_vram_total (AMD).
function Get-GpuCards {
    if ($IsWindows) {
        $vram = @{}
        $class = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
        foreach ($key in Get-ChildItem -Path $class -ErrorAction SilentlyContinue | Where-Object PSChildName -Match '^\d{4}$') {
            $props = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
            $size = $props.'HardwareInformation.qwMemorySize'
            if ($props.DriverDesc -and $size) { $vram[$props.DriverDesc] = [double]$size }
        }
        return Get-CimInstance -ClassName Win32_VideoController | ForEach-Object {
            [PSCustomObject]@{
                Name    = $_.Name
                Vendor  = $_.AdapterCompatibility
                Driver  = $_.InfFilename
                Version = $_.DriverVersion
                Memory  = $vram[$_.Name] ?? $(if ($_.AdapterRAM -gt 0) { [double]$_.AdapterRAM } else { $null })
                Slot    = $_.PNPDeviceID -replace '\\.*$', ''
            }
        }
    }

    $nvidia = @{}
    if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
        # « 00000000:01:00.0, 10240 » → slot PCI 0000:01:00.0, MiB
        foreach ($line in & nvidia-smi --query-gpu=pci.bus_id,memory.total --format=csv,noheader,nounits 2>$null) {
            $f = $line -split ',\s*'
            if ($f.Count -ge 2) { $nvidia[($f[0] -replace '^0000', '').ToLowerInvariant()] = [double]$f[1] * 1MB }
        }
    }
    Get-LinuxPciDevices | Where-Object { $_.Class -like '03*' } | ForEach-Object {
        $amd = Read-SysFile "/sys/bus/pci/devices/$($_.Slot)/mem_info_vram_total"
        [PSCustomObject]@{
            Name = $_.Name; Vendor = $_.Vendor; Driver = $_.Driver; Version = $_.Version; Slot = $_.Slot
            Memory = $nvidia[$_.Slot.ToLowerInvariant()] ?? $(if ($amd) { [double]$amd } else { $null })
        }
    }
}

# Mesures en direct : NVIDIA via nvidia-smi (Windows et Linux), AMD via /sys/class/drm (Linux).
function Get-GpuLive {
    if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
        $line = & nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits 2>$null |
            Select-Object -First 1
        if ($line) {
            $f = $line -split ',\s*'
            $num = { param($v) $d = 0.0; if ([double]::TryParse($v, [Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$d)) { $d } else { $null } }
            return [PSCustomObject]@{
                Name = $f[0]; Usage = & $num $f[1]
                VramUsed = if ($null -ne (& $num $f[2])) { (& $num $f[2]) * 1MB } else { $null }
                VramTotal = if ($null -ne (& $num $f[3])) { (& $num $f[3]) * 1MB } else { $null }
                Temperature = & $num $f[4]
            }
        }
    }

    if ($IsLinux) {
        foreach ($card in Get-ChildItem -Path /sys/class/drm -Directory -Filter 'card?' -ErrorAction SilentlyContinue) {
            $device = Join-Path $card.FullName 'device'
            $busy = Read-SysFile "$device/gpu_busy_percent"
            if ($null -eq $busy) { continue }
            $temp = Get-ChildItem -Path "$device/hwmon/*/temp1_input" -ErrorAction SilentlyContinue | Select-Object -First 1
            return [PSCustomObject]@{
                Name = $null; Usage = [double]$busy
                VramUsed = [double](Read-SysFile "$device/mem_info_vram_used")
                VramTotal = [double](Read-SysFile "$device/mem_info_vram_total")
                Temperature = if ($temp) { [double](Read-SysFile $temp.FullName) / 1000 } else { $null }
            }
        }
    }
    $null
}

#endregion

# Périphériques en erreur.
#   Windows : Win32_PnPEntity avec un ConfigManagerErrorCode non nul.
#   Linux   : périphériques PCI sans pilote chargé (hors ponts, mémoire et processeurs, qui n'en ont pas besoin).
function Get-DeviceProblems {
    if ($IsWindows) {
        return Get-CimInstance -ClassName Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' | ForEach-Object {
            $code = [int]$_.ConfigManagerErrorCode
            [PSCustomObject]@{
                Name     = $_.Name ?? $_.DeviceID
                Category = $_.PNPClass ?? 'Inconnu'
                Problem  = '{0} (code {1})' -f ($script:PnpErrors[$code] ?? 'Erreur'), $code
            }
        }
    }
    Get-LinuxPciDevices | Where-Object { -not $_.Driver -and $_.Class.Substring(0, 2) -notin '05', '06', '0b' } | ForEach-Object {
        [PSCustomObject]@{ Name = $_.Name; Category = $_.Category; Problem = 'Aucun pilote chargé' }
    }
}

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

    if (-not $script:Static) {
        $script:Static = Invoke-Block 'Infos fixes' {
            $static = if ($IsWindows) { Get-WindowsStatic } elseif ($IsLinux) { Get-LinuxStatic } else { throw 'Système non pris en charge' }
            $static | Add-Member -NotePropertyName Gpus -NotePropertyValue @(Get-GpuCards) -PassThru
        }
    }
    $static = $script:Static

    # GPU en direct : utilisation, mémoire vidéo, température (Metric à la suite → cartes en ligne + graphiques)
    $live = Invoke-Block 'GPU' { Get-GpuLive }
    if ($live) {
        $gpuName = $live.Name ?? ($static.Gpus | Select-Object -First 1).Name
        if ($null -ne $live.Usage) {
            $sections.Add([PSCustomObject]@{
                    Title = 'Utilisation du GPU'; Type = 'Metric'; Icon = 'pulse'; Value = $live.Usage; Unit = '%'; Max = 100
                    Detail = $gpuName
                })
        }
        if ($live.VramTotal -gt 0) {
            $totalGiB = [Math]::Round($live.VramTotal / 1GB, 1)
            $sections.Add([PSCustomObject]@{
                    Title = 'Mémoire vidéo'; Type = 'Metric'; Icon = 'ram'; Value = [Math]::Round($live.VramUsed / 1GB, 1); Unit = 'GiB'
                    Max = $totalGiB
                    Warning = [Math]::Round($totalGiB * $script:VramWarning, 1)
                    Critical = [Math]::Round($totalGiB * $script:VramCritical, 1)
                    Detail = ('{0} libres sur {1}' -f (Format-GiB ($live.VramTotal - $live.VramUsed)), (Format-GiB $live.VramTotal))
                })
        }
        if ($null -ne $live.Temperature -and $live.Temperature -ge $script:TempWarning) {
            Add-Finding $(if ($live.Temperature -ge $script:TempCritical) { 'critical' } else { 'warning' }) 'HW-GPU-HOT' `
                ('Carte graphique à {0}' -f (Format-Unit $live.Temperature '°C' '0')) 'Vérifier la ventilation du boîtier et de la carte graphique.'
        }
        if ($null -ne $live.Temperature) {
            $sections.Add([PSCustomObject]@{
                    Title = 'Température du GPU'; Type = 'Metric'; Icon = 'temperature'; Value = $live.Temperature; Unit = '°C'
                    Warning = $script:TempWarning; Critical = $script:TempCritical
                    Detail = 'Capteur du GPU'
                })
        }
    }

    if ($static) {
        if ($static.Board.Count -gt 0) {
            $sections.Add([PSCustomObject]@{ Title = 'Carte mère'; Type = 'KeyValue'; Icon = 'board'; Items = $static.Board })
        }
        if ($static.Bios.Count -gt 0) {
            $sections.Add([PSCustomObject]@{ Title = 'BIOS / UEFI'; Type = 'KeyValue'; Icon = 'shield_checkmark'; Items = $static.Bios })
        }

        # TPM (lu une fois : ne change pas pendant le fonctionnement)
        $tpm = Invoke-Block 'TPM' { Get-Cached 'tpm' 3600 { Get-TpmInfo } }
        if ($tpm) {
            $sections.Add([PSCustomObject]@{ Title = 'TPM'; Type = 'KeyValue'; Icon = 'lock_closed'; Items = $tpm.Items })
            if (-not $tpm.Present) {
                Add-Finding 'info' 'HW-TPM-MISSING' 'Aucun TPM détecté' 'Le TPM 2.0 est requis par Windows 11 et le chiffrement BitLocker : vérifier s''il est désactivé dans le BIOS (PTT / fTPM).'
            }
            elseif ($tpm.Major -and $tpm.Major -lt 2) {
                Add-Finding 'info' 'HW-TPM-OLD' ('TPM {0}.x : Windows 11 exige un TPM 2.0' -f $tpm.Major) $null
            }
        }

        # Cartes graphiques
        if ($static.Gpus.Count -gt 0) {
            $rows = foreach ($g in $static.Gpus) {
                , @($g.Name, $g.Vendor, $(if ($g.Memory) { [Math]::Round($g.Memory / 1GB, 1) } else { $null }), $g.Driver, $g.Version, $g.Slot)
            }
            $sections.Add([PSCustomObject]@{
                    Title = 'Cartes graphiques'; Type = 'Table'; Icon = 'desktop'
                    Columns = @('Carte', 'Fabricant', 'Mémoire (GiB)', 'Pilote', 'Version du pilote', 'Emplacement')
                    Rows = @($rows)
                })
        }

        # Mémoire vive : résumé, puis une ligne par barrette
        $memory = $static.Memory
        $installed = @($memory.Modules | Where-Object { $_.Size -gt 0 })
        $summary = [ordered]@{}
        if ($installed.Count -gt 0) {
            $summary['Installée'] = Format-GiB (($installed | Measure-Object -Property Size -Sum).Sum)
            $slots = if ($memory.Slots) { $memory.Slots } else { $memory.Modules.Count }
            $summary['Emplacements utilisés'] = '{0} sur {1}' -f $installed.Count, $slots
            if ($memory.MaxCapacity) { $summary['Capacité maximale'] = Format-GiB $memory.MaxCapacity }
            Add-Item $summary 'Type' (($installed.Type | Where-Object { $_ } | Select-Object -Unique) -join ', ')
            $speeds = $installed.Speed | Where-Object { $_ } | Select-Object -Unique
            if ($speeds) { $summary['Vitesse'] = ($speeds | ForEach-Object { Format-Unit $_ 'MT/s' '0' }) -join ', ' }
        }
        else {
            $summary['Installée'] = Format-GiB ([double]((Get-Content /proc/meminfo -TotalCount 1 -ErrorAction SilentlyContinue) -replace '\D', '') * 1KB)
        }
        if ($memory.Note) { $summary['Détail'] = $memory.Note }
        $sections.Add([PSCustomObject]@{ Title = 'Mémoire vive'; Type = 'KeyValue'; Icon = 'ram'; Items = $summary })

        if ($installed.Count -gt 0) {
            $rows = foreach ($m in $installed) {
                , @($m.Slot, [Math]::Round($m.Size / 1GB, 1), $m.Type, $m.Speed, $m.Vendor, $m.Part)
            }
            $sections.Add([PSCustomObject]@{
                    Title = 'Barrettes'; Type = 'Table'; Icon = 'ram'
                    Columns = @('Emplacement', 'Capacité (GiB)', 'Type', 'Vitesse (MT/s)', 'Fabricant', 'Référence')
                    Rows = @($rows)
                })
        }
    }

    # Écrans, audio, USB, Bluetooth : changent quand on branche quelque chose, relus toutes les 10 à 30 s
    Invoke-Block 'Écrans' {
        $displays = @(Get-Cached 'displays' 30 { Get-Displays })
        if ($displays.Count -gt 0) {
            $rows = foreach ($d in $displays) {
                , @(($d.Name ?? 'Écran'), $d.Vendor, $d.Connector, $d.Mode, $d.Inches, $d.Year)
            }
            $sections.Add([PSCustomObject]@{
                    Title = 'Écrans'; Type = 'Table'; Icon = 'desktop'
                    Columns = @('Écran', 'Fabricant', 'Connexion', $(if ($IsWindows) { 'Mode' } else { 'Définition native' }), 'Diagonale (pouces)', 'Année')
                    Rows = @($rows)
                })
        }
        if ($IsWindows) {
            $modes = @(Get-Cached 'modes' 30 { Get-WindowsDisplayModes })
            if ($modes.Count -gt 0) {
                $sections.Add([PSCustomObject]@{ Title = 'Affichage'; Type = 'KeyValue'; Icon = 'desktop'; Items = [ordered]@{ 'Mode actuel' = $modes -join ' · ' } })
            }
        }
    }

    Invoke-Block 'Audio' {
        $audio = @(Get-Cached 'audio' 10 { Get-AudioDevices })
        if ($audio.Count -gt 0) {
            $rows = foreach ($a in $audio | Sort-Object { -not $_.Default }, Kind, Name) {
                , @($a.Name, $a.Kind, $(if ($a.Default) { 'Oui' } elseif ($null -ne $a.Default) { 'Non' } else { $null }), $a.State)
            }
            $sections.Add([PSCustomObject]@{
                    Title = 'Audio'; Type = 'Table'; Icon = 'pulse'
                    Columns = @('Périphérique', 'Type', 'Par défaut', 'État')
                    Rows = @($rows)
                })
        }
    }

    Invoke-Block 'USB' {
        $usb = @(Get-Cached 'usb' 10 { Get-UsbDevices })
        if ($usb.Count -gt 0) {
            $rows = foreach ($u in $usb | Sort-Object Name) { , @($u.Name, $u.Vendor, $u.Id, $(if ($IsWindows) { $u.Category } else { $u.Speed })) }
            $sections.Add([PSCustomObject]@{
                    Title = 'Périphériques USB'; Type = 'Table'; Icon = 'plug_connected'
                    Columns = @('Périphérique', 'Fabricant', 'ID (VID:PID)', $(if ($IsWindows) { 'Classe' } else { 'Vitesse' }))
                    Rows = @($rows)
                })
        }
    }

    Invoke-Block 'Bluetooth' {
        $bluetooth = @(Get-Cached 'bluetooth' 10 { Get-BluetoothDevices })
        if ($bluetooth.Count -gt 0) {
            $rows = foreach ($b in $bluetooth) { , @($b.Name, $b.Address) }
            $sections.Add([PSCustomObject]@{
                    Title = 'Bluetooth connecté'; Type = 'Table'; Icon = 'link'
                    Columns = @('Appareil', 'Adresse'); Rows = @($rows)
                })
        }
    }

    # Pilotes des périphériques (Linux : relus toutes les 30 s ; Windows : lus une fois, requête lente)
    Invoke-Block 'Pilotes' {
        $drivers = if ($IsWindows) { $static.Drivers } else {
            Get-Cached 'pci' 30 { Get-LinuxPciDevices } | Where-Object { $_.Driver -and $_.Class.Substring(0, 2) -ne '06' } |
                Sort-Object Category, Name |
                ForEach-Object {
                    $origin = Get-ModuleOrigin $_.Taint
                    [PSCustomObject]@{ Name = $_.Name; Category = $_.Category; Driver = $_.Driver; Version = $_.Version; Date = $null; Signed = $origin.Signed; Origin = $origin.Origin }
                }
        }
        if ($drivers) {
            $rows = foreach ($d in $drivers) {
                $row = @($d.Name, $d.Category, $d.Driver, $d.Version)
                $row += if ($IsWindows) { $(if ($d.Date) { $d.Date.ToString('dd/MM/yyyy', $script:Fr) } else { $null }) } else { $d.Origin }
                $row += if ($d.Signed) { 'Oui' } else { 'Non' }
                , $row
            }
            $sections.Add([PSCustomObject]@{
                    Title = 'Pilotes des périphériques'; Type = 'Table'; Icon = 'settings'
                    Columns = @('Périphérique', 'Catégorie', $(if ($IsWindows) { 'Éditeur' } else { 'Pilote' }), 'Version', $(if ($IsWindows) { 'Date' } else { 'Origine' }), 'Signé')
                    Rows = @($rows)
                })

            # Linux : un module propriétaire non signé (NVIDIA) est courant sans Secure Boot → simple information.
            foreach ($d in $drivers | Where-Object { -not $_.Signed }) {
                Add-Finding $(if ($IsWindows) { 'warning' } else { 'info' }) 'HW-DRIVER-UNSIGNED' ('Pilote non signé : {0} ({1})' -f $d.Driver, $d.Name) `
                    $(if ($IsWindows) { 'Mettre à jour le pilote depuis le site du fabricant ; un pilote non signé peut être bloqué ou malveillant.' }
                      else { 'Module hors noyau non signé : il ne se chargera pas avec Secure Boot actif sans clé MOK enregistrée.' })
            }
            if ($IsWindows) {
                $limit = (Get-Date).AddYears(-5)
                foreach ($d in $drivers | Where-Object { $_.Date -and $_.Date -lt $limit -and $_.Category -in 'DISPLAY', 'NET', 'MEDIA', 'BLUETOOTH' }) {
                    Add-Finding 'info' 'HW-DRIVER-OLD' ('Pilote de plus de 5 ans : {0} ({1})' -f $d.Name, $d.Date.ToString('dd/MM/yyyy', $script:Fr)) `
                        'Vérifier s''il existe une version plus récente chez le fabricant.'
                }
            }
        }
    }

    # Périphériques en erreur
    Invoke-Block 'Périphériques en erreur' {
        $problems = @(Get-Cached 'problems' 30 { Get-DeviceProblems })
        foreach ($p in $problems) {
            Add-Finding $(if ($IsWindows) { 'warning' } else { 'info' }) 'HW-DEVICE-ERROR' ('{0} : {1}' -f $p.Name, $p.Problem) `
                $(if ($IsWindows) { 'Ouvrir le Gestionnaire de périphériques : réinstaller ou mettre à jour le pilote.' }
                  else { 'Installer le pilote (paquet du fabricant ou firmware) si ce périphérique doit être utilisé.' })
        }
        if ($problems.Count -gt 0) {
            $rows = foreach ($p in $problems) { , @($p.Name, $p.Category, $p.Problem) }
            $sections.Add([PSCustomObject]@{
                    Title = 'Périphériques en erreur'; Type = 'Table'; Icon = 'warning'
                    Columns = @('Périphérique', 'Catégorie', 'Problème')
                    Rows = @($rows)
                })
        }
        else {
            $sections.Add([PSCustomObject]@{
                    Title = 'Périphériques en erreur'; Type = 'KeyValue'; Icon = 'checkmark_circle'
                    Items = [ordered]@{ 'État' = 'Aucun périphérique en erreur' }
                })
        }
    }

    if ($errors.Count -gt 0) {
        $sections.Add([PSCustomObject]@{ Title = 'Erreurs'; Type = 'KeyValue'; Icon = 'warning'; Items = $errors })
    }

    # Sous-titre de l'en-tête : carte mère, carte graphique, mémoire installée
    $subtitle = @()
    if ($static) {
        $board = @($static.Board['Fabricant'], $static.Board['Modèle']) | Where-Object { $_ }
        if ($board) { $subtitle += ($board -join ' ') -replace ' Technology Co\., Ltd\.| Inc\.| Corporation', '' }
        $gpu = $static.Gpus | Select-Object -First 1
        if ($gpu) { $subtitle += $gpu.Name }
        $ram = @($static.Memory.Modules | Where-Object { $_.Size -gt 0 })
        if ($ram) { $subtitle += '{0} {1}' -f (Format-GiB (($ram | Measure-Object -Property Size -Sum).Sum)), (($ram.Type | Where-Object { $_ } | Select-Object -First 1)) }
    }

    [PSCustomObject]@{ Subtitle = ($subtitle -join ' · ').Trim(); Sections = $sections.ToArray(); Findings = $findings.ToArray() }
}

#region Fonctions ciblées et actions (module.json › functions)

function New-Finding([string]$Severity, [string]$Code, [string]$Message, [string]$Recommendation) {
    [PSCustomObject]@{ Severity = $Severity; Code = $Code; Message = $Message; Recommendation = $Recommendation }
}

# Résultat : Changes = ce qui a changé (ou changerait) ; Blocked = pourquoi l'action est impossible ; Undo = action inverse.
function New-ActionResult([string]$Subtitle, [object[]]$Sections, [object[]]$Findings, [object[]]$Changes, [string]$Blocked, $Undo) {
    $r = [ordered]@{
        Subtitle = $Subtitle; Sections = @($Sections | Where-Object { $_ }); Findings = @($Findings | Where-Object { $_ })
        Changes = @($Changes | Where-Object { $_ }); Blocked = $Blocked
    }
    if ($Undo) { $r.Undo = $Undo }
    [PSCustomObject]$r
}

function Get-AdminBlock {
    if ([Environment]::IsPrivilegedProcess) { return $null }
    "Droits $(if ($IsWindows) { 'administrateur' } else { 'root' }) requis : relancer SysInfo $(if ($IsWindows) { 'en administrateur' } else { 'avec sudo -E' })."
}

# Classes Windows jamais désactivées : disque système, contrôleurs de stockage, processeur, système, clavier et souris
# (on ne pourrait plus réactiver le périphérique).
$script:ProtectedClasses = @('System', 'Computer', 'Processor', 'DiskDrive', 'Volume', 'HDC', 'SCSIAdapter', 'SoftwareDevice', 'Keyboard', 'Mouse', 'HIDClass', 'Firmware', 'SecurityDevices')

# Modules Linux jamais déchargés : affichage, stockage, contrôleurs USB, saisie, systèmes de fichiers.
$script:ProtectedModules = @('nvidia', 'nvidia_drm', 'nvidia_modeset', 'nvidia_uvm', 'amdgpu', 'radeon', 'i915', 'xe', 'nouveau', 'nvme', 'nvme_core',
    'ahci', 'libahci', 'sd_mod', 'xhci_hcd', 'xhci_pci', 'ehci_hcd', 'ehci_pci', 'usbhid', 'hid', 'hid_generic', 'i8042', 'atkbd', 'psmouse',
    'ext4', 'btrfs', 'xfs', 'vfat', 'dm_crypt', 'dm_mod', 'md_mod', 'raid1')

# Périphériques : Id (Windows : InstanceId ; Linux : pci:<slot> ou usb:<port>), Name, Category, Driver, Enabled, Problem.
function Get-DeviceList {
    if ($IsWindows) {
        return @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | ForEach-Object {
                [PSCustomObject]@{
                    Id = $_.InstanceId; Name = $_.FriendlyName ?? $_.InstanceId; Category = $_.Class; Driver = $_.Service
                    Enabled = $_.ConfigManagerErrorCode -ne 22; Problem = if ($_.ConfigManagerErrorCode -notin 0, 22) { ('{0} (code {1})' -f ($script:PnpErrors[[int]$_.ConfigManagerErrorCode] ?? 'Erreur'), $_.ConfigManagerErrorCode) } else { $null }
                }
            })
    }
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($d in Get-LinuxPciDevices) {
        $list.Add([PSCustomObject]@{ Id = "pci:$($d.Slot)"; Name = $d.Name; Category = $d.Category; Driver = $d.Driver; Enabled = $true; Problem = if (-not $d.Driver -and $d.Class.Substring(0, 2) -notin ('05', '06', '0b')) { 'Aucun pilote chargé' } else { $null } })
    }
    foreach ($dir in Get-ChildItem -Path /sys/bus/usb/devices -ErrorAction SilentlyContinue | Where-Object Name -Match '^\d+-[\d.]+$') {
        if ((Read-SysFile (Join-Path $dir.FullName 'bDeviceClass')) -eq '09') { continue }
        $drivers = @(Get-ChildItem -Path "$($dir.FullName)/$($dir.Name):*" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $link = Join-Path $_.FullName 'driver'; if (Test-Path -LiteralPath $link) { Split-Path -Leaf (Get-Item -LiteralPath $link).Target } } | Select-Object -Unique)
        $list.Add([PSCustomObject]@{
                Id = "usb:$($dir.Name)"; Name = (Read-SysFile (Join-Path $dir.FullName 'product')) ?? "Périphérique USB $($dir.Name)"; Category = 'USB'
                Driver = $drivers -join ', '; Enabled = (Read-SysFile (Join-Path $dir.FullName 'authorized')) -ne '0'; Problem = $null
            })
    }
    $list.ToArray()
}

# hardware_list_devices : périphériques avec leur identifiant (à passer à set_device et reinstall_driver).
function Get-SIDevices {
    param(
        [string]$Filter,
        [bool]$ProblemOnly = $false,
        [ValidateRange(1, 2000)][int]$Top = 200
    )
    $devices = @(Get-DeviceList)
    if ($Filter) { $devices = @($devices | Where-Object { $_.Name -like "*$Filter*" -or $_.Category -like "*$Filter*" -or $_.Driver -like "*$Filter*" -or $_.Id -like "*$Filter*" }) }
    if ($ProblemOnly) { $devices = @($devices | Where-Object { $_.Problem -or -not $_.Enabled }) }
    $rows = @($devices | Sort-Object Category, Name | Select-Object -First $Top | ForEach-Object { , @($_.Name, $_.Category, $_.Driver, $(if ($_.Enabled) { 'Oui' } else { 'Non' }), $_.Problem, $_.Id) })
    [PSCustomObject]@{
        Subtitle = '{0} périphérique(s){1}' -f $devices.Count, $(if ($Filter) { " · filtre « $Filter »" } else { '' })
        Sections = @([PSCustomObject]@{ Title = 'Périphériques'; Type = 'Table'; Icon = 'developer_board'; Columns = @('Nom', 'Catégorie', 'Pilote', 'Activé', 'Problème', 'Identifiant'); Rows = $rows })
        Findings = @()
    }
}

function Find-Device([string]$Id) { @(Get-DeviceList) | Where-Object { $_.Id -eq $Id } | Select-Object -First 1 }

function Get-DeviceSection($Device) {
    [PSCustomObject]@{ Title = 'Périphérique'; Type = 'KeyValue'; Icon = 'developer_board'; Items = [ordered]@{ Nom = $Device.Name; Catégorie = $Device.Category; Pilote = $Device.Driver ?? '—'; Activé = $(if ($Device.Enabled) { 'Oui' } else { 'Non' }); Identifiant = $Device.Id } }
}

# hardware_set_device : désactive ou réactive un périphérique.
# Windows : Disable-PnpDevice / Enable-PnpDevice (administrateur). Linux : périphériques USB seulement, par
# /sys/bus/usb/devices/<port>/authorized (root) ; un périphérique PCI ne se désactive pas ici.
function Set-SIDevice {
    param(
        [Parameter(Mandatory)][string]$DeviceId,
        [Parameter(Mandatory)][bool]$Enabled,
        [switch]$DryRun
    )
    $device = Find-Device $DeviceId
    if (-not $device) { return New-ActionResult "Périphérique $DeviceId" @() @() @() "Aucun périphérique « $DeviceId » (identifiants : hardware_list_devices)." }
    $state = if ($Enabled) { 'activé' } else { 'désactivé' }
    $blocked = $null
    if ($device.Enabled -eq $Enabled) { $blocked = "$($device.Name) est déjà $state." }
    $findings = [System.Collections.Generic.List[object]]::new()
    if (-not $blocked -and -not $Enabled) {
        if ($IsWindows -and $device.Category -in $script:ProtectedClasses) { $blocked = "$($device.Name) ($($device.Category)) est nécessaire au système ou à la saisie : SysInfo ne le désactive pas." }
        elseif ($IsLinux -and $device.Id -like 'pci:*') { $blocked = 'Sous Linux, seuls les périphériques USB se désactivent ici (un périphérique PCI se retire en déchargeant son pilote : reinstall_driver).' }
        elseif ($IsLinux) {
            $port = $device.Id.Substring(4)
            $classes = @(Get-ChildItem -Path "/sys/bus/usb/devices/$port/${port}:*" -Directory -ErrorAction SilentlyContinue | ForEach-Object { Read-SysFile (Join-Path $_.FullName 'bInterfaceClass') })
            if ($classes -contains '03') { $blocked = "$($device.Name) est un clavier, une souris ou un autre périphérique de saisie : SysInfo ne le désactive pas." }
            elseif ($classes -contains '08') {
                $mounted = @(& lsblk -J -o NAME,MOUNTPOINTS,TRAN 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue | ForEach-Object blockdevices | Where-Object { $_.tran -eq 'usb' } | ForEach-Object { $_.children } | Where-Object { $_.mountpoints | Where-Object { $_ } })
                if ($mounted) { $findings.Add((New-Finding 'warning' 'HW-DEVICE-STORAGE' 'Un disque USB est monté : le démonter avant, sinon des données en cours d''écriture peuvent être perdues.' 'Éjecter le disque depuis le gestionnaire de fichiers.')) }
            }
        }
        if ($device.Category -in 'Net', 'Réseau' -or $device.Driver -match 'e1000|r8169|igc|iwlwifi|ath|rtw|mt7') { $findings.Add((New-Finding 'warning' 'HW-DEVICE-NETWORK' 'Carte réseau : la connexion qui passe par elle sera coupée.' $null)) }
        if ($device.Category -in 'Display', 'Affichage') { $findings.Add((New-Finding 'warning' 'HW-DEVICE-DISPLAY' 'Carte graphique : l''affichage passe en mode de base (basse résolution) jusqu''à sa réactivation.' $null)) }
    }
    if (-not $blocked) { $blocked = Get-AdminBlock }
    $findings.Add((New-Finding 'info' 'HW-DEVICE-UNDO' "Réversible : hardware_set_device avec enabled = $(-not $Enabled)." $null))
    $change = [PSCustomObject]@{ Target = $device.Name; Property = 'Activé'; Before = $(if ($device.Enabled) { 'Oui' } else { 'Non' }); After = $(if ($Enabled) { 'Oui' } else { 'Non' }) }
    if ($DryRun -or $blocked) { return New-ActionResult "$($device.Name) sera $state" @(Get-DeviceSection $device) $findings @($change) $blocked }

    if ($IsWindows) {
        if ($Enabled) { Enable-PnpDevice -InstanceId $device.Id -Confirm:$false -ErrorAction Stop } else { Disable-PnpDevice -InstanceId $device.Id -Confirm:$false -ErrorAction Stop }
    }
    else { Set-Content -LiteralPath "/sys/bus/usb/devices/$($device.Id.Substring(4))/authorized" -Value $(if ($Enabled) { '1' } else { '0' }) -ErrorAction Stop }
    $now = Find-Device $DeviceId
    $change.After = if ($now.Enabled) { 'Oui' } else { 'Non' }
    New-ActionResult "$($device.Name) $state" @(Get-DeviceSection ($now ?? $device)) @() @($change) $null @{ Function = 'set_device'; Parameters = @{ deviceId = $DeviceId; enabled = -not $Enabled } }
}

# hardware_reinstall_driver : réinstalle le pilote d'un périphérique.
# Windows : pnputil /remove-device puis /scan-devices (Windows redétecte le périphérique et réinstalle son pilote).
# Linux   : modprobe -r puis modprobe du module du périphérique (pilotes d'affichage, de stockage, USB et de saisie exclus).
function Update-SIDriver {
    param(
        [Parameter(Mandatory)][string]$DeviceId,
        [switch]$DryRun
    )
    $device = Find-Device $DeviceId
    if (-not $device) { return New-ActionResult "Périphérique $DeviceId" @() @() @() "Aucun périphérique « $DeviceId » (identifiants : hardware_list_devices)." }
    $blocked = $null
    $findings = [System.Collections.Generic.List[object]]::new()
    $module = $null
    if ($IsWindows) {
        if (-not $blocked -and $device.Category -in 'System', 'Computer', 'Processor', 'DiskDrive', 'Volume', 'HDC', 'SCSIAdapter') { $blocked = "$($device.Name) ($($device.Category)) porte le système : SysInfo ne le retire pas." }
        $findings.Add((New-Finding 'warning' 'HW-DRIVER-REINSTALL' 'Le périphérique disparaît quelques secondes puis est redétecté ; si Windows ne retrouve pas de pilote, il reste sans pilote.' 'Garder le pilote du fabricant sous la main.'))
    }
    else {
        $module = ($device.Driver -split ',\s*' | Select-Object -First 1) -replace '-', '_'
        if (-not $blocked -and -not $module) { $blocked = "$($device.Name) n'a pas de pilote chargé : rien à réinstaller (modprobe <module> pour en charger un)." }
        elseif (-not $blocked -and -not (Test-Path "/sys/module/$module/initstate")) { $blocked = "Le pilote $module est intégré au noyau : il ne se décharge pas." }
        elseif (-not $blocked -and $module -in $script:ProtectedModules) { $blocked = "Le pilote $module sert à l'affichage, au stockage ou à la saisie : le décharger figerait le système." }
        elseif (-not $blocked -and [int](Read-SysFile "/sys/module/$module/refcnt") -gt 0) { $blocked = "Le pilote $module est utilisé par $(Read-SysFile "/sys/module/$module/refcnt") autre(s) module(s) : déchargement impossible." }
        $users = @(Get-ChildItem "/sys/module/$module/drivers" -ErrorAction SilentlyContinue | ForEach-Object { Get-ChildItem $_.FullName -ErrorAction SilentlyContinue | Where-Object Name -Match '^[0-9a-f]{4}:|^\d+-' })
        if ($users.Count -gt 1) { $findings.Add((New-Finding 'warning' 'HW-DRIVER-SHARED' "Le pilote $module gère $($users.Count) périphériques : tous seront arrêtés quelques secondes." $null)) }
    }
    if (-not $blocked) { $blocked = Get-AdminBlock }
    $change = [PSCustomObject]@{ Target = $device.Name; Property = 'Pilote'; Before = $device.Driver ?? '—'; After = 'réinstallé' }
    if ($DryRun -or $blocked) { return New-ActionResult "Le pilote de $($device.Name) sera réinstallé" @(Get-DeviceSection $device) $findings @($change) $blocked }

    if ($IsWindows) {
        $out = & pnputil /remove-device $device.Id 2>&1
        if ($LASTEXITCODE -ne 0) { throw "pnputil /remove-device a échoué : $($out -join ' ')" }
        & pnputil /scan-devices 2>&1 | Out-Null
        Start-Sleep -Seconds 3
    }
    else {
        $out = & modprobe -r $module 2>&1
        if ($LASTEXITCODE -ne 0) { throw "modprobe -r $module a échoué : $($out -join ' ')" }
        $out = & modprobe $module 2>&1
        if ($LASTEXITCODE -ne 0) { throw "modprobe $module a échoué (le périphérique est sans pilote) : $($out -join ' ')" }
        Start-Sleep -Seconds 1
    }
    $now = Find-Device $DeviceId
    $change.After = if ($now) { $now.Driver ?? 'aucun' } else { 'périphérique non redétecté' }
    $result = @()
    if (-not $now -or -not $now.Driver) { $result += New-Finding 'warning' 'HW-DRIVER-MISSING' "$($device.Name) n'a pas retrouvé de pilote." 'Installer le pilote du fabricant, ou redémarrer.' }
    New-ActionResult "Pilote de $($device.Name) réinstallé" @(Get-DeviceSection ($now ?? $device)) $result @($change) $null
}

#endregion

Export-ModuleMember -Function Get-ModuleData, Get-SIDevices, Set-SIDevice, Update-SIDriver
