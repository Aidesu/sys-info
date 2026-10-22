# Module Matériel : carte mère, BIOS/UEFI, GPU, RAM, pilotes, périphériques en erreur.
#
# Sources
#   Windows : CIM (Win32_BaseBoard, Win32_ComputerSystem, Win32_BIOS, Win32_VideoController,
#             Win32_PhysicalMemory, Win32_PhysicalMemoryArray, Win32_PnPSignedDriver, Win32_PnPEntity),
#             registre (HKLM\SYSTEM\CurrentControlSet\Control\SecureBoot\State), nvidia-smi.
#   Linux   : /sys/class/dmi/id, /sys/firmware/efi, udev (udevadm info : barrettes mémoire sans droits root,
#             sinon dmidecode en root), lspci + /sys/bus/pci/devices (pilotes), /sys/module (versions),
#             nvidia-smi (NVIDIA) ou /sys/class/drm (AMD).
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
        if ($driver) {
            # Version du module si elle est publiée, sinon pilote intégré au noyau.
            $version = Read-SysFile "/sys/module/$($driver -replace '-', '_')/version"
            if (-not $version) { $version = "noyau $kernel" }
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
        }
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
            }
        }

    [PSCustomObject]@{ Board = $board; Bios = $bios; Memory = $memory; Drivers = @($drivers) }
}

#endregion

#region GPU

function Get-GpuCards {
    if ($IsWindows) {
        return Get-CimInstance -ClassName Win32_VideoController | ForEach-Object {
            [PSCustomObject]@{
                Name    = $_.Name
                Vendor  = $_.AdapterCompatibility
                Driver  = $_.InfFilename
                Version = $_.DriverVersion
                Slot    = $_.PNPDeviceID -replace '\\.*$', ''
            }
        }
    }
    Get-LinuxPciDevices | Where-Object { $_.Class -like '03*' } | ForEach-Object {
        [PSCustomObject]@{ Name = $_.Name; Vendor = $_.Vendor; Driver = $_.Driver; Version = $_.Version; Slot = $_.Slot }
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
    $errors = [ordered]@{}

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

        # Cartes graphiques
        if ($static.Gpus.Count -gt 0) {
            $rows = foreach ($g in $static.Gpus) { , @($g.Name, $g.Vendor, $g.Driver, $g.Version, $g.Slot) }
            $sections.Add([PSCustomObject]@{
                    Title = 'Cartes graphiques'; Type = 'Table'; Icon = 'desktop'
                    Columns = @('Carte', 'Fabricant', 'Pilote', 'Version du pilote', 'Emplacement')
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

    # Pilotes des périphériques (Linux : relus à chaque fois, c'est rapide ; Windows : lus une fois)
    Invoke-Block 'Pilotes' {
        $drivers = if ($IsWindows) { $static.Drivers } else {
            Get-Cached 'pci' 30 { Get-LinuxPciDevices } | Where-Object { $_.Driver -and $_.Class.Substring(0, 2) -ne '06' } |
                Sort-Object Category, Name |
                ForEach-Object { [PSCustomObject]@{ Name = $_.Name; Category = $_.Category; Driver = $_.Driver; Version = $_.Version } }
        }
        if ($drivers) {
            $rows = foreach ($d in $drivers) { , @($d.Name, $d.Category, $d.Driver, $d.Version) }
            $sections.Add([PSCustomObject]@{
                    Title = 'Pilotes des périphériques'; Type = 'Table'; Icon = 'settings'
                    Columns = @('Périphérique', 'Catégorie', 'Pilote', 'Version')
                    Rows = @($rows)
                })
        }
    }

    # Périphériques en erreur
    Invoke-Block 'Périphériques en erreur' {
        $problems = @(Get-Cached 'problems' 30 { Get-DeviceProblems })
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

    [PSCustomObject]@{ Subtitle = ($subtitle -join ' · ').Trim(); Sections = $sections.ToArray() }
}

Export-ModuleMember -Function Get-ModuleData
