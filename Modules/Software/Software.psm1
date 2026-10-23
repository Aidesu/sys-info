# Module Logiciels : applications installées (toutes sources), mises à jour en attente et historique, redémarrage
# requis, démarrage automatique, runtimes, navigateurs, activation, logiciels en fin de support.
#
# Sources
#   Windows : registre Uninstall (HKLM, WOW6432Node, HKCU), registre AppModel\Repository\Packages (applications du
#             Store), COM Microsoft.Update.AutoUpdate / Session (Windows Update), Get-HotFix, winget (si présent),
#             registre Run / RunOnce + StartupApproved + dossiers Démarrage, SoftwareLicensingProduct (activation),
#             registre NDP\v4 (.NET Framework), PythonCore, PowerShellEngine, StartMenuInternet, UserChoice.
#   Linux   : rpm -qa / dpkg-query / pacman -Q, fichiers .desktop (applications), flatpak list, snap list,
#             dnf / apt / pacman (mises à jour, depuis le cache local), flatpak remote-ls --updates --cached,
#             dnf history / /var/log/apt/history.log, noyaux installés (redémarrage requis), autostart XDG,
#             systemctl --user, xdg-settings (navigateur par défaut), commandes --version des runtimes.
#
# Tout est mis en cache (5 à 60 min) : la liste des logiciels change rarement et sa lecture coûte 1 à 3 s.
# Jamais exposé : clés de produit (même partielles).

$script:Fr = [cultureinfo]::GetCultureInfo('fr-FR')

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

function Format-Date($Date) { if ($Date) { ([datetime]$Date).ToString('dd/MM/yyyy HH:mm', $script:Fr) } else { $null } }
function Format-Day($Date) { if ($Date) { ([datetime]$Date).ToString('dd/MM/yyyy', $script:Fr) } else { $null } }

function New-Finding([string]$Severity, [string]$Code, [string]$Message, [string]$Recommendation) {
    [PSCustomObject]@{ Severity = $Severity; Code = $Code; Message = $Message; Recommendation = $Recommendation }
}

function Read-Text([string]$Path) { try { [System.IO.File]::ReadAllLines($Path) } catch { $null } }

function Get-RegValue([string]$Path, [string]$Name) { (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue).$Name }

# Taille en MiB (nombre, pour que la colonne trie) depuis un texte « 524.7 MB », « 1,2 GB »…
function ConvertTo-MiB([string]$Text) {
    if ($Text -notmatch '([\d.,]+)\s*([kKMGT]?)i?B') { return $null }
    $v = [double]($Matches[1] -replace ',', '.')
    # Clés de hashtable insensibles à la casse : k et K valent tous deux kilo.
    $factor = @{ '' = 1 / 1MB; k = 1 / 1KB; M = 1; G = 1KB; T = 1MB }[$Matches[2]]
    [Math]::Round($v * $factor, 1)
}

# Première ligne de sortie d'une commande (stdout ou stderr : java -version écrit sur stderr).
function Get-CommandOutput([string]$Command, [string[]]$Arguments) {
    $cmd = Get-Command $Command -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { return $null }
    # Alias d'exécution du Microsoft Store (python.exe vide dans WindowsApps) : ouvrirait le Store.
    if ($IsWindows -and $cmd.Source -like '*\WindowsApps\*') { return $null }
    "$(& $cmd.Source @Arguments 2>&1 | Where-Object { "$_" -match '\S' } | Select-Object -First 1)".Trim()
}

# Linux : paquet propriétaire de chaque fichier. rpm -qf en lot (une ligne par fichier, « file … is not owned »
# compris) ; si un fichier a plusieurs propriétaires le nombre de lignes diffère et on repasse fichier par fichier.
function Get-PackageOwners([string[]]$Paths) {
    $map = @{}
    if ($Paths.Count -eq 0) { return $map }
    if (Get-Command rpm -ErrorAction SilentlyContinue) {
        $out = @(& sh -c 'rpm -qf --qf "%{NAME}\n" -- "$@" 2>&1' sh @Paths)
        if ($out.Count -eq $Paths.Count) {
            for ($i = 0; $i -lt $Paths.Count; $i++) { $map[$Paths[$i]] = if ("$($out[$i])" -match '\s') { $null } else { "$($out[$i])" } }
            return $map
        }
        # Repli : un rpm par fichier, 8 en parallèle (xargs -P), une ligne « chemin<TAB>paquet(s) » chacun.
        $script = 'printf "%s\0" "$@" | xargs -0 -P 8 -n 16 sh -c ''for f; do o=$(rpm -qf --qf "%{NAME} " -- "$f" 2>/dev/null) || o=-; printf "%s\t%s\n" "$f" "$o"; done'' sh'
        foreach ($line in & sh -c $script sh @Paths 2>$null) {
            $i = $line.LastIndexOf("`t"); if ($i -lt 0) { continue }
            $owner = $line.Substring($i + 1).Trim()
            $map[$line.Substring(0, $i)] = if ($owner -and $owner -ne '-') { ($owner -split ' ')[0] } else { $null }
        }
    } elseif (Get-Command dpkg -ErrorAction SilentlyContinue) {
        foreach ($p in $Paths) { $map[$p] = $null }
        foreach ($line in & dpkg -S -- @Paths 2>$null) { if ($line -match '^([^:]+(?::[^:\s]+)?): (.+)$') { $map[$Matches[2]] = ($Matches[1] -split ',')[0] } }
    }
    $map
}

# Fichier .desktop → dictionnaire des clés de la section [Desktop Entry] (les traductions Name[fr] priment).
function Read-DesktopEntry([string]$Path) {
    $entry = @{}; $inMain = $false
    foreach ($line in Read-Text $Path) {
        if ($line -match '^\[(.+)\]') { $inMain = $Matches[1] -eq 'Desktop Entry'; continue }
        if ($inMain -and $line -match '^([\w-]+)(\[([\w@_]+)\])?\s*=\s*(.*)$') {
            $key = $Matches[1]; $lang = $Matches[3]
            if (-not $lang) { if (-not $entry.ContainsKey($key)) { $entry[$key] = $Matches[4] } }
            elseif ($lang -eq 'fr') { $entry[$key] = $Matches[4] }
        }
    }
    $entry
}

#endregion

#region Logiciels installés

# Entrées normalisées : Name, Version, Publisher, Date, SizeMiB, Source, Scope, Description, Id.

function Get-WindowsPrograms {
    $keys = @(
        @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'Tous les utilisateurs'),
        @('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'Tous les utilisateurs (32 bits)'),
        @('HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'Utilisateur')
    )
    $seen = @{}
    foreach ($k in $keys) {
        foreach ($item in Get-ChildItem -LiteralPath $k[0] -ErrorAction SilentlyContinue) {
            $p = $item.GetValue('DisplayName')
            if (-not $p) { continue }
            # Composants système, correctifs et mises à jour rattachés à un produit : pas des programmes.
            if ($item.GetValue('SystemComponent') -eq 1 -or $item.GetValue('ParentKeyName') -or "$($item.GetValue('ReleaseType'))" -match 'Update|Hotfix') { continue }
            $version = "$($item.GetValue('DisplayVersion'))"
            $key = "$p|$version"
            if ($seen[$key]) { continue }
            $seen[$key] = $true
            $date = "$($item.GetValue('InstallDate'))"
            [PSCustomObject]@{
                Name = "$p"; Version = $version; Publisher = "$($item.GetValue('Publisher'))"
                Date = if ($date -match '^(\d{4})(\d\d)(\d\d)$') { try { [datetime]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3]) } catch { $null } } else { $null }
                SizeMiB = if ($item.GetValue('EstimatedSize')) { [Math]::Round([double]$item.GetValue('EstimatedSize') / 1KB, 1) } else { $null }
                Source = 'Programme'; Scope = $k[1]; Description = "$($item.GetValue('InstallLocation'))"; Id = $item.PSChildName
            }
        }
    }
}

# Applications du Store de l'utilisateur, sans Get-AppxPackage (non chargé par PowerShell 7) : sous-clés
# « Nom_Version_Archi__Éditeur ». Frameworks et composants de Windows exclus.
function Get-StoreApps {
    $root = 'HKCU:\SOFTWARE\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages'
    $seen = @{}
    foreach ($item in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {
        $parts = $item.PSChildName -split '_'
        if ($parts.Count -lt 5) { continue }
        $name = $parts[0]
        if ($name -match '^(Microsoft\.(VCLibs|NET\.|UI\.Xaml|WindowsAppRuntime|Services\.Store|DesktopAppInstaller|Windows\.|Win32WebViewHost|AAD|AccountsControl|LockApp|ECApp|CredDialogHost|BioEnrollment|AsyncTextService|MicrosoftEdgeDevToolsClient|XboxGameCallableUI|ApplicationCompatibilityEnhancements)|windows\.|Windows\.|MicrosoftWindows\.|NcsiUwpApp|c5e2524a-|E2A4F912-|F46D4000-|1527c705-)') { continue }
        if ($seen[$name]) { continue }
        $seen[$name] = $true
        $display = "$($item.GetValue('DisplayName'))"
        [PSCustomObject]@{
            Name = if ($display -and $display -notlike '@*' -and $display -notlike 'ms-resource*') { $display } else { $name -replace '^[^.]+\.', '' }
            Version = $parts[1]; Publisher = ($name -split '\.')[0]; Date = $null; SizeMiB = $null
            Source = 'Microsoft Store'; Scope = 'Utilisateur'; Description = $name; Id = $item.PSChildName
        }
    }
}

# Linux : tous les paquets de la distribution.
function Get-LinuxPackages {
    if (Get-Command rpm -ErrorAction SilentlyContinue) {
        return & rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}\t%{ARCH}\t%{VENDOR}\t%{INSTALLTIME}\t%{SIZE}\t%{SUMMARY}\n' 2>$null | ForEach-Object {
            $f = $_ -split "`t"
            if ($f[0] -eq 'gpg-pubkey') { return }
            [PSCustomObject]@{
                Name = $f[0]; Version = $f[1]; Publisher = $f[3] -replace '^\(none\)$', ''; Date = [DateTimeOffset]::FromUnixTimeSeconds([long]$f[4]).LocalDateTime
                SizeMiB = [Math]::Round([double]$f[5] / 1MB, 1); Source = 'Paquet (rpm)'; Scope = $f[2]; Description = $f[6]; Id = $f[0]
            }
        }
    }
    if (Get-Command dpkg-query -ErrorAction SilentlyContinue) {
        return & dpkg-query -W -f '${db:Status-Abbrev}\t${Package}\t${Version}\t${Architecture}\t${Maintainer}\t${Installed-Size}\t${binary:Summary}\n' 2>$null | ForEach-Object {
            $f = $_ -split "`t"
            if ($f[0] -notlike 'ii*') { return }
            [PSCustomObject]@{
                Name = $f[1]; Version = $f[2]; Publisher = $f[4] -replace '\s*<.*$', ''; Date = $null
                SizeMiB = if ($f[5] -match '^\d+$') { [Math]::Round([double]$f[5] / 1KB, 1) } else { $null }; Source = 'Paquet (deb)'; Scope = $f[3]; Description = $f[6]; Id = $f[1]
            }
        }
    }
    if (Get-Command pacman -ErrorAction SilentlyContinue) {
        return & pacman -Q 2>$null | ForEach-Object {
            $f = $_ -split ' '
            [PSCustomObject]@{ Name = $f[0]; Version = $f[1]; Publisher = ''; Date = $null; SizeMiB = $null; Source = 'Paquet (pacman)'; Scope = ''; Description = ''; Id = $f[0] }
        }
    }
    @()
}

function Get-FlatpakApps {
    if (-not (Get-Command flatpak -ErrorAction SilentlyContinue)) { return @() }
    & flatpak list --app --columns=application,name,version,origin,installation,size 2>$null | ForEach-Object {
        $f = $_ -split "`t"
        if ($f.Count -lt 6) { return }
        [PSCustomObject]@{
            Name = $f[1]; Version = $f[2]; Publisher = $f[3]; Date = $null; SizeMiB = ConvertTo-MiB $f[5]
            Source = 'Flatpak'; Scope = @{ system = 'Système'; user = 'Utilisateur' }[$f[4]] ?? $f[4]; Description = $f[0]; Id = $f[0]
        }
    }
}

function Get-SnapApps {
    if (-not (Get-Command snap -ErrorAction SilentlyContinue)) { return @() }
    & snap list --color=never 2>$null | Select-Object -Skip 1 | ForEach-Object {
        $f = $_ -split '\s+'
        if ($f.Count -lt 5) { return }
        # Socles (base) et snapd : la plomberie de Snap, pas des applications.
        # Socles (base), snapd et snaps de contenu partagé (thèmes, bibliothèques GNOME / KDE / FFmpeg) : la
        # plomberie de Snap, pas des applications.
        if ($f[5] -match 'base|snapd' -or $f[0] -in 'snapd', 'bare' -or $f[0] -match '^(core\d*|gnome-\d|gtk-common-themes|kf\d-core|mesa-|ffmpeg-\d|gpu-\d)') { return }
        [PSCustomObject]@{ Name = $f[0]; Version = $f[1]; Publisher = $f[4] -replace '\*+$', ''; Date = $null; SizeMiB = $null; Source = 'Snap'; Scope = $f[3]; Description = "révision $($f[2])"; Id = $f[0] }
    }
}

