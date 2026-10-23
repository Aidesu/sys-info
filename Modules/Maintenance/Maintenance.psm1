# Module Maintenance : points de restauration, intégrité des fichiers système, image Windows, vérification des disques,
# nettoyage, optimisation (TRIM), file d'impression, réparations (Windows Update, WMI, cache d'icônes), redémarrage
# planifié.
#
# Sources
#   Windows : CIM root/default SystemRestore (points de restauration ; CreateRestorePoint), registre SystemRestore,
#             sfc.exe, DISM.exe, chkdsk.exe, fsutil, winmgmt.exe, Optimize-Volume, Get-PhysicalDisk, Get-Printer /
#             Get-PrintJob, service Spooler, dossiers Temp, cache des miniatures, Corbeille, SoftwareDistribution.
#   Linux   : snapper / timeshift (points de restauration), rpm -Va / debsums / pacman -Qkk (intégrité des paquets),
#             dnf / apt (réinstallation, cache), btrfs device stats / scrub, dumpe2fs, fstrim, lpstat / cancel (CUPS),
#             journalctl --vacuum-size, ~/.cache/thumbnails, ~/.local/share/Trash, shutdown.
#
# Toute action passe par -DryRun (aperçu) et la confirmation de SysInfo ; les actions critiques (C) exigent en plus
# les droits administrateur et sont précédées d'un point de restauration (créé par New-SIRestorePoint, appelé par
# SysInfo). Rien n'est jamais supprimé hors des emplacements listés ci-dessus.

$script:Fr = [cultureinfo]::GetCultureInfo('fr-FR')

# Cache des données qui changent peu : recalculées au plus toutes les $Seconds secondes.
$script:Cache = @{}
function Get-Cached([string]$Key, [int]$Seconds, [scriptblock]$Compute) {
    $entry = $script:Cache[$Key]
    if ($entry -and ((Get-Date) - $entry.At).TotalSeconds -lt $Seconds) { return $entry.Value }
    $value = & $Compute
    $script:Cache[$Key] = @{ At = Get-Date; Value = $value }
    $value
}

#region Outils

function Format-Date($Date) { if ($Date) { ([datetime]$Date).ToString('dd/MM/yyyy HH:mm', $script:Fr) } else { $null } }

function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1GB) { return '{0} GiB' -f ($Bytes / 1GB).ToString('0.0', $script:Fr) }
    if ($Bytes -ge 1MB) { return '{0} MiB' -f ($Bytes / 1MB).ToString('0', $script:Fr) }
    '{0} KiB' -f [Math]::Ceiling($Bytes / 1KB)
}

function New-Finding([string]$Severity, [string]$Code, [string]$Message, [string]$Recommendation) {
    [PSCustomObject]@{ Severity = $Severity; Code = $Code; Message = $Message; Recommendation = $Recommendation }
}

# Résultat d'une fonction : Changes = ce qui a changé (ou changerait) ; Blocked = pourquoi une action est impossible ;
# Undo = fonction du module qui annule l'action.
function New-Result([string]$Subtitle, [object[]]$Sections, [object[]]$Findings, [object[]]$Changes, [string]$Blocked, $Undo) {
    $r = [ordered]@{
        Subtitle = $Subtitle
        Sections = @($Sections | Where-Object { $_ })
        Findings = @($Findings | Where-Object { $_ })
        Changes  = @($Changes | Where-Object { $_ })
        Blocked  = $Blocked
    }
    if ($Undo) { $r.Undo = $Undo }
    [PSCustomObject]$r
}

function New-Change([string]$Target, [string]$Property, $Before, $After) {
    [PSCustomObject]@{ Target = $Target; Property = $Property; Before = $Before; After = $After }
}

function Test-Elevated { [Environment]::IsPrivilegedProcess }

function Get-AdminBlock {
    if (Test-Elevated) { return $null }
    "Droits $(if ($IsWindows) { 'administrateur' } else { 'root' }) requis : relancer SysInfo $(if ($IsWindows) { 'en administrateur' } else { 'avec sudo -E' })."
}

# Lance un programme en console et renvoie ses lignes de sortie (sfc et DISM écrivent en UTF-16 sous Windows).
# Pendant l'exécution, chaque ligne part dans le journal en direct de SysInfo (Write-Information) et un pourcentage
# (« Verification 45% complete », « [==== 45.0% ] ») met à jour la progression (Write-Progress).
function Invoke-Native([string]$Path, [string[]]$Arguments) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    Write-Information "$name $($Arguments -join ' ')"
    $previous = [Console]::OutputEncoding
    try {
        if ($IsWindows) { [Console]::OutputEncoding = [System.Text.Encoding]::Unicode }
        $last = $null
        @(& $Path @Arguments 2>&1 | ForEach-Object {
                $line = ("$_" -replace "`0", '').Trim()
                if (-not $line) { return }
                if ($line -match '(\d{1,3})(?:[.,]\d+)?\s*%') {
                    Write-Progress -Activity $name -Status $line -PercentComplete ([Math]::Min(100, [int]$Matches[1]))
                }
                elseif ($line -ne $last) { Write-Information $line }
                $last = $line
                $line
            })
    }
    finally { [Console]::OutputEncoding = $previous }
}

function Get-SystemDrive { if ($IsWindows) { $env:SystemDrive } else { '/' } }

# Dernière vérification des paquets (Linux) : la réparation s'appuie dessus sans relancer rpm -Va (plusieurs minutes).
$script:StateFile = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'SysInfo/state/modified-packages.json'

#endregion

#region Points de restauration

# Windows : protection du système (registre DisableSR, stratégie) et points existants (CIM SystemRestore, admin).
# Linux   : snapper (configuration « root ») ou Timeshift.
function Get-RestoreSupport {
    if ($IsWindows) {
        $policy = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore' -ErrorAction SilentlyContinue
        if ($policy.DisableSR -eq 1) { return @{ Tool = 'Restauration du système'; Problem = 'la restauration du système est désactivée par une stratégie' } }
        $points = @(Get-CimInstance -Namespace root/default -ClassName SystemRestore -ErrorAction SilentlyContinue)
        $vss = (Get-Service -Name VSS -ErrorAction SilentlyContinue)
        if ($vss -and $vss.StartType -eq 'Disabled') { return @{ Tool = 'Restauration du système'; Problem = 'le service Cliché instantané des volumes (VSS) est désactivé'; Points = $points } }
        return @{ Tool = 'Restauration du système'; Problem = $null; Points = $points }
    }
    if (Get-Command snapper -ErrorAction SilentlyContinue) {
        $configs = & snapper --no-dbus list-configs 2>$null
        if ($LASTEXITCODE -ne 0) { $configs = & snapper list-configs 2>$null }
        if ($configs -match '^\s*root\s') { return @{ Tool = 'snapper'; Problem = $null; Points = @() } }
        return @{ Tool = 'snapper'; Problem = 'snapper n''a pas de configuration « root » (snapper -c root create-config /)' }
    }
    if (Get-Command timeshift -ErrorAction SilentlyContinue) { return @{ Tool = 'Timeshift'; Problem = $null; Points = @() } }
    $fs = (& findmnt -no FSTYPE / 2>$null)
    @{ Tool = $null; Problem = "aucun outil d'instantanés installé (snapper ou Timeshift$(if ($fs -eq 'btrfs') { ', adaptés au Btrfs de ce système' }))" }
}

