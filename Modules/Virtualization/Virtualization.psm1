# Module Virtualisation & Conteneurs : prérequis matériels (VT-x / AMD-V, SLAT, activation dans le BIOS, KVM),
# machines virtuelles (Hyper-V, KVM / libvirt, VirtualBox), WSL, conteneurs Docker et Podman (état, santé, ports,
# images, volumes, espace occupé et récupérable). Démarrer, arrêter ou redémarrer une VM ou un conteneur (A).
#
# Sources
#   Windows : Win32_Processor (VirtualizationFirmwareEnabled, SecondLevelAddressTranslationExtensions,
#             VMMonitorModeExtensions), Win32_ComputerSystem (HypervisorPresent), CIM root/virtualization/v2
#             (Msvm_ComputerSystem, administrateur), wsl.exe -l -v (sortie UTF-16), VBoxManage, docker, podman.
#   Linux   : /proc/cpuinfo (vmx / svm, ept / npt), /dev/kvm, /sys/module/kvm_*, journalctl -k (« disabled by bios »),
#             virsh domstats (qemu:///system et qemu:///session), VBoxManage, docker, podman.
# Jamais exposé : variables d'environnement et étiquettes des conteneurs (elles contiennent souvent des secrets),
# journaux des conteneurs.

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
    if ($Bytes -ge 1TB) { return Format-Unit ($Bytes / 1TB) 'TiB' '0.0' }
    if ($Bytes -ge 1GB) { return Format-Unit ($Bytes / 1GB) 'GiB' '0.0' }
    if ($Bytes -ge 1MB) { return Format-Unit ($Bytes / 1MB) 'MiB' '0' }
    Format-Unit ($Bytes / 1KB) 'KiB' '0'
}

# « 1.052GB », « 38.06MB », « 0B » (docker) → octets.
function ConvertFrom-Size([string]$Text) {
    if ($Text -notmatch '([\d.]+)\s*([kKMGTP]?i?)B') { return 0 }
    $v = [double]::Parse($Matches[1], [cultureinfo]::InvariantCulture)
    $mult = switch ($Matches[2].ToUpper().TrimEnd('I')) { 'K' { 1e3 } 'M' { 1e6 } 'G' { 1e9 } 'T' { 1e12 } 'P' { 1e15 } default { 1 } }
    $v * $mult
}

$script:Tools = @{}
function Test-Tool([string]$Name) {
    if (-not $script:Tools.ContainsKey($Name)) { $script:Tools[$Name] = [bool](Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue) }
    $script:Tools[$Name]
}

# Commande externe avec délai maximal (un démon Docker bloqué ne doit pas figer la page) ; sortie et code de retour.
function Invoke-Timed([string]$Name, [string[]]$Arguments, [int]$Seconds = 10, [System.Text.Encoding]$Encoding) {
    if (-not (Test-Tool $Name)) { return [PSCustomObject]@{ Ok = $false; Lines = @(); Error = "$Name absent"; Missing = $true } }
    $psi = [System.Diagnostics.ProcessStartInfo]::new((Get-Command $Name -CommandType Application | Select-Object -First 1).Source)
    foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
    if ($Encoding) { $psi.StandardOutputEncoding = $Encoding }
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync(); $err = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($Seconds * 1000)) { try { $p.Kill($true) } catch { }; return [PSCustomObject]@{ Ok = $false; Lines = @(); Error = "$Name ne répond pas (plus de $Seconds s)"; Missing = $false } }
    [PSCustomObject]@{ Ok = $p.ExitCode -eq 0; Lines = @($out.Result -split "`r?`n" | Where-Object { $_ }); Error = ($err.Result -replace '\s+', ' ').Trim(); Missing = $false }
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

#region Prérequis

