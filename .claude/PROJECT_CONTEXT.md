# SysInfo — Contexte projet pour assistants IA

> Ce fichier sert de référence à toute IA qui travaille sur le projet.
> Le lire en entier avant de proposer du code.

---

## 1. Le projet en bref

**SysInfo** est un logiciel d'information système personnel et étendu, dans l'esprit du Gestionnaire des tâches de Windows, mais plus riche et extensible.

- **Multiplateforme** : Windows et Linux (même code, même rendu).
- **Modulaire** : chaque catégorie d'information (CPU, RAM, disques, réseau, processus…) est un **module PowerShell** indépendant.
- **Navigation par onglets** : une barre latérale liste les modules ; chaque module = un onglet affiché automatiquement.
- **Ajout sans toucher au C#** : déposer un nouveau dossier de module suffit pour qu'un nouvel onglet apparaisse.

---

## 2. Stack technique

| Élément | Choix |
|---|---|
| Runtime | .NET 10 |
| Interface | Avalonia (XAML `.axaml`), dernière version stable |
| Pattern | MVVM avec CommunityToolkit.Mvvm (`[ObservableProperty]`, `[RelayCommand]`) |
| Collecte | Modules PowerShell (`.psm1`) exécutés via `Microsoft.PowerShell.SDK` |
| Éditeurs | VS Code (Linux) et Visual Studio (Windows) |
| Distribution | `dotnet publish --self-contained` par OS (pas de single-file) |

---

## 3. Architecture

```
SysInfo/
├─ Program.cs, App.axaml           → démarrage, thème global
├─ Views/
│   ├─ MainWindow.axaml            → barre latérale + zone de contenu
│   └─ Sections/                   → rendus génériques (KeyValue, Table, Metric)
├─ ViewModels/
│   ├─ MainWindowViewModel.cs      → liste des onglets, onglet actif
│   └─ ModuleTabViewModel.cs       → un onglet = un module (données, rafraîchissement)
├─ Services/
│   ├─ PowerShellService.cs        → exécution PowerShell (runspace réutilisé)
│   └─ ModuleLoader.cs             → découverte et chargement des modules
├─ Models/
│   ├─ ModuleManifest.cs           → lecture de module.json
│   └─ Section.cs                  → types de sections affichables
├─ Modules/                        → UN DOSSIER PAR MODULE
│   ├─ CPU/
│   │   ├─ module.json
│   │   └─ CPU.psm1
│   └─ Memory/
│       ├─ module.json
│       └─ Memory.psm1
└─ ai/                             → documentation pour les IA (ce fichier)
```

**Flux :** `ModuleLoader` scanne `Modules/` → crée un `ModuleTabViewModel` par module compatible avec l'OS → l'onglet appelle `PowerShellService` → le psm1 renvoie des objets normalisés → la View les affiche via des DataTemplates génériques.

Le dossier `Modules/` est copié à côté de l'exécutable (`CopyToOutputDirectory="PreserveNewest"` dans le `.csproj`).

---

## 4. Contrat d'un module (à respecter strictement)

### 4.1 `module.json`

```json
{
  "id": "cpu",
  "title": "Processeur",
  "icon": "cpu",
  "order": 10,
  "refreshSeconds": 2,
  "platforms": ["windows", "linux"],
  "requiresAdmin": false
}
```

| Champ | Rôle |
|---|---|
| `id` | identifiant unique, minuscules, sans espace |
| `title` | nom affiché dans l'onglet (en français) |
| `icon` | nom d'icône interne |
| `order` | position dans la barre latérale (croissant) |
| `refreshSeconds` | intervalle de rafraîchissement ; `0` = manuel uniquement |
| `platforms` | OS supportés : `windows`, `linux` |
| `requiresAdmin` | `true` si des droits élevés sont nécessaires |

### 4.2 Le `.psm1`

Chaque module expose **une seule fonction publique** : `Get-ModuleData`.

- Elle gère elle-même les différences d'OS avec `$IsWindows` / `$IsLinux`.
- Elle **retourne des objets**, jamais de texte formaté : pas de `Write-Host`, pas de `Format-Table`.
- Elle ne demande aucune interaction (pas de `Read-Host`, pas de confirmation).
- Elle doit être rapide (< 500 ms visé) ; ce qui est lent va dans une section à rafraîchissement manuel.
- En cas d'échec partiel, elle renvoie ce qu'elle peut et signale l'erreur dans une section, sans tout faire planter.

### 4.3 Format de retour