# Points de restauration existants : Date, Description, Type.
function Get-RestorePointList {
    if ($IsWindows) {
        $types = @{ 0 = 'Installation'; 1 = 'Désinstallation'; 10 = 'Pilote'; 12 = 'Modification de paramètres'; 13 = 'Annulation' }
        return @(Get-CimInstance -Namespace root/default -ClassName SystemRestore -ErrorAction SilentlyContinue | Sort-Object SequenceNumber -Descending | ForEach-Object {
                [PSCustomObject]@{ Date = [Management.ManagementDateTimeConverter]::ToDateTime($_.CreationTime); Description = $_.Description; Type = $types[[int]$_.RestorePointType] ?? "$($_.RestorePointType)"; Id = $_.SequenceNumber }
            })
    }
    if ((Get-Command snapper -ErrorAction SilentlyContinue) -and (Test-Elevated)) {
        $json = (& snapper --jsonout -c root list 2>$null) -join ''
        if ($json) {
            return @(($json | ConvertFrom-Json).root | Where-Object { $_.number -ne 0 } | Sort-Object number -Descending | ForEach-Object {
                    [PSCustomObject]@{ Date = [datetime]$_.date; Description = $_.description; Type = $_.type; Id = $_.number }
                })
        }
    }
    if ((Get-Command timeshift -ErrorAction SilentlyContinue) -and (Test-Elevated)) {
        return @(& timeshift --list --scripted 2>$null | Where-Object { $_ -match '^\s*\d+\s+>\s+(\S+)\s+(\S+)\s*(.*)$' } | ForEach-Object {
                $null = $_ -match '^\s*\d+\s+>\s+(\S+)\s+(\S+)\s*(.*)$'
                $date = try { [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd_HH-mm-ss', $null) } catch { $null }
                [PSCustomObject]@{ Date = $date; Description = $Matches[3].Trim(); Type = $Matches[2]; Id = $Matches[1] }
            })
    }
    @()
}

# maintenance_create_restore_point (et SysInfo avant chaque action critique) : crée un point de restauration.
# Windows : SystemRestore.CreateRestorePoint (MODIFY_SETTINGS) ; Windows n'en crée pas un second en moins de 24 h :
# le point récent est alors réutilisé. Linux : snapper create (configuration root) ou timeshift --create.
function New-SIRestorePoint {
    param(
        [string]$Description = 'SysInfo',
        [switch]$DryRun
    )
    $support = Get-RestoreSupport
    $blocked = if ($support.Problem) { $support.Problem } else { Get-AdminBlock }
    $before = @(Get-RestorePointList)
    $last = $before | Select-Object -First 1
    $items = [ordered]@{ Outil = $support.Tool ?? 'aucun'; 'Points existants' = $before.Count }
    if ($last) { $items['Dernier point'] = '{0} · {1}' -f (Format-Date $last.Date), $last.Description }
    $section = [PSCustomObject]@{ Title = 'Points de restauration'; Type = 'KeyValue'; Icon = 'arrow_clockwise'; Items = $items }
    $Description = ($Description -replace '[^\w\s:().,«»''-]', '').Trim()
    if ($Description.Length -gt 80) { $Description = $Description.Substring(0, 80) }

    if ($DryRun -or $blocked) {
        $subtitle = if ($blocked) { 'Point de restauration impossible' } else { "Un point de restauration ($($support.Tool)) sera créé avant l'action" }
        return New-Result $subtitle @($section) @() @(New-Change ($support.Tool ?? 'Système') 'Points de restauration' $before.Count ($before.Count + 1)) $blocked
    }

    if ($IsWindows) {
        $result = Invoke-CimMethod -Namespace root/default -ClassName SystemRestore -MethodName CreateRestorePoint -Arguments @{ Description = $Description; RestorePointType = [uint32]12; EventType = [uint32]100 } -ErrorAction Stop
        if ($result.ReturnValue -ne 0) { return New-Result 'Point de restauration impossible' @($section) @() @() "CreateRestorePoint a renvoyé le code $($result.ReturnValue) (protection du système désactivée sur $env:SystemDrive ?)." }
        $after = @(Get-RestorePointList)
        if ($after.Count -eq $before.Count -and $last) {
            return New-Result "point récent réutilisé ($(Format-Date $last.Date) · $($last.Description))" @($section) @(New-Finding 'info' 'MNT-RESTORE-REUSED' 'Windows ne crée pas plus d''un point de restauration par 24 h : le plus récent sert de point de retour.' $null) @() $null
        }
        $new = $after | Select-Object -First 1
        return New-Result "créé le $(Format-Date $new.Date) ($Description)" @($section) @() @(New-Change $support.Tool 'Points de restauration' $before.Count $after.Count) $null
    }

    if ($support.Tool -eq 'snapper') {
        $out = & snapper -c root create -d $Description --cleanup-algorithm number --print-number 2>&1
        if ($LASTEXITCODE -ne 0) { return New-Result 'Point de restauration impossible' @($section) @() @() "snapper a échoué : $($out -join ' ')" }
        return New-Result "instantané snapper n° $(($out | Select-Object -Last 1).ToString().Trim()) ($Description)" @($section) @() @(New-Change 'snapper' 'Instantanés' $before.Count ($before.Count + 1)) $null
    }
    $out = & timeshift --create --comments $Description --scripted 2>&1
    if ($LASTEXITCODE -ne 0) { return New-Result 'Point de restauration impossible' @($section) @() @() "Timeshift a échoué : $(($out | Select-Object -Last 2) -join ' ')" }
    New-Result "instantané Timeshift créé ($Description)" @($section) @() @(New-Change 'Timeshift' 'Instantanés' $before.Count ($before.Count + 1)) $null
}

#endregion

#region Nettoyage

# Catégories de nettoyage : emplacements, fichiers concernés (plus vieux qu'un jour pour les dossiers temporaires),
# droits requis. Taille estimée sans rien supprimer.
function Get-CleanupTargets {
    $targets = [ordered]@{}
    if ($IsWindows) {
        $targets.temp = @{ Label = 'Fichiers temporaires'; Paths = @($env:TEMP) + $(if (Test-Elevated) { "$env:WINDIR\Temp" } else { @() }); OlderDays = 1; Admin = $false }
        $targets.thumbnails = @{ Label = 'Cache des miniatures'; Paths = @("$env:LOCALAPPDATA\Microsoft\Windows\Explorer"); Filter = 'thumbcache_*.db'; OlderDays = 0; Admin = $false }
        $targets.recycle = @{ Label = 'Corbeille'; Paths = @(); OlderDays = 0; Admin = $false }
        $targets.packages = @{ Label = 'Téléchargements de Windows Update'; Paths = @("$env:WINDIR\SoftwareDistribution\Download"); OlderDays = 0; Admin = $true }
        $targets.logs = @{ Label = 'Anciens journaux (CBS, DISM)'; Paths = @("$env:WINDIR\Logs\CBS", "$env:WINDIR\Logs\DISM"); Filter = '*.log'; OlderDays = 30; Admin = $true }
        return $targets
    }
    $targets.temp = @{ Label = 'Fichiers temporaires (les vôtres, plus de 7 jours)'; Paths = @('/tmp', '/var/tmp'); OlderDays = 7; Admin = $false; MineOnly = $true }
    $targets.thumbnails = @{ Label = 'Cache des miniatures'; Paths = @((Join-Path $HOME '.cache/thumbnails')); OlderDays = 0; Admin = $false }
    $targets.recycle = @{ Label = 'Corbeille'; Paths = @((Join-Path $HOME '.local/share/Trash/files'), (Join-Path $HOME '.local/share/Trash/info')); OlderDays = 0; Admin = $false }
    $targets.packages = @{ Label = 'Cache des paquets'; Paths = @('/var/cache/libdnf5', '/var/cache/dnf', '/var/cache/apt/archives', '/var/cache/pacman/pkg') | Where-Object { Test-Path $_ }; OlderDays = 0; Admin = $true }
    $targets.logs = @{ Label = 'Journal systemd (au-delà de 500 MiB)'; Paths = @('/var/log/journal'); OlderDays = 0; Admin = $true }
    $targets
}

# Fichiers d'une catégorie (sans les suivre hors de leur dossier) ; Size en octets.
function Get-CleanupFiles($Target) {
    $limit = (Get-Date).AddDays(-$Target.OlderDays)
    $uid = if ($IsLinux) { [int](& id -u) } else { 0 }
    foreach ($path in $Target.Paths) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $items = if ($Target.Filter) { Get-ChildItem -LiteralPath $path -Filter $Target.Filter -File -Force -ErrorAction SilentlyContinue }
                 else { Get-ChildItem -LiteralPath $path -File -Recurse -Force -ErrorAction SilentlyContinue -Attributes !ReparsePoint }
        foreach ($f in $items) {
            if ($Target.OlderDays -gt 0 -and $f.LastWriteTime -gt $limit) { continue }
            if ($Target.MineOnly) { try { if ((& stat -c %u -- $f.FullName 2>$null) -ne "$uid") { continue } } catch { continue } }
            $f
        }
    }
}

function Measure-Cleanup([string]$Key, $Target) {
    if ($Key -eq 'recycle' -and $IsWindows) {
        $shell = New-Object -ComObject Shell.Application
        $bin = $shell.Namespace(10)
        $size = 0; $count = 0
        foreach ($i in $bin.Items()) { $size += [double]$i.Size; $count++ }
        return @{ Size = $size; Files = $count }
    }
    if ($Key -eq 'logs' -and $IsLinux) {
        $line = & journalctl --disk-usage 2>$null | Select-Object -First 1
        $bytes = if ($line -match '([\d.,]+)([KMGT])') { [double]($Matches[1] -replace ',', '.') * @{ K = 1KB; M = 1MB; G = 1GB; T = 1TB }[$Matches[2]] } else { 0 }
        return @{ Size = [Math]::Max([double]0, $bytes - 500MB); Files = $null }
    }
    $files = @(Get-CleanupFiles $Target)
    @{ Size = [double](($files | Measure-Object Length -Sum).Sum ?? 0); Files = $files.Count }
}

# maintenance_cleanup : vide une catégorie (fichiers temporaires, miniatures, corbeille, cache des paquets ou de
# Windows Update, anciens journaux). Les fichiers en cours d'utilisation sont laissés en place.
function Clear-SIJunk {
    param(
        [Parameter(Mandatory)][ValidateSet('temp', 'thumbnails', 'recycle', 'packages', 'logs')][string]$Category,
        [switch]$DryRun
    )
    $target = (Get-CleanupTargets)[$Category]
    $blocked = if ($target.Admin) { Get-AdminBlock } else { $null }
    if (-not $blocked -and $IsLinux -and $Category -eq 'packages' -and -not $target.Paths) { $blocked = 'Aucun cache de paquets connu sur ce système.' }
    $measure = Measure-Cleanup $Category $target
    $size = Format-Size $measure.Size
    if (-not $blocked -and $measure.Size -lt 1MB -and $Category -ne 'recycle') { $blocked = "$($target.Label) : rien à nettoyer ($size)." }
    if (-not $blocked -and $Category -eq 'recycle' -and -not $measure.Files -and $measure.Size -eq 0) { $blocked = 'La corbeille est déjà vide.' }

    $items = [ordered]@{ Catégorie = $target.Label; 'Taille récupérable' = $size }
    if ($null -ne $measure.Files) { $items['Fichiers'] = $measure.Files }
    if ($target.Paths) { $items['Emplacements'] = $target.Paths -join ', ' }
    $section = [PSCustomObject]@{ Title = 'Nettoyage'; Type = 'KeyValue'; Icon = 'hard_drive'; Items = $items }
    $findings = @()
    if ($Category -eq 'recycle') { $findings += New-Finding 'warning' 'MNT-CLEANUP-PERMANENT' 'Les fichiers de la corbeille seront supprimés définitivement.' 'Vérifier qu''elle ne contient rien à récupérer.' }
    if ($Category -eq 'thumbnails') { $findings += New-Finding 'info' 'MNT-CLEANUP-REBUILT' 'Les miniatures seront recréées à l''ouverture des dossiers (affichage un peu plus lent au début).' $null }
    $change = New-Change $target.Label 'Espace occupé' $size '0'
    if ($DryRun -or $blocked) { return New-Result "$size seront libérés · $($target.Label)" @($section) $findings @($change) $blocked }

    $failed = 0
    if ($Category -eq 'recycle' -and $IsWindows) { Clear-RecycleBin -Force -ErrorAction SilentlyContinue }
    elseif ($Category -eq 'logs' -and $IsLinux) {
        $out = & journalctl --vacuum-size=500M 2>&1
        if ($LASTEXITCODE -ne 0) { throw "journalctl --vacuum-size a échoué : $($out -join ' ')" }
    }
    elseif ($Category -eq 'packages' -and $IsLinux) {
        $out = if (Get-Command dnf -ErrorAction SilentlyContinue) { & dnf clean packages 2>&1 } elseif (Get-Command apt-get -ErrorAction SilentlyContinue) { & apt-get clean 2>&1 } else { & pacman -Sc --noconfirm 2>&1 }
        if ($LASTEXITCODE -ne 0) { throw "Nettoyage du cache des paquets impossible : $($out -join ' ')" }
    }
    else {
        foreach ($f in @(Get-CleanupFiles $target)) {
            try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop } catch { $failed++ }
        }
        # Dossiers vides laissés par les fichiers temporaires.
        if ($Category -in 'temp', 'recycle') {
            foreach ($path in $target.Paths) {
                Get-ChildItem -LiteralPath $path -Directory -Recurse -Force -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length } -Descending |
                    Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue) } |
                    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
            }
        }
    }
    $after = Measure-Cleanup $Category $target
    $freed = [Math]::Max([double]0, $measure.Size - $after.Size)
    $result = @()
    if ($failed) { $result += New-Finding 'info' 'MNT-CLEANUP-IN-USE' "$failed fichier(s) en cours d'utilisation laissés en place." $null }
    New-Result "$(Format-Size $freed) libérés · $($target.Label)" @($section) $result @(New-Change $target.Label 'Espace occupé' $size (Format-Size $after.Size)) $null
}

