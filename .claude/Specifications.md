# SysInfo — Spécifications

> Source : doc « SysInfo — Catalogue des modules » (https://claude.ai/artifact/GoAYeMuavreYo2yyYvxf9b), relevé le 2026-10-23.
> Partie 1 = notes de travail (état, écarts, décisions). Partie 2 = copie du catalogue, référence fonctionnelle.

---

# Partie 1 — Notes de travail

## 1. État au 2026-10-23 (fin de S1)

4 modules sur 21 existent ; leur fiche du catalogue est couverte en lecture (niveau L), hors restes listés au §2.
Le MCP expose 15 outils : `get_system`, `get_hardware`, `get_network`, `get_storage` et 11 fonctions ciblées.

| # | Module | Vue d'ensemble (onglet, `get_<id>`) | Fonctions ciblées (carte « Outils », MCP) |
|---|---|---|---|
| 1 | Système | CPU total et par thread, mémoire (cache, engagée, swap), température ; OS (version, build, installation, démarrage, arrêt précédent propre ou inattendu) ; machine (fabricant, modèle, domaine, physique ou VM) ; CPU (fréquences, caches) ; top 15 processus ; date, fuseau, NTP ; langue, formats, clavier ; capteurs | `system_get_processes` (tri CPU / mémoire / E/S / nom, filtre, utilisateur, chemin, signature Windows, ligne de commande masquée), `system_get_process_tree` |
| 2 | Matériel | GPU en direct ; carte mère (n° de série si lisible) ; BIOS/UEFI, Secure Boot ; TPM ; cartes graphiques (VRAM) ; écrans (EDID : nom, connectique, définition, diagonale, année) ; audio (sorties, entrées, par défaut) ; USB ; Bluetooth connecté ; RAM et barrettes ; pilotes (date, éditeur ou origine, signé) ; périphériques en erreur | — |
| 3 | Réseau | débit, latence, perte ; connexion principale (Wi-Fi : bande, canal, sécurité, débit radio) ; DNS (suffixes, test de résolution, cache Windows) ; DHCP ; interfaces ; réseaux Wi-Fi visibles ; voisins ARP ; routes ; ports ; connexions TCP ; VPN ; partages et lecteurs réseau ; proxy et hosts ; traceroute 1.1.1.1 | `network_ping`, `network_traceroute`, `network_test_port`, `network_test_mtu`, `network_get_public_ip`, `network_discover_lan` (balayage /24, ARP, DNS, mDNS), `network_resolve_dns` |
| 4 | Stockage | remplissage ; activité ; disques (table GPT/MBR, n° de série, SMART) ; SMART détaillé ; partitions (alignement) ; inodes ; pools, RAID, Btrfs, LVM, ZFS ; TRIM ; volumes « dirty » (admin) ; erreurs | `storage_analyze_space` (plus gros dossiers et fichiers, classe C# compilée au premier appel), `storage_get_reclaimable_space` (estimation par catégorie, rien n'est supprimé) |
| 5–21 | autres | à faire | — |

Constats ajoutés en S1 : `SYS-SWAP-HIGH`, `SYS-UNEXPECTED-SHUTDOWN`, `SYS-TIME-NOT-SYNCED`, `SYS-PROC-UNSIGNED` ; `HW-GPU-HOT`, `HW-TPM-MISSING`, `HW-TPM-OLD`, `HW-DRIVER-UNSIGNED`, `HW-DRIVER-OLD`, `HW-DEVICE-ERROR` ; `NET-NO-CONNECTION`, `NET-PACKET-LOSS`, `NET-LATENCY-HIGH`, `NET-WIFI-WEAK`, `NET-WIFI-INSECURE`, `NET-LINK-SLOW`, `NET-DNS-FAIL`, `NET-DNS-SLOW`, `NET-HOSTS-CUSTOM`, `NET-PROXY`, `NET-HOST-UNREACHABLE`, `NET-PING-LOSS`, `NET-TRACE-INCOMPLETE`, `NET-MTU-LOW`, `NET-DNS-NO-ANSWER` ; `STO-PART-MISALIGNED`, `STO-INODES-FULL`, `STO-RAID-DEGRADED`, `STO-TRIM-OFF`, `STO-VOLUME-DIRTY`, `STO-SCAN-PARTIAL`, `STO-RECLAIMABLE`.

Fenêtre : carte « Outils » générique en bas de chaque page (formulaire depuis `module.json`, runspace séparé).

## 2. Restes des modules 1 à 4

Actions (niveaux A / C, sprint S4) : tuer un processus / changer sa priorité ; désactiver un périphérique, réinstaller un pilote ; vider le cache DNS, renouveler le bail DHCP ; reset Winsock / pile IP, désactiver une carte.

Limites connues, à reprendre si besoin :

- **Non testé sous Windows** : tout le code Windows de S1 a été écrit d'après la documentation des cmdlets et classes CIM, sans exécution. Priorité : une passe de test sur un poste Windows.
- Windows : périphérique audio par défaut non exposé (API COM) ; proxy WinHTTP non lu (seul le proxy utilisateur) ; pas de mDNS dans la découverte du réseau local.
- Linux : fréquence de rafraîchissement des écrans indisponible dans /sys (définition native seulement) ; n° de série de la carte mère et état ext4 « dirty » lisibles en root seulement ; taille du cache DNS retirée (`resolvectl statistics` prend 2 à 3 s).
- Analyse WinSxS (DISM, admin) : avec le module Maintenance.

## 3. Écarts avec le contrat actuel (à trancher avant de coder)

Le catalogue suppose un socle plus riche que celui décrit dans `CLAUDE.md` et `PROJECT_CONTEXT.md` §4. Points à décider :

1. **Granularité MCP** : le catalogue veut un outil par fonction (`storage_get_disk_health` ↔ `Get-SIDiskHealth`). Aujourd'hui c'est un outil par module (`get_<id>`, une seule fonction `Get-ModuleData`).
2. **Actions via MCP** : le catalogue expose les niveaux A et C au MCP (confirmation dans l'UI). `CLAUDE.md` interdit tout outil qui modifie le système « sans décision explicite ». Cette décision reste à prendre et à écrire.
3. **Format de sortie** : le catalogue demande `module / function / status / durationMs / data / findings`. Aujourd'hui c'est `Subtitle` + `Sections`. Piste : garder `Sections` pour l'UI et ajouter `Findings` (severity, code stable, message, recommendation) à côté.
4. **Paramètres** : `top`, `since`, `filter`, cible du ping… `Get-ModuleData` n'en prend aucun.
5. **Tâches longues** (SFC, DISM, scan, traceroute) : start → job id → status / result, avec timeout et annulation. Rien de tel aujourd'hui.
6. **Métadonnées par fonction** : `Level` (L/A/C/X), `Platforms`, `RequiresAdmin`, dépendance externe. Aujourd'hui elles existent seulement par module, dans `module.json`.
7. **Persistance** : historique échantillonné (7 jours), snapshots + diff, journal d'audit. Il faut du stockage disque ; SQLite = NuGet `Microsoft.Data.Sqlite`, JSONL = rien à ajouter.
8. **Dépendances externes** : LibreHardwareMonitorLib (Windows, MPL-2.0), smartctl, lm-sensors, nvidia-smi, avec un message « installer X pour activer ».
9. **Fonctions hors module** : Rapports (10), Diagnostic guidé (20), Inventaire (19) et Audit (21) agrègent d'autres modules. Elles ne rentrent pas dans le modèle « un dossier = un onglet ».
10. **Recouvrements** : Performance ↔ métriques de Système ; Capteurs ↔ températures de Système et Matériel ; Secure Boot dans Matériel et Sécurité ; points de restauration dans Maintenance et Sauvegarde. Il faut choisir un module propriétaire pour chacun.
11. **Rapport client** : logo Justware et export vers « Justware Interventions ». Le format et le mode d'export sont inconnus.
12. **Données jamais exposées**, même en L : clés BitLocker, mots de passe Wi-Fi et LAPS, clés de licence complètes, hashes, fichiers utilisateurs, historique de navigation.

## 4. Découpage en sprints proposé

| Sprint | Contenu | Niveau |
|---|---|---|
| S0 ✅ | Socle v2 : décisions §3, `Findings`, métadonnées `Level`, paramètres, nommage MCP, mise à jour de `CLAUDE.md` et `PROJECT_CONTEXT.md` | — |
| S1 ✅ | Compléter Système, Matériel, Réseau, Stockage, constats pour Matériel et Réseau, carte « Outils » | L |
| S2 | Événements, Services | L |
| S3 | Sécurité, Logiciels | L |
| S4 | Cadre des actions A/C (confirmation, dry-run, point de restauration) + tâches longues (job id) + Audit & Traçabilité (JSONL) + Maintenance + actions A/C des modules 1–8 | A / C |
| S5 | Performance (historique persistant, alertes), Capteurs & Énergie | L / A |
| S6 | Démarrage & Boot, Tâches planifiées, Sauvegarde, Impression, Virtualisation, Domaine & Configuration | L / A |
| S7 | Inventaire, Rapports (exports, snapshots, anonymisation), Diagnostic guidé | L |

## 5. Décisions S0 (2026-10-23)

| # | Sujet | Décision |
|---|---|---|
| 3.1 | Granularité MCP | **Hybride** : `get_<id>` = vue d'ensemble (`Get-ModuleData`) + une fonction ciblée par outil `<id>_<name>`, déclarée dans `module.json` (`functions`). Contrat §4.4 |
| 3.2 | Actions via MCP | **Lecture seule** : seules les fonctions `L` sont exposées. A/C en S4 avec confirmation UI + audit |
| 3.3 | Format de sortie | `Findings` à côté de `Sections` dans le retour PowerShell ; enveloppe `module / function / platform / timestamp / durationMs / status / data / findings` construite en C# (`Mcp/Envelope.cs`) |
| 3.4 | Paramètres | Déclarés par fonction (`parameters` : type, enum, bornes, défaut), vérifiés en C#, passés en `-Nom` à PowerShell. `Get-ModuleData` reste sans paramètre |
| 3.5 | Tâches longues | **Reporté à S4** (SFC, DISM, scan) : start → job id → status / result. Le traceroute reste en cache dans le module Réseau |
| 3.6 | Métadonnées | `level`, `platforms`, `requiresAdmin`, `dependencies` par fonction |
| 3.7 | Persistance | **JSONL** (aucune dépendance), à mettre en place en S4 (audit) et S5 (historique) ; à revoir si l'historique 7 jours devient lourd |
| 3.12 | Données sensibles | Règle écrite dans `CLAUDE.md` et §4.4 ; secrets évidents masqués dans les lignes de commande |

Restent ouverts : propriétaire des recouvrements (§3.10, à trancher au sprint concerné) et rapport client Justware (§3.11, avant S7).

### Livré en S0

- Contrat v2 : `functions` dans `module.json`, `Findings`, niveaux L/A/C/X (`PROJECT_CONTEXT.md` §4.3–4.4, `CLAUDE.md`).
- C# : `ModuleFunction` / `FunctionParameter` / `AccessLevel`, `Finding`, validation des fonctions dans `ModuleLoader`, `PowerShellService.InvokeAsync(commande, paramètres)`, outil MCP générique `Mcp/ModuleTool.cs` (schéma d'entrée, vérification des arguments), `Mcp/Envelope.cs`, `Mcp/McpDescriptions.cs`.
- UI : carte « Constats » en tête de page ; les constats `warning` / `critical` remontent sur l'onglet.
- Exemple de fonction : `system_get_processes` (`top`, `sortBy`, `filter` ; utilisateur, chemin, ligne de commande masquée).
- Premiers constats : `SYS-MEM-HIGH`, `SYS-CPU-HOT`, `STO-VOLUME-FULL`, `STO-SMART-FAILING`, `STO-SMART-MEDIA`, `STO-SSD-WEAR`, `STO-FS-ERRORS`, `STO-LOG-ERRORS`, `STO-SMART-UNAVAILABLE`.

---

# Partie 2 — Catalogue des modules (copie du doc)

## Vue d'ensemble

21 modules : tes 10 modules enrichis (1–10) + 11 ajouts (11–21), sur un socle commun pensé pour le MCP.

| # | Module | Fonctionnalités principales |
|---|---|---|
| 1 | Système | OS, build, CPU (charge par cœur), RAM + swap/pagefile, uptime, processus (arbre, signature, ligne de commande), heure/NTP, locale, VM détectée |
| 2 | Matériel | Carte mère, BIOS/UEFI, Secure Boot, TPM, barrettes RAM (slots libres), GPU, écrans, audio, USB/Bluetooth, pilotes (non signés, anciens), périphériques en erreur |
| 3 | Réseau | Interfaces, IP, DNS, DHCP, routes, ARP, ports + processus, connexions TCP, Wi-Fi (signal, canal), ping/traceroute/test port, IP publique, proxy, hosts, SMB, VPN, découverte LAN |
| 4 | Stockage | Disques (type, bus), SMART + usure SSD, partitions, volumes, inodes, analyse d'espace, RAID/LVM/ZFS/Storage Spaces, TRIM, erreurs I/O, dirty bit |
| 5 | Événements | Erreurs critiques filtrables, BSOD + minidumps, arrêts inattendus, crashs applis, indice de fiabilité, WHEA/MCE/OOM, timeline corrélée |
| 6 | Services | État, démarrage, compte, chemin binaire, dépendances, services auto arrêtés / failed, historique de plantage, logs, start/stop/restart |
| 7 | Sécurité | Antivirus, pare-feu, BitLocker/LUKS, Secure Boot/VBS, UAC, comptes, groupes, sessions, échecs de connexion, RDP/SSH, SMBv1/TLS, ACL, persistance suspecte, certificats, score sécurité |
| 8 | Logiciels | Programmes installés (toutes sources), MAJ en attente + historique, démarrage + impact, runtimes, activation, logiciels obsolètes, navigateurs |
| 9 | Maintenance | SFC, DISM, chkdsk/fsck, nettoyage avec estimation, réparation Windows Update, WMI, points de restauration, spouleur, TRIM |
| 10 | Rapports | Diagnostic global, score de santé, snapshots + diff avant/après, historique, exports JSON/HTML/CSV/MD/PDF, rapport client, anonymisation |
| 11 | Performance | Temps réel CPU/RAM/disque/réseau, historique échantillonné, seuils + alertes, détection de goulot, consommation par processus, mini-benchmark |
| 12 | Capteurs & Énergie | Températures, ventilateurs, throttling, batterie (usure, cycles), plan d'alimentation, sources de réveil, Fast Startup, onduleur |
| 13 | Démarrage & Boot | Durée de boot + coupables, BCD/GRUB, entrées UEFI, kernels installés |
| 14 | Tâches planifiées | Task Scheduler, cron, systemd timers : dernier résultat, tâches en échec, tâches suspectes |
| 15 | Sauvegarde & Restauration | Points de restauration, VSS, Historique des fichiers, OneDrive, Timeshift/snapper, outils tiers, alerte « pas de sauvegarde » |
| 16 | Impression & Périphériques | Imprimantes, ports, files bloquées, spouleur/CUPS, scanners, Bluetooth appairés |
| 17 | Virtualisation & Conteneurs | Hyper-V, WSL, Docker/Podman, KVM/libvirt, prérequis VT-x/AMD-V |
| 18 | Domaine & Configuration | AD/Entra ID, canal sécurisé, GPO appliquées, Intune, LAPS, variables d'env/PATH, sysctl/registre |
| 19 | Inventaire | Fiche machine en un appel, n° série, garantie, capacités d'évolution, compatibilité Windows 11 |
| 20 | Diagnostic guidé | Scénarios qui enchaînent plusieurs modules : PC lent, pas d'Internet, BSOD, disque plein, malware… |
| 21 | Audit & Traçabilité | Journal de chaque appel UI/MCP, état avant/après des actions, annulation |

## Règles MCP et socle commun

Chaque fonction déclare un niveau d'accès ; l'IA lit librement mais n'agit jamais sans garde-fou.

| Niveau | Sens | Garde-fou |
|---|---|---|
| L | Lecture seule | Aucun, exposé librement au MCP |
| A | Action réversible (redémarrer un service, vider un cache) | Confirmation dans l'UI SysInfo, journalisée |
| C | Action critique (SFC, pare-feu, désinstallation) | Admin + dry-run d'abord + point de restauration + confirmation humaine dans l'UI |
| X | Jamais exposé au MCP | UI uniquement |

**Sortie standard** de toute fonction (même forme pour l'UI et le MCP) :

```json
{
  "module": "storage",
  "function": "get_disk_health",
  "platform": "linux",
  "timestamp": "2026-10-23T10:00:00Z",
  "status": "warn",
  "durationMs": 412,
  "data": { },
  "findings": [
    { "severity": "warning", "code": "STO-SMART-REALLOC",
      "message": "12 secteurs réalloués sur /dev/sda",
      "recommendation": "Sauvegarder puis surveiller" }
  ]
}
```

- **Findings normalisés** (info / warning / critical + code stable) : l'IA agrège et priorise sans relire toutes les données.
- **Nommage** : fonction PowerShell `Get-SIDiskHealth` ↔ outil MCP `storage_get_disk_health`.
- **Métadonnées** par fonction : `Platforms` (Windows/Linux), `RequiresAdmin`, `Level` (L/A/C/X), dépendance externe éventuelle.
- **Volume limité par défaut** : paramètres `top`, `since`, `filter` et un résumé, pour ne pas noyer le contexte de l'IA (journaux, processus, logiciels).
- **Tâches longues** (SFC, DISM, scan, traceroute) : `start` → job id → `status` / `result`, avec timeout et annulation.
- **Élévation** : refus explicite si admin/root requis, jamais de résultat partiel silencieux.
- **Cache avec TTL** pour les appels lourds (logiciels installés, matériel) ; rien en cache pour le temps réel.
- **Dépendances optionnelles** détectées (smartctl, lm-sensors, nvidia-smi, LibreHardwareMonitorLib) avec un message « installer X pour activer ».
- **Linux en JSON natif** quand possible : `ip -j`, `lsblk -J`, `findmnt -J`, `smartctl -j`, `sensors -j`, `journalctl -o json`, `docker … --format json`.
- **Jamais exposé, même en L** : clés BitLocker/récupération, mots de passe Wi-Fi, mot de passe LAPS, clés de licence complètes, hashes, contenu des fichiers utilisateurs, historique de navigation.

## 1. Système

| Fonctionnalité | Windows | Linux | MCP |
|---|---|---|---|
| OS : nom, édition, version, build, arch, date d'installation | `Win32_OperatingSystem`, registre `CurrentVersion` | `/etc/os-release`, `uname -a` | L |
| Machine : hostname, domaine/workgroup, fabricant, modèle | `Win32_ComputerSystem` | `hostnamectl` | L |
| CPU : modèle, cœurs/threads, fréquences, cache, charge par cœur | `Win32_Processor`, `Get-Counter` | `lscpu -J`, `/proc/stat` | L |
| Mémoire : utilisée, commit, cache, pagefile/swap | `Win32_OperatingSystem`, `Win32_PageFileUsage` | `/proc/meminfo`, `swapon --show` | L |
| Uptime, dernier démarrage, dernier arrêt propre | `LastBootUpTime` | `/proc/uptime`, `last -x` | L |
| Processus : top CPU/RAM/IO, arbre, ligne de commande, chemin, signature, utilisateur | `Get-Process`, `Win32_Process`, `Get-AuthenticodeSignature` | `ps -eo …`, `/proc/<pid>` | L |
| Tuer un processus, changer sa priorité | `Stop-Process` | `kill`, `renice` | A |
| Heure, fuseau, synchro NTP | `Get-TimeZone`, `w32tm /query /status` | `timedatectl` | L |
| Langue, clavier, formats régionaux | `Get-WinSystemLocale`, `Get-Culture` | `localectl` | L |
| VM / hyperviseur détecté | `Win32_ComputerSystem.Model`, `HypervisorPresent` | `systemd-detect-virt` | L |

## 2. Matériel

| Fonctionnalité | Windows | Linux | MCP |
|---|---|---|---|
| Carte mère : fabricant, modèle, n° série | `Win32_BaseBoard` | `/sys/class/dmi/id`, `dmidecode -t baseboard` | L |
| BIOS/UEFI : version, date, mode UEFI/Legacy, Secure Boot | `Win32_BIOS`, `Confirm-SecureBootUEFI` | `dmidecode -t bios`, `/sys/firmware/efi`, `mokutil --sb-state` | L |
| TPM : présence, version, état | `Get-Tpm` | `/sys/class/tpm`, `tpm2_getcap` | L |
| Barrettes RAM : slots occupés/libres, capacité, fréquence, fabricant, réf. | `Win32_PhysicalMemory`, `Win32_PhysicalMemoryArray` | `dmidecode -t memory` | L |
| GPU : modèle, VRAM, pilote, version | `Win32_VideoController` | `lspci -k`, `nvidia-smi`, `glxinfo -B` | L |
| Écrans : modèle, résolution, fréquence, EDID | `WmiMonitorID` (root\wmi) | `xrandr`, `/sys/class/drm` | L |
| Audio : périphériques, sortie par défaut | `Win32_SoundDevice` | `aplay -l`, `pactl list` | L |
| USB / Bluetooth connectés | `Get-PnpDevice -Class USB,Bluetooth` | `lsusb`, `bluetoothctl devices` | L |
| Pilotes : version, date, éditeur, non signés, très anciens | `Win32_PnPSignedDriver` | `lsmod`, `modinfo` | L |
| Périphériques en erreur + explication du code | `Win32_PnPEntity.ConfigManagerErrorCode` | `lspci -k` (sans driver), `dmesg` | L |
| Désactiver/réactiver un périphérique, réinstaller un pilote | `Disable/Enable-PnpDevice`, `pnputil` | `modprobe -r` / `modprobe` | C |

## 3. Réseau

| Fonctionnalité | Windows | Linux | MCP |
|---|---|---|---|
| Interfaces : nom, MAC, état, vitesse, type (Ethernet/Wi-Fi/VPN) | `Get-NetAdapter` | `ip -j link`, `ethtool` | L |
| IPv4/IPv6, masque, passerelle | `Get-NetIPConfiguration` | `ip -j addr` | L |
| DNS : serveurs, suffixes, test de résolution, cache | `Get-DnsClientServerAddress`, `Resolve-DnsName`, `Get-DnsClientCache` | `resolvectl status`, `getent hosts` | L |
| DHCP : serveur, bail, expiration | `Win32_NetworkAdapterConfiguration` | `nmcli -t device show` | L |
| Routes, table ARP / voisins | `Get-NetRoute`, `Get-NetNeighbor` | `ip -j route`, `ip -j neigh` | L |
| Ports en écoute + processus propriétaire | `Get-NetTCPConnection -State Listen`, `Get-NetUDPEndpoint` | `ss -tulpn` | L |
| Connexions établies + processus + IP distante | `Get-NetTCPConnection` | `ss -tpn` | L |
| Wi-Fi : SSID, signal, canal, bande, sécurité, réseaux voisins | `netsh wlan show interfaces / networks` | `nmcli dev wifi` | L |
| Ping, traceroute, test de port TCP, MTU | `Test-Connection`, `Test-NetConnection -TraceRoute / -Port` | `ping`, `tracepath`, `nc -z` | L |
| Diagnostic box : latence passerelle vs Internet, IP publique | `Test-Connection`, `Invoke-RestMethod` | `ping`, `curl` | L |
| Proxy système, fichier hosts | `netsh winhttp show proxy`, registre Internet Settings | `$http_proxy`, `/etc/hosts` | L |
| Partages SMB, lecteurs réseau mappés | `Get-SmbShare`, `Get-SmbMapping` | `findmnt -J -t cifs,nfs` | L |
| VPN actifs | `Get-VpnConnection` | `nmcli con show --active`, `wg show` | L |
| Découverte LAN : box, imprimantes, NAS, objets domotiques (mDNS) | ping sweep + `Get-NetNeighbor` | `avahi-browse -art`, `nmap` si présent | L |
| Flush DNS, renouveler le bail DHCP | `Clear-DnsClientCache`, `ipconfig /renew` | `resolvectl flush-caches`, `nmcli con up` | A |
| Reset Winsock / pile IP, désactiver une carte | `netsh winsock reset`, `netsh int ip reset` | `nmcli con down` | C |

## 4. Stockage

| Fonctionnalité | Windows | Linux | MCP |
|---|---|---|---|
| Disques : modèle, type HDD/SSD/NVMe, bus, capacité, n° série | `Get-PhysicalDisk`, `Get-Disk` | `lsblk -J -o NAME,MODEL,ROTA,TRAN,SIZE,SERIAL` | L |
| SMART : état, secteurs réalloués, heures, température, usure SSD | `Get-StorageReliabilityCounter`, `smartctl -j` si installé | `smartctl -j -a` | L |
| Partitions : GPT/MBR, type, alignement | `Get-Partition` | `sfdisk -J`, `lsblk` | L |
| Volumes : FS, lettre / point de montage, libre, % | `Get-Volume` | `df -h`, `findmnt -J` | L |
| Inodes | — | `df -i` | L |
| Analyse d'espace : plus gros dossiers/fichiers, Temp, corbeille, WinSxS | `Get-ChildItem` + agrégation | `du -x` + agrégation | L |
| Pools / RAID : Storage Spaces, LVM, mdadm, ZFS, Btrfs | `Get-StoragePool`, `Get-VirtualDisk` | `lvs`, `mdadm --detail`, `zpool status`, `btrfs fi usage` | L |
| TRIM / optimisation : état, analyse | `fsutil behavior query DisableDeleteNotify`, `Optimize-Volume -Analyze` | `systemctl status fstrim.timer` | L |
| Erreurs disque récentes | Événements disk 7/51/153, Ntfs 55 | `journalctl -k` (I/O error) | L |
| Volume marqué « dirty » / à vérifier | `fsutil dirty query` | `tune2fs -l` (state) | L |

Chiffrement des volumes : voir Sécurité.

## 5. Événements

| Fonctionnalité | Windows | Linux | MCP |
|---|---|---|---|
| Erreurs/critiques sur une période, filtres journal / source / ID / niveau | `Get-WinEvent -FilterHashtable` | `journalctl -p err -S … -o json` | L |
| Arrêts inattendus | Kernel-Power 41, EventLog 6008 | `journalctl --list-boots`, `last -x` | L |
| BSOD / kernel panic : code, paramètres, pilote fautif probable | BugCheck 1001 + `C:\Windows\Minidump` | `journalctl -k -b -1`, kdump | L |
| Crashs et blocages d'applications | Application Error 1000, Application Hang 1002, WER | `coredumpctl list` | L |
| Indice de fiabilité (historique) | `Win32_ReliabilityStabilityMetrics`, `Win32_ReliabilityRecords` | — | L |
| Erreurs matérielles et mémoire | WHEA-Logger | `journalctl -k` (mce, oom-kill), rasdaemon | L |
| Échecs de mises à jour | WindowsUpdateClient 20 | logs apt / dnf | L |
| Timeline corrélée : erreurs + installations + MAJ + redémarrages | agrégation | agrégation | L |
| Exporter un journal | `wevtutil epl` | `journalctl -o export` | A |
| Effacer un journal | `wevtutil cl` | `journalctl --vacuum-time` | X |

## 6. Services

| Fonctionnalité | Windows | Linux | MCP |
|---|---|---|---|
| Liste : état, type de démarrage, compte, PID, chemin binaire, description | `Get-Service`, `Win32_Service` | `systemctl list-units --type=service --output=json`, `systemctl show` | L |
| Anomalies : services automatiques arrêtés, unités en échec | filtre `StartMode=Auto` et `State≠Running` | `systemctl --failed` | L |
| Dépendances amont / aval | `ServicesDependedOn`, `DependentServices` | `systemctl list-dependencies` | L |
| Historique de plantage, options de récupération | `sc qfailure`, événements 7031/7034 | `Restart=` dans `systemctl show`, `journalctl -u` | L |
| Signal sécurité : chemin sans guillemets, binaire hors System32 non signé | `Win32_Service.PathName` + signature | — | L |
| Logs d'un service | événements de sa source | `journalctl -u <unit>` | L |
| Démarrer / arrêter / redémarrer | `Start/Stop/Restart-Service` | `systemctl start/stop/restart` | A |
| Changer le type de démarrage, masquer | `Set-Service -StartupType` | `systemctl enable/disable/mask` | C |

## 7. Sécurité

| Fonctionnalité | Windows | Linux | MCP |
|---|---|---|---|
| Antivirus : temps réel, signatures, dernière analyse, menaces, AV tiers | `Get-MpComputerStatus`, `Get-MpThreatDetection`, `root\SecurityCenter2` | ClamAV si présent | L |
| Lancer une analyse rapide, MAJ des signatures | `Start-MpScan`, `Update-MpSignature` | `clamscan`, `freshclam` | A |
| Pare-feu : profils actifs, règles entrantes ouvertes, règles suspectes | `Get-NetFirewallProfile`, `Get-NetFirewallRule` | `ufw status`, `firewall-cmd --list-all`, `nft list ruleset` | L |
| Modifier le pare-feu | `Set-NetFirewallProfile`, `New-NetFirewallRule` | `ufw allow/deny` | C |
| Chiffrement : état, méthode, protecteurs (jamais la clé) | `Get-BitLockerVolume` | `lsblk -f`, `cryptsetup status` | L |
| Secure Boot, VBS/HVCI, Credential Guard, protection LSA | `Win32_DeviceGuard`, `Confirm-SecureBootUEFI` | `mokutil --sb-state` | L |
| UAC, SmartScreen, politique d'exécution PowerShell | registre, `Get-ExecutionPolicy -List` | — | L |
| SELinux / AppArmor | — | `getenforce`, `aa-status` | L |
| Comptes locaux : actifs, admins, dernier logon, mdp sans expiration, inactifs | `Get-LocalUser`, `Get-LocalGroupMember` | `/etc/passwd`, `lastlog`, `chage -l` | L |
| Groupes privilégiés et membres | `Get-LocalGroup` (Administrateurs) | `getent group sudo wheel`, `/etc/sudoers.d` | L |
| Sessions ouvertes, connexions récentes, échecs de connexion | `quser`, événements 4624/4625 | `who`, `last`, `lastb`, `journalctl -u sshd` | L |
| Politique de mots de passe et verrouillage | `net accounts` | `/etc/login.defs`, faillock | L |
| Accès distant : RDP, WinRM, SSH (activé, root login, auth par mdp) | registre `fDenyTSConnections`, `Get-Service WinRM,sshd` | `sshd -T` | L |
| Protocoles obsolètes : SMBv1, TLS 1.0/1.1, NTLMv1 | `Get-SmbServerConfiguration`, registre SCHANNEL | — | L |
| Autorisations : ACL d'un dossier, droits des partages | `Get-Acl`, `Get-SmbShareAccess` | `getfacl`, `stat` | L |
| Fichiers SUID et world-writable | — | `find / -xdev -perm -4000` | L |
| Persistance suspecte : clés Run, services, tâches, abonnements WMI | registre, `__EventFilter` / `__EventConsumer` | cron, unités systemd user, `~/.config/autostart`, `rc.local` | L |
| Certificats : expirés, racines inconnues | `Get-ChildItem Cert:\` | `/etc/ssl/certs`, `openssl x509` | L |
| Score de sécurité global (findings pondérés) | agrégation | agrégation | L |

Mises à jour de sécurité manquantes : voir Logiciels.

## 8. Logiciels

| Fonctionnalité | Windows | Linux | MCP |
|---|---|---|---|
| Programmes installés : nom, version, éditeur, date, taille, source | registre Uninstall (HKLM, WOW6432Node, HKCU), `Get-AppxPackage`, `winget list` | `dpkg-query` / `rpm -qa` / `pacman -Q`, `snap list`, `flatpak list` | L |
| Mises à jour en attente | COM `Microsoft.Update.Session`, `winget upgrade` | `apt list --upgradable`, `dnf check-update`, `flatpak remote-ls --updates` | L |
| Historique des mises à jour : KB, date, résultat | `Get-HotFix`, COM `QueryHistory` | `/var/log/apt/history.log`, `dnf history` | L |
| Installer les mises à jour | `winget upgrade`, COM Windows Update | `apt upgrade`, `dnf upgrade` | C |
| Désinstaller | `winget uninstall` | `apt remove` | C |
| Démarrage : Run/RunOnce, dossier Démarrage, tâches au logon, impact | registre, `Win32_StartupCommand`, `StartupApproved` | `~/.config/autostart`, `/etc/xdg/autostart`, `systemctl --user` | L |
| Activer / désactiver un élément au démarrage | registre `StartupApproved` | `Hidden=true` dans le .desktop, `systemctl --user disable` | A |
| Runtimes : .NET, VC++ Redist, Java, Python, Node, PowerShell | registre, `dotnet --list-runtimes` | `dotnet --list-runtimes`, `java -version`… | L |
| Activation Windows / Office (jamais la clé complète) | `SoftwareLicensingProduct` | — | L |
| Logiciels en fin de vie ou très en retard de version | comparaison avec une base EOL | idem | L |
| Navigateurs installés, navigateur par défaut, versions | registre | `xdg-settings get default-web-browser` | L |

## 9. Maintenance

Toute action C passe par : vérification seule → estimation (espace, durée) → point de restauration → exécution → résultat avant/après dans l'Audit.

| Fonctionnalité | Windows | Linux | MCP |
|---|---|---|---|
| Intégrité des fichiers système : vérifier | `sfc /verifyonly` | `debsums -s`, `rpm -Va` | L |
| Intégrité des fichiers système : réparer | `sfc /scannow` | réinstallation des paquets touchés | C |
| Image Windows : vérifier | `DISM /Online /Cleanup-Image /CheckHealth /ScanHealth` | — | L |
| Image Windows : réparer, nettoyer les composants | `/RestoreHealth`, `/StartComponentCleanup` | — | C |
| Vérification disque | `chkdsk /scan` (en ligne) ; `/f` planifié au boot | `fsck -n` ; réparation au boot | L / C |
| Nettoyage : Temp, cache miniatures, corbeille, logs (estimation d'abord) | `Remove-Item`, `cleanmgr /sagerun` | `apt clean`, `apt autoremove`, `journalctl --vacuum-size`, `~/.cache` | A |
| Réparation Windows Update : SoftwareDistribution, catroot2, BITS | arrêt `wuauserv`/`bits` + renommage | — | C |
| Points de restauration : lister, créer | `Get-ComputerRestorePoint`, `Checkpoint-Computer` | Timeshift, snapper | L / A |
| Réparation WMI | `winmgmt /verifyrepository`, `/salvagerepository` | — | L / C |
| TRIM / défragmentation | `Optimize-Volume` | `fstrim -v` | A |
| Spouleur : vider la file, redémarrer | arrêt Spooler + purge `spool\PRINTERS` | `cancel -a`, `systemctl restart cups` | A |
| Cache d'icônes, index de recherche | suppression `iconcache*.db`, reconstruction index | — | A |
| Redémarrage planifié | `shutdown /r /t` | `shutdown -r +N` | C |

## 10. Rapports

| Fonctionnalité | Détail | MCP |
|---|---|---|
| Diagnostic global | Lance toutes les fonctions L, trie les findings par sévérité | L |
| Score de santé | 0–100 par domaine : sécurité, stockage, performance, stabilité | L |
| Snapshots + diff | État horodaté de la machine, comparaison avant/après intervention | L |
| Historique | Évolution : espace disque, nombre d'erreurs, score, température moyenne | L |
| Exports | JSON, HTML, CSV, Markdown, PDF | L |
| Rapport client | Logo Justware, constat, actions faites, recommandations ; export vers Justware Interventions | L |
| Anonymisation | Masque utilisateur, hostname, IP, MAC, n° série avant partage | L |
| Rapports planifiés | Génération récurrente via Task Scheduler / systemd timer | A |

## 11. Performance

| Fonctionnalité | Windows | Linux | MCP |
|---|---|---|---|
| Temps réel : CPU, RAM, disque (IOPS, latence, file d'attente), débit réseau | `Get-Counter` | `/proc/stat`, `/proc/diskstats`, `/proc/net/dev` | L |
| Historique échantillonné (ex. 1 point / 30 s, 7 jours) pour les graphiques | job de fond + SQLite ou JSONL | idem | L |
| Seuils et alertes : CPU > 90 % pendant 5 min, disque < 10 %, commit RAM | règles configurables | idem | L (config : A) |
| Détection de goulot : CPU, pression mémoire, disque saturé | `Pages/sec`, `Avg. Disk sec/Transfer`, `% Processor Time` | PSI `/proc/pressure/{cpu,memory,io}` | L |
| Consommation par processus dans le temps (qui ralentit le PC) | `Get-Counter '\Process(*)\…'` | `/proc/<pid>/stat` échantillonné | L |
| Mini-benchmark disque : débit séquentiel, latence | `winsat disk` ou fichier test | `fio` ou `dd` | A |

## 12. Capteurs & Énergie

Sous Windows, PowerShell seul lit mal les températures : charger LibreHardwareMonitorLib.dll (licence MPL-2.0) donne CPU, GPU, disques, ventilateurs et tensions.

| Fonctionnalité | Windows | Linux | MCP |
|---|---|---|---|
| Températures CPU/GPU/disques, ventilateurs, tensions | LibreHardwareMonitorLib, `nvidia-smi` ; `MSAcpi_ThermalZoneTemperature` en secours | `sensors -j`, `/sys/class/hwmon`, `nvidia-smi` | L |
| Throttling thermique ou fréquence bridée | compteur `% Performance Limit` | `/sys/devices/system/cpu/cpu*/thermal_throttle` | L |
| Batterie : capacité d'origine vs actuelle (usure), cycles, état | `powercfg /batteryreport /xml`, `BatteryFullChargedCapacity` (root\wmi) | `upower -i`, `/sys/class/power_supply` | L |
| Plan d'alimentation actif et réglages | `powercfg /getactivescheme` | `powerprofilesctl`, `tlp-stat` | L |
| Changer de plan d'alimentation | `powercfg /setactive` | `powerprofilesctl set` | A |
| Veille / réveil : dernière source de réveil, timers, périphériques autorisés | `powercfg /lastwake`, `/waketimers`, `/devicequery wake_armed` | `/proc/acpi/wakeup`, `journalctl` (suspend) | L |
| Rapports énergie et Modern Standby | `powercfg /energy`, `/sleepstudy` | — | L |
| Démarrage rapide (Fast Startup) actif | registre `HiberbootEnabled` | — | L |
| Onduleur : charge, autonomie | `Win32_Battery` | `upsc` (NUT), `apcaccess` | L |

## 13. Démarrage & Boot

| Fonctionnalité | Windows | Linux | MCP |
|---|---|---|---|
| Durée du boot et de l'ouverture de session, éléments qui ralentissent | Diagnostics-Performance 100 à 110 | `systemd-analyze`, `blame`, `critical-chain` | L |
| Gestionnaire de démarrage : entrées, OS par défaut, délai | `bcdedit /enum` | `efibootmgr -v`, `/etc/default/grub` | L |
| Ordre de boot UEFI | `bcdedit /enum firmware` | `efibootmgr` | L |
| Kernel actif et kernels installés | — | `uname -r`, paquets kernel | L |
| Modifier BCD / GRUB, mode sans échec | `bcdedit /set` | `grub-mkconfig` | X |

Applications au démarrage de session : voir Logiciels.

## 14. Tâches planifiées

| Fonctionnalité | Windows | Linux | MCP |
|---|---|---|---|
| Liste : déclencheur, action, compte, dernière et prochaine exécution, résultat | `Get-ScheduledTask`, `Get-ScheduledTaskInfo` | `crontab -l`, `/etc/cron.*`, `systemctl list-timers --all` | L |
| Tâches en échec | `LastTaskResult ≠ 0` | timers liés à une unité failed | L |
| Tâches suspectes : hors `\Microsoft\`, binaire dans AppData/Temp, non signé, masquée | filtre + `Get-AuthenticodeSignature` | crons utilisateurs, scripts dans `/tmp` | L |
| Exécuter, activer, désactiver | `Start/Enable/Disable-ScheduledTask` | `systemctl start/enable/disable` | A |
| Créer, supprimer | `Register/Unregister-ScheduledTask` | `crontab -e`, fichiers timer | X |

## 15. Sauvegarde & Restauration

| Fonctionnalité | Windows | Linux | MCP |
|---|---|---|---|
| Points de restauration : activés, liste, espace réservé | `Get-ComputerRestorePoint`, `vssadmin list shadowstorage` | `timeshift --list`, `snapper list` | L |
| Clichés instantanés VSS | `vssadmin list shadows` | snapshots LVM / Btrfs / ZFS | L |
| Historique des fichiers, Sauvegarde Windows : config, dernière réussite | registre, journal FileHistory-Engine | — | L |
| OneDrive : état, dossiers protégés, erreurs de synchro | registre OneDrive, processus | Nextcloud / rclone si présents | L |
| Outils tiers détectés : Veeam Agent, Macrium, restic, borg, rsync | services et logiciels installés | timers systemd, cron | L |
| Alerte « aucune sauvegarde depuis X jours » | agrégation | agrégation | L |
| Créer un point de restauration | `Checkpoint-Computer` | `timeshift --create` | A |

## 16. Impression & Périphériques

| Fonctionnalité | Windows | Linux | MCP |
|---|---|---|---|
| Imprimantes : pilote, port, IP, par défaut, état, partage | `Get-Printer`, `Get-PrinterPort`, `Get-PrinterDriver` | `lpstat -t`, `lpinfo -v` | L |
| Files d'attente : travaux bloqués | `Get-PrintJob` | `lpq -a` | L |
| Spouleur / CUPS : état, erreurs | `Get-Service Spooler`, journal PrintService | `systemctl status cups` | L |
| Page de test | `Win32_Printer.PrintTestPage` | `lp` | A |
| Scanners | `Get-PnpDevice -Class Image` | `scanimage -L` | L |
| Bluetooth : appareils appairés, état | `Get-PnpDevice -Class Bluetooth` | `bluetoothctl devices Paired` | L |

Vider la file et redémarrer le spouleur : voir Maintenance.

## 17. Virtualisation & Conteneurs

| Fonctionnalité | Windows | Linux | MCP |
|---|---|---|---|
| Prérequis : VT-x/AMD-V, SLAT, activé dans le BIOS | `Win32_Processor.VirtualizationFirmwareEnabled` | `lscpu`, présence de `/dev/kvm` | L |
| Hyper-V : VMs, état, ressources, checkpoints | `Get-VM`, `Get-VMSnapshot` | — | L |
| WSL : distributions, version, état | `wsl -l -v` | — | L |
| Docker / Podman : conteneurs, images, volumes, espace occupé | `docker ps -a --format json`, `docker system df` | idem | L |
| KVM / libvirt : VMs | — | `virsh list --all` | L |
| Démarrer / arrêter une VM ou un conteneur | `Start-VM`, `docker start` | `virsh start`, `docker start` | A |

## 18. Domaine & Configuration

| Fonctionnalité | Windows | Linux | MCP |
|---|---|---|---|
| Jointure : domaine AD, Entra ID, workgroup | `dsregcmd /status`, `Win32_ComputerSystem` | `realm list`, sssd | L |
| Contrôleur joignable, canal sécurisé | `nltest /sc_query`, `Test-ComputerSecureChannel` | `realm`, `kinit` | L |
| GPO appliquées (ordinateur / utilisateur), erreurs | `gpresult /x` | — | L |
| Inscription MDM / Intune | `dsregcmd`, registre Enrollments | — | L |
| LAPS : configuré, dernière rotation (jamais le mot de passe) | `Get-LapsDiagnostics` | — | L |
| Forcer l'application des GPO | `gpupdate /force` | — | A |
| Variables d'environnement, PATH (doublons, chemins morts) | `[Environment]::GetEnvironmentVariables()` | `env`, `/etc/environment` | L |
| Paramètres noyau, clés de registre surveillées | registre | `sysctl -a` | L |

## 19. Inventaire

| Fonctionnalité | Windows | Linux | MCP |
|---|---|---|---|
| Fiche machine en un appel : fabricant, modèle, n° série, CPU, RAM, disques, OS, IP, MAC, utilisateur principal | agrégation des modules 1 à 4 | idem | L |
| Garantie et date de fabrication : lien vers le site du fabricant à partir du n° série | n° série → URL Dell / HP / Lenovo | idem | L |
| Capacités d'évolution : slots RAM libres, RAM max supportée, emplacements M.2/SATA | `Win32_PhysicalMemoryArray.MaxCapacity` | `dmidecode -t 16` | L |
| Compatibilité Windows 11 : TPM 2.0, CPU, Secure Boot, RAM, stockage | agrégation | — | L |
| Étiquette d'inventaire avec QR code | génération locale | idem | L |

## 20. Diagnostic guidé

Un outil MCP par scénario : l'IA appelle `diagnose_slow_pc` au lieu de dix fonctions, et reçoit causes probables classées + prochaines étapes. Tous en lecture (L) ; les corrections proposées renvoient aux actions A/C des modules.

| Scénario | Modules enchaînés | Ce qui est vérifié |
|---|---|---|
| PC lent | Performance, Démarrage, Stockage, Capteurs, Logiciels | Goulot, durée de boot, disque plein ou SMART dégradé, throttling, apps au démarrage |
| Pas d'Internet / Wi-Fi instable | Réseau | Dans l'ordre : lien → IP/DHCP → passerelle → DNS → Internet ; signal et canal Wi-Fi |
| Écrans bleus / plantages | Événements, Matériel, Capteurs | Codes BSOD, pilotes installés juste avant, WHEA, températures |
| Disque plein | Stockage, Maintenance | Plus gros dossiers, espace récupérable estimé |
| Ne s'éteint pas / se réveille seul | Capteurs & Énergie, Tâches planifiées | Source de réveil, timers, Fast Startup |
| Imprimante en panne | Impression, Services, Réseau | Spouleur, file bloquée, IP de l'imprimante joignable |
| Suspicion de malware | Sécurité, Système, Réseau, Tâches planifiées | Persistance, processus non signés, connexions sortantes inhabituelles, AV |
| Avant / après intervention | Rapports | Snapshot, diff, rapport client |

## 21. Audit & Traçabilité

Indispensable dès qu'une IA peut agir : chaque appel doit pouvoir être relu et, si possible, annulé.

| Fonctionnalité | Détail | MCP |
|---|---|---|
| Journal des appels | Horodatage, origine (UI ou client MCP), outil, paramètres, statut, durée | L |
| Historique des actions A/C | État avant / après, confirmation donnée par qui | L |
| Annulation | Retour arrière des actions réversibles (service, démarrage, plan d'alimentation) | A |
| Liste blanche MCP | Activer / désactiver chaque outil ou niveau côté Paramètres | X |
| Rétention et export du journal | Durée de conservation, export JSON | L |