function Get-VirtSupport {
    Get-Cached 'support' 3600 {
        $r = [ordered]@{ Cpu = $null; Extension = $null; Slat = $null; Firmware = $null; Hypervisor = $null; Kvm = $null; KvmAccess = $null; Nested = $null; Problem = $null }
        if ($IsWindows) {
            $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
            $cs = Get-CimInstance Win32_ComputerSystem
            $r.Cpu = $cpu.Name.Trim()
            $r.Hypervisor = [bool]$cs.HypervisorPresent
            # Hyperviseur actif (Hyper-V, VBS, WSL 2) : Windows ne renvoie plus les capacités, elles sont forcément là.
            if ($r.Hypervisor) { $r.Extension = $true; $r.Slat = $true; $r.Firmware = $true }
            else { $r.Extension = [bool]$cpu.VMMonitorModeExtensions; $r.Slat = [bool]$cpu.SecondLevelAddressTranslationExtensions; $r.Firmware = [bool]$cpu.VirtualizationFirmwareEnabled }
            if ($r.Extension -and -not $r.Firmware) { $r.Problem = 'bios' }
            return [PSCustomObject]$r
        }
        $info = [System.IO.File]::ReadAllText('/proc/cpuinfo')
        $r.Cpu = if ($info -match '(?m)^model name\s*:\s*(.+)$') { $Matches[1].Trim() } else { $null }
        $r.Extension = if ($info -match '(?m)^flags\s*:.*\b(vmx|svm)\b') { $Matches[1] } else { $null }
        $r.Slat = $info -match '(?m)^flags\s*:.*\b(ept|npt)\b'
        $r.Kvm = Test-Path /dev/kvm
        $r.KvmAccess = $false
        if ($r.Kvm) { try { $f = [System.IO.File]::Open('/dev/kvm', 'Open', 'ReadWrite'); $f.Dispose(); $r.KvmAccess = $true } catch { } }
        foreach ($m in 'kvm_intel', 'kvm_amd') { $n = "/sys/module/$m/parameters/nested"; if (Test-Path $n) { $r.Nested = ([System.IO.File]::ReadAllText($n).Trim()) -in 'Y', '1' } }
        $r.Hypervisor = $info -match '(?m)^flags\s*:.*\bhypervisor\b'   # Linux lui-même dans une VM
        $r.Firmware = $r.Kvm
        if ($r.Extension -and -not $r.Kvm) {
            $bios = @(& journalctl -k -b 0 -q --no-pager -g 'disabled by bios|VMX not supported|SVM not supported' 2>$null)
            $r.Problem = if ($bios) { 'bios' } else { 'module' }
            if ($bios) { $r.Firmware = $false }
        }
        if (-not $r.Extension -and -not $r.Hypervisor) { $r.Problem = 'cpu' }
        [PSCustomObject]$r
    }
}

#endregion

#region Machines virtuelles

$script:LibvirtStates = @{ 0 = 'inconnu'; 1 = 'en marche'; 2 = 'bloquée'; 3 = 'en pause'; 4 = 'en cours d''arrêt'; 5 = 'arrêtée'; 6 = 'plantée'; 7 = 'en veille' }

# VMs : Engine, Name, State, Running, Cpus, MemoryBytes, Uri.
function Get-VirtualMachines {
    Get-Cached 'vms' 30 {
        $errors = [System.Collections.Generic.List[string]]::new()
        $vms = [System.Collections.Generic.List[object]]::new()
        if ($IsLinux -and (Test-Tool virsh)) {
            foreach ($uri in 'qemu:///system', 'qemu:///session') {
                $r = Invoke-Timed virsh @('-c', $uri, 'domstats', '--state', '--balloon', '--vcpu') 10
                if (-not $r.Ok) { if ($uri -eq 'qemu:///system' -and $r.Error -notmatch 'Failed to connect socket.*No such file') { $errors.Add("libvirt ($uri) : $($r.Error)") }; continue }
                $cur = $null
                foreach ($line in $r.Lines) {
                    if ($line -match "^Domain: '(.+)'$") { $cur = [ordered]@{ Engine = 'KVM / libvirt'; Name = $Matches[1]; Uri = $uri }; $vms.Add($cur); continue }
                    if ($cur -and $line -match '^\s+([\w.]+)=(.+)$') { $cur[$Matches[1]] = $Matches[2] }
                }
            }
            foreach ($i in 0..($vms.Count - 1)) {
                if ($vms.Count -eq 0) { break }
                $v = $vms[$i]
                $state = [int]$v['state.state']
                $vms[$i] = [PSCustomObject]@{ Engine = $v.Engine; Name = $v.Name; State = $script:LibvirtStates[$state]; Running = $state -eq 1; Cpus = [int]$v['vcpu.maximum']
                    MemoryBytes = [double]$v['balloon.maximum'] * 1KB; Uri = $v.Uri; Id = $v.Name }
            }
        }
        if ($IsWindows) {
            if ([Environment]::IsPrivilegedProcess) {
                $states = @{ 2 = 'en marche'; 3 = 'arrêtée'; 6 = 'enregistrée'; 9 = 'en pause'; 32768 = 'en pause'; 32769 = 'enregistrée'; 32770 = 'en démarrage'; 32773 = 'en enregistrement'; 32774 = 'en arrêt' }
                foreach ($v in Get-CimInstance -Namespace root/virtualization/v2 -ClassName Msvm_ComputerSystem -Filter "Caption='Virtual Machine'" -ErrorAction SilentlyContinue) {
                    $setting = Get-CimAssociatedInstance -InputObject $v -ResultClassName Msvm_VirtualSystemSettingData -ErrorAction SilentlyContinue | Where-Object VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized' | Select-Object -First 1
                    $mem = if ($setting) { Get-CimAssociatedInstance -InputObject $setting -ResultClassName Msvm_MemorySettingData -ErrorAction SilentlyContinue | Select-Object -First 1 } else { $null }
                    $cpu = if ($setting) { Get-CimAssociatedInstance -InputObject $setting -ResultClassName Msvm_ProcessorSettingData -ErrorAction SilentlyContinue | Select-Object -First 1 } else { $null }
                    $vms.Add([PSCustomObject]@{ Engine = 'Hyper-V'; Name = $v.ElementName; State = $states[[int]$v.EnabledState] ?? "$($v.EnabledState)"; Running = $v.EnabledState -eq 2
                            Cpus = $cpu.VirtualQuantity; MemoryBytes = [double]$mem.VirtualQuantity * 1MB; Uri = $null; Id = $v.Name })
                }
            }
            elseif ((Get-Service vmms -ErrorAction SilentlyContinue)) { $errors.Add('Hyper-V : liste des VMs lisible en administrateur.') }
        }
        if (Test-Tool VBoxManage) {
            $running = @((Invoke-Timed VBoxManage @('list', 'runningvms') 10).Lines | ForEach-Object { if ($_ -match '\{([^}]+)\}') { $Matches[1] } })
            foreach ($line in (Invoke-Timed VBoxManage @('list', 'vms') 10).Lines) {
                if ($line -match '^"(.+)"\s+\{([^}]+)\}$') {
                    $vms.Add([PSCustomObject]@{ Engine = 'VirtualBox'; Name = $Matches[1]; State = if ($running -contains $Matches[2]) { 'en marche' } else { 'arrêtée' }; Running = $running -contains $Matches[2]
                            Cpus = $null; MemoryBytes = $null; Uri = $null; Id = $Matches[2] })
                }
            }
        }
        [PSCustomObject]@{ Vms = @($vms); Errors = @($errors) }
    }
}

