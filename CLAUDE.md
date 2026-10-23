@.claude/PROJECT_CONTEXT.md

## Serveur MCP (important)

SysInfo expose ses données aux agents et IA via un **serveur MCP** (Model Context Protocol). C'est une interface au même titre que la fenêtre : à concevoir avec le même soin.

### Règles

- **SDK officiel** : NuGet `ModelContextProtocol` (C#). Pas de JSON-RPC écrit à la main.
- **Outils générés automatiquement** (modèle hybride, décidé le 2026-10-23) : chaque module chargé par `ModuleLoader` devient un outil `get_<id>` (vue d'ensemble = `Get-ModuleData`, mêmes données que l'onglet), et chaque fonction ciblée déclarée dans son `module.json` devient un outil `<id>_<name>` avec ses paramètres (contrat §4.4). Ajouter un module ou une fonction = de nouveaux outils, sans toucher au C#.
- **Même source que l'interface** : l'outil appelle la fonction PowerShell via `PowerShellService` (même runspace par module). Aucune logique de collecte propre au MCP.
- **Enveloppe standard** : chaque outil renvoie `{ module, function, platform, timestamp, durationMs, status, data: { Subtitle, Sections }, findings }` ; `status` = constat le plus grave (`ok`, `warning`, `critical`). Une action ajoute `dryRun`, `changes` et éventuellement `blocked`, `undo` et `restorePoint` ; une tâche longue ajoute `jobId`. Construite dans `Mcp/Envelope.cs`.
- **Description claire** : chaque outil a une description en anglais issue du `module.json`, car c'est elle qui permet à l'IA de choisir le bon outil. Les paramètres ont un schéma JSON (type, enum, bornes) ; un argument invalide ou inconnu renvoie une erreur d'outil.
- **Actions confirmées** (décidé le 2026-10-23, S4a) : les fonctions `L` sont exposées librement ; les actions `A` le sont avec un argument `dryRun` (aperçu seul), et sans lui l'utilisateur confirme dans une fenêtre SysInfo (`SysInfo --confirm`, lancée par le serveur, refus par défaut et après 2 min) ; une action `Blocked` est refusée sans rien demander. Les actions `C` (S4b) exigent en plus `SysInfo --mcp` en administrateur (l'aperçu marche sans), un point de restauration créé avant et une case « J'ai lu l'aperçu » ; elles ne sont exposées que si l'utilisateur les active (`mcpCriticalActions`, désactivé par défaut). `X` n'est jamais exposé. Réglages : `mcpActions`, `mcpCriticalActions`, liste blanche `mcpDisabledTools`. Contrat : `PROJECT_CONTEXT.md` §4.5.
- **Audit** : chaque appel d'outil MCP (lectures comprises) et chaque action est écrit dans le journal JSONL (`Services/AuditLog.cs`), avec un `id` ; le module Audit le relit (`get_audit`, `audit_get_log`) et défait une action par son `undo` (`audit_undo`).
- **Tâches longues** (`"long": true`) : au-delà de 25 s, l'outil renvoie un `jobId` ; `job_status` (attente jusqu'à 55 s) et `job_cancel` (`Mcp/JobManager.cs`, `Mcp/JobTools.cs`).
- **Données jamais exposées**, même en lecture : clés BitLocker, mots de passe, clés de licence complètes, hashes, fichiers utilisateurs, historique de navigation.
- **Mêmes filtres que l'UI** : modules non compatibles avec l'OS non exposés ; modules `requiresAdmin` renvoient une erreur claire si l'app n'est pas élevée.
- **Erreurs** : un module qui échoue renvoie une erreur d'outil MCP (`isError`) avec le message, sans faire tomber le serveur.
- **Transport stdio** : l'agent local (Claude Code, Claude Desktop…) lance `SysInfo --mcp` et dialogue via stdin/stdout. Rien d'autre que le protocole sur stdout ; tous les logs vont sur stderr. Pas de HTTP (`ModelContextProtocol.AspNetCore`) sans décision explicite.
- **Lancement** : `SysInfo --mcp` démarre le serveur **sans fenêtre** ; sans argument, l'app graphique se lance normalement.
- **Tester** chaque outil avec MCP Inspector : `npx @modelcontextprotocol/inspector dotnet run -- --mcp`.