```powershell
function Get-ModuleData {
    [PSCustomObject]@{
        Sections = @(
            [PSCustomObject]@{
                Title = 'Général'
                Type  = 'KeyValue'
                Items = [ordered]@{ Modèle = '...'; Cœurs = 8; Fréquence = '3.6 GHz' }
            }
            [PSCustomObject]@{
                Title = 'Utilisation'
                Type  = 'Metric'
                Value = 42
                Unit  = '%'
                Max   = 100
                Warning  = 75   # facultatif : seuil Attention (même unité que Value)
                Critical = 90   # facultatif : seuil Critique
            }
            [PSCustomObject]@{
                Title   = 'Par cœur'
                Type    = 'Table'
                Columns = @('Cœur', 'Usage %')
                Rows    = @( @(0, 35), @(1, 48) )
            }
        )
    }
}
Export-ModuleMember -Function Get-ModuleData
```

**Types de sections supportés :**

| Type | Usage | Rendu |
|---|---|---|
| `KeyValue` | infos fixes (modèle, version, uptime) | liste clé → valeur |
| `Metric` | valeur numérique qui évolue | jauge + graphique d'historique |
| `Table` | listes (processus, disques, interfaces) | tableau triable |

Un nouveau type de section = modification du C# (Model + DataTemplate). Ne pas en inventer côté PowerShell sans l'ajouter côté interface.

**Seuils d'une `Metric`** (facultatifs, ajoutés au contrat le 2026-10-22) : `Warning` et `Critical`, dans la même unité que `Value`. Au-delà, la jauge et l'historique prennent la couleur d'état, un badge « Attention » / « Critique » s'affiche, et l'onglet du module porte l'état le plus grave de ses Metric. Sans seuils, aucune couleur d'état. Seuils par défaut conseillés : CPU 75 / 90 %, remplissage disque 85 / 95 %, température 80 / 90 °C.

**`Table`** : `Columns` (libellés) et `Rows` (un tableau de valeurs par ligne, dans l'ordre des colonnes). Une colonne dont toutes les valeurs sont des nombres est alignée à droite, en mono, et formatée à la française ; renvoyer des **nombres**, pas des chaînes déjà formatées, pour qu'elle trie correctement.

---

## 5. Règles côté C# / Avalonia

- Bindings compilés : toujours `x:DataType` sur les vues.
- Aucun appel PowerShell sur le thread UI : tout passe par `Task.Run` / async.
- Réutiliser un runspace par module plutôt que d'en recréer un à chaque rafraîchissement.
- Seul l'**onglet actif** se rafraîchit automatiquement ; les autres sont en pause.
- Un module qui plante n'affecte jamais les autres : erreur affichée dans son onglet uniquement.
- `ExecutionPolicy = Bypass` dans l'`InitialSessionState` (sinon blocage sous Windows).
- Nommage du code en anglais, textes de l'interface en français.

---

## 6. Interface

- Disposition type Gestionnaire des tâches : **barre latérale** d'onglets à gauche, contenu à droite.
- Design **sobre et soigné** : peu de couleurs, une couleur d'accent, typographie nette, espacements cohérents.
- Éviter l'esthétique générique « template » : pas de dégradés gratuits, pas d'ombres partout, pas d'icônes décoratives inutiles.
- Thème clair et sombre.
- Les graphiques `Metric` gardent un historique court (ex. 60 points).

---

## 7. Ajouter un module (checklist)

1. Créer `Modules/<Nom>/`.
2. Ajouter `module.json` avec un `id` unique.
3. Écrire `<Nom>.psm1` avec `Get-ModuleData` au format de la section 4.3.
4. Tester le module seul dans `pwsh` :
   ```powershell
   Import-Module ./Modules/<Nom>/<Nom>.psm1 -Force
   Get-ModuleData | ConvertTo-Json -Depth 5
   ```
5. Lancer l'app : l'onglet apparaît automatiquement.

---

## 8. Consignes pour l'IA

- Réponses **courtes et directes**, en français.
- En cas d'ambiguïté, **poser une question courte** plutôt que supposer.
- Respecter le contrat de module (section 4) ; tout changement de contrat doit être signalé explicitement.
- Toujours préciser **quel fichier** modifier et donner le code complet du passage concerné.
- Penser systématiquement **Windows ET Linux** : indiquer la source utilisée sur chaque OS (CIM/WMI vs `/proc`, `/sys`, commandes système).
- Ne pas ajouter de dépendance NuGet ou de module PowerShell externe sans le justifier.

---

## 9. Idées de modules

CPU · Mémoire · Disques · Réseau · Processus · Services · GPU · Températures/capteurs · Batterie · Système (OS, uptime, noyau) · Démarrage · Utilisateurs connectés · Logiciels installés.