# WSL (Windows) : distributions, version, état. wsl.exe écrit en UTF-16.
function Get-WslDistributions {
    if (-not $IsWindows) { return [PSCustomObject]@{ Installed = $false; Distros = @() } }
    Get-Cached 'wsl' 60 {
        $r = Invoke-Timed wsl.exe @('--list', '--verbose') 10 ([System.Text.Encoding]::Unicode)
        if (-not $r.Ok -or -not $r.Lines) { return [PSCustomObject]@{ Installed = -not $r.Missing -and $r.Lines.Count -gt 0; Distros = @() } }
        $distros = foreach ($line in $r.Lines | Select-Object -Skip 1) {
            if ($line -match '^\s*(\*?)\s*(\S+)\s+(\S+)\s+(\d+)\s*$') {
                [PSCustomObject]@{ Name = $Matches[2]; Default = $Matches[1] -eq '*'; State = @{ Running = 'en marche'; Stopped = 'arrêtée'; Installing = 'installation' }[$Matches[3]] ?? $Matches[3]; Running = $Matches[3] -eq 'Running'; Version = [int]$Matches[4] }
            }
        }
        [PSCustomObject]@{ Installed = $true; Distros = @($distros) }
    }
}

#endregion

#region Conteneurs

# Conteneurs d'un moteur (docker ou podman) : Engine, Id, Name, Image, State, Status, Health, Ports, Project, ExitCode, Restarting.
function Get-Containers([string]$Engine) {
    Get-Cached "containers:$Engine" 15 {
        $r = Invoke-Timed $Engine @('ps', '-a', '--format', '{{json .}}') 10
        if ($r.Missing) { return [PSCustomObject]@{ Available = $false; Error = $null; Items = @() } }
        if (-not $r.Ok) { return [PSCustomObject]@{ Available = $true; Error = $r.Error; Items = @() } }
        # podman --format json renvoie un tableau ; docker, un objet par ligne.
        $raw = if ($r.Lines.Count -eq 1 -and $r.Lines[0].StartsWith('[')) { @($r.Lines[0] | ConvertFrom-Json) } else { @($r.Lines | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } }) }
        $items = foreach ($c in $raw) {
            $name = if ($c.Names -is [array]) { $c.Names[0] } else { "$($c.Names)" }
            $status = "$($c.Status)"
            $state = "$($c.State)".ToLower()
            $project = if ($c.Labels -is [string] -and $c.Labels -match 'com\.docker\.compose\.project=([^,]+)') { $Matches[1] } elseif ($c.Labels.'com.docker.compose.project') { $c.Labels.'com.docker.compose.project' } elseif ($c.Labels.'io.podman.compose.project') { $c.Labels.'io.podman.compose.project' } else { $null }
            $ports = if ($c.Ports -is [string]) { $c.Ports } else { (@($c.Ports | ForEach-Object { if ($_.host_port) { "$($_.host_port)->$($_.container_port)/$($_.protocol)" } }) -join ', ') }
            [PSCustomObject]@{
                Engine = $Engine; Id = "$($c.ID ?? $c.Id)".Substring(0, [Math]::Min(12, "$($c.ID ?? $c.Id)".Length)); Name = $name; Image = $c.Image; State = $state; Status = $status
                Health = if ($status -match '\((healthy|unhealthy|health: starting)\)') { $Matches[1] -replace 'health: ', '' } else { $null }
                Ports = ($ports -replace '0\.0\.0\.0:', '' -replace '\[::\]:\d+->\d+/\w+,?\s*', '').Trim(', ')
                Project = $project; ExitCode = if ($status -match 'Exited \((\d+)\)') { [int]$Matches[1] } elseif ($null -ne $c.ExitCode) { [int]$c.ExitCode } else { $null }
                Restarting = $state -eq 'restarting'; Created = "$($c.CreatedAt)"
            }
        }
        [PSCustomObject]@{ Available = $true; Error = $null; Items = @($items) }
    }
}

