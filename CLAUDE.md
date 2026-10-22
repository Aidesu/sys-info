@.claude/PROJECT_CONTEXT.md

## Serveur MCP (important)

SysInfo expose ses données aux agents et IA via un **serveur MCP** (Model Context Protocol). C'est une interface au même titre que la fenêtre : à concevoir avec le même soin.

### Règles

- **SDK officiel** : NuGet `ModelContextProtocol` (C#). Pas de JSON-RPC écrit à la main.
- **Un outil par module, généré automatiquement** : chaque module chargé par `ModuleLoader` devient un outil `get_<id>` (ex. `get_system`). Ajouter un module = un nouvel outil, sans toucher au C#.
- **Même source que l'interface** : l'outil appelle `Get-ModuleData` via `PowerShellService` et renvoie les `Sections` (contrat §4.3) en JSON. Aucune logique de collecte propre au MCP.
- **Description claire** : chaque outil a une description en anglais issue du `module.json` (titre + contenu), car c'est elle qui permet à l'IA de choisir le bon outil.
- **Lecture seule** : aucun outil qui modifie le système (tuer un processus, arrêter un service…) sans décision explicite.
- **Mêmes filtres que l'UI** : modules non compatibles avec l'OS non exposés ; modules `requiresAdmin` renvoient une erreur claire si l'app n'est pas élevée.
- **Erreurs** : un module qui échoue renvoie une erreur d'outil MCP (`isError`) avec le message, sans faire tomber le serveur.
- **Transport stdio** : l'agent local (Claude Code, Claude Desktop…) lance `SysInfo --mcp` et dialogue via stdin/stdout. Rien d'autre que le protocole sur stdout ; tous les logs vont sur stderr. Pas de HTTP (`ModelContextProtocol.AspNetCore`) sans décision explicite.
- **Lancement** : `SysInfo --mcp` démarre le serveur **sans fenêtre** ; sans argument, l'app graphique se lance normalement.
- **Tester** chaque outil avec MCP Inspector : `npx @modelcontextprotocol/inspector dotnet run -- --mcp`.
