@.claude/PROJECT_CONTEXT.md

## Serveur MCP (important)

SysInfo expose ses données aux agents et IA via un **serveur MCP** (Model Context Protocol). C'est une interface au même titre que la fenêtre : à concevoir avec le même soin.

### Règles

- **SDK officiel** : NuGet `ModelContextProtocol` (C#). Pas de JSON-RPC écrit à la main.
- **Outils générés automatiquement** (modèle hybride, décidé le 2026-10-23) : chaque module chargé par `ModuleLoader` devient un outil `get_<id>` (vue d'ensemble = `Get-ModuleData`, mêmes données que l'onglet), et chaque fonction ciblée déclarée dans son `module.json` devient un outil `<id>_<name>` avec ses paramètres (contrat §4.4). Ajouter un module ou une fonction = de nouveaux outils, sans toucher au C#.
- **Même source que l'interface** : l'outil appelle la fonction PowerShell via `PowerShellService` (même runspace par module). Aucune logique de collecte propre au MCP.
- **Enveloppe standard** : chaque outil renvoie `{ module, function, platform, timestamp, durationMs, status, data: { Subtitle, Sections }, findings }` ; `status` = constat le plus grave (`ok`, `warning`, `critical`). Construite dans `Mcp/Envelope.cs`.
- **Description claire** : chaque outil a une description en anglais issue du `module.json`, car c'est elle qui permet à l'IA de choisir le bon outil. Les paramètres ont un schéma JSON (type, enum, bornes) ; un argument invalide ou inconnu renvoie une erreur d'outil.
- **Lecture seule** : seules les fonctions de niveau `L` sont exposées. Les niveaux `A` / `C` (actions) attendent le cadre de confirmation dans l'UI + audit (sprint S4) ; `X` n'est jamais exposé.
- **Données jamais exposées**, même en lecture : clés BitLocker, mots de passe, clés de licence complètes, hashes, fichiers utilisateurs, historique de navigation.
- **Mêmes filtres que l'UI** : modules non compatibles avec l'OS non exposés ; modules `requiresAdmin` renvoient une erreur claire si l'app n'est pas élevée.
- **Erreurs** : un module qui échoue renvoie une erreur d'outil MCP (`isError`) avec le message, sans faire tomber le serveur.
- **Transport stdio** : l'agent local (Claude Code, Claude Desktop…) lance `SysInfo --mcp` et dialogue via stdin/stdout. Rien d'autre que le protocole sur stdout ; tous les logs vont sur stderr. Pas de HTTP (`ModelContextProtocol.AspNetCore`) sans décision explicite.
- **Lancement** : `SysInfo --mcp` démarre le serveur **sans fenêtre** ; sans argument, l'app graphique se lance normalement.
- **Tester** chaque outil avec MCP Inspector : `npx @modelcontextprotocol/inspector dotnet run -- --mcp`.