# Espace occupé par le moteur : images, conteneurs, volumes, cache de construction (total et récupérable).
function Get-EngineSpace([string]$Engine) {
    Get-Cached "df:$Engine" 300 {
        $r = Invoke-Timed $Engine @('system', 'df', '--format', '{{json .}}') 20
        if (-not $r.Ok) { return @() }
        foreach ($line in $r.Lines) {
            try { $j = $line | ConvertFrom-Json } catch { continue }
            $type = @{ 'Images' = 'Images'; 'Containers' = 'Conteneurs'; 'Local Volumes' = 'Volumes'; 'Build Cache' = 'Cache de construction' }["$($j.Type)"] ?? "$($j.Type)"
            [PSCustomObject]@{ Engine = $Engine; Type = $type; Count = [int]"$($j.TotalCount)"; Active = [int]"$($j.Active)"; Size = ConvertFrom-Size "$($j.Size)"; Reclaimable = ConvertFrom-Size "$($j.Reclaimable)" }
        }
    }
}

function Get-Engines { @('docker', 'podman' | Where-Object { Test-Tool $_ }) }

#endregion

#region Vue d'ensemble

function Get-ModuleData {
    $sections = [System.Collections.Generic.List[object]]::new()
    $findings = [System.Collections.Generic.List[object]]::new()
    $errors = [ordered]@{}
    function Invoke-Block([string]$Name, [scriptblock]$Block) {
        try { & $Block } catch { $errors[$Name] = $_.Exception.Message; $null }
    }

    # Prérequis
    $s = Invoke-Block 'Prérequis' { Get-VirtSupport }
    if ($s) {
        $yes = { param($v) if ($null -eq $v) { '—' } elseif ($v) { 'oui' } else { 'non' } }
        $items = [ordered]@{ 'Processeur' = $s.Cpu ?? '—'
            'Extensions de virtualisation' = if ($s.Extension -is [string]) { $(if ($s.Extension -eq 'vmx') { 'oui (Intel VT-x)' } else { 'oui (AMD-V)' }) } else { & $yes $s.Extension }
            'Traduction d''adresses (SLAT)' = & $yes $s.Slat; 'Activée dans le BIOS / UEFI' = & $yes $s.Firmware }
        if ($IsWindows) { $items['Hyperviseur actif (Hyper-V, VBS, WSL 2)'] = & $yes $s.Hypervisor }
        else {
            $items['KVM'] = if ($s.Kvm) { if ($s.KvmAccess) { 'disponible (/dev/kvm accessible)' } else { 'disponible, /dev/kvm non accessible à ce compte' } } else { 'indisponible' }
            if ($null -ne $s.Nested) { $items['Virtualisation imbriquée'] = & $yes $s.Nested }
            if ($s.Hypervisor) { $items['Ce système'] = 'tourne lui-même dans une machine virtuelle' }
        }
        $sections.Add([PSCustomObject]@{ Title = 'Prérequis'; Type = 'KeyValue'; Icon = 'developer_board'; Items = $items })
        switch ($s.Problem) {
            'bios' { $findings.Add((New-Finding 'warning' 'VIRT-DISABLED-BIOS' 'La virtualisation est prise en charge par le processeur mais désactivée dans le BIOS / UEFI.' 'Activer Intel VT-x / AMD SVM dans le BIOS / UEFI (menu CPU ou Advanced).')) }
            'module' { $findings.Add((New-Finding 'info' 'VIRT-KVM-MISSING' 'Le processeur prend en charge la virtualisation mais le module KVM n''est pas chargé.' 'Charger le module (modprobe kvm_intel ou kvm_amd) ou installer le paquet de virtualisation.')) }
            'cpu' { $findings.Add((New-Finding 'info' 'VIRT-UNSUPPORTED' 'Le processeur ne prend pas en charge la virtualisation matérielle.' $null)) }
        }
        if ($IsLinux -and $s.Kvm -and -not $s.KvmAccess) { $findings.Add((New-Finding 'info' 'VIRT-KVM-NO-ACCESS' "Ce compte n'a pas accès à /dev/kvm : les VMs lancées par lui seraient très lentes (sans accélération)." 'Ajouter le compte au groupe kvm (puis se reconnecter).')) }
    }

    # Machines virtuelles
    $vm = Invoke-Block 'Machines virtuelles' { Get-VirtualMachines }
    foreach ($e in @($vm.Errors)) { $errors['Machines virtuelles'] = $e }
    $vms = @($vm.Vms)
    if ($vms.Count) {
        $sections.Add([PSCustomObject]@{ Title = 'Machines virtuelles'; Type = 'Table'; Icon = 'server'; Columns = @('Machine', 'Moteur', 'État', 'Processeurs', 'Mémoire (GiB)')
                Rows = @($vms | Sort-Object { -not $_.Running }, Name | ForEach-Object { , @($_.Name, $_.Engine, $_.State, $_.Cpus, $(if ($_.MemoryBytes) { [Math]::Round($_.MemoryBytes / 1GB, 1) } else { $null })) }) })
        foreach ($v in $vms | Where-Object { $_.State -eq 'plantée' }) { $findings.Add((New-Finding 'warning' 'VIRT-VM-CRASHED' "La machine virtuelle $($v.Name) a planté." 'Voir son journal (libvirt : /var/log/libvirt/qemu) puis la redémarrer.')) }
    }

    # WSL
    $wsl = Invoke-Block 'WSL' { Get-WslDistributions }
    if ($wsl.Distros.Count) {
        $sections.Add([PSCustomObject]@{ Title = 'WSL'; Type = 'Table'; Icon = 'desktop'; Columns = @('Distribution', 'État', 'Version WSL', 'Par défaut')
                Rows = @($wsl.Distros | ForEach-Object { , @($_.Name, $_.State, $_.Version, $(if ($_.Default) { 'oui' } else { '' })) }) })
        foreach ($d in $wsl.Distros | Where-Object Version -eq 1) { $findings.Add((New-Finding 'info' 'VIRT-WSL1' "$($d.Name) utilise WSL 1." "Passer en WSL 2 pour de meilleures performances et la compatibilité (wsl --set-version $($d.Name) 2).")) }
    }

    # Conteneurs
    $containers = [System.Collections.Generic.List[object]]::new()
    $space = [System.Collections.Generic.List[object]]::new()
    foreach ($engine in Get-Engines) {
        $c = Invoke-Block $engine { Get-Containers $engine }
        if ($c.Error) {
            $errors[$engine] = $c.Error
            if ($c.Error -match 'permission denied') { $findings.Add((New-Finding 'info' 'VIRT-DOCKER-DENIED' "$engine est installé mais ce compte n'a pas accès au démon." "Ajouter le compte au groupe $engine, ou lancer SysInfo avec les droits.")) }
            elseif ($c.Error -match 'Cannot connect|Is the docker daemon running|ne répond pas') { $findings.Add((New-Finding 'info' 'VIRT-DOCKER-DOWN' "Le démon $engine ne répond pas." "Démarrer le service ($engine.service) s'il doit tourner.")) }
            continue
        }
        foreach ($item in $c.Items) { $containers.Add($item) }
        $df = @(Invoke-Block "$engine (espace)" { Get-EngineSpace $engine } | Where-Object { $_ })
        if (($df | Measure-Object Count -Sum).Sum -gt 0) { foreach ($d in $df) { $space.Add($d) } }
    }
    if ($containers.Count) {
        $sections.Add([PSCustomObject]@{ Title = 'Conteneurs'; Type = 'Table'; Icon = 'apps_list'; Columns = @('Conteneur', 'Projet', 'Image', 'État', 'Santé', 'Ports', 'Moteur')
                Rows = @($containers | Sort-Object { $_.State -ne 'running' }, Project, Name | ForEach-Object { , @($_.Name, $_.Project, $_.Image, $_.Status, $_.Health, $_.Ports, $_.Engine) }) })
        foreach ($c in $containers | Where-Object Health -eq 'unhealthy') { $findings.Add((New-Finding 'warning' 'VIRT-CONTAINER-UNHEALTHY' "Le conteneur $($c.Name) est en mauvaise santé (test de santé en échec)." "Voir ses journaux ($($c.Engine) logs $($c.Name)).")) }
        foreach ($c in $containers | Where-Object Restarting) { $findings.Add((New-Finding 'warning' 'VIRT-CONTAINER-RESTARTING' "Le conteneur $($c.Name) redémarre en boucle." "Voir ses journaux ($($c.Engine) logs $($c.Name)) : il plante au démarrage.")) }
        foreach ($c in $containers | Where-Object { $_.State -eq 'exited' -and $_.ExitCode -and $_.ExitCode -notin 0, 130, 137, 143 } | Select-Object -First 5) {
            $findings.Add((New-Finding 'info' 'VIRT-CONTAINER-EXITED' "Le conteneur $($c.Name) s'est arrêté en erreur (code $($c.ExitCode))." "Voir ses journaux ($($c.Engine) logs $($c.Name)) ; le supprimer s'il ne sert plus."))
        }
    }
    if ($space.Count) {
        $sections.Add([PSCustomObject]@{ Title = 'Espace occupé par les conteneurs'; Type = 'Table'; Icon = 'hard_drive'; Columns = @('Moteur', 'Type', 'Nombre', 'Actifs', 'Taille (GiB)', 'Récupérable (GiB)')
                Rows = @($space | ForEach-Object { , @($_.Engine, $_.Type, $_.Count, $_.Active, [Math]::Round($_.Size / 1GB, 2), [Math]::Round($_.Reclaimable / 1GB, 2)) }) })
        $reclaim = ($space | Measure-Object Reclaimable -Sum).Sum
        if ($reclaim -ge 10GB) { $findings.Add((New-Finding 'info' 'VIRT-SPACE-RECLAIMABLE' ('{0} récupérables (images, conteneurs arrêtés, cache de construction inutilisés).' -f (Format-Bytes $reclaim)) 'docker system prune (et docker builder prune) libèrent cet espace ; vérifier d''abord ce qui sera supprimé.')) }
    }

    if ($errors.Count) { $sections.Add([PSCustomObject]@{ Title = 'Remarques et erreurs de collecte'; Type = 'KeyValue'; Icon = 'info'; Items = $errors }) }

    $parts = @()
    if ($vms.Count) { $parts += '{0} VM(s), {1} en marche' -f $vms.Count, @($vms | Where-Object Running).Count }
    if ($wsl.Distros.Count) { $parts += 'WSL : {0} distribution(s)' -f $wsl.Distros.Count }
    if ($containers.Count) { $parts += '{0} conteneur(s), {1} en marche' -f $containers.Count, @($containers | Where-Object State -eq 'running').Count }
    if (-not $parts) { $parts += if ($s.Problem) { 'virtualisation indisponible' } else { 'aucune VM ni conteneur' } }
    [PSCustomObject]@{ Subtitle = $parts -join ' · '; Sections = $sections.ToArray(); Findings = $findings.ToArray() }
}

