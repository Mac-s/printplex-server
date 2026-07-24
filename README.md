# PrintPlexServer

Transformation de l'app macOS **PrintPlex** en architecture serveur + clients, sur le modèle de Plex :
un serveur possède la bibliothèque de fichiers 3D (scan, parsing, vignettes, estimations, Shopify) et
l'expose via une API REST ; les apps macOS/iOS et une interface web deviennent des clients légers.

## État d'avancement

- [x] **Phase 1 — `PrintPlexCore`** : extraction du cœur métier de l'app macOS en package SwiftPM
      portable (macOS + Linux), découplé de SwiftData, SwiftUI et AppKit.
- [ ] **Phase 2 — Serveur** : exécutable Vapor/Hummingbird (scan + SQLite + API REST + SSE + vignettes),
      conteneurisé via docker-compose.
- [ ] **Phase 3 — Client macOS** : l'app existante consomme l'API au lieu de scanner localement.
- [ ] **Phase 4 — iOS & web**.

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
