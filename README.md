# PrintPlexServer

Transformation de l'app macOS **PrintPlex** en architecture serveur + clients, sur le modèle de Plex :
un serveur possède la bibliothèque de fichiers 3D (scan, parsing, vignettes, estimations, Shopify) et
l'expose via une API REST ; les apps macOS/iOS et une interface web deviennent des clients légers.

## État d'avancement

- [x] **Phase 1 — `PrintPlexCore`** : extraction du cœur métier de l'app macOS en package SwiftPM
      portable (macOS + Linux), découplé de SwiftData, SwiftUI et AppKit.
- [x] **Phase 2 — Serveur** : exécutable Vapor (`PrintPlexServerApp`) : scan + SQLite (Fluent) +
      API REST + SSE + vignettes, conteneurisé via docker-compose.
- [ ] **Phase 3 — Client macOS** : l'app existante consomme l'API au lieu de scanner localement.
- [ ] **Phase 4 — iOS & web**.

## API du serveur

| Méthode | Route | Description |
|---|---|---|
| GET | `/health` | Sonde de vie (utilisée par le healthcheck Docker) |
| GET | `/api/projects` | Liste des projets (triés par dernière modification) |
| GET | `/api/projects/:id` | Détail d'un projet avec ses fichiers |
| PATCH | `/api/projects/:id` | Met à jour les métadonnées (DB **et** `info.json` — la bibliothèque reste la source de vérité) |
| GET | `/api/projects/:id/estimate` | Estimation agrégée des pièces 3MF parsées |
| GET | `/api/projects/:id/shopify` | Produit Shopify correspondant (ID explicite ou match par nom) |
| GET | `/api/files/unsorted` | Fichiers orphelins (hors projet) |
| GET | `/api/files/:id` | Détail d'un fichier |
| GET | `/api/files/:id/download` | Téléchargement (chemin validé sous la racine bibliothèque) |
| GET | `/api/files/:id/thumbnail` | Vignette : image servie telle quelle, ou PNG embarqué du .3mf (extrait + mis en cache) |
| GET | `/api/files/:id/estimate` | Estimation d'impression (`?printerId=&materialId=&layerHeightMM=&infillPercent=&shellCount=&manualWork=`) |
| POST | `/api/scan` | Déclenche un scan (`?wait=true` pour bloquer jusqu'à la fin) |
| GET | `/api/scan/status` | État du scan + compteurs |
| GET | `/api/scan/events` | **SSE** : progression du scan en temps réel |
| GET | `/api/printers` · `/api/materials` | Référentiels pour les estimations (profils par défaut) |
| GET/POST | `/api/shopify/products` · `/api/shopify/sync` | Cache produits Shopify côté serveur |

Le serveur scanne au démarrage puis rescanne périodiquement (`PRINTPLEX_SCAN_INTERVAL_MIN`,
défaut 15 min, 0 pour désactiver). Les `.3mf` nouveaux ou modifiés passent ensuite au parsing de
maillage (volume, surface, bounding box) pour alimenter les estimations.

### Variables d'environnement

`PRINTPLEX_LIBRARY_PATH`, `PRINTPLEX_DATA_PATH` (SQLite + cache vignettes),
`PRINTPLEX_SCAN_INTERVAL_MIN`, `PRINTPLEX_HOSTNAME`, `PRINTPLEX_PORT`,
`SHOPIFY_STORE_DOMAIN`, `SHOPIFY_ACCESS_TOKEN`, `PRINTPLEX_DB_IN_MEMORY` (tests).

### Lancer

```bash
# En local
PRINTPLEX_LIBRARY_PATH=~/Ma/Bibliotheque swift run PrintPlexServerApp

# En Docker
PRINTPLEX_LIBRARY=/chemin/vers/bibliotheque docker compose up -d --build
```

## Contenu du package

| Module | Origine (app macOS) | Adaptation |
|---|---|---|
| `ThreeMFParser` | `ThreeMFParser.swift` | `import zlib` → target système `CZlib` (portable Linux) ; ajout de `parse(data:)` |
| `PrintEstimator` | `PrintEstimator.swift` | `PrinterStore` (UserDefaults/@Observable) laissé côté client ; types rendus `Codable`/`Sendable` |
| `ShopifyClient` | `ShopifyService.swift` | Stateless : plus de `@Observable`/`@MainActor`/UserDefaults ; credentials injectés ; matching découplé de `PrintProject` |
| `LibraryScanner` | `ScannerService.swift` | Découplé de SwiftData : le consommateur fournit les chemins connus et consomme un `AsyncStream<ScanEvent>` ; iCloud isolé derrière `#if os(macOS)` |
| `CoreTypes` / `DTOs` | `Models.swift` | Les `@Model` SwiftData deviennent des structs `Codable` — futur format d'échange de l'API |

Correctif apporté au passage : les chemins de fichiers sont désormais standardisés
(`standardizedFileURL`) de façon cohérente, sinon l'association fichier → projet échouait quand la
racine de la bibliothèque est atteinte via un symlink (`/var` → `/private/var`…).

Resté dans l'app (spécifique macOS, à remplacer côté serveur en phase 2) : `ThumbnailCache`
(QuickLook/AppKit), `FileSystemMonitor` (FSEvents), `FolderAccess` (security-scoped bookmarks),
`ScanCoordinator` et `BulkEstimationService` (orchestration SwiftData).

## Build & tests

```bash
swift build
swift test
```

Sous Linux (Docker), prévoir `libz` (présent dans les images `swift:` officielles) :

```bash
docker run --rm -v "$PWD:/src" -w /src swift:6.0 swift test
```

> Portabilité Linux : imports conditionnels `FoundationXML` (XMLParser) et `FoundationNetworking`
> (URLSession, avec shim async), `swift-crypto` à la place de CryptoKit, zlib via module map.
> Compilé et testé sur macOS ; la compilation Linux reste à valider dès qu'un démon Docker est
> disponible.

## Décision structurante à venir (phase 2)

Le serveur Docker n'a pas accès à iCloud Drive : la bibliothèque devra vivre sur un volume
accessible au conteneur (disque local, NAS…). Le champ `CloudStatus` est conservé dans les modèles
pour le client macOS.