#endregion

#region Fonctions ciblées

# virtualization_list_containers : conteneurs (filtre), avec images et volumes.
function Get-SIContainers {
    param([string]$Filter, [ValidateSet('all', 'running', 'stopped')][string]$State = 'all', [bool]$IncludeImages = $false)
    $sections = [System.Collections.Generic.List[object]]::new()
    $all = foreach ($engine in Get-Engines) { $script:Cache.Remove("containers:$engine"); (Get-Containers $engine).Items }
    $all = @($all | Where-Object { $_ })
    if ($Filter) { $all = @($all | Where-Object { "$($_.Name) $($_.Image) $($_.Project)" -like "*$Filter*" }) }
    if ($State -eq 'running') { $all = @($all | Where-Object State -eq 'running') } elseif ($State -eq 'stopped') { $all = @($all | Where-Object State -ne 'running') }
    $sections.Add([PSCustomObject]@{ Title = 'Conteneurs'; Type = 'Table'; Icon = 'apps_list'; Columns = @('Conteneur', 'Id', 'Projet', 'Image', 'État', 'Santé', 'Ports', 'Créé', 'Moteur')
            Rows = @($all | ForEach-Object { , @($_.Name, $_.Id, $_.Project, $_.Image, $_.Status, $_.Health, $_.Ports, $_.Created, $_.Engine) }) })
    if ($IncludeImages) {
        foreach ($engine in Get-Engines) {
            $r = Invoke-Timed $engine @('images', '--format', '{{json .}}') 15
            $rows = foreach ($line in $r.Lines) {
                try { $i = $line | ConvertFrom-Json } catch { continue }
                $repo = if ($i.Repository) { $i.Repository } else { "$($i.Names | Select-Object -First 1)" }
                , @($repo, "$($i.Tag)", "$($i.ID ?? $i.Id)".Substring(0, 12), [Math]::Round((ConvertFrom-Size "$($i.Size)") / 1MB), "$($i.CreatedSince ?? $i.CreatedAt)", "$($i.Containers)", $engine)
            }
            $sections.Add([PSCustomObject]@{ Title = "Images ($engine)"; Type = 'Table'; Icon = 'hard_drive'; Columns = @('Image', 'Étiquette', 'Id', 'Taille (MiB)', 'Créée', 'Conteneurs', 'Moteur'); Rows = @($rows) })
            $vol = Invoke-Timed $engine @('volume', 'ls', '--format', '{{json .}}') 15
            $vrows = foreach ($line in $vol.Lines) { try { $v = $line | ConvertFrom-Json; , @("$($v.Name)", "$($v.Driver)", $engine) } catch { } }
            $sections.Add([PSCustomObject]@{ Title = "Volumes ($engine)"; Type = 'Table'; Icon = 'hard_drive'; Columns = @('Volume', 'Pilote', 'Moteur'); Rows = @($vrows) })
        }
    }
    [PSCustomObject]@{ Subtitle = '{0} conteneur(s)' -f $all.Count; Sections = $sections.ToArray(); Findings = @() }
}