#endregion

#region Intégrité, disques, image Windows

# maintenance_verify_system_files : vérifie les fichiers du système sans rien réparer (tâche longue).
# Windows : sfc /verifyonly (administrateur). Linux : rpm -Va (fichiers dont le contenu a changé, hors configuration),
# debsums -s ou pacman -Qkk.
function Get-SISystemFileCheck {
    param([ValidateRange(1, 500)][int]$Top = 100)
    if ($IsWindows) {
        if (-not (Test-Elevated)) { throw 'sfc exige les droits administrateur : relancer SysInfo en administrateur.' }
        $out = Invoke-Native "$env:WINDIR\System32\sfc.exe" @('/verifyonly')
        $text = $out -join "`n"
        $state = if ($text -match 'did not find any integrity violations|n''a trouvé aucune violation') { 'ok' }
                 elseif ($text -match 'found integrity violations|a trouvé des violations') { 'corrupt' }
                 else { 'unknown' }
        $findings = switch ($state) {
            'corrupt' { New-Finding 'critical' 'MNT-SYSFILES-CORRUPT' 'sfc a trouvé des fichiers système endommagés.' 'Lancer maintenance_repair_system_files (sfc /scannow), puis maintenance_repair_windows_image si le problème persiste.' }
            'unknown' { New-Finding 'warning' 'MNT-SYSFILES-UNKNOWN' 'Résultat de sfc non reconnu : voir la sortie.' $null }
        }
        return New-Result "sfc /verifyonly : $(@{ ok = 'aucune violation'; corrupt = 'fichiers endommagés'; unknown = 'résultat inconnu' }[$state])" @(
            [PSCustomObject]@{ Title = 'Sortie de sfc'; Type = 'Table'; Icon = 'search'; Columns = @('Ligne'); Rows = @($out | Select-Object -Last 15 | ForEach-Object { , @($_) }) }
        ) @($findings) @() $null
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    $tool = $null; $unreadable = 0
    if (Get-Command rpm -ErrorAction SilentlyContinue) {
        $tool = 'rpm -Va'
        # Paquets vérifiés par lots de 40 : même travail que rpm -Va, avec une progression réelle.
        $all = @(& rpm -qa --qf '%{NAME}\n' 2>$null | Sort-Object -Unique)
        Write-Information "rpm -V --nomtime … sur $($all.Count) paquets, par lots de 40"
        $output = [System.Collections.Generic.List[string]]::new()
        for ($i = 0; $i -lt $all.Count; $i += 40) {
            $batch = $all[$i..([Math]::Min($i + 39, $all.Count - 1))]
            Write-Progress -Activity 'Vérification des paquets' -Status "$([Math]::Min($i + 40, $all.Count)) / $($all.Count) · $($batch[0]) …" -PercentComplete ([int](100 * $i / [Math]::Max(1, $all.Count)))
            foreach ($l in & rpm -V --nomtime --nouser --nogroup --nordev --nocaps @batch 2>&1) { $output.Add("$l") }
        }
        # Lignes « S.5....T.  c /etc/x » : 5 = contenu modifié ; c = configuration (attendu) ; ? = illisible.
        foreach ($line in $output) {
            # « missing … (Permission denied) » : illisible sans root, pas manquant.
            if ($line -match '\(Permission denied\)\s*$') { $unreadable++; continue }
            if ($line -match '^missing\s+(?:(\w)\s+)?(/.+)$') { if ($Matches[1] -notin 'c', 'g') { $rows.Add(@($Matches[2], 'manquant', $null)) }; continue }
            if ($line -notmatch '^(\S{9})\s+(\w)?\s*(/.+)$') { continue }
            $flags = $Matches[1]; $kind = $Matches[2]; $file = $Matches[3]
            if ($flags.Contains('?')) { $unreadable++; continue }
            if ($kind -in 'c', 'g', 'd', 'l', 'r' -or $flags[2] -ne '5') { continue }
            Write-Information "modifié : $file"
            $rows.Add(@($file, 'contenu modifié', $null))
        }
        if ($rows.Count) {
            $owners = @{}
            # Paquet de chaque fichier (500 au plus) : la réparation réinstalle ces paquets.
            foreach ($r in $rows | Select-Object -First 500) { $owners[$r[0]] = (& rpm -qf --qf '%{NAME}' -- $r[0] 2>$null | Select-Object -First 1) }
            foreach ($r in $rows) { $r[2] = $owners[$r[0]] }
        }
    }
    elseif (Get-Command debsums -ErrorAction SilentlyContinue) {
        $tool = 'debsums -s'
        foreach ($line in & debsums -s 2>&1) { if ($line -match '(/\S+)') { $rows.Add(@($Matches[1], 'contenu modifié', $null)) } }
    }
    elseif (Get-Command pacman -ErrorAction SilentlyContinue) {
        $tool = 'pacman -Qkk'
        foreach ($line in & pacman -Qkk 2>&1) { if ($line -match '^warning: (\S+): (/\S+) \((.+)\)$' -and $Matches[3] -match 'checksum|size') { $rows.Add(@($Matches[2], $Matches[3], $Matches[1])) } }
    }
    else { throw 'Aucun gestionnaire de paquets pris en charge (rpm, debsums, pacman).' }

    try {
        [void](New-Item -ItemType Directory -Path (Split-Path $script:StateFile) -Force)
        @{ time = (Get-Date).ToString('o'); tool = $tool; packages = @($rows | ForEach-Object { $_[2] } | Where-Object { $_ } | Sort-Object -Unique) } | ConvertTo-Json | Set-Content -LiteralPath $script:StateFile -Encoding utf8
    }
    catch { }
    $findings = @()
    if ($rows.Count) { $findings += New-Finding 'warning' 'MNT-SYSFILES-MODIFIED' "$($rows.Count) fichier(s) de paquets modifiés ou manquants (hors configuration)." 'Vérifier ces fichiers ; maintenance_repair_system_files réinstalle les paquets concernés.' }
    if ($unreadable) { $findings += New-Finding 'info' 'SEC-SCAN-PARTIAL' "$unreadable fichier(s) illisibles sans droits root : non vérifiés." $null }
    New-Result "$tool : $($rows.Count) fichier(s) modifié(s)" @(
        [PSCustomObject]@{ Title = 'Fichiers modifiés'; Type = 'Table'; Icon = 'warning'; Columns = @('Fichier', 'Écart', 'Paquet'); Rows = @($rows | Select-Object -First $Top) }
    ) $findings @() $null
}

# maintenance_repair_system_files : répare les fichiers système (tâche longue, critique).
# Windows : sfc /scannow. Linux : réinstalle les paquets dont des fichiers (hors configuration) ont été modifiés
# (dnf reinstall / apt-get install --reinstall), d'après une vérification rpm -V / debsums faite à l'aperçu.
function Repair-SISystemFiles {
    param([switch]$DryRun)
    $blocked = $null
    if ($IsWindows) {
        $blocked = Get-AdminBlock
        $section = [PSCustomObject]@{ Title = 'Réparation'; Type = 'KeyValue'; Icon = 'checkmark_circle'; Items = [ordered]@{ Outil = 'sfc /scannow'; Durée = '10 à 30 min'; Source = 'magasin de composants (WinSxS)' } }
        $findings = @(New-Finding 'info' 'MNT-REPAIR-REBOOT' 'Certains fichiers ne sont remplacés qu''au prochain redémarrage.' $null)
        if ($DryRun -or $blocked) { return New-Result 'sfc /scannow va vérifier et réparer les fichiers système' @($section) $findings @(New-Change 'Fichiers système' 'État' 'à vérifier' 'réparés si besoin') $blocked }
        $out = Invoke-Native "$env:WINDIR\System32\sfc.exe" @('/scannow')
        $text = $out -join "`n"
        $result = if ($text -match 'did not find any integrity violations|aucune violation') { 'aucune violation' }
                  elseif ($text -match 'successfully repaired|a réparé') { 'fichiers réparés' }
                  elseif ($text -match 'unable to fix|n''a pas pu réparer') { 'réparation incomplète' } else { 'terminé' }
        $after = @()
        if ($result -eq 'réparation incomplète') { $after += New-Finding 'critical' 'MNT-SYSFILES-UNREPAIRED' 'sfc n''a pas pu tout réparer.' 'Lancer maintenance_repair_windows_image (DISM /RestoreHealth), redémarrer puis relancer sfc.' }
        return New-Result "sfc /scannow : $result" @($section, [PSCustomObject]@{ Title = 'Sortie de sfc'; Type = 'Table'; Icon = 'search'; Columns = @('Ligne'); Rows = @($out | Select-Object -Last 15 | ForEach-Object { , @($_) }) }) $after @(New-Change 'Fichiers système' 'État' 'à vérifier' $result) $null
    }

    # Linux : paquets à réinstaller, d'après la dernière vérification (maintenance_verify_system_files, moins de 7 jours).
    $state = try { Get-Content -LiteralPath $script:StateFile -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null }
    $packages = @($state.packages | Where-Object { $_ })
    if (-not $state -or [datetime]$state.time -lt (Get-Date).AddDays(-7)) { $blocked = 'Lancer d''abord maintenance_verify_system_files (vérification de moins de 7 jours requise).' }
    elseif ($packages.Count -eq 0) { $blocked = "La vérification du $(Format-Date ([datetime]$state.time)) n'a trouvé aucun fichier de paquet modifié : rien à réparer." }
    $manager = if (Get-Command dnf -ErrorAction SilentlyContinue) { 'dnf' } elseif (Get-Command apt-get -ErrorAction SilentlyContinue) { 'apt-get' } else { $null }
    if (-not $blocked -and -not $manager) { $blocked = 'Réinstallation prise en charge avec dnf ou apt-get seulement.' }
    if (-not $blocked) { $blocked = Get-AdminBlock }
    $section = [PSCustomObject]@{ Title = 'Paquets à réinstaller'; Type = 'Table'; Icon = 'apps_list'; Columns = @('Paquet'); Rows = @($packages | ForEach-Object { , @($_) }) }
    $findings = @(New-Finding 'info' 'MNT-REPAIR-NETWORK' 'Les paquets sont téléchargés de nouveau depuis les dépôts (connexion requise).' $null)
    if ($DryRun -or $blocked) { return New-Result "$($packages.Count) paquet(s) seront réinstallés" @($section) $findings @($packages | ForEach-Object { New-Change $_ 'Fichiers' 'modifiés' 'réinstallés' }) $blocked }
    $out = if ($manager -eq 'dnf') { & dnf reinstall -y @packages 2>&1 } else { & apt-get install --reinstall -y @packages 2>&1 }
    if ($LASTEXITCODE -ne 0) { throw "$manager a échoué : $(($out | Select-Object -Last 3) -join ' ')" }
    Remove-Item -LiteralPath $script:StateFile -Force -ErrorAction SilentlyContinue
    New-Result "$($packages.Count) paquet(s) réinstallés" @($section) @() @($packages | ForEach-Object { New-Change $_ 'Fichiers' 'modifiés' 'réinstallés' }) $null
}

# maintenance_check_windows_image : état du magasin de composants (DISM /ScanHealth, tâche longue, administrateur).
function Get-SIWindowsImageHealth {
    if (-not (Test-Elevated)) { throw 'DISM exige les droits administrateur : relancer SysInfo en administrateur.' }
    $out = Invoke-Native "$env:WINDIR\System32\Dism.exe" @('/Online', '/Cleanup-Image', '/ScanHealth', '/English')
    $text = $out -join "`n"
    $state = if ($text -match 'No component store corruption detected') { 'sain' } elseif ($text -match 'repairable') { 'réparable' } elseif ($text -match 'not repairable') { 'non réparable' } else { 'inconnu' }
    $findings = switch ($state) {
        'réparable' { New-Finding 'warning' 'MNT-IMAGE-CORRUPT' 'Le magasin de composants Windows est endommagé (réparable).' 'Lancer maintenance_repair_windows_image (DISM /RestoreHealth).' }
        'non réparable' { New-Finding 'critical' 'MNT-IMAGE-UNREPAIRABLE' 'Le magasin de composants Windows est endommagé et non réparable par DISM.' 'Réparation de Windows par mise à niveau sur place (ISO) à envisager.' }
    }
    New-Result "Image Windows : $state" @([PSCustomObject]@{ Title = 'Sortie de DISM'; Type = 'Table'; Icon = 'search'; Columns = @('Ligne'); Rows = @($out | Select-Object -Last 12 | ForEach-Object { , @($_) }) }) @($findings) @() $null
}

# maintenance_repair_windows_image : DISM /RestoreHealth (réparation depuis Windows Update) ou /StartComponentCleanup
# (supprime les anciennes versions des composants ; les mises à jour installées ne peuvent plus être désinstallées).
function Repair-SIWindowsImage {
    param(
        [ValidateSet('restore_health', 'component_cleanup')][string]$Operation = 'restore_health',
        [switch]$DryRun
    )
    $blocked = Get-AdminBlock
    $switch = @{ restore_health = '/RestoreHealth'; component_cleanup = '/StartComponentCleanup' }[$Operation]
    $label = @{ restore_health = 'Réparation de l''image Windows'; component_cleanup = 'Nettoyage des composants Windows' }[$Operation]
    $section = [PSCustomObject]@{ Title = 'DISM'; Type = 'KeyValue'; Icon = 'checkmark_circle'; Items = [ordered]@{ Opération = $label; Commande = "DISM /Online /Cleanup-Image $switch"; Durée = '10 à 40 min' } }
    $findings = @()
    if ($Operation -eq 'component_cleanup') { $findings += New-Finding 'warning' 'MNT-IMAGE-NO-UNINSTALL' 'Après le nettoyage, les mises à jour déjà installées ne pourront plus être désinstallées.' $null }
    else { $findings += New-Finding 'info' 'MNT-REPAIR-NETWORK' 'Les fichiers sains sont téléchargés depuis Windows Update (connexion requise).' $null }
    if ($DryRun -or $blocked) { return New-Result "$label (DISM $switch)" @($section) $findings @(New-Change 'Image Windows' 'État' 'actuel' $(if ($Operation -eq 'restore_health') { 'réparée' } else { 'nettoyée' })) $blocked }
    $out = Invoke-Native "$env:WINDIR\System32\Dism.exe" @('/Online', '/Cleanup-Image', $switch, '/English')
    $ok = ($out -join "`n") -match 'operation completed successfully|restore operation completed successfully'
    if (-not $ok) { throw "DISM a échoué : $(($out | Select-Object -Last 3) -join ' ')" }
    New-Result "$label terminée" @($section) @() @(New-Change 'Image Windows' 'État' 'actuel' $(if ($Operation -eq 'restore_health') { 'réparée' } else { 'nettoyée' })) $null
}

# maintenance_check_disk : vérifie un volume sans le démonter (tâche longue).
# Windows : chkdsk <lecteur> /scan (en ligne, administrateur). Linux : Btrfs : compteurs d'erreurs (btrfs device stats)
# et scrub en lecture seule (root) ; ext4 / XFS montés : état du système de fichiers seulement (vérification complète
# hors ligne, au démarrage).
function Test-SIDisk {
    param([string]$Volume = $(Get-SystemDrive))
    if ($IsWindows) {
        if (-not (Test-Elevated)) { throw 'chkdsk exige les droits administrateur : relancer SysInfo en administrateur.' }
        if ($Volume -notmatch '^[A-Za-z]:?\\?$') { throw "Volume invalide : $Volume (exemple : C:)" }
        $drive = $Volume.Substring(0, 1).ToUpper() + ':'
        $out = Invoke-Native "$env:WINDIR\System32\chkdsk.exe" @($drive, '/scan')
        $text = $out -join "`n"
        $bad = $text -match 'found problems|a trouvé des problèmes|errors found|Windows has found problems'
        $findings = if ($bad) { @(New-Finding 'critical' 'MNT-DISK-ERRORS' "chkdsk a trouvé des erreurs sur $drive." 'Lancer maintenance_schedule_disk_repair (réparation au prochain démarrage).') } else { @() }
        return New-Result "chkdsk $drive /scan : $(if ($bad) { 'erreurs trouvées' } else { 'aucune erreur' })" @([PSCustomObject]@{ Title = 'Sortie de chkdsk'; Type = 'Table'; Icon = 'hard_drive'; Columns = @('Ligne'); Rows = @($out | Select-Object -Last 15 | ForEach-Object { , @($_) }) }) $findings @() $null
    }

    $mount = (& findmnt -J -T $Volume -o TARGET,SOURCE,FSTYPE 2>$null) -join '' | ConvertFrom-Json -ErrorAction SilentlyContinue
    $fs = $mount.filesystems | Select-Object -First 1
    if (-not $fs) { throw "Point de montage introuvable : $Volume" }
    $items = [ordered]@{ 'Point de montage' = $fs.target; Périphérique = $fs.source; Type = $fs.fstype }
    $findings = @(); $rows = @()
    switch ($fs.fstype) {
        'btrfs' {
            $stats = & btrfs device stats $fs.target 2>&1
            if ($LASTEXITCODE -ne 0) { $findings += New-Finding 'info' 'SEC-SCAN-PARTIAL' 'Compteurs Btrfs illisibles sans droits root.' $null }
            else {
                foreach ($line in $stats) { if ($line -match '^\[(.+)\]\.(\w+)\s+(\d+)$') { $rows += , @($Matches[1], $Matches[2], [long]$Matches[3]) } }
                $errors = ($rows | Where-Object { $_[2] -gt 0 }).Count
                if ($errors) { $findings += New-Finding 'critical' 'MNT-DISK-ERRORS' "Btrfs a compté des erreurs sur $($fs.target)." 'Sauvegarder, vérifier le câble ou le disque (SMART), puis réinitialiser les compteurs (btrfs device stats -z).' }
            }
            if (Test-Elevated) {
                $scrub = & btrfs scrub start -B -r $fs.target 2>&1
                $items['Scrub (lecture seule)'] = ($scrub | Where-Object { $_ -match 'Error summary|summary' } | Select-Object -First 1) ?? ($scrub | Select-Object -Last 1)
                if (($scrub -join ' ') -match 'csum=(\d+)|read=(\d+)' -and ($Matches[1] -gt 0 -or $Matches[2] -gt 0)) { $findings += New-Finding 'critical' 'MNT-DISK-CHECKSUM' "Le scrub a trouvé des erreurs de somme de contrôle sur $($fs.target)." 'Sauvegarder au plus vite ; vérifier l''état SMART du disque.' }
            }
            else { $items['Scrub'] = 'non lancé (root requis)' }
        }
        { $_ -in 'ext2', 'ext3', 'ext4' } {
            $header = & dumpe2fs -h $fs.source 2>$null
            if ($header) {
                foreach ($key in 'Filesystem state', 'Mount count', 'Maximum mount count', 'Last checked', 'FS Error count') {
                    $line = $header | Where-Object { $_ -like "${key}:*" } | Select-Object -First 1
                    if ($line) { $items[$key] = ($line -split ':', 2)[1].Trim() }
                }
                if ($items['Filesystem state'] -and $items['Filesystem state'] -notmatch '^clean') { $findings += New-Finding 'warning' 'MNT-DISK-DIRTY' "Le système de fichiers $($fs.target) n'est pas marqué propre ($($items['Filesystem state']))." 'Une vérification complète (fsck) se fera au prochain démarrage ou depuis un système de secours.' }
            }
            else { $findings += New-Finding 'info' 'SEC-SCAN-PARTIAL' 'En-tête ext4 illisible sans droits root.' $null }
            $findings += New-Finding 'info' 'MNT-DISK-ONLINE' 'Un système de fichiers ext4 monté ne se vérifie pas à fond : fsck complet hors ligne.' $null
        }
        default { $findings += New-Finding 'info' 'MNT-DISK-ONLINE' "Vérification en ligne non prise en charge pour $($fs.fstype) : fsck hors ligne." $null }
    }
    $sections = @([PSCustomObject]@{ Title = 'Volume'; Type = 'KeyValue'; Icon = 'hard_drive'; Items = $items })
    if ($rows) { $sections += [PSCustomObject]@{ Title = 'Compteurs d''erreurs Btrfs'; Type = 'Table'; Icon = 'warning'; Columns = @('Périphérique', 'Compteur', 'Valeur'); Rows = $rows } }
    New-Result "Vérification de $($fs.target) ($($fs.fstype))" $sections $findings @() $null
}

# maintenance_schedule_disk_repair : Windows, chkdsk /f au prochain démarrage (le volume est marqué à vérifier).
function Set-SIDiskRepair {
    param(
        [string]$Volume = $env:SystemDrive,
        [switch]$DryRun
    )
    if ($Volume -notmatch '^[A-Za-z]:?\\?$') { return New-Result 'Volume invalide' @() @() @() "Volume invalide : $Volume (exemple : C:)" }
    $drive = $Volume.Substring(0, 1).ToUpper() + ':'
    $blocked = Get-AdminBlock
    $dirty = (& fsutil dirty query $drive 2>$null) -join ' '
    if (-not $blocked -and $dirty -match 'is Dirty|est sale|est marqué') { $blocked = "$drive est déjà marqué : chkdsk se lancera au prochain démarrage." }
    $section = [PSCustomObject]@{ Title = 'Réparation au démarrage'; Type = 'KeyValue'; Icon = 'hard_drive'; Items = [ordered]@{ Volume = $drive; État = $dirty } }
    $findings = @(New-Finding 'warning' 'MNT-DISK-BOOT-CHECK' 'Au prochain démarrage, chkdsk vérifie et répare le volume avant Windows : cela peut prendre de quelques minutes à plus d''une heure.' 'Prévoir le redémarrage à un moment où l''ordinateur n''est pas nécessaire.')
    if ($DryRun -or $blocked) { return New-Result "chkdsk $drive /f se lancera au prochain démarrage" @($section) $findings @(New-Change $drive 'Vérification au démarrage' 'non' 'oui') $blocked }
    $out = & fsutil dirty set $drive 2>&1
    if ($LASTEXITCODE -ne 0) { throw "fsutil a échoué : $($out -join ' ')" }
    New-Result "$drive sera vérifié et réparé au prochain démarrage" @($section) $findings @(New-Change $drive 'Vérification au démarrage' 'non' 'oui') $null
}

#endregion

#region Optimisation, impression, réparations Windows

# maintenance_optimize_volume : TRIM (SSD) ou défragmentation (disque dur) d'un volume.
# Windows : Optimize-Volume -ReTrim / -Defrag (administrateur). Linux : fstrim -v (root).
function Optimize-SIVolume {
    param(
        [string]$Volume = $(Get-SystemDrive),
        [switch]$DryRun
    )
    $blocked = Get-AdminBlock
    if ($IsWindows) {
        $letter = $Volume.Substring(0, 1).ToUpper()
        $partition = Get-Partition -DriveLetter $letter -ErrorAction SilentlyContinue
        if (-not $partition) { return New-Result 'Volume introuvable' @() @() @() "Aucun volume $letter`:" }
        $media = (Get-PhysicalDisk | Where-Object DeviceId -eq "$($partition.DiskNumber)").MediaType
        $op = if ($media -eq 'HDD') { 'Défragmentation' } else { 'TRIM' }
        $section = [PSCustomObject]@{ Title = 'Optimisation'; Type = 'KeyValue'; Icon = 'hard_drive'; Items = [ordered]@{ Volume = "$letter`:"; Disque = $media ?? 'inconnu'; Opération = $op } }
        if ($DryRun -or $blocked) { return New-Result "$op de $letter`:" @($section) @() @(New-Change "$letter`:" 'Dernière optimisation' 'précédente' 'maintenant') $blocked }
        if ($op -eq 'TRIM') { Optimize-Volume -DriveLetter $letter -ReTrim -ErrorAction Stop } else { Optimize-Volume -DriveLetter $letter -Defrag -ErrorAction Stop }
        return New-Result "$op de $letter`: terminé" @($section) @() @(New-Change "$letter`:" 'Dernière optimisation' 'précédente' (Format-Date (Get-Date))) $null
    }
    $mount = ((& findmnt -J -T $Volume -o TARGET,SOURCE,FSTYPE 2>$null) -join '' | ConvertFrom-Json -ErrorAction SilentlyContinue).filesystems | Select-Object -First 1
    if (-not $mount) { return New-Result 'Volume introuvable' @() @() @() "Point de montage introuvable : $Volume" }
    $disc = (& lsblk -ndo DISC-GRAN $mount.source 2>$null | Select-Object -First 1)
    if (-not $blocked -and ("$disc".Trim() -in '', '0B')) { $blocked = "$($mount.source) ne prend pas en charge le TRIM (disque dur ou contrôleur sans « discard »)." }
    $section = [PSCustomObject]@{ Title = 'Optimisation'; Type = 'KeyValue'; Icon = 'hard_drive'; Items = [ordered]@{ 'Point de montage' = $mount.target; Périphérique = $mount.source; Type = $mount.fstype; Opération = 'TRIM (fstrim)' } }
    if ($DryRun -or $blocked) { return New-Result "TRIM de $($mount.target)" @($section) @() @(New-Change $mount.target 'Blocs libres signalés au SSD' 'non signalés' 'signalés') $blocked }
    $out = & fstrim -v $mount.target 2>&1
    if ($LASTEXITCODE -ne 0) { throw "fstrim a échoué : $($out -join ' ')" }
    New-Result "TRIM de $($mount.target) : $($out -join ' ')" @($section) @() @(New-Change $mount.target 'Blocs libres signalés au SSD' 'non signalés' "$out") $null
}

# Travaux d'impression en attente : Printer, Id, Document, Owner, Submitted.
function Get-PrintQueue {
    if ($IsWindows) {
        return @(Get-Printer -ErrorAction SilentlyContinue | ForEach-Object {
                $p = $_.Name
                Get-PrintJob -PrinterName $p -ErrorAction SilentlyContinue | ForEach-Object { [PSCustomObject]@{ Printer = $p; Id = $_.Id; Document = $_.DocumentName; Owner = $_.UserName; Submitted = $_.SubmittedTime; Status = "$($_.JobStatus)" } }
            })
    }
    @(& lpstat -o 2>$null | ForEach-Object {
            if ($_ -match '^(\S+)-(\d+)\s+(\S+)\s+\d+\s+(.+)$') {
                $date = try { [datetime]::Parse($Matches[4], $script:Fr) } catch { try { [datetime]::Parse($Matches[4]) } catch { $null } }
                [PSCustomObject]@{ Printer = $Matches[1]; Id = [int]$Matches[2]; Document = $null; Owner = $Matches[3]; Submitted = $date; Status = $null }
            }
        })
}

# maintenance_reset_print_queue : vide la file d'impression et relance le spouleur.
# Windows : arrêt du Spooler, suppression de spool\PRINTERS, redémarrage (administrateur).
# Linux : cancel -a (tous les travaux en root, sinon les vôtres) puis redémarrage de CUPS (root).
function Reset-SIPrintSpooler {
    param([switch]$DryRun)
    $queue = @(Get-PrintQueue)
    $blocked = if ($IsWindows) { Get-AdminBlock } else { $null }
    if (-not $blocked -and $IsLinux -and -not (Get-Command cancel -ErrorAction SilentlyContinue)) { $blocked = 'CUPS n''est pas installé.' }
    $mine = if ($IsLinux -and -not (Test-Elevated)) { @($queue | Where-Object Owner -eq $env:USER) } else { $queue }
    if (-not $blocked -and $IsLinux -and -not (Test-Elevated) -and $mine.Count -eq 0) { $blocked = 'Aucun de vos travaux d''impression en attente, et relancer CUPS exige root.' }
    $rows = @($queue | ForEach-Object { , @($_.Printer, $_.Id, $_.Document, $_.Owner, (Format-Date $_.Submitted), $_.Status) })
    $sections = @([PSCustomObject]@{ Title = 'Travaux en attente'; Type = 'Table'; Icon = 'apps_list'; Columns = @('Imprimante', 'N°', 'Document', 'Propriétaire', 'Envoyé le', 'État'); Rows = $rows })
    $findings = @()
    if ($queue.Count) { $findings += New-Finding 'warning' 'MNT-PRINT-CANCEL' "$($mine.Count) travail(aux) d'impression seront annulés : il faudra les relancer." $null }
    if ($IsLinux -and -not (Test-Elevated)) { $findings += New-Finding 'info' 'MNT-PRINT-PARTIAL' 'Sans droits root : seuls vos travaux sont annulés et CUPS n''est pas redémarré.' $null }
    $change = New-Change 'File d''impression' 'Travaux' $queue.Count ($queue.Count - $mine.Count)
    if ($DryRun -or $blocked) { return New-Result "La file d'impression sera vidée ($($mine.Count) travail(aux)) et le spouleur relancé" $sections $findings @($change) $blocked }

    if ($IsWindows) {
        Stop-Service -Name Spooler -Force -ErrorAction Stop
        Get-ChildItem -LiteralPath "$env:WINDIR\System32\spool\PRINTERS" -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        Start-Service -Name Spooler -ErrorAction Stop
    }
    else {
        $out = & cancel -a 2>&1
        if ($LASTEXITCODE -ne 0 -and $mine.Count) { throw "cancel -a a échoué : $($out -join ' ')" }
        if (Test-Elevated) { & systemctl restart cups 2>&1 | Out-Null }
    }
    $left = @(Get-PrintQueue).Count
    New-Result "File d'impression vidée ($left travail(aux) restant(s))" $sections @() @(New-Change 'File d''impression' 'Travaux' $queue.Count $left) $null
}

# maintenance_rebuild_icon_cache : Windows, supprime le cache d'icônes et relance l'Explorateur (fenêtres de
# l'Explorateur fermées, bureau et barre des tâches redessinés).
function Reset-SIIconCache {
    param([switch]$DryRun)
    $dir = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"
    $files = @(Get-ChildItem -LiteralPath $dir -Filter 'iconcache*.db' -File -Force -ErrorAction SilentlyContinue) + @(Get-ChildItem -LiteralPath $env:LOCALAPPDATA -Filter 'IconCache.db' -File -Force -ErrorAction SilentlyContinue)
    $size = Format-Size (($files | Measure-Object Length -Sum).Sum ?? 0)
    $section = [PSCustomObject]@{ Title = 'Cache d''icônes'; Type = 'KeyValue'; Icon = 'desktop'; Items = [ordered]@{ Fichiers = $files.Count; Taille = $size; Dossier = $dir } }
    $findings = @(New-Finding 'warning' 'MNT-EXPLORER-RESTART' 'L''Explorateur est relancé : ses fenêtres ouvertes se ferment, le bureau et la barre des tâches disparaissent quelques secondes.' $null)
    $blocked = if ($files.Count -eq 0) { 'Aucun fichier de cache d''icônes trouvé.' } else { $null }
    if ($DryRun -or $blocked) { return New-Result "Le cache d'icônes ($size) sera reconstruit" @($section) $findings @(New-Change 'Cache d''icônes' 'Fichiers' $files.Count 0) $blocked }
    Get-Process -Name explorer -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 800
    foreach ($f in $files) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
    Start-Process explorer.exe
    $left = @(Get-ChildItem -LiteralPath $dir -Filter 'iconcache*.db' -File -Force -ErrorAction SilentlyContinue).Count
    New-Result 'Cache d''icônes supprimé, Explorateur relancé' @($section) @() @(New-Change 'Cache d''icônes' 'Fichiers' $files.Count $left) $null
}

# maintenance_repair_windows_update : arrête wuauserv, bits, cryptsvc et msiserver, renomme SoftwareDistribution et
# catroot2 (.old horodaté, conservés), puis relance les services. Windows Update reconstruit son cache.
function Reset-SIWindowsUpdate {
    param([switch]$DryRun)
    $blocked = Get-AdminBlock
    $folders = @("$env:WINDIR\SoftwareDistribution", "$env:WINDIR\System32\catroot2")
    $services = 'wuauserv', 'bits', 'cryptsvc', 'msiserver'
    $rows = @($folders | ForEach-Object {
            $size = (Get-ChildItem -LiteralPath $_ -File -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
            , @($_, $(if (Test-Path -LiteralPath $_) { Format-Size ($size ?? 0) } else { 'absent' }))
        })
    $sections = @([PSCustomObject]@{ Title = 'Dossiers renommés'; Type = 'Table'; Icon = 'arrow_clockwise'; Columns = @('Dossier', 'Taille'); Rows = $rows })
    $findings = @(
        New-Finding 'warning' 'MNT-WU-HISTORY' 'L''historique affiché par Windows Update est perdu (les mises à jour installées restent installées).' $null
        New-Finding 'info' 'MNT-WU-REDOWNLOAD' 'La prochaine recherche de mises à jour est plus longue : le cache est reconstruit.' $null
    )
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $changes = @($folders | ForEach-Object { New-Change $_ 'Nom' (Split-Path $_ -Leaf) "$(Split-Path $_ -Leaf).old-$stamp" })
    if ($DryRun -or $blocked) { return New-Result 'Le cache de Windows Update sera réinitialisé' $sections $findings $changes $blocked }

    foreach ($s in $services) { Stop-Service -Name $s -Force -ErrorAction SilentlyContinue }
    try {
        foreach ($f in $folders) { if (Test-Path -LiteralPath $f) { Rename-Item -LiteralPath $f -NewName "$(Split-Path $f -Leaf).old-$stamp" -ErrorAction Stop } }
    }
    finally {
        foreach ($s in $services) { Start-Service -Name $s -ErrorAction SilentlyContinue }
    }
    New-Result 'Cache de Windows Update réinitialisé' $sections @() $changes $null
}

# maintenance_check_wmi : cohérence du dépôt WMI (winmgmt /verifyrepository, administrateur).
function Test-SIWmiRepository {
    if (-not (Test-Elevated)) { throw 'winmgmt exige les droits administrateur : relancer SysInfo en administrateur.' }
    $out = Invoke-Native "$env:WINDIR\System32\wbem\winmgmt.exe" @('/verifyrepository')
    $ok = ($out -join ' ') -match 'consistent|cohérent'
    $inconsistent = ($out -join ' ') -match 'not consistent|inconsistent|incohérent'
    $findings = if ($inconsistent) { @(New-Finding 'critical' 'MNT-WMI-INCONSISTENT' 'Le dépôt WMI est incohérent : inventaire, antivirus et outils d''administration peuvent échouer.' 'Lancer maintenance_repair_wmi.') } else { @() }
    New-Result "Dépôt WMI : $(if ($inconsistent) { 'incohérent' } elseif ($ok) { 'cohérent' } else { 'résultat inconnu' })" @([PSCustomObject]@{ Title = 'winmgmt'; Type = 'Table'; Icon = 'search'; Columns = @('Sortie'); Rows = @($out | ForEach-Object { , @($_) }) }) $findings @() $null
}

# maintenance_repair_wmi : winmgmt /salvagerepository (reconstruit le dépôt WMI en gardant ce qui est lisible).
function Repair-SIWmiRepository {
    param([switch]$DryRun)
    $blocked = Get-AdminBlock
    $section = [PSCustomObject]@{ Title = 'Réparation WMI'; Type = 'KeyValue'; Icon = 'settings'; Items = [ordered]@{ Commande = 'winmgmt /salvagerepository'; Effet = 'dépôt WMI reconstruit, données lisibles conservées' } }
    $findings = @(New-Finding 'warning' 'MNT-WMI-RESTART' 'Le service WMI et ceux qui en dépendent redémarrent ; les outils qui l''utilisent peuvent échouer quelques secondes.' $null)
    if ($DryRun -or $blocked) { return New-Result 'Le dépôt WMI sera réparé' @($section) $findings @(New-Change 'Dépôt WMI' 'État' 'actuel' 'reconstruit') $blocked }
    $out = Invoke-Native "$env:WINDIR\System32\wbem\winmgmt.exe" @('/salvagerepository')
    if ($LASTEXITCODE -ne 0) { throw "winmgmt a échoué : $($out -join ' ')" }
    New-Result 'Dépôt WMI reconstruit' @($section) @() @(New-Change 'Dépôt WMI' 'État' 'actuel' 'reconstruit') $null
}

#endregion

#region Redémarrage planifié

# maintenance_schedule_restart : planifie un redémarrage dans N minutes, ou annule celui qui est planifié.
# Windows : shutdown /r /t (secondes) et /a. Linux : shutdown -r +N et -c (root).
function Set-SIRestart {
    param(
        [ValidateRange(1, 1440)][int]$Minutes = 10,
        [bool]$Cancel = $false,
        [switch]$DryRun
    )
    $blocked = if ($IsLinux) { Get-AdminBlock } else { $null }
    $pending = if ($IsLinux) { Test-Path /run/systemd/shutdown/scheduled } else { $null }
    if (-not $blocked -and $Cancel -and $IsLinux -and -not $pending) { $blocked = 'Aucun redémarrage n''est planifié.' }
    $at = (Get-Date).AddMinutes($Minutes)
    $section = [PSCustomObject]@{ Title = 'Redémarrage'; Type = 'KeyValue'; Icon = 'arrow_clockwise'; Items = [ordered]@{ Opération = if ($Cancel) { 'annulation du redémarrage planifié' } else { "redémarrage à $($at.ToString('HH:mm', $script:Fr))" } } }
    $findings = @()
    if (-not $Cancel) { $findings += New-Finding 'warning' 'MNT-RESTART-UNSAVED' "L'ordinateur redémarrera dans $Minutes min : enregistrer son travail ; les sessions ouvertes seront fermées." 'Annulable avec la même action et cancel = true.' }
    $change = if ($Cancel) { New-Change 'Ordinateur' 'Redémarrage planifié' 'oui' 'annulé' } else { New-Change 'Ordinateur' 'Redémarrage planifié' 'non' (Format-Date $at) }
    if ($DryRun -or $blocked) { return New-Result $(if ($Cancel) { 'Le redémarrage planifié sera annulé' } else { "Redémarrage planifié dans $Minutes min" }) @($section) $findings @($change) $blocked }

    if ($IsWindows) {
        $out = if ($Cancel) { & shutdown.exe /a 2>&1 } else { & shutdown.exe /r /t ($Minutes * 60) /c "Redémarrage planifié par SysInfo" 2>&1 }
    }
    else {
        $out = if ($Cancel) { & shutdown -c 2>&1 } else { & shutdown -r "+$Minutes" 'Redémarrage planifié par SysInfo' 2>&1 }
    }
    if ($LASTEXITCODE -ne 0) { throw "shutdown a échoué : $($out -join ' ')" }
    $undo = if ($Cancel) { $null } else { @{ Function = 'schedule_restart'; Parameters = @{ cancel = $true } } }
    New-Result $(if ($Cancel) { 'Redémarrage planifié annulé' } else { "Redémarrage planifié à $($at.ToString('HH:mm', $script:Fr))" }) @($section) $findings @($change) $null $undo
}

#endregion

#region Vue d'ensemble

function Get-ModuleData {
    $sections = [System.Collections.Generic.List[object]]::new()
    $findings = [System.Collections.Generic.List[object]]::new()

    # Points de restauration.
    $support = Get-Cached 'restore-support' 300 { Get-RestoreSupport }
    $points = @(Get-Cached 'restore-points' 300 { Get-RestorePointList })
    $last = $points | Select-Object -First 1
    $items = [ordered]@{ Outil = $support.Tool ?? 'aucun'; État = if ($support.Problem) { $support.Problem } else { 'disponible' } }
    $items['Points'] = if ($IsLinux -and -not (Test-Elevated) -and $support.Tool) { 'liste lisible en root' } else { $points.Count }
    if ($last) { $items['Dernier point'] = '{0} · {1}' -f (Format-Date $last.Date), $last.Description }
    $sections.Add([PSCustomObject]@{ Title = 'Points de restauration'; Type = 'KeyValue'; Icon = 'arrow_clockwise'; Items = $items })
    if ($points.Count) {
        $sections.Add([PSCustomObject]@{ Title = 'Derniers points de restauration'; Type = 'Table'; Icon = 'timer'; Columns = @('Date', 'Description', 'Type'); Rows = @($points | Select-Object -First 10 | ForEach-Object { , @((Format-Date $_.Date), $_.Description, $_.Type) }) })
    }
    if ($support.Problem) {
        $findings.Add((New-Finding $(if ($IsWindows) { 'warning' } else { 'info' }) 'MNT-NO-RESTORE-POINT' "Aucun point de restauration possible : $($support.Problem)." $(if ($IsWindows) { 'Activer la protection du système sur le disque système (Propriétés système › Protection du système).' } else { 'Installer snapper (Btrfs) ou Timeshift pour pouvoir revenir en arrière après une modification.' })))
    }
    elseif ($last -and $last.Date -lt (Get-Date).AddDays(-30)) {
        $findings.Add((New-Finding 'info' 'MNT-RESTORE-OLD' "Dernier point de restauration le $(Format-Date $last.Date)." 'En créer un avant une installation ou une modification importante (maintenance_create_restore_point).'))
    }

    # Nettoyage possible (estimation, mise en cache 10 min).
    $cleanup = Get-Cached 'cleanup' 600 {
        $targets = Get-CleanupTargets
        @($targets.Keys | ForEach-Object { $m = Measure-Cleanup $_ $targets[$_]; [PSCustomObject]@{ Key = $_; Label = $targets[$_].Label; Size = $m.Size; Count = $m.Files; Admin = $targets[$_].Admin } })
    }
    $total = ($cleanup | Measure-Object Size -Sum).Sum
    $sections.Add([PSCustomObject]@{
            Title = 'Nettoyage possible'; Type = 'Table'; Icon = 'hard_drive'; Columns = @('Catégorie', 'Code', 'Taille (MiB)', 'Fichiers', 'Droits')
            Rows = @($cleanup | ForEach-Object { , @($_.Label, $_.Key, [Math]::Round($_.Size / 1MB), $_.Count, $(if ($_.Admin) { 'administrateur' } else { 'utilisateur' })) })
        })
    if ($total -ge 5GB) { $findings.Add((New-Finding 'info' 'MNT-CLEANUP' "$(Format-Size $total) récupérables par nettoyage." 'Voir la carte « Nettoyage possible » et l''action maintenance_cleanup.')) }

    # File d'impression.
    $queue = @(Get-Cached 'print-queue' 30 { Get-PrintQueue })
    $spooler = if ($IsWindows) { "$((Get-Service -Name Spooler -ErrorAction SilentlyContinue).Status)" } else { (& systemctl is-active cups 2>$null) }
    $sections.Add([PSCustomObject]@{ Title = 'Impression'; Type = 'KeyValue'; Icon = 'apps_list'; Items = [ordered]@{ $(if ($IsWindows) { 'Spouleur' } else { 'CUPS' }) = $spooler ?? 'absent'; 'Travaux en attente' = $queue.Count } })
    $stuck = @($queue | Where-Object { $_.Submitted -and $_.Submitted -lt (Get-Date).AddHours(-1) })
    if ($stuck.Count) { $findings.Add((New-Finding 'warning' 'MNT-PRINT-STUCK' "$($stuck.Count) travail(aux) d'impression bloqué(s) depuis plus d'une heure." 'Vérifier l''imprimante, puis maintenance_reset_print_queue.')) }

    $subtitle = @("$($support.Tool ?? 'pas de point de restauration')", "$(Format-Size $total) récupérables")
    if ($queue.Count) { $subtitle += "$($queue.Count) impression(s) en attente" }
    [PSCustomObject]@{ Subtitle = $subtitle -join ' · '; Sections = $sections.ToArray(); Findings = $findings.ToArray() }
}

#endregion

Export-ModuleMember -Function Get-ModuleData, New-SIRestorePoint, Clear-SIJunk, Get-SISystemFileCheck, Repair-SISystemFiles,
    Get-SIWindowsImageHealth, Repair-SIWindowsImage, Test-SIDisk, Set-SIDiskRepair, Optimize-SIVolume, Reset-SIPrintSpooler,
    Reset-SIIconCache, Reset-SIWindowsUpdate, Test-SIWmiRepository, Repair-SIWmiRepository, Set-SIRestart