# Linux : applications de bureau installées par paquet (.desktop visibles de /usr/share/applications) ou par
# l'utilisateur (~/.local/share/applications), rattachées à leur paquet.
function Get-LinuxDesktopApps($Packages) {
    $files = @(Get-ChildItem /usr/share/applications, /usr/local/share/applications -Filter *.desktop -File -ErrorAction SilentlyContinue)
    $entries = foreach ($f in $files) {
        $e = Read-DesktopEntry $f.FullName
        if ($e.Type -ne 'Application' -or $e.NoDisplay -eq 'true' -or $e.Hidden -eq 'true' -or -not $e.Name) { continue }
        [PSCustomObject]@{ Path = $f.FullName; Entry = $e }
    }
    $owners = Get-PackageOwners @($entries.Path)
    $byName = @{}; foreach ($p in $Packages) { $byName[$p.Name] = $p }
    $seen = @{}
    foreach ($x in $entries) {
        $pkg = $owners[$x.Path]; $p = if ($pkg) { $byName[$pkg] } else { $null }
        $key = $pkg ?? $x.Path
        if ($seen[$key]) { continue }
        $seen[$key] = $true
        [PSCustomObject]@{
            Name = $x.Entry.Name; Version = $p.Version; Publisher = $p.Publisher; Date = $p.Date; SizeMiB = $p.SizeMiB
            Source = if ($pkg) { $p.Source } else { 'Hors paquet' }; Scope = 'Système'; Description = $x.Entry.Comment ?? $p.Description; Id = $pkg ?? (Split-Path $x.Path -Leaf)
        }
    }
    foreach ($f in Get-ChildItem (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.local/share/applications') -Filter *.desktop -File -ErrorAction SilentlyContinue) {
        $e = Read-DesktopEntry $f.FullName
        if ($e.Type -ne 'Application' -or $e.NoDisplay -eq 'true' -or -not $e.Name) { continue }
        # Raccourcis web et entrées créées par Wine / Steam / navigateurs : ce ne sont pas des installations.
        if ($f.Name -match '^(chrome-|brave-|msedge-|wine-|userapp-)' -or $e.Exec -match 'steam://') { continue }
        [PSCustomObject]@{ Name = $e.Name; Version = $null; Publisher = $null; Date = $f.LastWriteTime; SizeMiB = $null; Source = 'Utilisateur'; Scope = 'Utilisateur'; Description = $e.Comment; Id = $f.Name }
    }
}

# Date de dernière modification de la base des paquets (rpm, dpkg, pacman) : la liste (1 à 3 s à lire) n'est relue
# que si elle a changé.
function Get-PackageDbStamp {
    $item = Get-Item /usr/lib/sysimage/rpm/rpmdb.sqlite, /var/lib/rpm/rpmdb.sqlite, /var/lib/rpm/Packages, /var/lib/dpkg/status, /var/lib/pacman/local -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($item) { $item.LastWriteTime.Ticks } else { (Get-Date).ToString('yyyyMMddHH') }
}

function Get-Packages { $stamp = Get-PackageDbStamp; Get-Cached "packages|$stamp" 86400 { @(Get-LinuxPackages) } }

# Applications (vue d'ensemble) : programmes Windows + Store, ou applications de bureau Linux + Flatpak + Snap.
function Get-Applications {
    if ($IsWindows) { return @(Get-Cached 'programs' 600 { @(Get-WindowsPrograms) }) + @(Get-Cached 'store' 600 { @(Get-StoreApps) }) }
    $stamp = Get-PackageDbStamp
    $packages = @(Get-Packages)
    @(Get-Cached "desktopapps|$stamp" 86400 { @(Get-LinuxDesktopApps $packages) }) + @(Get-Cached 'flatpak' 600 { @(Get-FlatpakApps) }) + @(Get-Cached 'snap' 600 { @(Get-SnapApps) })
}

#endregion

#region Mises à jour

# Linux, depuis le cache local (rapide, sans réseau) ou après actualisation des dépôts ($Refresh).
# Entrées : Name, Installed, Available, Source, Security.
function Get-LinuxPendingUpdates([bool]$Refresh) {
    $list = [System.Collections.Generic.List[object]]::new()
    $notes = [System.Collections.Generic.List[string]]::new()
    if (Get-Command dnf -ErrorAction SilentlyContinue) {
        $cacheArg = if ($Refresh) { '--refresh' } else { '-C' }
        $installed = @{}
        foreach ($p in Get-Packages) { $installed["$($p.Name).$($p.Scope)"] = $p.Version }
        foreach ($line in & dnf $cacheArg list --upgrades -q 2>$null) {
            if ($line -notmatch '^(\S+)\.(\w+)\s+(\S+)\s+(\S+)\s*$') { continue }
            $list.Add([PSCustomObject]@{ Name = $Matches[1]; Installed = $installed["$($Matches[1]).$($Matches[2])"]; Available = $Matches[3]; Source = "dnf · $($Matches[4])"; Security = $false })
        }
        # Avis de sécurité (~1 s) : lus seulement s'il y a des mises à jour.
        if ($list.Count -gt 0) {
            $security = @{}
            foreach ($line in & dnf $cacheArg advisory list --security -q 2>$null) { if ($line -match '^\S+\s+\S+\s+(\S+?)-\d') { $security[$Matches[1]] = $true } }
            foreach ($u in $list) { $u.Security = [bool]$security[$u.Name] }
        }
        # Âge du cache des dépôts : celui de l'utilisateur (dnf sans root) ou du système.
        $cache = Get-ChildItem (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cache/libdnf5'), /var/cache/libdnf5, /var/cache/dnf -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $Refresh -and $cache) { $notes.Add("dnf : cache du $(Format-Date $cache.LastWriteTime)") }
    } elseif (Get-Command apt -ErrorAction SilentlyContinue) {
        foreach ($line in & apt list --upgradable 2>$null) {
            if ($line -match '^([^/]+)/(\S+)\s+(\S+)\s+\S+\s+\[upgradable from: ([^\]]+)\]') {
                $list.Add([PSCustomObject]@{ Name = $Matches[1]; Installed = $Matches[4]; Available = $Matches[3]; Source = "apt · $($Matches[2])"; Security = $Matches[2] -match 'security' })
            }
        }
        $stamp = Get-Item /var/lib/apt/periodic/update-success-stamp, /var/cache/apt/pkgcache.bin -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($stamp) { $notes.Add("apt : listes du $(Format-Date $stamp.LastWriteTime)" + $(if ($Refresh) { ' (actualisation : root requis, apt update)' } else { '' })) }
    } elseif (Get-Command pacman -ErrorAction SilentlyContinue) {
        $out = if ($Refresh -and (Get-Command checkupdates -ErrorAction SilentlyContinue)) { & checkupdates 2>$null } else { & pacman -Qu 2>$null }
        foreach ($line in $out) { if ($line -match '^(\S+) (\S+) -> (\S+)') { $list.Add([PSCustomObject]@{ Name = $Matches[1]; Installed = $Matches[2]; Available = $Matches[3]; Source = 'pacman'; Security = $false }) } }
    }
    if (Get-Command flatpak -ErrorAction SilentlyContinue) {
        $flatArgs = @('remote-ls', '--updates', '--app', '--columns=application,version,origin')
        if (-not $Refresh) { $flatArgs += '--cached' }
        $current = @{}; foreach ($a in Get-Cached 'flatpak' 600 { @(Get-FlatpakApps) }) { $current[$a.Id] = $a.Version }
        foreach ($line in & flatpak @flatArgs 2>$null) {
            $f = $line -split "`t"
            if ($f.Count -ge 2 -and $f[0]) { $list.Add([PSCustomObject]@{ Name = $f[0]; Installed = $current[$f[0]]; Available = $f[1]; Source = "Flatpak · $($f[2])"; Security = $false }) }
        }
    }
    if ($Refresh -and (Get-Command snap -ErrorAction SilentlyContinue)) {
        foreach ($line in & snap refresh --list --color=never 2>$null | Select-Object -Skip 1) {
            $f = $line -split '\s+'
            if ($f.Count -ge 2) { $list.Add([PSCustomObject]@{ Name = $f[0]; Installed = $null; Available = $f[1]; Source = 'Snap'; Security = $false }) }
        }
    }
    [PSCustomObject]@{ Updates = $list.ToArray(); Notes = $notes.ToArray() }
}

# Windows Update : dates de la dernière recherche et de la dernière installation réussies (UTC → local).
function Get-WindowsUpdateStatus {
    $results = (New-Object -ComObject Microsoft.Update.AutoUpdate).Results
    [PSCustomObject]@{
        LastSearch = if ($results.LastSearchSuccessDate) { ([datetime]$results.LastSearchSuccessDate).ToLocalTime() } else { $null }
        LastInstall = if ($results.LastInstallationSuccessDate) { ([datetime]$results.LastInstallationSuccessDate).ToLocalTime() } else { $null }
    }
}

# Historique : Windows Update (QueryHistory) ; Linux : transactions dnf ou journal d'apt.
# Entrées : Date, Title, Result, Kind, Id.
function Get-UpdateHistoryEntries([int]$Days, [int]$Max) {
    $since = (Get-Date).AddDays(-$Days)
    if ($IsWindows) {
        $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
        $count = [Math]::Min($searcher.GetTotalHistoryCount(), 1000)
        if ($count -eq 0) { return @() }
        $codes = @{ 0 = 'Non commencé'; 1 = 'En cours'; 2 = 'Réussi'; 3 = 'Réussi avec erreurs'; 4 = 'Échec'; 5 = 'Annulé' }
        $operations = @{ 1 = 'Installation'; 2 = 'Désinstallation'; 3 = 'Autre' }
        return @($searcher.QueryHistory(0, $count) | Where-Object { $_.Date -and ([datetime]$_.Date).ToLocalTime() -ge $since -and $_.Title } | Select-Object -First $Max | ForEach-Object {
                [PSCustomObject]@{
                    Date = ([datetime]$_.Date).ToLocalTime(); Title = $_.Title; Result = $codes[[int]$_.ResultCode]; Failed = [int]$_.ResultCode -in 4, 5
                    Kind = $operations[[int]$_.Operation]; Id = if ($_.Title -match '\b(KB\d+)\b') { $Matches[1] } else { $null }; Detail = if ([int]$_.HResult -ne 0) { '0x{0:X8}' -f [int]$_.HResult } else { $null }
                }
            })
    }
    if (Get-Command dnf -ErrorAction SilentlyContinue) {
        return @(& dnf history list 2>$null | ForEach-Object {
                if ($_ -match '^\s*(\d+)\s+(.*?)\s*(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\s+(\S.*?)?\s+(\d+)\s*$') {
                    $date = [datetime]$Matches[3]
                    if ($date -ge $since) {
                        [PSCustomObject]@{ Date = $date; Title = if ($Matches[2]) { $Matches[2].Trim() } else { '(mise à jour automatique ou logithèque)' }; Result = 'Réussi'; Failed = $false; Kind = "$($Matches[5]) paquet(s)" + $(if ($Matches[4]) { " · $($Matches[4].Trim())" } else { '' }); Id = $Matches[1]; Detail = $null }
                    }
                }
            } | Sort-Object Date -Descending | Select-Object -First $Max)
    }
    if (Test-Path /var/log/apt/history.log) {
        $entries = [System.Collections.Generic.List[object]]::new(); $cur = $null
        foreach ($line in Read-Text '/var/log/apt/history.log') {
            if ($line -match '^Start-Date:\s*(.+)$') { $cur = [PSCustomObject]@{ Date = [datetime]($Matches[1] -replace '\s+', ' '); Title = ''; Result = 'Réussi'; Failed = $false; Kind = ''; Id = $null; Detail = $null } }
            elseif ($cur -and $line -match '^Commandline:\s*(.+)$') { $cur.Title = $Matches[1] }
            elseif ($cur -and $line -match '^(Install|Upgrade|Remove|Purge):\s*(.+)$') { $cur.Kind += '{0} {1} ' -f @{ Install = 'Installés'; Upgrade = 'Mis à jour'; Remove = 'Supprimés'; Purge = 'Purgés' }[$Matches[1]], ([regex]::Matches($Matches[2], '\),?').Count) }
            elseif ($cur -and $line -match '^Error:') { $cur.Result = 'Erreur'; $cur.Failed = $true }
            elseif ($cur -and $line -match '^End-Date:') { if ($cur.Date -ge $since) { $entries.Add($cur) }; $cur = $null }
        }
        return @($entries | Sort-Object Date -Descending | Select-Object -First $Max)
    }
    @()
}

# Redémarrage requis. Windows : clés RebootRequired / RebootPending. Linux : noyau installé plus récent que celui
# en cours (rpm), ou /var/run/reboot-required (Debian, Ubuntu).
function Get-RebootRequired {
    if ($IsWindows) {
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { return 'Windows Update' }
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { return 'composants Windows' }
        return $null
    }
    if (Test-Path /var/run/reboot-required) { return ((Read-Text /var/run/reboot-required.pkgs) -join ', ') ?? 'mise à jour' }
    if (Get-Command rpm -ErrorAction SilentlyContinue) {
        $running = (& uname -r).Trim()
        $newest = & rpm -q kernel-core kernel --qf '%{INSTALLTIME} %{VERSION}-%{RELEASE}.%{ARCH}\n' 2>$null | Where-Object { $_ -match '^\d+ ' } | Sort-Object { [long]($_ -split ' ')[0] } | Select-Object -Last 1
        if ($newest -and ($newest -split ' ')[1] -ne $running) { return "noyau $(($newest -split ' ')[1]) installé, $running en cours" }
    }
    $null
}

#endregion

#region Démarrage, runtimes, navigateurs, activation

# Programmes lancés à l'ouverture de session : Name, Command, Location, Scope, Enabled, Missing.
function Get-StartupItems {
    $items = [System.Collections.Generic.List[object]]::new()
    if ($IsWindows) {
        # StartupApproved : premier octet pair = activé, impair = désactivé (Gestionnaire des tâches › Démarrage).
        function Test-Approved([string]$Hive, [string]$Sub, [string]$Name) {
            $v = Get-RegValue "$Hive\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\$Sub" $Name
            if ($v -is [byte[]] -and $v.Count -gt 0) { return ($v[0] % 2) -eq 0 }
            $true
        }
        foreach ($k in @(@('HKLM:', 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'Run', 'Tous les utilisateurs'), @('HKLM:', 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run', 'Run32', 'Tous les utilisateurs'), @('HKCU:', 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'Run', 'Utilisateur'))) {
            $item = Get-Item -LiteralPath "$($k[0])\$($k[1])" -ErrorAction SilentlyContinue
            if (-not $item) { continue }
            foreach ($name in $item.GetValueNames() | Where-Object { $_ }) {
                $cmd = "$($item.GetValue($name))"
                $exe = if ($cmd -match '^\s*"([^"]+)"') { $Matches[1] } elseif ($cmd -match '^\s*(.+?\.exe)\b') { $Matches[1] } else { ($cmd -split '\s+')[0] }
                $exe = [Environment]::ExpandEnvironmentVariables($exe)
                $items.Add([PSCustomObject]@{ Name = $name; Command = $cmd; Location = "$($k[0])\…\$(Split-Path $k[1] -Leaf)"; Scope = $k[3]; Enabled = Test-Approved $k[0] $k[2] $name; Missing = $exe -match '^[A-Za-z]:\\' -and -not (Test-Path -LiteralPath $exe) })
            }
        }
        $wsh = New-Object -ComObject WScript.Shell
        foreach ($f in @(@([Environment]::GetFolderPath('Startup'), 'HKCU:', 'Utilisateur'), @([Environment]::GetFolderPath('CommonStartup'), 'HKLM:', 'Tous les utilisateurs'))) {
            foreach ($file in Get-ChildItem -LiteralPath $f[0] -File -ErrorAction SilentlyContinue | Where-Object Name -ne 'desktop.ini') {
                $target = if ($file.Extension -eq '.lnk') { $wsh.CreateShortcut($file.FullName).TargetPath } else { $file.FullName }
                $items.Add([PSCustomObject]@{ Name = $file.BaseName; Command = $target; Location = 'Dossier Démarrage'; Scope = $f[2]; Enabled = Test-Approved $f[1] 'StartupFolder' $file.Name; Missing = $target -and -not (Test-Path -LiteralPath $target) })
            }
        }
        return $items.ToArray()
    }

    # Linux : autostart XDG (l'entrée de l'utilisateur remplace celle du système de même nom), puis services
    # systemd --user activés hors plomberie de session.
    $desktop = "$env:XDG_CURRENT_DESKTOP" -split ':' | Where-Object { $_ }
    $userDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.config/autostart'
    $byName = [ordered]@{}
    foreach ($dir in '/etc/xdg/autostart', $userDir) {
        foreach ($f in Get-ChildItem $dir -Filter *.desktop -File -ErrorAction SilentlyContinue) { $byName[$f.Name] = $f }
    }
    foreach ($f in $byName.Values) {
        $e = Read-DesktopEntry $f.FullName
        $only = $e.OnlyShowIn -split ';' | Where-Object { $_ }
        $not = $e.NotShowIn -split ';' | Where-Object { $_ }
        # Entrée réservée à un autre bureau (GNOME sous KDE…) : ne démarre pas, ignorée.
        if (($only -and -not ($only | Where-Object { $_ -in $desktop })) -or ($not | Where-Object { $_ -in $desktop })) { continue }
        $exe = ($e.Exec -split '\s+')[0] -replace '^"|"$', ''
        $missing = $exe -and -not (Get-Command $exe -CommandType Application -ErrorAction SilentlyContinue) -and -not ($exe -like '/*' -and (Test-Path $exe))
        $items.Add([PSCustomObject]@{
                Name = $e.Name ?? $f.BaseName; Command = $e.Exec; Location = $f.DirectoryName
                Scope = if ($f.DirectoryName -eq $userDir) { 'Utilisateur' } else { 'Tous les utilisateurs' }
                Enabled = $e.Hidden -ne 'true' -and $e.'X-GNOME-Autostart-enabled' -ne 'false' -and $e.'X-KDE-autostart-enabled' -ne 'false'; Missing = [bool]$missing
            })
    }
    foreach ($line in & systemctl --user list-unit-files --type=service --state=enabled --no-legend 2>$null) {
        $unit = ($line -split '\s+')[0]
        if (-not $unit -or $unit -match '^(dbus|pipewire|wireplumber|xdg-|systemd-|at-spi|gvfs|obex|p11-kit|grub-|plasma-|evolution-|tracker|localsearch|gnome-|org\.)') { continue }
        $items.Add([PSCustomObject]@{ Name = $unit; Command = $null; Location = 'systemctl --user'; Scope = 'Utilisateur'; Enabled = $true; Missing = $false })
    }
    $items.ToArray()
}

# Runtimes et environnements d'exécution : Name, Version, Path.
function Get-Runtimes($Programs) {
    $list = [System.Collections.Generic.List[object]]::new()
    function Add-Runtime([string]$Name, [string]$Version, [string]$Path) { if ($Version) { $list.Add([PSCustomObject]@{ Name = $Name; Version = $Version; Path = $Path }) } }

    foreach ($line in @(if (Get-Command dotnet -ErrorAction SilentlyContinue) { & dotnet --list-runtimes 2>$null })) {
        if ($line -match '^(\S+) (\S+) \[(.+)\]$') { Add-Runtime $Matches[1] $Matches[2] $Matches[3] }
    }
    if ($IsWindows) {
        $release = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' 'Release'
        if ($release) {
            $fx = switch ([int]$release) { { $_ -ge 533320 } { '4.8.1'; break } { $_ -ge 528040 } { '4.8'; break } { $_ -ge 461808 } { '4.7.2'; break } { $_ -ge 461308 } { '4.7.1'; break } { $_ -ge 460798 } { '4.7'; break } { $_ -ge 394802 } { '4.6.2'; break } default { '4.6.1 ou antérieur' } }
            Add-Runtime '.NET Framework' $fx "Release $release"
        }
        foreach ($hive in 'HKLM:\SOFTWARE\Python\PythonCore', 'HKCU:\SOFTWARE\Python\PythonCore', 'HKLM:\SOFTWARE\WOW6432Node\Python\PythonCore') {
            foreach ($k in Get-ChildItem $hive -ErrorAction SilentlyContinue) {
                Add-Runtime 'Python' ((Get-RegValue $k.PSPath 'Version') ?? $k.PSChildName) (Get-RegValue "$($k.PSPath)\InstallPath" '(default)')
            }
        }
        Add-Runtime 'Windows PowerShell' (Get-RegValue 'HKLM:\SOFTWARE\Microsoft\PowerShell\3\PowerShellEngine' 'PowerShellVersion') $null
        foreach ($p in $Programs | Where-Object { $_.Name -match 'Visual C\+\+ (\d{4}).*Redistributable' }) { Add-Runtime 'Visual C++ Redistributable' ("$($Matches[1]) · $($p.Version)" + $(if ($p.Name -match 'x86') { ' (x86)' } elseif ($p.Name -match 'x64') { ' (x64)' } else { '' })) $null }
        foreach ($p in $Programs | Where-Object { $_.Name -match '^(Java|Eclipse Temurin|Microsoft Build of OpenJDK|Amazon Corretto|Azul Zulu)' }) { Add-Runtime 'Java' "$($p.Version) ($($p.Name))" $null }
    } else {
        if ("$(Get-CommandOutput 'python3' @('--version'))" -match 'Python (\S+)') { Add-Runtime 'Python' $Matches[1] (Get-Command python3).Source }
        if ("$(Get-CommandOutput 'java' @('-version'))" -match 'version "([^"]+)"') { Add-Runtime 'Java' $Matches[1] (Get-Command java).Source }
    }
    $probes = @(
        @('Node.js', 'node', @('--version'), '^v?(\S+)'), @('PowerShell', 'pwsh', @('-NoLogo', '-NoProfile', '-Version'), 'PowerShell (\S+)'),
        @('Go', 'go', @('version'), 'go(\d\S*)'), @('Rust', 'rustc', @('--version'), 'rustc (\S+)'), @('PHP', 'php', @('--version'), '^PHP (\S+)'), @('Ruby', 'ruby', @('--version'), '^ruby (\S+)')
    )
    if ($IsWindows) {
        $probes += , @('Python', 'py', @('--version'), 'Python (\S+)')
        $probes += , @('Java', 'java', @('-version'), 'version "([^"]+)"')
    }
    foreach ($p in $probes) {
        if ($list | Where-Object Name -eq $p[0]) { continue }
        $out = Get-CommandOutput $p[1] $p[2]
        if ($out -match $p[3]) { Add-Runtime $p[0] $Matches[1] (Get-Command $p[1] -CommandType Application | Select-Object -First 1).Source }
    }
    $list.ToArray()
}

# Navigateurs : Name, Version, Default, Path.
function Get-Browsers {
    $list = [System.Collections.Generic.List[object]]::new()
    if ($IsWindows) {
        $progId = Get-RegValue 'HKCU:\SOFTWARE\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice' 'ProgId'
        $defaultName = switch -Regex ("$progId") { '^ChromeHTML' { 'Chrome' } '^MSEdge' { 'Edge' } '^Firefox' { 'Firefox' } '^Brave' { 'Brave' } '^Opera' { 'Opera' } '^Vivaldi' { 'Vivaldi' } '^LibreWolf' { 'LibreWolf' } default { "$progId" } }
        $seen = @{}
        foreach ($root in 'HKLM:\SOFTWARE\Clients\StartMenuInternet', 'HKLM:\SOFTWARE\WOW6432Node\Clients\StartMenuInternet', 'HKCU:\SOFTWARE\Clients\StartMenuInternet') {
            foreach ($k in Get-ChildItem $root -ErrorAction SilentlyContinue) {
                $name = (Get-RegValue $k.PSPath '(default)') ?? $k.PSChildName
                $cmd = Get-RegValue "$($k.PSPath)\shell\open\command" '(default)'
                $exe = if ("$cmd" -match '^\s*"([^"]+)"') { $Matches[1] } else { "$cmd".Trim() }
                if (-not $exe -or $seen[$exe]) { continue }
                $seen[$exe] = $true
                $version = try { (Get-Item -LiteralPath $exe -ErrorAction Stop).VersionInfo.ProductVersion } catch { $null }
                $list.Add([PSCustomObject]@{ Name = $name; Version = $version; Default = $defaultName -and $name -match [regex]::Escape($defaultName); Path = $exe })
            }
        }
        return $list.ToArray()
    }
    $default = "$(if (Get-Command xdg-settings -ErrorAction SilentlyContinue) { & xdg-settings get default-web-browser 2>$null })".Trim()
    $known = @(
        @('Firefox', 'firefox', 'firefox.desktop'), @('Firefox Developer Edition', 'firefox-developer-edition', 'firefox-developer-edition.desktop'),
        @('Google Chrome', 'google-chrome', 'google-chrome.desktop'), @('Chromium', 'chromium-browser', 'chromium-browser.desktop'), @('Chromium', 'chromium', 'chromium.desktop'),
        @('Brave', 'brave-browser', 'brave-browser.desktop'), @('Microsoft Edge', 'microsoft-edge', 'microsoft-edge.desktop'), @('Vivaldi', 'vivaldi', 'vivaldi-stable.desktop'),
        @('Opera', 'opera', 'opera.desktop'), @('LibreWolf', 'librewolf', 'librewolf.desktop'), @('Epiphany', 'epiphany', 'org.gnome.Epiphany.desktop')
    )
    foreach ($b in $known) {
        $cmd = Get-Command $b[1] -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $cmd -or ($list | Where-Object Path -eq $cmd.Source)) { continue }
        $version = if ("$(Get-CommandOutput $b[1] @('--version'))" -match '(\d+(\.\d+)+)') { $Matches[1] } else { $null }
        $list.Add([PSCustomObject]@{ Name = $b[0]; Version = $version; Default = $default -eq $b[2]; Path = $cmd.Source })
    }
    $flatpak = @{ 'org.mozilla.firefox' = 'Firefox'; 'com.google.Chrome' = 'Google Chrome'; 'org.chromium.Chromium' = 'Chromium'; 'com.brave.Browser' = 'Brave'; 'com.microsoft.Edge' = 'Microsoft Edge'; 'com.vivaldi.Vivaldi' = 'Vivaldi'; 'com.opera.Opera' = 'Opera'; 'io.gitlab.librewolf-community' = 'LibreWolf'; 'org.torproject.torbrowser-launcher' = 'Tor Browser'; 'app.zen_browser.zen' = 'Zen' }
    foreach ($a in Get-Cached 'flatpak' 600 { @(Get-FlatpakApps) }) {
        if ($flatpak[$a.Id]) { $list.Add([PSCustomObject]@{ Name = "$($flatpak[$a.Id]) (Flatpak)"; Version = $a.Version; Default = $default -eq "$($a.Id).desktop"; Path = $a.Id }) }
    }
    if ($default -and -not ($list | Where-Object Default)) {
        # Navigateur hors liste (Firefox Developer Edition installé par l'utilisateur…) : nom et commande de son .desktop.
        $file = foreach ($dir in (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.local/share/applications'), '/usr/share/applications', '/var/lib/flatpak/exports/share/applications') { $f = Join-Path $dir $default; if (Test-Path -LiteralPath $f) { $f; break } }
        $e = if ($file) { Read-DesktopEntry $file } else { @{} }
        $exe = ($e.Exec -split '\s+')[0] -replace '^"|"$', ''
        $version = if ($exe -and (Test-Path -LiteralPath $exe) -and "$(Get-CommandOutput $exe @('--version'))" -match '(\d+(\.\d+)+)') { $Matches[1] } else { $null }
        $list.Add([PSCustomObject]@{ Name = $e.Name ?? ($default -replace '\.desktop$', ''); Version = $version; Default = $true; Path = $exe ? $exe : $default })
    }
    $list.ToArray()
}

# Activation de Windows et d'Office (licences avec clé installée). La clé partielle n'est jamais lue.
function Get-Activation {
    $states = @{ 0 = 'Sans licence'; 1 = 'Activé'; 2 = 'Période de grâce initiale'; 3 = 'Période de grâce (changement matériel)'; 4 = 'Période de grâce (non authentique)'; 5 = 'Notification (non activé)'; 6 = 'Période de grâce étendue' }
    @(Get-CimInstance -ClassName SoftwareLicensingProduct -Filter 'PartialProductKey IS NOT NULL' -Property Name, Description, LicenseStatus, GracePeriodRemaining, ApplicationID -ErrorAction Stop) | ForEach-Object {
        [PSCustomObject]@{
            Product = $_.Name; Channel = if ($_.Description -match '(\w+(_\w+)?) channel') { $Matches[1] } else { $_.Description }
            State = $states[[int]$_.LicenseStatus] ?? "$($_.LicenseStatus)"; Licensed = [int]$_.LicenseStatus -eq 1
            Grace = if ([int]$_.GracePeriodRemaining -gt 0) { '{0} jour(s)' -f [int]($_.GracePeriodRemaining / 1440) } else { $null }
            Windows = $_.ApplicationID -eq '55c92734-d682-4d71-983e-d6ec3f16059f'
        }
    }
}

#endregion

#region Fin de support

# Logiciels en fin de support : expression sur « Nom Version », libellé, date de fin, gravité une fois passée.
# Base au 2026-10-23, à tenir à jour (sources : endoflife.date, cycles de vie Microsoft).
$script:EolRules = @(
    @('^Python 2\.', 'Python 2.7', '2020-01-01', 'warning'), @('^Python 3\.7\.', 'Python 3.7', '2023-06-27', 'warning'), @('^Python 3\.8\.', 'Python 3.8', '2024-10-07', 'warning'),
    @('^Python 3\.9\.', 'Python 3.9', '2025-10-31', 'warning'), @('^Python 3\.10\.', 'Python 3.10', '2026-10-31', 'warning'),
    @('^Node\.?js (v)?14\.', 'Node.js 14', '2023-04-30', 'warning'), @('^Node\.?js (v)?16\.', 'Node.js 16', '2023-09-11', 'warning'), @('^Node\.?js (v)?18\.', 'Node.js 18', '2025-04-30', 'warning'), @('^Node\.?js (v)?20\.', 'Node.js 20', '2026-04-30', 'warning'),
    @('(?i)(\.NET|NETCore|AspNetCore|WindowsDesktop|Desktop Runtime)\b[^0-9]*\b3\.1\.\d', '.NET Core 3.1', '2022-12-13', 'warning'),
    @('(?i)(\.NET|NETCore|AspNetCore|WindowsDesktop|Desktop Runtime)\b[^0-9]*\b5\.0\.\d', '.NET 5', '2022-05-10', 'warning'),
    @('(?i)(\.NET|NETCore|AspNetCore|WindowsDesktop|Desktop Runtime)\b[^0-9]*\b6\.0\.\d', '.NET 6', '2024-11-12', 'warning'),
    @('(?i)(\.NET|NETCore|AspNetCore|WindowsDesktop|Desktop Runtime)\b[^0-9]*\b7\.0\.\d', '.NET 7', '2024-05-14', 'warning'),
    @('(?i)(\.NET|NETCore|AspNetCore|WindowsDesktop|Desktop Runtime)\b[^0-9]*\b8\.0\.\d', '.NET 8', '2026-11-10', 'warning'),
    @('(?i)(\.NET|NETCore|AspNetCore|WindowsDesktop|Desktop Runtime)\b[^0-9]*\b9\.0\.\d', '.NET 9', '2026-11-10', 'warning'),
    @('^PowerShell 7\.2\.', 'PowerShell 7.2', '2024-11-08', 'warning'), @('^PowerShell 7\.3\.', 'PowerShell 7.3', '2024-05-08', 'warning'), @('^PowerShell 7\.4\.', 'PowerShell 7.4', '2026-11-10', 'warning'),
    @('^PHP (5|7)\.', 'PHP 7 et antérieurs', '2022-11-28', 'warning'), @('^PHP 8\.0\.', 'PHP 8.0', '2023-11-26', 'warning'), @('^PHP 8\.1\.', 'PHP 8.1', '2025-12-31', 'warning'),
    @('^Java (1\.)?6\b|^Java 6 Update', 'Java 6', '2018-12-31', 'warning'), @('^Java (1\.)?7\b|^Java 7 Update', 'Java 7', '2022-07-19', 'warning'),
    @('(?i)Microsoft (Office|Visio|Project)\b.*\b2013\b', 'Office 2013', '2023-04-11', 'warning'),
    @('(?i)Microsoft (Office|Visio|Project)\b.*\b2016\b', 'Office 2016', '2025-10-14', 'warning'),
    @('(?i)Microsoft (Office|Visio|Project)\b.*\b2019\b', 'Office 2019', '2025-10-14', 'warning'),
    @('(?i)Microsoft (Office|Visio|Project)\b.*\b2021\b', 'Office 2021', '2026-10-13', 'warning'),
    @('(?i)Adobe Flash Player', 'Adobe Flash Player', '2020-12-31', 'critical'), @('(?i)Microsoft Silverlight', 'Microsoft Silverlight', '2021-10-12', 'warning'),
    @('(?i)Adobe Reader XI|Adobe Acrobat XI', 'Adobe Reader / Acrobat XI', '2017-10-15', 'warning'), @('(?i)Adobe Acrobat (Reader )?(DC )?2017', 'Adobe Acrobat 2017', '2022-06-06', 'warning'),
    @('(?i)Visual C\+\+ 2005\b', 'Visual C++ 2005', '2016-04-12', 'info'), @('(?i)Visual C\+\+ 2008\b', 'Visual C++ 2008', '2018-04-10', 'info'),
    @('(?i)Visual C\+\+ 2010\b', 'Visual C++ 2010', '2020-07-14', 'info'), @('(?i)Visual C\+\+ 2012\b', 'Visual C++ 2012', '2023-01-10', 'info'), @('(?i)Visual C\+\+ 2013\b', 'Visual C++ 2013', '2024-04-09', 'info')
)

# Correspondances : Label, End (date), Severity, Past (déjà en fin de support), Matches (logiciels concernés).
function Get-EolMatches($Software, [int]$SoonDays = 60) {
    $today = (Get-Date).Date
    foreach ($r in $script:EolRules) {
        $end = [datetime]$r[2]
        if ($end -gt $today.AddDays($SoonDays)) { continue }
        $hits = @($Software | Where-Object { ('{0} {1}' -f $_.Name, $_.Version) -match $r[0] -or $_.Name -match $r[0] })
        if ($hits.Count -eq 0) { continue }
        [PSCustomObject]@{ Label = $r[1]; End = $end; Severity = $r[3]; Past = $end -le $today; Matches = @($hits | ForEach-Object { if ($_.Version -and $_.Name -notmatch [regex]::Escape($_.Version)) { "$($_.Name) $($_.Version)" } else { $_.Name } } | Select-Object -Unique) }
    }
}

#endregion

function Get-ModuleData {
    $sections = [System.Collections.Generic.List[object]]::new()
    $findings = [System.Collections.Generic.List[object]]::new()
    $errors = [ordered]@{}
    function Invoke-Block([string]$Name, [scriptblock]$Block) {
        try { & $Block } catch { $errors[$Name] = $_.Exception.Message; $null }
    }
    function Add-Finding([string]$Severity, [string]$Code, [string]$Message, [string]$Recommendation) {
        $findings.Add((New-Finding $Severity $Code $Message $Recommendation))
    }
    $summary = [ordered]@{}

    $apps = @(Invoke-Block 'Applications' { Get-Applications } | Where-Object { $_ })
    foreach ($g in $apps | Group-Object Source | Sort-Object Count -Descending) { $summary["Applications · $($g.Name)"] = $g.Count }
    if ($IsLinux) {
        $packages = @(Get-Packages)
        if ($packages) { $summary['Paquets de la distribution'] = $packages.Count }
    }

    # Mises à jour
    $reboot = Invoke-Block 'Redémarrage' { Get-Cached 'reboot' 300 { Get-RebootRequired } }
    if ($IsWindows) {
        $wu = Invoke-Block 'Windows Update' { Get-Cached 'wu' 600 { Get-WindowsUpdateStatus } }
        if ($wu) {
            $summary['Windows Update · dernière recherche'] = Format-Date $wu.LastSearch
            $summary['Windows Update · dernière installation'] = Format-Date $wu.LastInstall
            if ($wu.LastInstall -and $wu.LastInstall -lt (Get-Date).AddDays(-35)) {
                Add-Finding 'warning' 'SW-UPDATES-OLD' ('Aucune mise à jour Windows installée depuis le {0}' -f (Format-Day $wu.LastInstall)) 'Ouvrir Paramètres › Windows Update et lancer la recherche ; si elle échoue, voir l''historique (software_get_update_history) et les événements.'
            }
            if ($wu.LastSearch -and $wu.LastSearch -lt (Get-Date).AddDays(-14)) {
                Add-Finding 'warning' 'SW-UPDATE-SEARCH-OLD' ('Windows Update n''a pas recherché de mises à jour depuis le {0}' -f (Format-Day $wu.LastSearch)) 'Vérifier le service Windows Update (wuauserv) et la connexion ; lancer une recherche manuelle.'
            }
        }
    } else {
        $pending = Invoke-Block 'Mises à jour' { Get-Cached 'pending' 1800 { Get-LinuxPendingUpdates $false } }
        if ($pending) {
            $security = @($pending.Updates | Where-Object Security)
            $summary['Mises à jour en attente'] = '{0}{1}' -f $pending.Updates.Count, $(if ($security) { " dont $($security.Count) de sécurité" } else { '' })
            if ($pending.Updates.Count -gt 0) {
                $rows = foreach ($u in $pending.Updates | Sort-Object { -not $_.Security }, Name | Select-Object -First 200) { , @($u.Name, $u.Installed, $u.Available, $u.Source, $(if ($u.Security) { 'Oui' } else { '' })) }
                $title = 'Mises à jour en attente' + $(if ($pending.Notes) { " ($($pending.Notes -join ' · '))" } else { '' })
                $sections.Add([PSCustomObject]@{ Title = $title; Type = 'Table'; Icon = 'arrow_download'; Columns = @('Logiciel', 'Installé', 'Disponible', 'Source', 'Sécurité'); Rows = @($rows) })
                Add-Finding $(if ($security) { 'warning' } else { 'info' }) 'SW-UPDATES-PENDING' ('{0} mise(s) à jour en attente{1}' -f $pending.Updates.Count, $(if ($security) { " dont $($security.Count) de sécurité" } else { '' })) `
                    $(if (Get-Command dnf -ErrorAction SilentlyContinue) { 'sudo dnf upgrade (et flatpak update), ou la logithèque.' } elseif (Get-Command apt -ErrorAction SilentlyContinue) { 'sudo apt update && sudo apt upgrade' } else { 'Mettre le système à jour avec le gestionnaire de paquets.' })
            }
        }
    }
    $summary['Redémarrage requis'] = if ($reboot) { "Oui ($reboot)" } else { 'Non' }
    if ($reboot) { Add-Finding 'warning' 'SW-REBOOT-PENDING' "Redémarrage requis pour terminer une mise à jour : $reboot" 'Redémarrer pour appliquer les correctifs (le noyau ou les composants mis à jour ne sont actifs qu''après).' }

    # Historique récent
    $history = @(Invoke-Block 'Historique' { Get-Cached 'history' 600 { Get-UpdateHistoryEntries 365 200 } } | Where-Object { $_ })
    if ($history.Count -gt 0) {
        $last = $history | Where-Object { -not $_.Failed } | Sort-Object Date -Descending | Select-Object -First 1
        if ($IsLinux -and $last) {
            $summary['Dernière mise à jour'] = Format-Date $last.Date
            if ($last.Date -lt (Get-Date).AddDays(-30)) { Add-Finding 'warning' 'SW-UPDATES-OLD' ('Aucune installation ni mise à jour de paquet depuis le {0}' -f (Format-Day $last.Date)) 'Mettre le système à jour : les correctifs de sécurité sortent chaque semaine.' }
        }
        $rows = foreach ($h in $history | Select-Object -First 15) { , @((Format-Date $h.Date), $h.Title, $h.Kind, $h.Result) }
        $sections.Add([PSCustomObject]@{ Title = 'Dernières mises à jour'; Type = 'Table'; Icon = 'arrow_clockwise'; Columns = @('Date', $(if ($IsWindows) { 'Mise à jour' } else { 'Commande' }), $(if ($IsWindows) { 'Opération' } else { 'Changements' }), 'Résultat'); Rows = @($rows) })
    }

    # Démarrage
    $startup = @(Invoke-Block 'Démarrage' { Get-Cached 'startup' 300 { Get-StartupItems } } | Where-Object { $_ })
    if ($startup.Count -gt 0) {
        $summary['Programmes au démarrage'] = '{0} actif(s) sur {1}' -f @($startup | Where-Object Enabled).Count, $startup.Count
        $rows = foreach ($s in $startup | Sort-Object { -not $_.Enabled }, Name) { , @($s.Name, $(if ($s.Enabled) { 'Activé' } else { 'Désactivé' }), $s.Scope, $s.Command, $s.Location) }
        $sections.Add([PSCustomObject]@{ Title = 'Programmes au démarrage'; Type = 'Table'; Icon = 'play'; Columns = @('Nom', 'État', 'Portée', 'Commande', 'Emplacement'); Rows = @($rows) })
        foreach ($s in $startup | Where-Object { $_.Enabled -and $_.Missing } | Select-Object -First 10) {
            Add-Finding 'info' 'SW-STARTUP-MISSING' "Élément de démarrage « $($s.Name) » : programme introuvable ($($s.Command))" 'Reste d''un logiciel désinstallé : supprimer l''entrée.'
        }
    }

    # Runtimes
    $programs = if ($IsWindows) { @($apps | Where-Object Source -eq 'Programme') } else { @() }
    $runtimes = @(Invoke-Block 'Runtimes' { Get-Cached 'runtimes' 600 { Get-Runtimes $programs } } | Where-Object { $_ })
    if ($runtimes.Count -gt 0) {
        $rows = foreach ($r in $runtimes | Sort-Object Name, Version) { , @($r.Name, $r.Version, $r.Path) }
        $sections.Add([PSCustomObject]@{ Title = 'Runtimes'; Type = 'Table'; Icon = 'developer_board'; Columns = @('Runtime', 'Version', 'Emplacement'); Rows = @($rows) })
    }

    # Navigateurs
    $browsers = @(Invoke-Block 'Navigateurs' { Get-Cached 'browsers' 3600 { Get-Browsers } } | Where-Object { $_ })
    if ($browsers.Count -gt 0) {
        $summary['Navigateur par défaut'] = (($browsers | Where-Object Default | Select-Object -First 1).Name) ?? 'inconnu'
        $rows = foreach ($b in $browsers | Sort-Object { -not $_.Default }, Name) { , @($b.Name, $b.Version, $(if ($b.Default) { 'Oui' } else { '' }), $b.Path) }
        $sections.Add([PSCustomObject]@{ Title = 'Navigateurs'; Type = 'Table'; Icon = 'globe'; Columns = @('Navigateur', 'Version', 'Par défaut', 'Programme'); Rows = @($rows) })
    }

    # Activation (Windows)
    if ($IsWindows) {
        $licenses = @(Invoke-Block 'Activation' { Get-Cached 'activation' 3600 { Get-Activation } } | Where-Object { $_ })
        if ($licenses.Count -gt 0) {
            $win = $licenses | Where-Object Windows | Select-Object -First 1
            $summary['Activation de Windows'] = if ($win) { $win.State } else { 'inconnue' }
            $rows = foreach ($l in $licenses) { , @($l.Product, $l.Channel, $l.State, $l.Grace) }
            $sections.Add([PSCustomObject]@{ Title = 'Activation'; Type = 'Table'; Icon = 'checkmark_circle'; Columns = @('Produit', 'Canal', 'État', 'Grâce restante'); Rows = @($rows) })
            foreach ($l in $licenses | Where-Object { -not $_.Licensed }) {
                Add-Finding $(if ($l.Windows) { 'warning' } else { 'info' }) 'SW-NOT-ACTIVATED' ('{0} : {1}' -f $l.Product, $l.State.ToLower()) $(if ($l.Windows) { 'Activer Windows (Paramètres › Système › Activation) ; une copie non activée perd la personnalisation et peut cacher une licence non authentique.' } else { 'Activer le produit ou désinstaller la licence inutilisée.' })
            }
        }
    }

    # Fin de support (applications Windows et runtimes ; sous Linux la distribution suit ses paquets)
    $eolScope = @($runtimes | ForEach-Object { [PSCustomObject]@{ Name = $_.Name -replace '^Microsoft\.', '' -replace '^NETCore\.App$', '.NET Runtime'; Version = ($_.Version -split ' ')[0] } }) + $programs
    $eol = @(Get-EolMatches $eolScope)
    if ($eol.Count -gt 0) {
        $rows = foreach ($e in $eol | Sort-Object End) { , @($e.Label, (Format-Day $e.End), $(if ($e.Past) { 'Terminé' } else { 'Bientôt' }), ($e.Matches -join ' ; ')) }
        $sections.Add([PSCustomObject]@{ Title = 'Fin de support'; Type = 'Table'; Icon = 'warning'; Columns = @('Logiciel', 'Fin de support', 'État', 'Installé'); Rows = @($rows) })
        foreach ($e in $eol) {
            if ($e.Past) { Add-Finding $e.Severity 'SW-EOL' ('{0} n''est plus maintenu depuis le {1} : {2}' -f $e.Label, (Format-Day $e.End), ($e.Matches -join ', ')) 'Passer à une version maintenue, ou le désinstaller s''il ne sert plus : il ne reçoit plus de correctifs de sécurité.' }
            else { Add-Finding 'info' 'SW-EOL-SOON' ('{0} arrive en fin de support le {1} : {2}' -f $e.Label, (Format-Day $e.End), ($e.Matches -join ', ')) 'Prévoir la migration vers une version maintenue.' }
        }
    }

    # Applications installées
    if ($apps.Count -gt 0) {
        $rows = foreach ($a in $apps | Sort-Object Name) { , @($a.Name, $a.Version, $a.Publisher, $a.Source, (Format-Day $a.Date), $a.SizeMiB) }
        $sections.Add([PSCustomObject]@{ Title = 'Applications installées'; Type = 'Table'; Icon = 'apps_list'; Columns = @('Nom', 'Version', 'Éditeur / dépôt', 'Source', 'Installé le', 'Taille (MiB)'); Rows = @($rows) })
    }

    $sections.Insert(0, [PSCustomObject]@{ Title = 'Résumé'; Type = 'KeyValue'; Icon = 'apps_list'; Items = $summary })
    if ($errors.Count -gt 0) {
        $sections.Add([PSCustomObject]@{ Title = 'Erreurs du module'; Type = 'KeyValue'; Icon = 'error_circle'; Items = $errors })
    }
    $subtitle = '{0} applications{1}{2}' -f $apps.Count, $(if ($summary.Contains('Mises à jour en attente')) { " · $($summary['Mises à jour en attente']) mise(s) à jour en attente" } else { '' }), $(if ($reboot) { ' · redémarrage requis' } else { '' })
    [PSCustomObject]@{ Subtitle = $subtitle; Sections = $sections.ToArray(); Findings = $findings.ToArray() }
}

#region Fonctions ciblées (module.json › functions)

# software_list : logiciels installés, filtrés et triés.
function Get-SISoftware {
    param(
        [ValidateSet('applications', 'store', 'packages', 'flatpak', 'snap', 'all')][string]$Source = 'applications',
        [string]$Filter,
        [ValidateSet('name', 'date', 'size')][string]$SortBy = 'name',
        [ValidateRange(1, 5000)][int]$Top = 200
    )
    $list = switch ($Source) {
        'applications' { if ($IsWindows) { Get-Cached 'programs' 600 { @(Get-WindowsPrograms) } } else { Get-Applications } }
        'store' { if ($IsWindows) { Get-Cached 'store' 600 { @(Get-StoreApps) } } else { throw 'Le Microsoft Store n''existe que sous Windows.' } }
        'packages' { if ($IsWindows) { Get-Cached 'programs' 600 { @(Get-WindowsPrograms) } } else { Get-Packages } }
        'flatpak' { if ($IsLinux) { Get-Cached 'flatpak' 600 { @(Get-FlatpakApps) } } else { throw 'Flatpak n''existe que sous Linux.' } }
        'snap' { if ($IsLinux) { Get-Cached 'snap' 600 { @(Get-SnapApps) } } else { throw 'Snap n''existe que sous Linux.' } }
        'all' {
            if ($IsWindows) { @(Get-Cached 'programs' 600 { @(Get-WindowsPrograms) }) + @(Get-Cached 'store' 600 { @(Get-StoreApps) }) }
            else { @(Get-Packages) + @(Get-Cached 'flatpak' 600 { @(Get-FlatpakApps) }) + @(Get-Cached 'snap' 600 { @(Get-SnapApps) }) }
        }
    }
    $list = @($list | Where-Object { $_ -and (-not $Filter -or $_.Name -like "*$Filter*" -or $_.Publisher -like "*$Filter*" -or $_.Description -like "*$Filter*" -or $_.Id -like "*$Filter*") })
    $sorted = switch ($SortBy) {
        'date' { $list | Sort-Object { $_.Date ?? [datetime]::MinValue } -Descending }
        'size' { $list | Sort-Object { $_.SizeMiB ?? -1 } -Descending }
        default { $list | Sort-Object Name }
    }
    $rows = foreach ($a in $sorted | Select-Object -First $Top) { , @($a.Name, $a.Version, $a.Publisher, $a.Source, $a.Scope, (Format-Day $a.Date), $a.SizeMiB, $a.Description) }
    [PSCustomObject]@{
        Subtitle = '{0} logiciel(s) · source {1}{2}{3}' -f $list.Count, $Source, $(if ($Filter) { " · « $Filter »" } else { '' }), $(if ($list.Count -gt $Top) { " · $Top premiers" } else { '' })
        Sections = @([PSCustomObject]@{ Title = 'Logiciels'; Type = 'Table'; Icon = 'apps_list'; Columns = @('Nom', 'Version', 'Éditeur / dépôt', 'Source', 'Portée', 'Installé le', 'Taille (MiB)', 'Description'); Rows = @($rows) })
        Findings = @()
    }
}

# software_get_pending_updates : recherche des mises à jour disponibles.
function Get-SIPendingUpdates {
    param([bool]$Refresh = $false)
    $findings = [System.Collections.Generic.List[object]]::new()
    $notes = @()
    if ($IsWindows) {
        $list = [System.Collections.Generic.List[object]]::new()
        $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
        $result = $searcher.Search("IsInstalled=0 and IsHidden=0")
        foreach ($u in $result.Updates) {
            $categories = @($u.Categories | ForEach-Object { $_.Name })
            $list.Add([PSCustomObject]@{
                    Name = $u.Title; Installed = $null; Available = if ($u.Title -match '\b(KB\d+)\b') { $Matches[1] } else { $null }
                    Source = 'Windows Update · ' + (($categories | Select-Object -First 2) -join ', ')
                    Security = [bool]($categories -match 'Security|Sécurité|Critical|critique') -or ("$($u.MsrcSeverity)" -in 'Critical', 'Important')
                })
        }
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            # winget upgrade : tableau en texte, colonnes repérées par la ligne de tirets (libellés traduits).
            $out = @(& winget upgrade --accept-source-agreements --disable-interactivity 2>$null | ForEach-Object { "$_" -replace '^.*\r', '' })
            $dash = [Array]::FindIndex([string[]]$out, [Predicate[string]] { param($l) $l -match '^-{10,}' })
            if ($dash -gt 0) {
                $header = $out[$dash - 1]
                $starts = @([regex]::Matches($header, '(?<=^|\s)\S') | ForEach-Object Index)
                foreach ($line in $out | Select-Object -Skip ($dash + 1)) {
                    if ($line.Length -lt $starts[-1] -or $line -match '^\d+ (mises|upgrades|package)') { continue }
                    $cols = for ($i = 0; $i -lt $starts.Count; $i++) {
                        $end = if ($i + 1 -lt $starts.Count) { $starts[$i + 1] } else { $line.Length }
                        if ($starts[$i] -lt $line.Length) { $line.Substring($starts[$i], [Math]::Min($end, $line.Length) - $starts[$i]).Trim() } else { '' }
                    }
                    if ($cols.Count -ge 4) { $list.Add([PSCustomObject]@{ Name = $cols[0]; Installed = $cols[2]; Available = $cols[3]; Source = 'winget · ' + $cols[-1]; Security = $false }) }
                }
            }
        } else { $notes += 'winget absent : mises à jour des applications non vérifiées' }
        $updates = $list.ToArray()
    } else {
        Write-Progress -Activity 'Mises à jour' -Status $(if ($Refresh) { 'Actualisation des dépôts et recherche…' } else { 'Recherche dans le cache des dépôts…' })
        $pending = Get-LinuxPendingUpdates $Refresh
        $updates = $pending.Updates; $notes += $pending.Notes
        $script:Cache.Remove('pending')
    }
    $security = @($updates | Where-Object Security)
    $rows = foreach ($u in $updates | Sort-Object { -not $_.Security }, Name) { , @($u.Name, $u.Installed, $u.Available, $u.Source, $(if ($u.Security) { 'Oui' } else { '' })) }
    if ($updates.Count -gt 0) {
        $findings.Add((New-Finding $(if ($security) { 'warning' } else { 'info' }) 'SW-UPDATES-PENDING' ('{0} mise(s) à jour en attente{1}' -f $updates.Count, $(if ($security) { " dont $($security.Count) de sécurité" } else { '' })) 'Installer les mises à jour, en priorité celles de sécurité.'))
    }
    if ($IsWindows -and $notes) { $findings.Add((New-Finding 'info' 'SW-UPDATES-PARTIAL' ($notes -join ' · ') 'Installer winget (App Installer, Microsoft Store) pour vérifier aussi les applications.')) }
    [PSCustomObject]@{
        Subtitle = '{0} mise(s) à jour en attente{1}{2}' -f $updates.Count, $(if ($security) { " dont $($security.Count) de sécurité" } else { '' }), $(if ($notes -and -not $IsWindows) { ' · ' + ($notes -join ' · ') } else { '' })
        Sections = @([PSCustomObject]@{ Title = 'Mises à jour en attente'; Type = 'Table'; Icon = 'arrow_download'; Columns = @('Logiciel', 'Installé', 'Disponible', 'Source', 'Sécurité'); Rows = @($rows) })
        Findings = $findings.ToArray()
    }
}

# software_get_update_history : historique des mises à jour et installations.
function Get-SIUpdateHistory {
    param(
        [ValidateRange(1, 730)][int]$Days = 90,
        [ValidateRange(1, 1000)][int]$Top = 100,
        [ValidateRange(0, 20)][int]$Details = 3
    )
    $sections = [System.Collections.Generic.List[object]]::new()
    $findings = [System.Collections.Generic.List[object]]::new()
    $history = @(Get-UpdateHistoryEntries $Days $Top)
    $rows = foreach ($h in $history) { , @((Format-Date $h.Date), $h.Title, $h.Kind, $h.Result, $h.Id, $h.Detail) }
    $sections.Add([PSCustomObject]@{ Title = $(if ($IsWindows) { 'Windows Update' } else { 'Transactions' }); Type = 'Table'; Icon = 'arrow_clockwise'; Columns = @('Date', $(if ($IsWindows) { 'Mise à jour' } else { 'Commande' }), $(if ($IsWindows) { 'Opération' } else { 'Changements' }), 'Résultat', $(if ($IsWindows) { 'KB' } else { 'N°' }), 'Code'); Rows = @($rows) })
    $failed = @($history | Where-Object Failed)
    foreach ($g in $failed | Group-Object { $_.Id ?? $_.Title } | Select-Object -First 10) {
        $findings.Add((New-Finding 'warning' 'SW-UPDATE-FAILED' ('{0} : {1} échec(s), le dernier le {2}{3}' -f $g.Name, $g.Count, (Format-Date ($g.Group | Sort-Object Date -Descending)[0].Date), $(if ($g.Group[0].Detail) { " (code $($g.Group[0].Detail))" } else { '' })) 'Rechercher le code d''erreur ; relancer la mise à jour après un redémarrage, ou l''outil de résolution des problèmes de Windows Update.'))
    }
    if ($IsWindows) {
        $hotfixes = @(Get-HotFix -ErrorAction SilentlyContinue | Where-Object { $_.InstalledOn -and $_.InstalledOn -ge (Get-Date).AddDays(-$Days) } | Sort-Object InstalledOn -Descending | Select-Object -First $Top)
        $hrows = foreach ($h in $hotfixes) { , @($h.HotFixID, $h.Description, (Format-Day $h.InstalledOn), $h.InstalledBy) }
        $sections.Add([PSCustomObject]@{ Title = 'Correctifs installés (Get-HotFix)'; Type = 'Table'; Icon = 'checkmark_circle'; Columns = @('KB', 'Type', 'Installé le', 'Par'); Rows = @($hrows) })
    } elseif ($Details -gt 0 -and (Get-Command dnf -ErrorAction SilentlyContinue)) {
        $actions = @{ Install = 'Installé'; Upgrade = 'Mis à jour'; Upgraded = 'Remplacé'; Remove = 'Supprimé'; Downgrade = 'Rétrogradé'; Reinstall = 'Réinstallé'; Replaced = 'Remplacé'; Reason = 'Raison changée' }
        $prows = [System.Collections.Generic.List[object]]::new()
        foreach ($h in $history | Select-Object -First $Details) {
            foreach ($line in & dnf history info $h.Id 2>$null) {
                if ($line -match '^\s+(Install|Upgrade|Remove|Downgrade|Reinstall|Replaced|Upgraded|Reason Change)\s+(\S+)\s+(.*?)\s{2,}(\S+)\s*$') {
                    if ($Matches[1] -in 'Replaced', 'Upgraded') { continue }
                    $prows.Add(@($h.Id, (Format-Date $h.Date), ($actions[$Matches[1]] ?? $Matches[1]), $Matches[2], $Matches[4]))
                }
            }
        }
        $sections.Add([PSCustomObject]@{ Title = "Paquets modifiés (dernières transactions : $Details)"; Type = 'Table'; Icon = 'apps_list'; Columns = @('N°', 'Date', 'Action', 'Paquet', 'Dépôt'); Rows = $prows.ToArray() })
    }
    [PSCustomObject]@{
        Subtitle = '{0} opération(s) sur {1} jours{2}' -f $history.Count, $Days, $(if ($failed) { " · $($failed.Count) échec(s)" } else { '' })
        Sections = $sections.ToArray(); Findings = $findings.ToArray()
    }
}

#endregion

#region Actions (niveau A : aperçu -DryRun, confirmation dans SysInfo, journal d'audit)

# Résultat d'une action : Changes = ce qui a changé (ou changerait) ; Blocked = pourquoi elle est impossible.
function New-ActionResult([string]$Subtitle, [object[]]$Sections, [object[]]$Findings, [object[]]$Changes, [string]$Blocked) {
    [PSCustomObject]@{
        Subtitle = $Subtitle
        Sections = @($Sections | Where-Object { $_ })
        Findings = @($Findings | Where-Object { $_ })
        Changes  = @($Changes | Where-Object { $_ })
        Blocked  = $Blocked
    }
}

# Éléments de démarrage modifiables qui portent ce nom (insensible à la casse) : Name, Kind, Enabled, Scope, Location,
# Command, plus de quoi agir (Windows : ruche, clé StartupApproved et nom de valeur ; Linux : fichier .desktop
# système et utilisateur, ou unité systemd --user, y compris désactivée).
function Find-StartupEntries([string]$Name) {
    $found = [System.Collections.Generic.List[object]]::new()
    if ($IsWindows) {
        $approvedRoot = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
        function Get-Approved([string]$Hive, [string]$Sub, [string]$Value) {
            $v = Get-RegValue "$Hive\$approvedRoot\$Sub" $Value
            -not ($v -is [byte[]] -and $v.Count -gt 0 -and ($v[0] % 2) -ne 0)
        }
        foreach ($k in @(@('HKCU:', 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'Run', 'Utilisateur'), @('HKLM:', 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'Run', 'Tous les utilisateurs'), @('HKLM:', 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run', 'Run32', 'Tous les utilisateurs'))) {
            $item = Get-Item -LiteralPath "$($k[0])\$($k[1])" -ErrorAction SilentlyContinue
            foreach ($value in @($item.GetValueNames()) | Where-Object { $_ -and $_ -eq $Name }) {
                $found.Add([PSCustomObject]@{ Name = $value; Kind = 'run'; Hive = $k[0]; Approved = "$($k[0])\$approvedRoot\$($k[2])"; Value = $value; Scope = $k[3]; Location = "$($k[0])\…\$(Split-Path $k[1] -Leaf)"; Command = "$($item.GetValue($value))"; Enabled = Get-Approved $k[0] $k[2] $value })
            }
        }
        foreach ($f in @(@([Environment]::GetFolderPath('Startup'), 'HKCU:', 'Utilisateur'), @([Environment]::GetFolderPath('CommonStartup'), 'HKLM:', 'Tous les utilisateurs'))) {
            foreach ($file in Get-ChildItem -LiteralPath $f[0] -File -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -eq $Name -or $_.Name -eq $Name }) {
                $found.Add([PSCustomObject]@{ Name = $file.BaseName; Kind = 'folder'; Hive = $f[1]; Approved = "$($f[1])\$approvedRoot\StartupFolder"; Value = $file.Name; Scope = $f[2]; Location = 'Dossier Démarrage'; Command = $file.FullName; Enabled = Get-Approved $f[1] 'StartupFolder' $file.Name })
            }
        }
        return $found.ToArray()
    }

    $userDir = Join-Path $HOME '.config/autostart'
    $files = [ordered]@{}
    foreach ($dir in '/etc/xdg/autostart', $userDir) {
        foreach ($f in Get-ChildItem $dir -Filter *.desktop -File -ErrorAction SilentlyContinue) { $files[$f.Name] = $f }
    }
    foreach ($f in $files.Values) {
        $e = Read-DesktopEntry $f.FullName
        if ($Name -notin $e.Name, $f.BaseName, $f.Name) { continue }
        $found.Add([PSCustomObject]@{
                Name = $e.Name ?? $f.BaseName; Kind = 'xdg'; UserFile = Join-Path $userDir $f.Name
                SystemFile = if (Test-Path -LiteralPath "/etc/xdg/autostart/$($f.Name)") { "/etc/xdg/autostart/$($f.Name)" } else { $null }
                Scope = if ($f.DirectoryName -eq $userDir) { 'Utilisateur' } else { 'Tous les utilisateurs' }; Location = $f.FullName; Command = $e.Exec
                Enabled = $e.Hidden -ne 'true' -and $e.'X-GNOME-Autostart-enabled' -ne 'false' -and $e.'X-KDE-autostart-enabled' -ne 'false'
            })
    }
    $unit = if ($Name -match '\.(service|timer)$') { $Name } else { "$Name.service" }
    $state = (& systemctl --user is-enabled -- $unit 2>$null | Select-Object -First 1)
    if ($state -in 'enabled', 'disabled') {
        $found.Add([PSCustomObject]@{ Name = $unit; Kind = 'unit'; Scope = 'Utilisateur'; Location = 'systemctl --user'; Command = $null; Enabled = $state -eq 'enabled' })
    }
    $found.ToArray()
}

# Fichier .desktop : fixe une clé de la section [Desktop Entry] (ajoutée si absente).
function Set-DesktopKey([string[]]$Lines, [string]$Key, [string]$Value) {
    $out = [System.Collections.Generic.List[string]]::new(); $inMain = $false; $done = $false
    foreach ($line in $Lines) {
        if ($line -match '^\[(.+)\]') {
            if ($inMain -and -not $done) { $out.Add("$Key=$Value"); $done = $true }
            $inMain = $Matches[1] -eq 'Desktop Entry'
        }
        elseif ($inMain -and $line -match "^$([regex]::Escape($Key))\s*=") { if (-not $done) { $out.Add("$Key=$Value"); $done = $true }; continue }
        $out.Add($line)
    }
    if (-not $done) { $out.Add("$Key=$Value") }
    $out.ToArray()
}

# software_set_startup : active ou désactive un programme lancé à l'ouverture de session, sans le désinstaller ni le
# supprimer du démarrage (réversible par la même action).
# Windows : valeur StartupApproved (comme le Gestionnaire des tâches) ; HKLM : administrateur.
# Linux   : autostart XDG, copie utilisateur avec Hidden=true / false (le fichier système n'est jamais modifié) ;
#           unité systemd --user : systemctl --user enable / disable.
function Set-SIStartupItem {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Enabled,
        [switch]$DryRun
    )

    $entries = @(Find-StartupEntries $Name)
    $state = if ($Enabled) { 'Activé' } else { 'Désactivé' }
    if ($entries.Count -eq 0) {
        $known = (@(Get-StartupItems) | ForEach-Object Name | Select-Object -First 15) -join ', '
        return New-ActionResult "Démarrage : $Name" @() @() @() "Aucun élément de démarrage « $Name » (éléments : $known)."
    }
    if ($entries.Count -gt 1) {
        # Linux : une entrée XDG et une unité du même nom ; Windows : même nom dans plusieurs clés.
        return New-ActionResult "Démarrage : $Name" @() @() @() "Plusieurs éléments s'appellent « $Name » ($((@($entries | ForEach-Object { "$($_.Location)" })) -join ' ; ')) : préciser le nom du fichier ou de l'unité."
    }
    $e = $entries[0]
    $before = if ($e.Enabled) { 'Activé' } else { 'Désactivé' }
    $blocked = $null
    if ($e.Enabled -eq $Enabled) { $blocked = "« $($e.Name) » est déjà $($state.ToLower()) au démarrage." }
    elseif ($IsWindows -and $e.Hive -eq 'HKLM:' -and -not [Environment]::IsPrivilegedProcess) { $blocked = "« $($e.Name) » démarre pour tous les utilisateurs : relancer SysInfo en administrateur pour le modifier." }

    $section = [PSCustomObject]@{
        Title = 'Élément de démarrage'; Type = 'KeyValue'; Icon = 'play'
        Items = [ordered]@{ Nom = $e.Name; Emplacement = $e.Location; Portée = $e.Scope; Commande = $e.Command ?? '—'; État = $before }
    }
    $findings = @([PSCustomObject]@{ Severity = 'info'; Code = 'SW-STARTUP-NEXT-LOGON'; Message = "Pris en compte à la prochaine ouverture de session ; le programme $(if ($Enabled) { 'n''est pas lancé' } else { 'n''est pas arrêté' }) maintenant." })
    if ($IsLinux -and $e.Kind -eq 'xdg' -and $e.Scope -eq 'Tous les utilisateurs') {
        $findings += [PSCustomObject]@{ Severity = 'info'; Code = 'SW-STARTUP-USER-COPY'; Message = "Seulement pour votre compte : une copie de l'entrée est créée dans ~/.config/autostart (le fichier système n'est pas modifié)." }
    }
    $change = [PSCustomObject]@{ Target = $e.Name; Property = 'Démarrage automatique'; Before = $before; After = $state }
    if ($DryRun -or $blocked) { return New-ActionResult "« $($e.Name) » sera $($state.ToLower()) au démarrage" @($section) $findings @($change) $blocked }

    switch ($e.Kind) {
        { $_ -in 'run', 'folder' } {
            # 12 octets : 02 = activé ; 03 + date (FILETIME) = désactivé, comme le Gestionnaire des tâches.
            $bytes = [byte[]]::new(12)
            if ($Enabled) { $bytes[0] = 2 } else { $bytes[0] = 3; [BitConverter]::GetBytes((Get-Date).ToFileTime()).CopyTo($bytes, 4) }
            if (-not (Test-Path -LiteralPath $e.Approved)) { [void](New-Item -Path $e.Approved -Force) }
            Set-ItemProperty -LiteralPath $e.Approved -Name $e.Value -Value $bytes -Type Binary -ErrorAction Stop
        }
        'xdg' {
            $source = if (Test-Path -LiteralPath $e.UserFile) { $e.UserFile } else { $e.SystemFile }
            $lines = Set-DesktopKey @(Read-Text $source) 'Hidden' $(if ($Enabled) { 'false' } else { 'true' })
            if ($Enabled -and ($lines -match '^X-GNOME-Autostart-enabled\s*=\s*false')) { $lines = Set-DesktopKey $lines 'X-GNOME-Autostart-enabled' 'true' }
            if ($Enabled -and ($lines -match '^X-KDE-autostart-enabled\s*=\s*false')) { $lines = Set-DesktopKey $lines 'X-KDE-autostart-enabled' 'true' }
            [void](New-Item -ItemType Directory -Path (Split-Path $e.UserFile) -Force)
            [System.IO.File]::WriteAllLines($e.UserFile, [string[]]$lines)
        }
        'unit' {
            $out = & systemctl --user $(if ($Enabled) { 'enable' } else { 'disable' }) -- $e.Name 2>&1
            if ($LASTEXITCODE -ne 0) { throw "systemctl --user a échoué : $($out -join ' ')" }
        }
    }
    $script:Cache.Remove('startup')

    $now = @(Find-StartupEntries $e.Name) | Select-Object -First 1
    $after = if ($now.Enabled) { 'Activé' } else { 'Désactivé' }
    $section.Items['État'] = $after
    $result = @()
    if ($now.Enabled -ne $Enabled) { $result += [PSCustomObject]@{ Severity = 'warning'; Code = 'SW-STARTUP-UNCHANGED'; Message = "« $($e.Name) » est toujours $($after.ToLower()) après l'action." } }
    $done = New-ActionResult "« $($e.Name) » $($after.ToLower()) au démarrage" @($section) $result @([PSCustomObject]@{ Target = $e.Name; Property = 'Démarrage automatique'; Before = $before; After = $after }) $null
    $done | Add-Member Undo @{ Function = 'set_startup'; Parameters = @{ name = $Name; enabled = -not $Enabled } }
    $done
}

function Get-AdminBlock {
    if ([Environment]::IsPrivilegedProcess) { return $null }
    "Droits $(if ($IsWindows) { 'administrateur' } else { 'root' }) requis : relancer SysInfo $(if ($IsWindows) { 'en administrateur' } else { 'avec sudo -E' })."
}

# Windows Update : mises à jour logicielles non installées et non masquées (recherche en ligne, ~1 min).
function Find-WindowsUpdates([bool]$SecurityOnly) {
    $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
    $found = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'").Updates
    @(foreach ($u in $found) {
            $security = @($u.Categories | Where-Object { $_.Name -match 'Security|Sécurité' }).Count -gt 0 -or $u.MsrcSeverity
            if ($SecurityOnly -and -not $security) { continue }
            [PSCustomObject]@{ Update = $u; Name = $u.Title; Installed = $null; Available = ($u.KBArticleIDs | ForEach-Object { "KB$_" }) -join ', '; Source = 'Windows Update'; Security = [bool]$security }
        })
}

# software_install_updates : installe les mises à jour en attente (tâche longue).
#   system  : Windows Update (session COM : téléchargement puis installation) ; Linux : dnf upgrade (--security),
#             apt-get upgrade, pacman -Syu.
#   flatpak : flatpak update. winget : winget upgrade --all (Windows). all : tout ce qui précède.
function Install-SIUpdates {
    param(
        [ValidateSet('system', 'flatpak', 'winget', 'all')][string]$Scope = 'system',
        [bool]$SecurityOnly = $false,
        [switch]$DryRun
    )
    $blocked = $null
    $findings = [System.Collections.Generic.List[object]]::new()
    $pending = [System.Collections.Generic.List[object]]::new()
    $system = $Scope -in 'system', 'all'; $flat = $Scope -in 'flatpak', 'all' -and $IsLinux; $winget = $Scope -in 'winget', 'all' -and $IsWindows
    if ($Scope -eq 'flatpak' -and $IsWindows) { $blocked = 'Flatpak n''existe que sous Linux.' }
    if ($Scope -eq 'winget' -and $IsLinux) { $blocked = 'winget n''existe que sous Windows.' }
    $manager = if ($IsLinux) { if (Get-Command dnf -ErrorAction SilentlyContinue) { 'dnf' } elseif (Get-Command apt-get -ErrorAction SilentlyContinue) { 'apt-get' } elseif (Get-Command pacman -ErrorAction SilentlyContinue) { 'pacman' } } else { $null }
    if (-not $blocked -and $SecurityOnly -and $IsLinux -and $manager -ne 'dnf') { $blocked = "securityOnly n'est pris en charge qu'avec dnf ($manager installe tout ou rien)." }

    $wu = @()
    if (-not $blocked) {
        if ($IsWindows) {
            if ($system) { $wu = @(Find-WindowsUpdates $SecurityOnly); foreach ($u in $wu) { $pending.Add($u) } }
            if ($winget -and (Get-Command winget -ErrorAction SilentlyContinue)) {
                foreach ($line in (Get-CommandOutput 'winget' @('upgrade', '--accept-source-agreements', '--disable-interactivity'))) {
                    if ($line -match '^(.+?)\s{2,}(\S+)\s+(\S+)\s+(\S+)\s+winget\s*$') { $pending.Add([PSCustomObject]@{ Name = $Matches[1].Trim(); Installed = $Matches[3]; Available = $Matches[4]; Source = 'winget'; Security = $false }) }
                }
            }
        }
        else {
            $all = (Get-LinuxPendingUpdates $false).Updates
            foreach ($u in $all) {
                $isFlat = $u.Source -like 'Flatpak*'
                if (($isFlat -and $flat) -or (-not $isFlat -and $u.Source -notlike 'Snap*' -and $system -and (-not $SecurityOnly -or $u.Security))) { $pending.Add($u) }
            }
        }
    }
    if (-not $blocked -and $pending.Count -eq 0) { $blocked = 'Aucune mise à jour en attente pour ce choix (d''après le dernier cache des dépôts : software_get_pending_updates avec refresh pour actualiser).' }
    if (-not $blocked) { $blocked = Get-AdminBlock }
    if ($pending | Where-Object { $_.Name -match '^kernel|^linux-image|Cumulative|cumulative' }) { $findings.Add((New-Finding 'warning' 'SW-UPDATE-REBOOT' 'Le noyau ou une mise à jour cumulative est concerné : un redémarrage sera nécessaire.' $null)) }
    $findings.Add((New-Finding 'info' 'SW-UPDATE-DURATION' 'Téléchargement et installation : de quelques minutes à une heure ; éviter d''éteindre l''ordinateur pendant ce temps.' $null))

    $rows = @($pending | Select-Object -First 300 | ForEach-Object { , @($_.Name, $_.Installed, $_.Available, $_.Source, $(if ($_.Security) { 'Oui' } else { 'Non' })) })
    $sections = @([PSCustomObject]@{ Title = 'Mises à jour'; Type = 'Table'; Icon = 'arrow_download'; Columns = @('Nom', 'Installé', 'Disponible', 'Source', 'Sécurité'); Rows = $rows })
    $change = [PSCustomObject]@{ Target = 'Logiciels'; Property = 'Mises à jour en attente'; Before = $pending.Count; After = 0 }
    if ($DryRun -or $blocked) { return New-ActionResult "$($pending.Count) mise(s) à jour seront installées" $sections $findings @($change) $blocked }

    $log = [System.Collections.Generic.List[string]]::new()
    $reboot = $false
    if ($IsWindows) {
        if ($wu) {
            $session = New-Object -ComObject Microsoft.Update.Session
            $collection = New-Object -ComObject Microsoft.Update.UpdateColl
            foreach ($u in $wu) { if (-not $u.Update.EulaAccepted) { $u.Update.AcceptEula() }; [void]$collection.Add($u.Update) }
            Write-Progress -Activity 'Windows Update' -Status "Téléchargement de $($collection.Count) mise(s) à jour…"
            $downloader = $session.CreateUpdateDownloader(); $downloader.Updates = $collection; [void]$downloader.Download()
            Write-Progress -Activity 'Windows Update' -Status "Installation de $($collection.Count) mise(s) à jour…"
            $installer = $session.CreateUpdateInstaller(); $installer.Updates = $collection
            $result = $installer.Install()
            $reboot = $result.RebootRequired
            $log.Add("Windows Update : code de résultat $($result.ResultCode) (2 = réussi, 3 = réussi avec erreurs, 4 = échec)")
            if ($result.ResultCode -ge 4) { throw "Windows Update : échec de l'installation (code $($result.ResultCode))." }
        }
        if ($winget -and (Get-Command winget -ErrorAction SilentlyContinue)) {
            $out = Get-CommandOutput 'winget' @('upgrade', '--all', '--silent', '--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity')
            $log.Add("winget : $(($out | Select-Object -Last 1))")
        }
    }
    else {
        if ($system -and ($pending | Where-Object { $_.Source -notlike 'Flatpak*' })) {
            $cmd = switch ($manager) {
                'dnf' { @('dnf', 'upgrade', '-y') + $(if ($SecurityOnly) { '--security' } else { @() }) }
                'apt-get' { @('apt-get', '-y', 'upgrade') }
                'pacman' { @('pacman', '-Syu', '--noconfirm') }
            }
            $env:DEBIAN_FRONTEND = 'noninteractive'
            Write-Information ($cmd -join ' ')
            $out = & $cmd[0] @($cmd[1..9]) 2>&1 | ForEach-Object { Write-Information "$_"; "$_" }
            if ($LASTEXITCODE -ne 0) { throw "$manager a échoué : $(($out | Select-Object -Last 3) -join ' ')" }
            $log.Add("$manager : $(($out | Where-Object { $_ -match 'Complete|Terminé|upgraded|mis à jour' } | Select-Object -Last 1) ?? 'terminé')")
        }
        if ($flat -and ($pending | Where-Object { $_.Source -like 'Flatpak*' })) {
            Write-Information 'flatpak update -y --noninteractive'
            $out = & flatpak update -y --noninteractive 2>&1 | ForEach-Object { Write-Information "$_"; "$_" }
            if ($LASTEXITCODE -ne 0) { throw "flatpak update a échoué : $(($out | Select-Object -Last 2) -join ' ')" }
            $log.Add('Flatpak : à jour')
        }
        $reboot = [bool](Get-RebootRequired)
    }
    $script:Cache.Clear()
    $after = @()
    if ($reboot) { $after += New-Finding 'warning' 'SW-REBOOT-PENDING' 'Redémarrage nécessaire pour terminer les mises à jour.' 'Redémarrer quand c''est possible (maintenance_schedule_restart).' }
    $sections += [PSCustomObject]@{ Title = 'Résultat'; Type = 'Table'; Icon = 'checkmark_circle'; Columns = @('Étape'); Rows = @($log | ForEach-Object { , @($_) }) }
    $change.After = 'installées'
    New-ActionResult "$($pending.Count) mise(s) à jour installées" $sections $after @($change) $null
}

# Logiciel à désinstaller : Name, Version, Source, plus de quoi agir. Recherche exacte, puis partielle si unique.
function Find-InstalledSoftware([string]$Name, [string]$Source) {
    $candidates = if ($IsWindows) { @(Get-WindowsPrograms) }
                  else {
                      @(Get-Packages) + @(Get-Cached 'flatpak' 600 { @(Get-FlatpakApps) }) + @(Get-Cached 'snap' 600 { @(Get-SnapApps) })
                  }
    if ($Source -ne 'auto') {
        $want = @{ package = 'Paquet*'; flatpak = 'Flatpak'; snap = 'Snap'; program = 'Programme' }[$Source]
        $candidates = @($candidates | Where-Object Source -like $want)
    }
    $exact = @($candidates | Where-Object { $_.Name -eq $Name -or $_.Id -eq $Name })
    $list = if ($exact) { $exact } else { @($candidates | Where-Object { $_.Name -like "*$Name*" }) }
    # Même paquet pour plusieurs architectures (glibc x86_64 et i686) : un seul logiciel, retiré pour toutes.
    @($list | Group-Object Source, Name | ForEach-Object { $_.Group[0] })
}

# software_uninstall : désinstalle un logiciel.
# Windows : QuietUninstallString, sinon msiexec /x (MSI, silencieux), sinon winget uninstall, sinon le désinstalleur du
#           programme (fenêtre à suivre à l'écran). Linux : dnf remove / apt-get remove / pacman -R, flatpak uninstall,
#           snap remove ; l'aperçu liste les paquets qui partiraient avec lui.
function Uninstall-SISoftware {
    param(
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('auto', 'program', 'package', 'flatpak', 'snap')][string]$Source = 'auto',
        [switch]$DryRun
    )
    $found = @(Find-InstalledSoftware $Name $Source)
    if ($found.Count -eq 0) { return New-ActionResult "Désinstallation de $Name" @() @() @() "Aucun logiciel « $Name » (voir software_list, source packages pour les paquets)." }
    if ($found.Count -gt 1) { return New-ActionResult "Désinstallation de $Name" @() @() @() "Plusieurs logiciels correspondent : $(($found | Select-Object -First 8 | ForEach-Object { "$($_.Name) ($($_.Source))" }) -join ', '). Préciser le nom exact." }
    $sw = $found[0]
    $blocked = $null; $method = $null; $removed = @()
    $findings = [System.Collections.Generic.List[object]]::new()

    if ($IsWindows) {
        $key = foreach ($root in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall') {
            $k = Get-Item -LiteralPath "$root\$($sw.Id)" -ErrorAction SilentlyContinue; if ($k) { $k; break }
        }
        $quiet = "$($key.GetValue('QuietUninstallString'))"
        $method = if ($quiet) { @{ Kind = 'quiet'; Command = $quiet } }
                  elseif ($key.GetValue('WindowsInstaller') -eq 1 -and $sw.Id -match '^\{[0-9A-F-]+\}$') { @{ Kind = 'msi'; Command = "msiexec.exe /x $($sw.Id) /qn /norestart" } }
                  elseif (Get-Command winget -ErrorAction SilentlyContinue) { @{ Kind = 'winget'; Command = "winget uninstall --name ""$($sw.Name)"" --exact --silent" } }
                  elseif ("$($key.GetValue('UninstallString'))") { @{ Kind = 'interactive'; Command = "$($key.GetValue('UninstallString'))" } }
        if (-not $method) { $blocked = "$($sw.Name) n'a pas de commande de désinstallation." }
        if ($method.Kind -eq 'interactive') { $findings.Add((New-Finding 'warning' 'SW-UNINSTALL-INTERACTIVE' 'Ce programme n''a pas de désinstallation silencieuse : son assistant s''ouvre à l''écran et il faut le suivre.' $null)) }
        if ($sw.Scope -like 'Tous*' -and -not $blocked) { $blocked = Get-AdminBlock }
    }
    else {
        switch -Wildcard ($sw.Source) {
            'Paquet*' {
                $manager = if (Get-Command dnf -ErrorAction SilentlyContinue) { 'dnf' } elseif (Get-Command apt-get -ErrorAction SilentlyContinue) { 'apt-get' } else { 'pacman' }
                $method = @{ Kind = $manager; Command = "$manager remove $($sw.Id)" }
                # Paquets retirés avec lui (dépendances inverses), sans rien changer.
                if ($manager -eq 'dnf') {
                    $out = & dnf remove --assumeno -C $sw.Id 2>&1
                    $removed = @($out | Where-Object { $_ -match '^\s+(\S+)\s+\S+\s+\S+\s+\S+' -and $_ -notmatch 'Package|Paquet|Removing|Suppression' } | ForEach-Object { ($_.Trim() -split '\s+')[0] } | Where-Object { $_ -ne $sw.Id })
                    if (($out -join ' ') -match 'protected|protégé') { $blocked = "$($sw.Id) est protégé par dnf (paquet essentiel au système)." }
                }
                elseif ($manager -eq 'apt-get') {
                    $removed = @(& apt-get -s remove $sw.Id 2>$null | Where-Object { $_ -match '^Remv (\S+)' } | ForEach-Object { ($_ -split '\s+')[1] } | Where-Object { $_ -ne $sw.Id })
                    if ((& dpkg-query -W -f '${Essential} ${Priority}' $sw.Id 2>$null) -match '^yes|required') { $blocked = "$($sw.Id) est un paquet essentiel du système." }
                }
                if ($sw.Id -match '^(kernel|linux-image|systemd|glibc|bash|sudo|dnf|rpm|apt|dpkg|pacman|coreutils|filesystem|util-linux|NetworkManager|grub2?|shim|dbus|polkit|openssh-server|pwsh|powershell)') { $blocked = "$($sw.Id) est nécessaire au fonctionnement du système : SysInfo ne le désinstalle pas." }
                if (-not $blocked) { $blocked = Get-AdminBlock }
            }
            'Flatpak' {
                $user = $sw.Scope -eq 'Utilisateur'
                $method = @{ Kind = 'flatpak'; Command = "flatpak uninstall $(if ($user) { '--user ' })$($sw.Id)" }
                if (-not $user -and -not $blocked) { $blocked = Get-AdminBlock }
                $findings.Add((New-Finding 'info' 'SW-UNINSTALL-DATA' 'Les données de l''application dans ~/.var/app sont conservées.' $null))
            }
            'Snap' { $method = @{ Kind = 'snap'; Command = "snap remove $($sw.Id)" }; $blocked = Get-AdminBlock }
            default { $blocked = "$($sw.Name) ($($sw.Source)) ne se désinstalle pas automatiquement." }
        }
    }
    if ($removed.Count) { $findings.Add((New-Finding 'warning' 'SW-UNINSTALL-DEPENDENTS' "$($removed.Count) autre(s) paquet(s) seront retirés avec lui : $(($removed | Select-Object -First 15) -join ', ')." 'Vérifier qu''aucun ne sert encore.')) }

    $items = [ordered]@{ Logiciel = $sw.Name; Version = $sw.Version; Source = $sw.Source; Portée = $sw.Scope; Méthode = $method.Command }
    $sections = @([PSCustomObject]@{ Title = 'Désinstallation'; Type = 'KeyValue'; Icon = 'apps_list'; Items = $items })
    $changes = @([PSCustomObject]@{ Target = $sw.Name; Property = 'Installé'; Before = "oui ($($sw.Version))"; After = 'non' }) + @($removed | ForEach-Object { [PSCustomObject]@{ Target = $_; Property = 'Installé'; Before = 'oui'; After = 'non (dépendance)' } })
    if ($DryRun -or $blocked) { return New-ActionResult "$($sw.Name) sera désinstallé" $sections $findings $changes $blocked }

    switch ($method.Kind) {
        'msi' { $p = Start-Process msiexec.exe -ArgumentList "/x $($sw.Id) /qn /norestart" -Wait -PassThru; if ($p.ExitCode -notin 0, 3010) { throw "msiexec a échoué (code $($p.ExitCode))." } }
        'winget' { $out = Get-CommandOutput 'winget' @('uninstall', '--name', $sw.Name, '--exact', '--silent', '--accept-source-agreements', '--disable-interactivity'); if ($LASTEXITCODE -ne 0) { throw "winget a échoué : $(($out | Select-Object -Last 2) -join ' ')" } }
        { $_ -in 'quiet', 'interactive' } {
            $cmd = $method.Command
            $exe, $rest = if ($cmd -match '^\s*"([^"]+)"\s*(.*)$') { $Matches[1], $Matches[2] } elseif ($cmd -match '^\s*(\S+\.exe)\s*(.*)$') { $Matches[1], $Matches[2] } else { $cmd, '' }
            $p = Start-Process -FilePath $exe -ArgumentList $rest -Wait -PassThru
            if ($p.ExitCode -notin 0, 3010) { throw "Le désinstalleur a renvoyé le code $($p.ExitCode)." }
        }
        'dnf' { $out = & dnf remove -y $sw.Id 2>&1 | ForEach-Object { Write-Information "$_"; "$_" }; if ($LASTEXITCODE -ne 0) { throw "dnf a échoué : $(($out | Select-Object -Last 3) -join ' ')" } }
        'apt-get' { $env:DEBIAN_FRONTEND = 'noninteractive'; $out = & apt-get remove -y $sw.Id 2>&1; if ($LASTEXITCODE -ne 0) { throw "apt-get a échoué : $(($out | Select-Object -Last 3) -join ' ')" } }
        'pacman' { $out = & pacman -R --noconfirm $sw.Id 2>&1; if ($LASTEXITCODE -ne 0) { throw "pacman a échoué : $(($out | Select-Object -Last 3) -join ' ')" } }
        'flatpak' { $out = & flatpak uninstall -y --noninteractive $(if ($sw.Scope -eq 'Utilisateur') { '--user' } else { '--system' }) $sw.Id 2>&1; if ($LASTEXITCODE -ne 0) { throw "flatpak a échoué : $(($out | Select-Object -Last 2) -join ' ')" } }
        'snap' { $out = & snap remove $sw.Id 2>&1; if ($LASTEXITCODE -ne 0) { throw "snap a échoué : $($out -join ' ')" } }
    }
    $script:Cache.Clear()
    $still = @(Find-InstalledSoftware $sw.Name $Source | Where-Object { $_.Name -eq $sw.Name -and $_.Version -eq $sw.Version })
    $changes[0].After = if ($still) { 'toujours installé' } else { 'non' }
    $after = @()
    if ($still) { $after += New-Finding 'warning' 'SW-UNINSTALL-INCOMPLETE' "$($sw.Name) apparaît toujours comme installé." 'Le désinstalleur attend peut-être une action, ou demande un redémarrage.' }
    New-ActionResult "$($sw.Name) désinstallé" $sections $after $changes $null
}

#endregion

Export-ModuleMember -Function Get-ModuleData, Get-SISoftware, Get-SIPendingUpdates, Get-SIUpdateHistory, Set-SIStartupItem, Install-SIUpdates, Uninstall-SISoftware