# Cible d'une action : un conteneur ou une VM unique, trouvé par nom (et moteur).
function Find-Target([string]$Kind, [string]$Name, [string]$Engine) {
    $found = @()
    if ($Kind -in 'container', 'auto') {
        foreach ($e in Get-Engines) {
            if ($Engine -and $Engine -ne $e) { continue }
            $script:Cache.Remove("containers:$e")
            $found += @((Get-Containers $e).Items | Where-Object { $_.Name -eq $Name -or $_.Id -eq $Name } | ForEach-Object { [PSCustomObject]@{ Kind = 'container'; Engine = $e; Name = $_.Name; Running = $_.State -eq 'running'; State = $_.Status; Item = $_ } })
        }
    }
    if ($Kind -in 'vm', 'auto') {
        $script:Cache.Remove('vms'); $script:Cache.Remove('wsl')
        $map = @{ 'KVM / libvirt' = 'libvirt'; 'Hyper-V' = 'hyperv'; 'VirtualBox' = 'virtualbox' }
        $found += @((Get-VirtualMachines).Vms | Where-Object { $_.Name -eq $Name -and (-not $Engine -or $map[$_.Engine] -eq $Engine) } | ForEach-Object { [PSCustomObject]@{ Kind = 'vm'; Engine = $map[$_.Engine]; Name = $_.Name; Running = $_.Running; State = $_.State; Item = $_ } })
        $found += @((Get-WslDistributions).Distros | Where-Object { $_.Name -eq $Name -and (-not $Engine -or $Engine -eq 'wsl') } | ForEach-Object { [PSCustomObject]@{ Kind = 'vm'; Engine = 'wsl'; Name = $_.Name; Running = $_.Running; State = $_.State; Item = $_ } })
    }
    $found
}

