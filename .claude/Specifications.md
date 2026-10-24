# SysInfo — Spécifications

> Source : doc « SysInfo — Catalogue des modules » (https://claude.ai/artifact/GoAYeMuavreYo2yyYvxf9b), relevé le 2026-10-23.
> Partie 1 = notes de travail (état, écarts, décisions). Partie 2 = copie du catalogue, référence fonctionnelle.

---

# Partie 1 — Notes de travail

## 1. État au 2026-10-24 (fin de S7)

Les 21 modules du catalogue existent.
MCP par défaut (actions critiques désactivées) : 103 outils sous Linux, 108 sous Windows ; avec les actions critiques : 112 / 122 (21 `get_<id>`, `job_status`, `job_cancel`, puis fonctions L, A et C de chaque OS).

Actions A : `inventory_create_label`, `reports_export`, `reports_client_report`, `tasks_run`, `tasks_set_enabled`, `printing_print_test_page`, `virtualization_control`, `domain_force_gpupdate` (Windows), `performance_set_alert`, `performance_benchmark_disk`, `sensors_set_power_plan`, `system_stop_process`, `system_set_priority`, `network_flush_dns`, `network_renew_dhcp`, `events_export_log`, `services_control`, `security_start_scan`, `security_update_signatures`, `software_set_startup`, `maintenance_cleanup`, `maintenance_create_restore_point`, `maintenance_optimize_volume`, `maintenance_reset_print_queue`, `maintenance_rebuild_icon_cache` (Windows), `audit_undo`, `audit_export_log`.
Actions C : `hardware_set_device`, `hardware_reinstall_driver`, `network_reset_stack` (Windows), `network_set_adapter`, `services_set_start_type`, `security_set_firewall`, `software_install_updates`, `software_uninstall`, `maintenance_repair_system_files`, `maintenance_repair_windows_image`, `maintenance_schedule_disk_repair`, `maintenance_repair_windows_update`, `maintenance_repair_wmi` (Windows pour ces quatre), `maintenance_schedule_restart`.
Tâches longues : `reports_run_diagnostic`, `reports_create_snapshot`, `reports_compare`, `reports_client_report`, les 7 `diagnose_*`, `domain_force_gpupdate` (Windows), `performance_benchmark_disk`, `sensors_get_energy_report` (Windows), `security_start_scan`, `security_update_signatures`, `storage_analyze_space`, `network_discover_lan`, `security_find_special_files`, `software_get_pending_updates`, `software_install_updates`, `software_uninstall`, `maintenance_verify_system_files`, `maintenance_repair_system_files`, `maintenance_check_windows_image`, `maintenance_repair_windows_image`, `maintenance_check_disk`.

| # | Module | Vue d'ensemble (onglet, `get_<id>`) | Fonctions ciblées (carte « Outils », MCP) |
|---|---|---|---|
| 1 | Système | CPU total et par thread, mémoire (cache, engagée, swap), température ; OS (version, build, installation, démarrage, arrêt précédent propre ou inattendu) ; machine (fabricant, modèle, domaine, physique ou VM) ; CPU (fréquences, caches) ; top 15 processus ; date, fuseau, NTP ; langue, formats, clavier ; capteurs | `system_get_processes` (tri CPU / mémoire / E/S / nom, filtre, utilisateur, chemin, signature Windows, ligne de commande masquée), `system_get_process_tree` |
| 2 | Matériel | GPU en direct ; carte mère (n° de série si lisible) ; BIOS/UEFI, Secure Boot ; TPM ; cartes graphiques (VRAM) ; écrans (EDID : nom, connectique, définition, diagonale, année) ; audio (sorties, entrées, par défaut) ; USB ; Bluetooth connecté ; RAM et barrettes ; pilotes (date, éditeur ou origine, signé) ; périphériques en erreur | — |
| 3 | Réseau | débit, latence, perte ; connexion principale (Wi-Fi : bande, canal, sécurité, débit radio) ; DNS (suffixes, test de résolution, cache Windows) ; DHCP ; interfaces ; réseaux Wi-Fi visibles ; voisins ARP ; routes ; ports ; connexions TCP ; VPN ; partages et lecteurs réseau ; proxy et hosts ; traceroute 1.1.1.1 | `network_ping`, `network_traceroute`, `network_test_port`, `network_test_mtu`, `network_get_public_ip`, `network_discover_lan` (balayage /24, ARP, DNS, mDNS), `network_resolve_dns` |
| 4 | Stockage | remplissage ; activité ; disques (table GPT/MBR, n° de série, SMART) ; SMART détaillé ; partitions (alignement) ; inodes ; pools, RAID, Btrfs, LVM, ZFS ; TRIM ; volumes « dirty » (admin) ; erreurs | `storage_analyze_space` (plus gros dossiers et fichiers, classe C# compilée au premier appel), `storage_get_reclaimable_space` (estimation par catégorie, rien n'est supprimé) |
| 5 | Événements | résumé 7 jours (erreurs, arrêts inattendus, écrans bleus / kernel panics, plantages, erreurs matérielles, OOM, échecs de MAJ, indice de fiabilité Windows) ; tables par type (écran bleu : code, nom, cause probable) ; erreurs les plus fréquentes (regroupées) ; dernières erreurs | `events_query` (journal, source, ID, niveau, période, texte), `events_get_timeline` (démarrages, arrêts, plantages, installations, erreurs critiques ; répétitions regroupées), `events_get_reliability` (Windows) |
| 6 | Services | résumé ; anomalies (en échec, automatiques arrêtés, redémarrages en boucle) ; plantages et échecs 7 jours ; signaux de sécurité Windows (chemin sans guillemets, binaire non signé) ; liste complète (état, démarrage, compte, PID, redémarrages, binaire) | `services_list` (état, démarrage, texte), `services_get_service` (propriétés, dépendances dans les deux sens, récupération, journal) |
| 7 | Sécurité | score (100 − constats pondérés : 20 critique, 8 attention, 2 info) ; antivirus (Centre de sécurité, Defender : temps réel, signatures, analyses, menaces 30 j ; ClamAV) ; pare-feu (profils Windows ; zones firewalld, ufw, nftables) ; chiffrement par volume (BitLocker et types de protecteurs, LUKS) ; plateforme (Secure Boot, VBS / HVCI / Credential Guard, LSA, UAC, SmartScreen, stratégie d'exécution ; SELinux / AppArmor, lockdown) ; comptes locaux et groupes privilégiés ; sessions ; échecs de connexion 24 h ; politique de mots de passe et verrouillage ; accès distant (RDP / NLA, WinRM, SSH, Samba, xrdp, Cockpit) ; protocoles obsolètes Windows (SMBv1, TLS 1.0 / 1.1, NTLMv1) ; persistance suspecte ; autorités racines ajoutées | `security_get_logons`, `security_get_firewall_rules` (règles larges signalées), `security_find_persistence` (Run, Démarrage, Winlogon, IFEO, AppInit, tâches, WMI ; cron, unités locales, autostart, rc.local, ld.so.preload), `security_get_certificates`, `security_get_acl`, `security_find_special_files` (Linux : SUID / SGID, modifiables par tous, hors paquet) |
| 8 | Logiciels | résumé par source ; mises à jour en attente (Linux, depuis le cache) ou dates Windows Update ; redémarrage requis ; historique récent ; programmes au démarrage (état, portée) ; runtimes ; navigateurs et navigateur par défaut ; activation Windows / Office (jamais la clé) ; fin de support ; applications installées | `software_list` (applications, Store, paquets, Flatpak, Snap ; filtre, tri), `software_get_pending_updates` (recherche Windows Update en ligne + winget ; dnf / apt / pacman, avis de sécurité dnf, Flatpak, Snap), `software_get_update_history` |
| 9 | Maintenance | points de restauration (outil, état, liste) ; nettoyage possible par catégorie ; impression (spouleur / CUPS, travaux en attente) | `maintenance_verify_system_files`, `maintenance_check_windows_image`, `maintenance_check_disk`, `maintenance_check_wmi` ; actions ci-dessus |
| 11 | Performance | charge en direct (CPU, mémoire, activité et débit disque, réseau) ; goulots d'étranglement (PSI Linux, files d'attente Windows) ; historique 24 h (moyennes par quart d'heure, enregistré sur disque) ; processus les plus gourmands sur 1 h ; seuils d'alerte et alertes des 7 derniers jours ; état de l'historique | `performance_get_history` (1 h, 6 h, 24 h, 7 j ; statistiques), `performance_get_top_consumers`, `performance_get_alerts`, `performance_set_alert` (A), `performance_benchmark_disk` (A, longue) |
| 12 | Capteurs & Énergie | températures (graphique processeur / carte graphique, une jauge par sonde, cœurs regroupés), ventilateurs, tensions et consommation ; fréquence, limite, turbo et bridage thermique du processeur ; bridage NVIDIA ; batterie (charge, santé, cycles) et périphériques sans fil ; onduleur ; plan d'alimentation ; veille et réveil, démarrage rapide | `sensors_get_sensors`, `sensors_get_battery` (historique de charge), `sensors_get_wake_history`, `sensors_get_energy_report` (Windows, admin, longue), `sensors_set_power_plan` (A) |
| 13 | Démarrage | dernier démarrage et durée de chaque étape ; chaîne critique et unités les plus longues (Linux) ou éléments lents (Windows, admin) ; durée des démarrages précédents (graphique) ; gestionnaire de démarrage (GRUB, systemd-boot, Windows Boot Manager) ; ordre UEFI ; noyaux installés | `boot_get_history`, `boot_analyze` |
| 14 | Tâches planifiées | résumé ; tâches en échec ; tâches suspectes ; prochaines exécutions ; liste (Windows : hors `\Microsoft\`) : planification en français, commande masquée, compte, dernière exécution et résultat | `tasks_list`, `tasks_get_task` (avec journal), `tasks_run` (A), `tasks_set_enabled` (A, annulable) |
| 15 | Sauvegarde | dernière sauvegarde (date, source), outils, tâches de sauvegarde et résultat, synchronisation (OneDrive et dossiers protégés, Nextcloud, Syncthing, Dropbox, rclone), points de restauration et instantanés | `backup_list_snapshots` |
| 16 | Impression & Périphériques | service d'impression, imprimantes (état, problème, adresse, pilote, partage), travaux en attente, scanners (recherche en arrière-plan), Bluetooth (adaptateur, appareils appairés, batterie) | `printing_get_printer` (joignable sur le réseau), `printing_list_jobs`, `printing_print_test_page` (A) |
| 17 | Virtualisation & Conteneurs | prérequis (VT-x / AMD-V, SLAT, BIOS, KVM), VMs (libvirt, Hyper-V admin, VirtualBox), WSL, conteneurs Docker / Podman (santé, ports, projet), espace occupé et récupérable | `virtualization_list_containers` (images, volumes), `virtualization_control` (A, annulable) |
| 18 | Domaine & Configuration | jointure (AD, Entra ID, realmd), contrôleur joignable, canal sécurisé, MDM, stratégies de groupe (dernière application, erreurs), LAPS (jamais le mot de passe), PATH, sysctl / registre surveillés | `domain_get_environment` (secrets masqués), `domain_get_sysctl` (Linux), `domain_get_gpo` (Windows), `domain_force_gpupdate` (A, Windows) |
| 10 | Rapports | score de santé global et par domaine (historique 30 jours), constats les plus graves de tous les modules, instantanés et exports | `reports_run_diagnostic` (tous les constats), `reports_create_snapshot`, `reports_list_snapshots`, `reports_compare` (avant / après), `reports_export` (A : HTML, Markdown, JSON, CSV, anonymisation), `reports_client_report` (A : rapport d'intervention HTML, logo Justware) |
| 19 | Inventaire | fiche machine (fabricant, modèle, n° de série, CPU, mémoire, disques, GPU, OS, IP, MAC, domaine, utilisateur), garantie (lien fabricant), évolution (mémoire max, emplacements, barrettes), compatibilité Windows 11, cartes réseau | `inventory_create_label` (A : étiquette SVG avec QR code) |
| 20 | Diagnostic guidé | scénarios avec les signes actuels relevés dans les modules | `diagnose_slow_pc`, `diagnose_no_internet`, `diagnose_crashes`, `diagnose_disk_full`, `diagnose_wake_issues`, `diagnose_printer`, `diagnose_malware` (causes classées, vérifications, étape suivante) |
| 21 | Audit | 30 jours : appels fenêtre / MCP, actions exécutées, aperçus, refus, blocages, erreurs ; dernières actions (annulables) ; outils les plus appelés ; dernières erreurs | `audit_get_log`, `audit_undo`, `audit_export_log` |

Constats ajoutés en S1 : `SYS-SWAP-HIGH`, `SYS-UNEXPECTED-SHUTDOWN`, `SYS-TIME-NOT-SYNCED`, `SYS-PROC-UNSIGNED` ; `HW-GPU-HOT`, `HW-TPM-MISSING`, `HW-TPM-OLD`, `HW-DRIVER-UNSIGNED`, `HW-DRIVER-OLD`, `HW-DEVICE-ERROR` ; `NET-NO-CONNECTION`, `NET-PACKET-LOSS`, `NET-LATENCY-HIGH`, `NET-WIFI-WEAK`, `NET-WIFI-INSECURE`, `NET-LINK-SLOW`, `NET-DNS-FAIL`, `NET-DNS-SLOW`, `NET-HOSTS-CUSTOM`, `NET-PROXY`, `NET-HOST-UNREACHABLE`, `NET-PING-LOSS`, `NET-TRACE-INCOMPLETE`, `NET-MTU-LOW`, `NET-DNS-NO-ANSWER` ; `STO-PART-MISALIGNED`, `STO-INODES-FULL`, `STO-RAID-DEGRADED`, `STO-TRIM-OFF`, `STO-VOLUME-DIRTY`, `STO-SCAN-PARTIAL`, `STO-RECLAIMABLE`.

Constats ajoutés en S2 : `EVT-UNEXPECTED-SHUTDOWN`, `EVT-BSOD`, `EVT-KERNEL-PANIC`, `EVT-KERNEL-OOPS`, `EVT-APP-CRASHES`, `EVT-HARDWARE-ERROR`, `EVT-OOM-KILL`, `EVT-UPDATE-FAILED`, `EVT-RELIABILITY-LOW`, `EVT-ERROR-FLOOD` ; `SVC-FAILED`, `SVC-AUTO-STOPPED`, `SVC-RESTART-LOOP`, `SVC-CRASHING`, `SVC-UNQUOTED-PATH`, `SVC-UNSIGNED-BINARY`.

Constats ajoutés en S3 : `SEC-AV-OFF`, `SEC-AV-OUTDATED`, `SEC-AV-THREAT`, `SEC-AV-TAMPER-OFF`, `SEC-FIREWALL-OFF`, `SEC-FIREWALL-OPEN`, `SEC-FIREWALL-WIDE`, `SEC-FIREWALL-RULE-BROAD`, `SEC-DISK-UNENCRYPTED`, `SEC-SWAP-UNENCRYPTED`, `SEC-BITLOCKER-SUSPENDED`, `SEC-SECUREBOOT-OFF`, `SEC-VBS-OFF`, `SEC-LSA-UNPROTECTED`, `SEC-UAC-OFF`, `SEC-UAC-LOW`, `SEC-SMARTSCREEN-OFF`, `SEC-EXECPOLICY-OPEN`, `SEC-MAC-OFF`, `SEC-GUEST-ENABLED`, `SEC-PASSWORD-NOT-REQUIRED`, `SEC-ACCOUNT-INACTIVE`, `SEC-ROOT-EQUIVALENT-GROUP`, `SEC-LOGON-FAILURES`, `SEC-NO-LOCKOUT`, `SEC-PASSWORD-SHORT`, `SEC-RDP-NO-NLA`, `SEC-RDP-ON`, `SEC-SSH-ROOT-LOGIN`, `SEC-SSH-PASSWORD-AUTH`, `SEC-SMB1-ON`, `SEC-TLS-OLD`, `SEC-NTLMV1`, `SEC-PERSISTENCE-SUSPECT`, `SEC-ROOT-CERT-ADDED`, `SEC-CERT-EXPIRED`, `SEC-CERT-EXPIRING`, `SEC-ACL-WEAK`, `SEC-SUID-UNPACKAGED`, `SEC-WORLD-WRITABLE`, `SEC-SCAN-PARTIAL` ; `SW-UPDATES-PENDING`, `SW-UPDATES-OLD`, `SW-UPDATE-SEARCH-OLD`, `SW-UPDATES-PARTIAL`, `SW-UPDATE-FAILED`, `SW-REBOOT-PENDING`, `SW-STARTUP-MISSING`, `SW-NOT-ACTIVATED`, `SW-EOL`, `SW-EOL-SOON`.

Constats ajoutés en S4b : `HW-DEVICE-STORAGE`, `HW-DEVICE-NETWORK`, `HW-DEVICE-DISPLAY`, `HW-DEVICE-UNDO`, `HW-DRIVER-REINSTALL`, `HW-DRIVER-SHARED`, `HW-DRIVER-MISSING` ; `NET-RESET-REBOOT`, `NET-RESET-SETTINGS`, `NET-ADAPTER-PRIMARY`, `NET-ADAPTER-UNDO` ; `SVC-START-DEPENDENTS`, `SVC-START-MASKED`, `SVC-START-NOW` ; `SEC-FIREWALL-DISABLING`, `SEC-FIREWALL-PUBLIC` ; `SW-UPDATE-REBOOT`, `SW-UPDATE-DURATION`, `SW-UNINSTALL-INTERACTIVE`, `SW-UNINSTALL-DATA`, `SW-UNINSTALL-DEPENDENTS`, `SW-UNINSTALL-INCOMPLETE` ; `MNT-NO-RESTORE-POINT`, `MNT-RESTORE-OLD`, `MNT-RESTORE-REUSED`, `MNT-CLEANUP`, `MNT-CLEANUP-PERMANENT`, `MNT-CLEANUP-REBUILT`, `MNT-CLEANUP-IN-USE`, `MNT-SYSFILES-CORRUPT`, `MNT-SYSFILES-UNKNOWN`, `MNT-SYSFILES-MODIFIED`, `MNT-SYSFILES-UNREPAIRED`, `MNT-REPAIR-REBOOT`, `MNT-REPAIR-NETWORK`, `MNT-IMAGE-CORRUPT`, `MNT-IMAGE-UNREPAIRABLE`, `MNT-IMAGE-NO-UNINSTALL`, `MNT-DISK-ERRORS`, `MNT-DISK-CHECKSUM`, `MNT-DISK-DIRTY`, `MNT-DISK-ONLINE`, `MNT-DISK-BOOT-CHECK`, `MNT-PRINT-CANCEL`, `MNT-PRINT-PARTIAL`, `MNT-PRINT-STUCK`, `MNT-EXPLORER-RESTART`, `MNT-WU-HISTORY`, `MNT-WU-REDOWNLOAD`, `MNT-WMI-INCONSISTENT`, `MNT-WMI-RESTART`, `MNT-RESTART-UNSAVED` ; `AUD-MCP-ACTIONS`, `AUD-MCP-DECLINED`, `AUD-EXPORT-PRIVATE`.

Constats ajoutés en S7 : `INV-RAM-UPGRADABLE`, `INV-SERIAL-DENIED`, `INV-WIN11-INCOMPATIBLE`, `INV-WIN10`, `INV-LABEL-NO-SERIAL`, `INV-LABEL-PRINT` ; `RPT-SCORE-LOW`, `RPT-MODULE-ERROR`, `RPT-NEW-FINDING`, `RPT-EXPORT-PRIVATE`, `RPT-NO-ACTIONS` ; `DIAG-SLOW-SATURATED`, `DIAG-SLOW-MEMORY`, `DIAG-SLOW-PROCESS`, `DIAG-SLOW-HEAT`, `DIAG-SLOW-POWER`, `DIAG-SLOW-DISK`, `DIAG-SLOW-BOOT`, `DIAG-SLOW-STARTUP`, `DIAG-SLOW-REBOOT`, `DIAG-SLOW-ERRORS`, `DIAG-NET-NO-LINK`, `DIAG-NET-NO-IP`, `DIAG-NET-NO-GATEWAY`, `DIAG-NET-GATEWAY-DOWN`, `DIAG-NET-LOCAL-LOSS`, `DIAG-NET-DNS`, `DIAG-NET-NO-INTERNET`, `DIAG-NET-QUALITY`, `DIAG-CRASH-HARDWARE`, `DIAG-CRASH-HEAT`, `DIAG-CRASH-DRIVER`, `DIAG-CRASH-DISK`, `DIAG-CRASH-AFTER-INSTALL`, `DIAG-CRASH-OBSERVED`, `DIAG-DISK-FULL`, `DIAG-DISK-RECLAIMABLE`, `DIAG-DISK-CONTAINERS`, `DIAG-DISK-CLEANUP`, `DIAG-DISK-ANALYZE`, `DIAG-WAKE-NIGHT`, `DIAG-WAKE-SOURCE`, `DIAG-WAKE-TIMER`, `DIAG-WAKE-DEVICES`, `DIAG-WAKE-FASTSTARTUP`, `DIAG-PRN-SPOOLER`, `DIAG-PRN-STUCK`, `DIAG-PRN-NONE`, `DIAG-PRN-PRINTER`, `DIAG-PRN-NETWORK`, `DIAG-MAL-AV`, `DIAG-MAL-PERSISTENCE`, `DIAG-MAL-TASK`, `DIAG-MAL-PROCESS`, `DIAG-MAL-CONNECTIONS`, `DIAG-MAL-PROTECTION`, `DIAG-MAL-CPU`, `DIAG-MAL-SCAN`.

Constats ajoutés en S6 : `BOOT-SLOW`, `BOOT-FIRMWARE-SLOW`, `BOOT-DEGRADED`, `BOOT-SLOW-UNIT`, `BOOT-SLOWER`, `BOOT-ORDER-EXTERNAL`, `BOOT-NEWER-KERNEL`, `BOOT-NO-FALLBACK`, `BOOT-HISTORY-EMPTY` ; `TSK-FAILED`, `TSK-SUSPICIOUS`, `TSK-MISSED`, `TSK-HISTORY-OFF`, `TSK-DISABLE-MICROSOFT` ; `BAK-NONE`, `BAK-OLD`, `BAK-UNKNOWN-DATE`, `BAK-FAILED`, `BAK-SYNC-ONLY`, `BAK-SYNC-STOPPED`, `BAK-RESTORE-OFF`, `BAK-SNAPSHOTS-DENIED` ; `PRN-SPOOLER-DOWN`, `PRN-SPOOLER-ERRORS`, `PRN-PRINTER-PROBLEM`, `PRN-NO-DEFAULT`, `PRN-SHARED`, `PRN-JOB-STUCK`, `PRN-UNREACHABLE`, `PRN-TEST-PAGE`, `PRN-BT-BATTERY-LOW`, `PRN-BT-OFF` ; `VIRT-DISABLED-BIOS`, `VIRT-KVM-MISSING`, `VIRT-UNSUPPORTED`, `VIRT-KVM-NO-ACCESS`, `VIRT-VM-CRASHED`, `VIRT-WSL1`, `VIRT-DOCKER-DENIED`, `VIRT-DOCKER-DOWN`, `VIRT-CONTAINER-UNHEALTHY`, `VIRT-CONTAINER-RESTARTING`, `VIRT-CONTAINER-EXITED`, `VIRT-SPACE-RECLAIMABLE`, `VIRT-STOP-SERVICES`, `VIRT-STOP-VM`, `VIRT-START-MEMORY`, `VIRT-STOP-REQUESTED` ; `CFG-DC-UNREACHABLE`, `CFG-SECURE-CHANNEL`, `CFG-SSSD-DOWN`, `CFG-GPO-OLD`, `CFG-GPO-ERRORS`, `CFG-GPO-USER-ONLY`, `CFG-GPUPDATE-USER-ONLY`, `CFG-GPUPDATE-LOGOFF`, `CFG-LAPS-OFF`, `CFG-LAPS-OLD`, `CFG-PATH-DUPLICATE`, `CFG-PATH-MISSING`, `CFG-PATH-UNSAFE`, `CFG-SYSCTL`, `CFG-SYSCTL-DENIED`, `CFG-WU-DISABLED`, `CFG-AUTOLOGON`, `CFG-WSUS`.

Constats ajoutés en S5 : `PERF-ALERT-CPU`, `PERF-ALERT-MEMORY`, `PERF-ALERT-SWAP`, `PERF-ALERT-COMMIT`, `PERF-ALERT-DISK`, `PERF-ALERT-DISK-LATENCY`, `PERF-ALERT-NETWORK`, `PERF-ALERT-DISK-FREE`, `PERF-BOTTLENECK-CPU`, `PERF-BOTTLENECK-MEMORY`, `PERF-BOTTLENECK-DISK`, `PERF-BOTTLENECK-NETWORK`, `PERF-HISTORY-WRITE`, `PERF-HISTORY-EMPTY`, `PERF-HISTORY-PARTIAL`, `PERF-PROCESS-HEAVY`, `PERF-BENCH-WRITE`, `PERF-DISK-SLOW` ; `SNS-TEMP-HIGH`, `SNS-TEMP-CRITICAL`, `SNS-FAN-STOPPED`, `SNS-CPU-THROTTLING`, `SNS-CPU-CAPPED`, `SNS-TURBO-OFF`, `SNS-GPU-THROTTLING`, `SNS-BATTERY-WORN`, `SNS-BATTERY-LOW`, `SNS-UPS-ON-BATTERY`, `SNS-UPS-REPLACE-BATTERY`, `SNS-POWER-SAVER`, `SNS-FASTSTARTUP-ON`, `SNS-LHM-MISSING`, `SNS-SENSORS-LIMITED`, `SNS-NO-BATTERY`, `SNS-BATTERY-REPORT`, `SNS-WAKE-NIGHT`, `SNS-ENERGY-ERRORS`, `SNS-PLAN-SLOWER`.

Constats ajoutés en S4a (aperçus et résultats d'actions) : `SYS-STOP-SERVICE-PROCESS`, `SYS-STOP-CHILDREN`, `SYS-STOP-UNSAVED`, `SYS-STOP-IGNORED`, `SYS-PRIORITY-HIGH`, `SYS-PRIORITY-TEMPORARY` ; `NET-DNS-FLUSH-SLOWER`, `NET-DHCP-RENEW-CUT`, `NET-DHCP-NO-ADDRESS` ; `EVT-EXPORT-PARTIAL`, `EVT-EXPORT-PRIVATE` ; `SVC-CONTROL-DEPENDENTS`, `SVC-CONTROL-REMOTE-CUT`, `SVC-CONTROL-TEMPORARY`, `SVC-CONTROL-FAILED` ; `SEC-SCAN-DURATION`, `SEC-AV-ALREADY-CURRENT` (et `SEC-AV-THREAT` après une analyse) ; `SW-STARTUP-NEXT-LOGON`, `SW-STARTUP-USER-COPY`, `SW-STARTUP-UNCHANGED`.

Fenêtre : carte « Outils » générique en bas de chaque page (formulaire depuis `module.json`, runspace séparé) ; actions avec « Simuler » et « Exécuter… » (fenêtre de confirmation), « Arrêter » pendant l'exécution. Paramètres › Actions et audit.

## 2. Restes des modules 1 à 8

Toutes les actions A et C du catalogue pour les modules 1 à 8 sont faites (§1). Effacer un journal : niveau X, jamais exposé (non proposé). Modifier BCD / GRUB : X, module 13.

Limites connues, à reprendre si besoin :

- **Non testé sous Windows** : tout le code Windows de S1 a été écrit d'après la documentation des cmdlets et classes CIM, sans exécution. Priorité : une passe de test sur un poste Windows.
- Windows : périphérique audio par défaut non exposé (API COM) ; proxy WinHTTP non lu (seul le proxy utilisateur) ; pas de mDNS dans la découverte du réseau local.
- Linux : fréquence de rafraîchissement des écrans indisponible dans /sys (définition native seulement) ; n° de série de la carte mère et état ext4 « dirty » lisibles en root seulement ; taille du cache DNS retirée (`resolvectl statistics` prend 2 à 3 s).
- Analyse WinSxS (DISM, admin) : avec le module Maintenance.
- Événements : pilote fautif d'un écran bleu non identifié (il faudrait analyser le minidump) ; sous Linux, le résumé lit les 2 000 erreurs les plus récentes et le signale au-delà ; un démarrage qui s'arrête pendant le démarrage suivant peut compter comme arrêt inattendu.
- Sécurité : beaucoup de données Windows demandent l'administrateur (BitLocker détaillé, journal Sécurité 4624 / 4625, abonnements WMI) ; sans droits, état BitLocker via le Shell et échecs de connexion non lus (signalé). Sous Linux sans root : configuration sshd, règles ufw / nftables, profils AppArmor, crontabs des autres comptes et expiration des mots de passe des autres comptes illisibles (signalé). Partages Samba et droits des partages Windows non couverts (le module Réseau liste les partages). Racines « ajoutées » sous Windows = absentes d'AuthRoot et non émises par Microsoft (heuristique). Pas de vérification sudo NOPASSWD (root requis).
- Logiciels : sous Windows, mises à jour en attente seulement via la fonction (recherche en ligne lente) ; impact au démarrage non mesuré ; tâches planifiées au logon laissées au module Tâches planifiées ; applications du Store lues dans le registre (Get-AppxPackage n'est pas chargé par PowerShell 7). Sous Linux : mises à jour d'après le cache de dnf de l'utilisateur (date affichée) ; Snap seulement avec refresh ; date d'installation absente pour deb et pacman. Base de fin de support intégrée au module (`$script:EolRules`, au 2026-10-23), à tenir à jour ; appliquée aux runtimes et aux programmes Windows (sous Linux, la distribution suit ses paquets). Premier appel : 3 s (Sécurité), 5 à 7 s (Logiciels), puis cache.
- Actions (S4a) : **non testées sous Windows** ; sous Linux, testées en aperçu et en exécution : arrêt et priorité d'un processus, cache DNS, export de journal, élément de démarrage (entrée XDG de test) ; en aperçu seulement : bail DHCP (couperait le réseau), services (root requis), antivirus (ClamAV absent). Confirmation testée : fenêtre affichée, refus et fenêtre fermée de force ; le clic sur « Exécuter » reste à tester à la main. Après une action, les pages gardent leur cache jusqu'au rafraîchissement suivant (runspaces séparés). Sous Linux, piloter un service système exige root (la règle polkit par défaut demande un mot de passe, impossible sans terminal).
- Actions C et Maintenance (S4b) : **non testées sous Windows ni en root** ; sous Linux, aperçus testés pour toutes, blocages vérifiés (pilote intégré au noyau, clavier, service essentiel, paquet protégé, port couvert par une plage, droits) ; exécutées : aucune (root requis). Maintenance testée en vue d'ensemble, vérification des fichiers (rpm -Va, ~2 min), vérification Btrfs, aperçus de nettoyage. Audit testé : vue d'ensemble, journal, annulation d'un élément de démarrage. Linux sans snapper ni Timeshift (cas de ce poste) : aucun point de restauration, signalé dans la fenêtre de confirmation. Windows ne crée qu'un point de restauration par 24 h (le récent est réutilisé). Fenêtre de confirmation en root sous Linux : il faut garder l'affichage (`sudo --preserve-env=…`). Restes du catalogue Maintenance : réparation de disque au démarrage sous Linux (pas de mécanisme systemd fiable), défragmentation Linux (sans objet).
- Performance (S5) : l'historique n'est enregistré que pendant que SysInfo tourne (fenêtre ouverte, même réduite si la pause est désactivée, ou serveur MCP appelé régulièrement) : pas de service en arrière-plan. Fichiers JSONL ~0,9 Mio par jour plein. Processus enregistrés : 5 premiers en CPU et 3 en mémoire par point de 30 s (les petits consommateurs sont sous-estimés). Lecture de 7 jours : ~2 s. Windows non testé (compteurs PDH, GlobalMemoryStatusEx, disque sans cache). Mini-benchmark testé sous Linux (NVMe : lecture 3 GiB/s, écriture 657 MiB/s, 0,06 ms en 4 KiB) ; il n'existe que dans l'application (classe native).
- Capteurs (S5) : Windows non testé ; sans LibreHardwareMonitor, seules les zones thermiques ACPI (souvent une seule, peu fiable). LibreHardwareMonitorLib n'est pas embarquée (pilote noyau, administrateur, licence MPL) : SysInfo lit le WMI de l'application LibreHardwareMonitor si elle tourne. Pas de ventilateurs sous Linux sans pilote de carte mère (cas de ce poste). Batterie, onduleur et veille testés seulement « absents » (poste fixe sans veille récente). Changement de plan testé en vrai avec tuned (balanced → desktop → balanced). nvidia-smi n'est pas appelé quand la carte est en veille (portable).
- S7 : **Windows non testé** (fiche machine CIM, tpmtool, Confirm-SecureBootUEFI, Win32_SystemSlot, rapport de batterie…). Testé sous Linux : les trois modules, le pont `ModuleHost` (fenêtre de test MCP), instantané et comparaison (changement réel détecté : minuterie ajoutée, service disparu), exports HTML / CSV / Markdown, anonymisation vérifiée (aucun nom, adresse IP ou MAC restant), rapport client rendu dans un navigateur, étiquette et QR code relus par OpenCV (QR : 6 textes de test, versions 1 à 10, UTF-8).
- Rapports : **rapports planifiés non faits** (créer une tâche planifiée est de niveau X dans le module Tâches, et il faudrait un mode `SysInfo --report` sans fenêtre) ; PDF : par l'impression du navigateur ; envoi vers « Justware Interventions » : format inconnu (§3.11), seul le HTML est produit. Premier relevé complet sans pages ouvertes (serveur MCP) : ~13 s. La comparaison ignore les modules dont les valeurs bougent sans cesse (Système, Performance, Capteurs, Réseau, Audit) et les tableaux datés ou numérotés.
- Inventaire : n° de série et emplacements d'extension en root sous Linux ; garantie : lien vers le site du fabricant, pas de consultation en ligne ; liste des processeurs compatibles Windows 11 simplifiée (Intel 8e gén.+, Ryzen 2000+ hors APU 2000) ; « à vérifier » sinon.
- Diagnostic guidé : seuils simples (processus > 20 % de CPU en moyenne sur 1 h, plus de 8 programmes au démarrage, 20 sous Linux) ; le scénario « avant / après » renvoie aux fonctions de Rapports.
- S6, général : **Windows non testé** (Planificateur par COM, bcdedit, Diagnostics-Performance, Win32_Printer, Hyper-V CIM, WSL, dsregcmd, nltest, gpresult, LAPS) ; beaucoup de données Windows demandent l'administrateur (durées de démarrage, bcdedit, points de restauration, VMs Hyper-V, stratégies de l'ordinateur).
- Démarrage (S6) : sous Linux sans root, noyau par défaut de GRUB illisible (grubenv) ; historique des durées tiré du journal (perdu si le journal n'est pas persistant). Modifier BCD / GRUB : X.
- Tâches (S6) : testé sous Linux : minuteries système et utilisateur, crons, anacron ; activation / désactivation testée en vrai sur une minuterie utilisateur (aller-retour fidèle : une minuterie lancée sans être activée est seulement arrêtée puis relancée). Crons non pilotables (fichiers) ; minuteries système : root. Crontabs des autres comptes : root.
- Sauvegarde (S6) : ce poste n'a aucune sauvegarde (BAK-NONE, juste) ; détection d'une tâche de sauvegarde testée avec une minuterie utilisateur temporaire. Pas de lecture des dépôts restic / borg (mots de passe) : la date vient de la tâche qui les lance. Points de restauration Linux : snapper / Timeshift en root.
- Impression (S6) : aucune imprimante ni appareil Bluetooth appairé sur ce poste : analyse de lpstat et bluetoothctl testée seulement « vide ». lpstat attend ~1 s par appel (une fois toutes les 5 min) ; scanimage tourne en arrière-plan (la page n'attend pas).
- Virtualisation (S6) : testé avec 13 conteneurs Docker et 9 VMs libvirt ; démarrage / arrêt testés sur un conteneur jetable. VirtualBox, Hyper-V et WSL non testés.
- Domaine (S6) : poste en groupe de travail : jointure, contrôleur, canal sécurisé, GPO et LAPS non testés. Les variables d'environnement listées sont celles du processus SysInfo (celles d'un agent MCP diffèrent de celles de la fenêtre).
- Services : sous Linux, PID et compteurs de redémarrages relus toutes les 30 s (systemctl show coûte ~0,5 s pour 200 unités) ; l'état, lui, est relu à chaque rafraîchissement.

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
| S2 ✅ | Événements, Services | L |
| S3 ✅ | Sécurité, Logiciels | L |
| S4a ✅ | Cadre des actions A (aperçu `-DryRun`, `Blocked`, `Changes`, fenêtre de confirmation `SysInfo --confirm`), tâches longues (job id, annulation, délai), journal d'audit JSONL, actions A des modules 1–8 | A |
| S4b ✅ | Actions C (admin, aperçu, point de restauration, case « J'ai lu l'aperçu ») des modules 1–8, module Maintenance, module Audit & Traçabilité (journal, annulation par `undo`, export), liste blanche MCP dans les Paramètres | C |
| UX ✅ | « Voir plus » (tableaux, listes, jauges, constats), animations de hauteur (`AnimatedHeight`), constats animés à l'entrée et à la sortie, fondu des pages et du contenu, carte Outils séparée en consultations / actions | — |
| S5 ✅ | Performance (charge, goulots, historique JSONL 7 jours, alertes configurables, processus gourmands, mini-benchmark disque), Capteurs & Énergie (sondes, bridage, batterie, onduleur, plans, veille) ; contrat : `History` d'une Metric ; assistants natifs `PerfSampler`, `PdhQuery`, `PowerStatus`, `SysFs`, `DiskBenchmark`, relevé de processus partagé | L / A |
| S6 ✅ | Démarrage & Boot, Tâches planifiées, Sauvegarde, Impression & Périphériques, Virtualisation & Conteneurs, Domaine & Configuration (lecture, actions A annulables : tâches, VM / conteneurs, page de test, gpupdate) ; aucun changement de contrat | L / A |
| Activité ✅ | Page Activité : tâches en cours avec journal et progression en direct (`Write-Information`, `Write-Progress` relayés par `PowerShellService`), arrêt, tâches longues MCP ; historique tiré du journal d'audit avec détail ; pastille dans la barre latérale | — |
| S7 ✅ | Inventaire (fiche, garantie, évolution, Windows 11, étiquette QR), Rapports (score, diagnostic global, instantanés et comparaison, exports, rapport client HTML Justware, anonymisation), Diagnostic guidé (7 scénarios) ; pont `SysInfo.Host.ModuleHost` (§4.7), `SysInfo.Native.QrCode` | L / A |

## 5. Décisions S0 (2026-10-23)

| # | Sujet | Décision |
|---|---|---|
| 3.1 | Granularité MCP | **Hybride** : `get_<id>` = vue d'ensemble (`Get-ModuleData`) + une fonction ciblée par outil `<id>_<name>`, déclarée dans `module.json` (`functions`). Contrat §4.4 |
| 3.2 | Actions via MCP | `L` exposé librement ; `A` exposé depuis S4a avec aperçu, confirmation dans une fenêtre SysInfo et audit (§ Décisions S4a) ; `C` en S4b |
| 3.3 | Format de sortie | `Findings` à côté de `Sections` dans le retour PowerShell ; enveloppe `module / function / platform / timestamp / durationMs / status / data / findings` construite en C# (`Mcp/Envelope.cs`) |
| 3.4 | Paramètres | Déclarés par fonction (`parameters` : type, enum, bornes, défaut), vérifiés en C#, passés en `-Nom` à PowerShell. `Get-ModuleData` reste sans paramètre |
| 3.5 | Tâches longues | Fait en S4a : `"long": true` ; attente 25 s puis job id, `job_status` / `job_cancel`, délai `timeoutSeconds`. Le traceroute reste en cache dans le module Réseau |
| 3.6 | Métadonnées | `level`, `platforms`, `requiresAdmin`, `dependencies` par fonction |
| 3.7 | Persistance | **JSONL** (aucune dépendance), à mettre en place en S4 (audit) et S5 (historique) ; à revoir si l'historique 7 jours devient lourd |
| 3.12 | Données sensibles | Règle écrite dans `CLAUDE.md` et §4.4 ; secrets évidents masqués dans les lignes de commande |

Restent ouverts : envoi du rapport client vers « Justware Interventions » (§3.11 : format inconnu ; le rapport HTML est fait) et rapports planifiés.

### Décisions S3 (recouvrements, §3.10)

| Sujet | Décision |
|---|---|
| Secure Boot (Matériel ↔ Sécurité) | Matériel affiche l'état brut avec le firmware ; Sécurité porte le constat `SEC-SECUREBOOT-OFF` |
| Démarrage (Logiciels ↔ Sécurité ↔ Tâches planifiées) | Logiciels liste les programmes lancés à l'ouverture de session et leur état ; Sécurité analyse tous les points de persistance et ne montre que les suspects ; les tâches planifiées restent au module 14 (Sécurité ne lit que celles hors Microsoft, pour la persistance) |
| Mises à jour (Logiciels ↔ Événements) | Logiciels : en attente, historique, redémarrage requis (`SW-…`) ; Événements garde `EVT-UPDATE-FAILED` (échecs vus dans les journaux) |
| Signaux de sécurité des services | Restent dans Services (`SVC-UNQUOTED-PATH`, `SVC-UNSIGNED-BINARY`), non repris par le score de Sécurité |

### Décisions S4a (2026-10-23)

| Sujet | Décision |
|---|---|
| Confirmation d'une action MCP | Le serveur (sans fenêtre) lance `SysInfo --confirm <demande.json>` : fenêtre dédiée qui recalcule elle-même l'aperçu, « Refuser » par défaut (Entrée, Échap, fermeture), refus automatique après 120 s, réponse sur stdout. Marche que l'app principale soit ouverte ou non ; exige une session graphique (sinon erreur claire). Pas d'elicitation MCP (le client pourrait l'auto-approuver) |
| Découpage S4 | S4a (cadre + actions A) puis S4b (actions C, Maintenance, onglet Audit) |
| Aperçu | `-DryRun` obligatoire pour toute action ; `Blocked` arrête tout avant la confirmation |
| Audit | JSONL mensuel, appels MCP (lectures comprises) + carte « Outils » + actions ; pas le rafraîchissement automatique ; rétention 365 jours |
| Exposition | Réglage `mcpActions` (activé par défaut) ; la liste blanche par outil reste pour l'onglet Audit (S4b) |
| Runspaces | Trois par module (`ModuleRunner`) : vue d'ensemble, fonctions et actions, tâches longues |

### Décisions S4b (2026-10-23)

| Sujet | Décision |
|---|---|
| Droits des actions C | Administrateur exigé pour l'exécution, dans la fenêtre comme en MCP ; l'aperçu reste possible sans |
| Point de restauration | Créé par SysInfo (C#) avant chaque action C, via `New-SIRestorePoint` du module Maintenance ; `"restorePoint": false` pour s'en passer. Impossible : affiché dans la confirmation, l'utilisateur décide ; échec alors qu'il était possible : action annulée |
| Exposition MCP des C | Désactivée par défaut (`mcpCriticalActions`) ; liste blanche par outil A / C dans Paramètres |
| Annulation | Champ `Undo` des actions (fonction inverse du même module), rejoué par `audit_undo` si elle est de niveau A ; une annulation C se lance par son outil |
| Audit | Module PowerShell `Modules/Audit` qui relit le JSONL (pas d'onglet C# dédié) ; entrées identifiées par `id` |
| Recouvrement points de restauration (§3.10) | Maintenance les crée et les liste ; Sauvegarde & Restauration (module 15) les reprendra en lecture |
| Vérification puis réparation des paquets (Linux) | La réparation s'appuie sur la dernière vérification (fichier d'état, moins de 7 jours) au lieu de relancer `rpm -Va` |

### Décisions S5 (2026-10-24)

| Sujet | Décision |
|---|---|
| Recouvrement Performance ↔ Système (§3.10) | Système garde sa vue en direct (CPU par thread, top 15) ; Performance porte l'historique, les alertes, les goulots et les consommateurs dans le temps. Le relevé des processus est partagé (`ProcessSampler.Shared`) |
| Recouvrement Capteurs ↔ Système / Matériel (§3.10) | Capteurs possède toutes les sondes, le bridage et l'énergie ; Système garde sa jauge de température CPU, Matériel la carte graphique en direct |
| Historique (§3.7) | JSONL quotidien, un point de 30 s (moyennes + processus), 7 jours ; écrit par le module (pas de service) ; plusieurs processus SysInfo : le premier qui a 30 s de mesures écrit, les autres relisent |
| Graphiques d'historique | Contrat : `History` sur une Metric (points fournis par le module) au lieu d'un nouveau type de section |
| Alertes | Seuils par mesure (valeur, durée, gravité, actif) dans `state/performance-alerts.json`, modifiables par `performance_set_alert` (A, annulable) ; alerte = moyenne au-delà du seuil sur la durée ; début et fin journalisés (`history/performance-alerts-AAAA-MM.jsonl`) ; pas de notification système |
| Capteurs Windows | Pas de LibreHardwareMonitorLib embarquée ; lecture du WMI de LibreHardwareMonitor s'il tourne, sinon zones thermiques PDH |

### Décisions S6 (2026-10-24)

| Sujet | Décision |
|---|---|
| Points de restauration (§3.10) | Maintenance les crée et les liste ; Sauvegarde les lit (avec VSS, snapper, Timeshift, ZFS) sans action de création |
| Tâches planifiées ↔ Sécurité | Tâches liste toutes les tâches et signale les suspectes (`TSK-SUSPICIOUS`) ; Sécurité garde sa persistance suspecte (`SEC-PERSISTENCE-SUSPECT`) : recouvrement assumé |
| Impression ↔ Maintenance / Matériel | Impression lit (imprimantes, files, scanners, Bluetooth appairé) et imprime une page de test ; vider la file reste dans Maintenance ; Matériel garde USB et Bluetooth connecté |
| Créer / supprimer une tâche, modifier BCD / GRUB | Niveau X, non proposé |
| Conteneurs | Variables d'environnement, étiquettes et journaux jamais exposés (secrets fréquents) ; seul le projet compose est repris |
| Variables d'environnement | Valeurs masquées quand le nom évoque un secret (token, secret, password, key, auth, session…) ; identifiants d'URL masqués |

### Décisions S7 (2026-10-24)

| Sujet | Décision |
|---|---|
| Fonctions hors module (§3.9) | Trois modules d'agrégation (Inventaire, Rapports, Diagnostic guidé) qui lisent les autres par le pont `SysInfo.Host.ModuleHost` (mêmes runspaces que les pages et le MCP, lectures seulement) ; seuls dans pwsh, ils importent les autres modules. Contrat : `PROJECT_CONTEXT.md` §4.7 |
| Rapport client (§3.11) | HTML autonome imprimable (PDF par le navigateur), logo `Documents/SysInfo/logo.png` / `.svg` s'il existe, sinon « JUSTWARE » en texte ; actions tirées du journal d'audit ; avant / après par instantané. Pas d'envoi vers Justware Interventions tant que son format est inconnu |
| Instantanés | L (fichiers de SysInfo seulement, `snapshots/`, JSON compressé) ; exports, rapport client et étiquette : A (fichier dans Documents/SysInfo/Exports) |
| Score de santé | 100 − 20 par critique − 8 par attention − infos (10 au plus), par domaine ; global = moyenne des domaines |
| QR code | Encodeur intégré (`Native/QrCode.cs`, pas de NuGet), validé par un décodeur indépendant |
| Rapports planifiés | Reportés : créer une tâche planifiée est X (S6) et demanderait un mode sans fenêtre |

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