# virtualization_control : démarre, arrête ou redémarre un conteneur ou une machine virtuelle.
function Set-SIVirtualState {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('start', 'stop', 'restart')][string]$Action,
        [ValidateSet('auto', 'container', 'vm')][string]$Kind = 'auto',
        [ValidateSet('docker', 'podman', 'libvirt', 'hyperv', 'virtualbox', 'wsl')][string]$Engine,
        [switch]$DryRun
    )
    $found = @(Find-Target $Kind $Name $Engine)
    $blocked = $null
    $t = $null
    if (-not $found.Count) { $blocked = "Aucun conteneur ni machine virtuelle « $Name »$(if ($Engine) { " ($Engine)" })." }
    elseif ($found.Count -gt 1) { $blocked = "« $Name » existe dans plusieurs moteurs ($(($found | ForEach-Object Engine) -join ', ')) : préciser engine." }
    else {
        $t = $found[0]
        if ($Action -eq 'start' -and $t.Running) { $blocked = "$($t.Name) est déjà en marche." }
        elseif ($Action -eq 'stop' -and -not $t.Running) { $blocked = "$($t.Name) est déjà arrêté(e)." }
        elseif ($Action -eq 'restart' -and -not $t.Running) { $blocked = "$($t.Name) est arrêté(e) : utiliser start." }
        elseif ($t.Engine -eq 'hyperv' -and -not [Environment]::IsPrivilegedProcess) { $blocked = 'Piloter Hyper-V demande les droits administrateur.' }
        elseif ($t.Engine -eq 'wsl' -and $Action -eq 'restart') { $blocked = 'WSL : arrêter (stop) puis démarrer (start) la distribution.' }
    }
    $label = if ($t) { "$($t.Name) ($(@{ docker = 'conteneur Docker'; podman = 'conteneur Podman'; libvirt = 'VM KVM'; hyperv = 'VM Hyper-V'; virtualbox = 'VM VirtualBox'; wsl = 'distribution WSL' }[$t.Engine]))" } else { $Name }
    $verb = @{ start = 'démarré(e)'; stop = 'arrêté(e)'; restart = 'redémarré(e)' }[$Action]
    $items = [ordered]@{ 'Cible' = $label; 'État actuel' = $t.State ?? '—' }
    if ($t.Kind -eq 'container') { $items['Image'] = $t.Item.Image; $items['Ports'] = $t.Item.Ports; if ($t.Item.Project) { $items['Projet'] = $t.Item.Project } }
    if ($t.Kind -eq 'vm' -and $t.Item.Cpus) { $items['Processeurs'] = $t.Item.Cpus; $items['Mémoire'] = Format-Bytes $t.Item.MemoryBytes }
    $section = [PSCustomObject]@{ Title = 'Cible'; Type = 'KeyValue'; Icon = $(if ($t.Kind -eq 'vm') { 'server' } else { 'apps_list' }); Items = $items }
    $findings = @()
    if ($t -and $Action -in 'stop', 'restart') {
        if ($t.Kind -eq 'container' -and $t.Item.Ports) { $findings += New-Finding 'warning' 'VIRT-STOP-SERVICES' "Les services publiés par ce conteneur ($($t.Item.Ports)) seront coupés." $null }
        if ($t.Kind -eq 'vm') { $findings += New-Finding 'warning' 'VIRT-STOP-VM' 'Arrêt propre demandé au système invité (comme le bouton d''alimentation) : ce qui n''est pas enregistré dans la VM peut être perdu ; une VM qui ignore la demande reste allumée.' $null }
    }
    if ($t -and $Action -eq 'start' -and $t.Kind -eq 'vm' -and $t.Item.MemoryBytes) {
        $free = if ($IsLinux) { if ([System.IO.File]::ReadAllText('/proc/meminfo') -match 'MemAvailable:\s+(\d+)') { [double]$Matches[1] * 1KB } } else { [double](Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory * 1KB }
        if ($free -and $t.Item.MemoryBytes -gt $free) { $findings += New-Finding 'warning' 'VIRT-START-MEMORY' ('La VM demande {0} de mémoire, {1} disponibles : l''hôte va ralentir ou utiliser le swap.' -f (Format-Bytes $t.Item.MemoryBytes), (Format-Bytes $free)) $null }
    }
    $before = if ($t) { if ($t.Running) { 'en marche' } else { 'arrêté(e)' } } else { $null }
    $afterText = @{ start = 'en marche'; stop = 'arrêté(e)'; restart = 'redémarré(e)' }[$Action]
    $change = New-Change $label 'État' $before $afterText
    if ($DryRun -or $blocked) { return New-ActionResult "$label sera $verb" @($section) $findings @($change) $blocked $null }

    $r = switch ($t.Engine) {
        { $_ -in 'docker', 'podman' } { Invoke-Timed $t.Engine @($Action, $t.Item.Id) 120 }
        'libvirt' {
            switch ($Action) {
                'start' { Invoke-Timed virsh @('-c', $t.Item.Uri, 'start', $t.Name) 60 }
                'stop' { Invoke-Timed virsh @('-c', $t.Item.Uri, 'shutdown', $t.Name) 60 }
                'restart' { Invoke-Timed virsh @('-c', $t.Item.Uri, 'reboot', $t.Name) 60 }
            }
        }
        'virtualbox' {
            switch ($Action) {
                'start' { Invoke-Timed VBoxManage @('startvm', $t.Item.Id, '--type', 'headless') 120 }
                'stop' { Invoke-Timed VBoxManage @('controlvm', $t.Item.Id, 'acpipowerbutton') 60 }
                'restart' { Invoke-Timed VBoxManage @('controlvm', $t.Item.Id, 'reset') 60 }
            }
        }
        'wsl' {
            if ($Action -eq 'stop') { Invoke-Timed wsl.exe @('--terminate', $t.Name) 60 ([System.Text.Encoding]::Unicode) } else { Invoke-Timed wsl.exe @('-d', $t.Name, '--exec', 'true') 120 ([System.Text.Encoding]::Unicode) }
        }
        'hyperv' {
            # RequestStateChange : 2 = démarrer, 4 = arrêt propre (via le service d'arrêt de l'invité), 11 = redémarrer.
            $vm = Get-CimInstance -Namespace root/virtualization/v2 -ClassName Msvm_ComputerSystem -Filter "Name='$($t.Item.Id)'"
            if ($Action -eq 'stop') {
                $svc = Get-CimAssociatedInstance -InputObject $vm -ResultClassName Msvm_ShutdownComponent | Select-Object -First 1
                $res = if ($svc) { Invoke-CimMethod -InputObject $svc -MethodName InitiateShutdown -Arguments @{ Force = $false; Reason = 'SysInfo' } } else { Invoke-CimMethod -InputObject $vm -MethodName RequestStateChange -Arguments @{ RequestedState = [uint16]4 } }
            }
            else { $res = Invoke-CimMethod -InputObject $vm -MethodName RequestStateChange -Arguments @{ RequestedState = [uint16]$(if ($Action -eq 'start') { 2 } else { 11 }) } }
            [PSCustomObject]@{ Ok = $res.ReturnValue -in 0, 4096; Lines = @(); Error = "code $($res.ReturnValue)" }
        }
    }
    if (-not $r.Ok) { throw "$label n'a pas pu être $verb : $($r.Error)" }
    $script:Cache.Clear()
    $undo = switch ($Action) { 'start' { @{ Function = 'control'; Parameters = @{ name = $t.Name; action = 'stop'; engine = $t.Engine } } } 'stop' { @{ Function = 'control'; Parameters = @{ name = $t.Name; action = 'start'; engine = $t.Engine } } } default { $null } }
    $note = if ($t.Kind -eq 'vm' -and $Action -eq 'stop') { @(New-Finding 'info' 'VIRT-STOP-REQUESTED' 'Arrêt demandé : la VM s''éteint dans les secondes qui suivent (vérifier son état).' $null) } else { @() }
    New-ActionResult "$label $verb" @($section) $note @(New-Change $label 'État' $before $afterText) $null $undo
}

#endregion

Export-ModuleMember -Function Get-ModuleData, Get-SIContainers, Set-SIVirtualState
