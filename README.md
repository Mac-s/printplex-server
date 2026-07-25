# PrintPlexServer

Transformation de l'app macOS **PrintPlex** en architecture serveur + clients, sur le modèle de Plex :
un serveur possède la bibliothèque de fichiers 3D (scan, parsing, vignettes, estimations, Shopify) et
l'expose via une API REST ; les apps macOS/iOS et une interface web deviennent des clients légers.

## État d'avancement

- [x] **Phase 1 — `PrintPlexCore`** : extraction du cœur métier de l'app macOS en package SwiftPM
      portable (macOS + Linux), découplé de SwiftData, SwiftUI et AppKit.
- [x] **Phase 2 — Serveur** : exécutable Vapor (`PrintPlexServerApp`) : scan + SQLite (Fluent) +
      API REST + SSE + vignettes, conteneurisé via docker-compose.
- [x] **Dashboard de test** (`Public/`) : mini SPA vanilla JS servie par le serveur lui-même, pour
      valider les fonctionnalités sans attendre le client macOS. Inclut un menu **Réglages** complet
      (Bibliothèque, Matériel, Shopify, À propos) qui reprend tous les onglets de `SettingsView.swift`
      côté macOS, et une interface façon Plex : sidebar de filtres (catégories, tags, matériaux,
      créateurs, types 3D, statut Shopify, "à faire") + grille de projets avec visuels, qui reprend
      `ContentView.swift`/`ProjectCardView.swift` côté macOS.
- [x] **Bibliothèques façon Plex** : un seul point de montage Docker générique
      (`PRINTPLEX_MEDIA_PATH`), et les dossiers à scanner ("bibliothèques") se configurent ensuite
      depuis Réglages → Bibliothèque, avec un vrai navigateur de dossiers — exactement le modèle Plex.
- [ ] **Phase 3 — Client macOS** : l'app existante consomme l'API au lieu de scanner localement.
- [ ] **Phase 4 — iOS & web** (probablement une évolution de ce dashboard).

## Dashboard de test (`Public/`)

Servi directement par Vapor à la racine (`/`) via `FileMiddleware` — aucune étape de build, ça
marche identiquement en local et dans Docker. Permet de :

- voir la liste des projets et lancer un scan avec suivi en direct (SSE) ;
- une vue de détail de projet qui reprend `ProjectDetailView.swift` côté macOS section par section
  (voir plus bas) ;
- télécharger un fichier ou voir sa vignette (image, ou PNG extrait du .3mf) ;
- **Réglages** (bouton ⚙️ dans la barre du haut) — mirroir web du `SettingsView.swift` macOS :
  - *Bibliothèque* : chemins bibliothèque/données (informatifs), scan automatique on/off + intervalle
    (persisté, pris en compte par la boucle de scan sans redémarrage), bouton "Scanner maintenant".
    La surveillance FSEvents apparaît grisée avec une note — elle n'a pas d'équivalent serveur/Linux,
    remplacée par le scan périodique.
  - *Matériel* : imprimantes (ajout/édition/suppression, mêmes champs que `PrinterFormSheet`) et
    matériaux (prix par kg éditable, catalogue fixe — comme dans l'app).
  - *Shopify* : domaine + token (persistés en base, plus seulement des variables d'environnement),
    synchronisation, compteur de produits.
  - *À propos* : version du serveur, chemin de la bibliothèque.

Les imprimantes/matériaux, autrefois figés dans `PrinterProfile.defaults`/`PrintMaterial.defaults`,
sont maintenant des tables SQLite (`PrinterModel`/`MaterialModel`), seedées une fois depuis ces
mêmes défauts puis pleinement éditables via l'API. Idem pour le scan et Shopify
(`AppSettingsModel`, ligne singleton) — les variables d'environnement ne servent plus qu'à
initialiser ces valeurs au tout premier démarrage.

### Interface façon Plex (sidebar + grille)

Reprend `ContentView.swift`/`ProjectCardView.swift` de l'app macOS :

- **Sidebar de filtres** : Bibliothèque (Tous les projets / À faire), Shopify (par statut, une fois
  synchronisé au moins une fois), Types 3D (STL/3MF/OBJ/STEP), Categories/Tags/Materiaux/Createurs —
  sélection multiple avec logique de narrowing (ne montre que les valeurs encore atteignables une
  fois une sélection faite) et compteurs, exactement comme `visibleTags`/`visibleCategories`/etc. côté
  macOS. Categories/Materiaux/Createurs ont un menu contextuel (clic droit) Renommer/Supprimer qui
  applique le changement à tous les projets concernés (PATCH individuel par projet, comme
  `applyRename`/`deleteCategory` côté macOS).
- **Grille de projets** : cartes avec image de couverture (calculée côté serveur — voir plus bas),
  badge de statut Shopify, tags, compteur pièces/fichiers, date relative. Bannière "À trier"
  (fichiers non classés) et rangée "Ajouté récemment" en haut de la vue "Tous les projets". La vue
  "À faire" superpose des chips oranges sur les projets aux métadonnées incomplètes.
- La recherche (barre du haut) filtre la grille quel que soit le filtre actif, comme `.searchable`
  côté macOS.

Pour que la grille n'ait pas besoin de charger le détail de chaque projet, `GET /api/projects`
précalcule `coverFileId`/`partsCount`/`totalFileCount`/`imageCount` côté serveur (une seule requête
groupée sur tous les fichiers, pas une par projet). Le "Types 3D" s'appuie sur `GET /api/files`
(filtrable par `?kind=`) et `GET /api/files/stats` (compteurs agrégés par type).

### Vue de détail (reprend `ProjectDetailView.swift` section par section)

Rebâtie pour reproduire la vue macOS à l'identique plutôt qu'un simple formulaire :

- **En-tête éditable** : nom/description avec sauvegarde automatique (debounce 600ms + flush au
  blur, comme `scheduleSave()`/`persistTextFields()` côté macOS), rangée de stats (pièces/fichiers/
  taille/date relative).
- **Galerie d'images** : bande horizontale en ratio naturel (pas de recadrage), image de couverture
  marquée d'une étoile, menu contextuel (clic droit) "Définir comme image principale" qui persiste
  via le `coverImageFileName` déjà supporté par `PATCH /api/projects/:id`.
- **Métadonnées** : créateur/catégorie avec autocomplétion (dérivée des projets déjà chargés
  côté client, pas de nouvel endpoint), chips matériaux/tags éditables (ajout/suppression + suggestions).
- **Actions** — équivalents web honnêtes des trois fonctionnalités impossibles dans un navigateur :
  copie du chemin du dossier dans le presse-papiers (au lieu de "Révéler dans le Finder"), menu de
  téléchargement des pièces (au lieu du lancement direct d'un slicer natif), et un vrai visualiseur 3D
  (voir plus bas) au lieu de SceneKit.
- **Shopify riche** : correspondance affichée (pastille de statut, titre, prix, lien "Voir" vers la
  fiche boutique), assignation manuelle du produit (`<select>` avec tous les produits synchronisés +
  "Auto (par nom)"), bouton de resynchronisation.
- **Estimation par fichier** : la section liste **tous** les fichiers `.3mf` du projet (kind
  `threeMF`), même ceux qu'un scan n'a pas encore réussi à parser (`meshStats` absent) — ils
  apparaissent avec la mention "pas de statistiques" plutôt que de disparaître silencieusement.
  Contrairement à l'ancien formulaire (un seul calcul agrégé côté serveur), `PrintEstimator.swift`
  a été **porté fidèlement en JS** (`estimatePrint()`/`totalEstimate()` dans `Public/app.js`) et
  tourne entièrement côté client à partir des `meshStats`/`plateStats` déjà chargés — changer
  d'imprimante/matériau/fichier/plateau/niveau de manutention recalcule instantanément, sans
  aller-retour réseau, exactement comme les vues SwiftUI réactives de l'app macOS. Le niveau de
  manutention par fichier (`aucun`/`easy`/`medium`/`hard`) se persiste via un endpoint
  `PATCH /api/files/:id` (`FileUpdateRequest.manualWorkLevel`, stocké dans `printParams`).
- **Fichiers .3mf multi-plateaux (BambuStudio)** : `ThreeMFParser.parseAllPlates()` parse
  **chaque plateau séparément** (`Metadata/model_settings.config` → objets par plateau →
  `3D/3dmodel.model` résout les `<component>` vers leurs fichiers géométrie sous `3D/Objects/`) —
  jamais fusionnés, pour ne pas gonfler artificiellement poids/temps/coût d'un plateau avec la
  géométrie des autres. `parse()`/`parse(data:)` restent des raccourcis qui ne renvoient que le
  plateau 0, pour ne rien casser côté appelants existants. Le scan met en cache `meshStats`
  (plateau 0, comme avant) et un nouveau `plateStats: [MeshStatsDTO]?` (tous les plateaux,
  seulement rempli si `plateCount > 1`) sur `FileModel`/`FileDTO`. Quand un fichier a plusieurs
  plateaux détectés, sa carte d'estimation affiche un sélecteur "Plateau 1/2/3…" — changer de
  plateau recalcule instantanément (toujours côté client, aucun aller-retour réseau).
  `GET /api/files/:id/estimate` accepte aussi `?plateIndex=N` pour les clients qui préfèrent
  laisser le serveur calculer (l'agrégat `GET /api/projects/:id/estimate` reste plateau 0 par
  fichier, inchangé — pas de bon moyen d'exprimer "un plateau différent par fichier" dans un seul
  paramètre de requête, et le dashboard web ne l'utilise plus de toute façon depuis le calcul
  client-side).
- **Fichiers groupés par rôle** : `modelPart` → `slicerConfig` → `document` → `other`, même ordre que
  `roleDisplayOrder` côté macOS (les images sont exclues de cette liste, déjà montrées dans la galerie).

#### Visualiseur 3D (`Public/viewer.js`)

Remplace la prévisualisation SceneKit par un rendu WebGL maison, sans dépendance externe (pas de
Three.js, pas de CDN) :

- **STL** (binaire détecté via la taille de fichier attendue `84 + n×50`, sinon ASCII via regex) et
  **OBJ** (`v`/`f`, triangulation en éventail) parsés directement.
- **3MF** : un lecteur ZIP minimal (`v3dUnzip`) gère les entrées *stored* et *deflate* — le deflate
  passe par l'API native `DecompressionStream('deflate-raw')` du navigateur, donc aucune librairie
  d'inflate n'est nécessaire. Le XML `3D/3dmodel.model` est ensuite parsé au `DOMParser`, en ignorant
  la logique multi-plateau (juste un rendu visuel, pas une donnée d'estimation).
- Rendu : shaders WebGL1 minimalistes (une lumière directionnelle), petites fonctions matricielles
  maison (pas de gl-matrix), orbite à la souris + zoom à la molette — équivalent de
  `allowsCameraControl` de SceneKit. Formats non supportés (STEP) → message "Aperçu non disponible".

### Bibliothèques façon Plex

Avant : un seul `PRINTPLEX_LIBRARY_PATH` fixé au démarrage du conteneur. Maintenant : le conteneur
monte un seul répertoire média générique (`PRINTPLEX_MEDIA_PATH`, ex. `/media`), et les dossiers à
scanner ("bibliothèques") se configurent au runtime depuis **Réglages → Bibliothèque**, avec un
navigateur de dossiers (fil d'Ariane cliquable) mirroir de la boîte de dialogue "Ajouter une
bibliothèque" de Plex.

- `LibraryModel`/`LibraryDTO` : `{ id, name, relativePath, dateAdded }` — `relativePath` est
  toujours relatif à `mediaPath`, jamais un chemin absolu, pour que la config reste portable si le
  point de montage change d'hôte. `relativePath: ""` veut dire "toute la racine média = une seule
  bibliothèque" (cas le plus simple, équivalent à l'ancien comportement à bibliothèque unique).
- Aucune bibliothèque configurée = aucun scan, comme un Plex fraîchement installé. Ajouter une
  bibliothèque déclenche un scan automatique en arrière-plan (priorité `.background`).
- `ScanService.performScan()` boucle sur toutes les bibliothèques configurées et accumule leurs
  résultats avant la passe de nettoyage (fichiers/projets qui ont disparu) — donc **retirer une
  bibliothèque** suffit à faire disparaître ses projets de l'index au scan suivant, sans action
  supplémentaire : ils ne sont simplement plus jamais "vus".
- Plusieurs disques/emplacements séparés ? Chaque bibliothèque doit rester **sous** le répertoire
  média (validé côté serveur, même logique que `FileController.safePath`) — montez-les à des
  sous-chemins différents sous `/media` plutôt qu'ailleurs (voir `docker-compose.yml`).

Un bug de concurrence a été détecté et corrigé au passage, dans `ScanService` : `runScan()` faisait
« rejoindre » un scan déjà en cours plutôt que d'en relancer un nouveau — correct pour éviter le
travail redondant, mais si une requête arrive *pendant* le scan (ex. une deuxième bibliothèque tout
juste ajoutée), elle rejoignait une passe qui avait déjà lu l'ancienne liste de bibliothèques et ne
la reflétait donc jamais. Corrigé avec un flag `rescanRequested` : toute requête arrivant en cours de
scan est désormais garantie d'obtenir au moins une passe complète qui relit l'état à jour après son
arrivée, avant de rendre la main. Un deuxième bug apparenté (race sur la remise à zéro de l'état
"scan en cours", visible uniquement en environnement de test) a aussi été corrigé : le nettoyage se
fait maintenant *à l'intérieur* du corps de la tâche de scan elle-même, jamais après coup côté
appelant, pour éliminer toute dépendance à l'ordre de reprise des continuations concurrentes.

### Deux bugs pré-existants corrigés au passage

1. **`updateProjectInfo` ne pouvait pas effacer un champ.** La fusion du dictionnaire JSON passait
   par `JSONEncoder`, qui *omet* silencieusement les propriétés optionnelles à `nil` (via
   `encodeIfPresent`) au lieu de les encoder en `null` — donc remettre un champ à `nil` dans le
   closure ne se répercutait jamais sur `info.json`, l'ancienne valeur restait indéfiniment. Corrigé
   dans `LibraryScanner.updateProjectInfo` en construisant le dictionnaire de fusion champ par champ
   plutôt qu'en round-trippant par l'encodeur. Ce bug existait déjà dans `ScannerService.swift` côté
   app macOS (même logique).
2. **`String?` ne peut pas distinguer "champ omis" de "champ explicitement vidé" en JSON** — les deux
   décodent en `nil`. Convention adoptée pour `category`/`creator` dans `PATCH /api/projects/:id` :
   une chaîne vide (`""`) signifie "effacer ce champ" (c'est ce qu'envoie le "Supprimer" du menu
   contextuel). Les tableaux (`tags`, `suggestedMaterials`) n'ont pas ce problème, un tableau vide
   `[]` est déjà sans ambiguïté.

### Le scan bloquait l'interface (vues de détail bloquées sur "Chargement")

Cause : le driver Fluent SQLite ouvre **une connexion par event loop** — un scan et une requête de
lecture finissent presque toujours sur des connexions physiques différentes. Sans mode WAL, le
journal par défaut de SQLite (rollback journal) pose un verrou sur le fichier entier à chaque
transaction d'écriture ; un scan qui enchaîne des centaines de `save()` séquentiels affamait donc
toute lecture pendant toute sa durée. C'est exactement ce qui faisait rester les vues de détail
bloquées sur "Chargement" tant qu'un scan tournait.

Corrigé dans `configure.swift` en activant `PRAGMA journal_mode=WAL` (les lecteurs travaillent sur un
instantané cohérent sans jamais être bloqués par un écrivain actif) + `PRAGMA busy_timeout=5000` en
filet de sécurité pour le cas plus rare écrivain-contre-écrivain. En complément, tout le travail de
scan tourne maintenant à la priorité Swift Concurrency la plus basse (`.background`) — parcours du
système de fichiers (`LibraryScanner.scan`), boucle périodique et déclenchement manuel non-bloquant
(`configure.swift`, `ScanController.swift`), et parsing des maillages 3MF (`ScanService.swift`) — pour
que ce travail cède la main aux threads du pool coopératif dès que l'interface en a besoin. Seul le
scan explicitement bloquant (`POST /api/scan?wait=true`, utilisé par les tests) garde une priorité
normale, puisque l'appelant demande justement à attendre le résultat.

Validé avec une bibliothèque de test de 800 projets (scan de plusieurs secondes) : 20 requêtes de
détail lancées pendant que `isScanning: true` répondent toutes en 69–136 ms, aussi bien en `curl`
qu'en `fetch()` réel depuis la page.

⚠️ Point d'attention côté client à retenir : `PrintEstimate.formattedTime`, `.formattedWeight`,
`.totalCostEur`, etc. sont des **propriétés calculées** côté Swift — la synthèse `Codable` ne les
sérialise pas, elles n'existent donc pas dans le JSON. Le dashboard recalcule ces valeurs en JS à
partir des champs bruts (`printTimeSeconds`, `filamentWeightG`…) ; **tout futur client (macOS, iOS)
devra faire pareil**, ou alors il faudra ajouter un `CodingKeys`/DTO explicite côté serveur qui les
inclut.

## API du serveur

| Méthode | Route | Description |
|---|---|---|
| GET | `/health` | Sonde de vie (utilisée par le healthcheck Docker) |
| GET | `/api/projects` | Liste des projets (triés par dernière modification) |
| GET | `/api/projects/:id` | Détail d'un projet avec ses fichiers |
| PATCH | `/api/projects/:id` | Met à jour les métadonnées (DB **et** `info.json` — la bibliothèque reste la source de vérité) |
| GET | `/api/projects/:id/estimate` | Estimation agrégée des pièces 3MF parsées |
| GET | `/api/projects/:id/shopify` | Produit Shopify correspondant (ID explicite ou match par nom) |
| GET | `/api/files` | Liste plate de tous les fichiers (filtrable par `?kind=stl\|threeMF\|obj\|step\|other`) |
| GET | `/api/files/unsorted` | Fichiers orphelins (hors projet) |
| GET | `/api/files/stats` | Compteurs par type + fichiers non triés, pour les badges de la sidebar |
| GET | `/api/files/:id` | Détail d'un fichier |
| GET | `/api/files/:id/download` | Téléchargement (chemin validé sous la racine bibliothèque) |
| GET | `/api/files/:id/thumbnail` | Vignette : image servie telle quelle, ou PNG embarqué du .3mf (extrait + mis en cache) |
| GET | `/api/files/:id/estimate` | Estimation d'impression (`?printerId=&materialId=&layerHeightMM=&infillPercent=&shellCount=&manualWork=`) |
| POST | `/api/scan` | Déclenche un scan (`?wait=true` pour bloquer jusqu'à la fin) |
| GET | `/api/scan/status` | État du scan + compteurs |
| GET | `/api/scan/events` | **SSE** : progression du scan en temps réel |
| GET/POST | `/api/printers` · PATCH/DELETE `/api/printers/:id` | CRUD imprimantes (seedées depuis les défauts, éditables) |
| GET | `/api/materials` · PATCH `/api/materials/:id` | Catalogue matériaux (prix/kg éditable, catalogue fixe) |
| GET/POST | `/api/shopify/products` · `/api/shopify/sync` | Cache produits Shopify côté serveur |
| GET | `/api/settings` | Vue d'ensemble des réglages (scan, Shopify, chemins) |
| PATCH | `/api/settings/scan` | Active/désactive le scan auto + intervalle (effectif sans redémarrage) |
| GET/PUT | `/api/settings/shopify` | Lecture/écriture des credentials Shopify (persistés en base) |
| GET/POST | `/api/libraries` · DELETE `/api/libraries/:id` | CRUD des bibliothèques (dossiers scannés) |
| GET | `/api/libraries/browse?path=` | Navigateur de dossiers sous le répertoire média, pour le picker |

Le serveur scanne au démarrage puis rescanne périodiquement (`PRINTPLEX_SCAN_INTERVAL_MIN`,
défaut 15 min, 0 pour désactiver). Les `.3mf` nouveaux ou modifiés passent ensuite au parsing de
maillage (volume, surface, bounding box) pour alimenter les estimations.

### Variables d'environnement

`PRINTPLEX_MEDIA_PATH` (point de montage générique — les bibliothèques elles-mêmes se configurent
depuis Réglages, pas par variable d'environnement), `PRINTPLEX_DATA_PATH` (SQLite + cache vignettes),
`PRINTPLEX_SCAN_INTERVAL_MIN` (valeur de seed initiale uniquement — éditable ensuite depuis
Réglages), `PRINTPLEX_HOSTNAME`, `PRINTPLEX_PORT`,
`SHOPIFY_STORE_DOMAIN`, `SHOPIFY_ACCESS_TOKEN` (seed initial, éditable ensuite depuis Réglages),
`PRINTPLEX_DB_IN_MEMORY` (tests).

### Lancer

```bash
# En local
PRINTPLEX_MEDIA_PATH=~/Mes/Fichiers3D swift run PrintPlexServerApp
# puis Réglages → Bibliothèque → + Ajouter, dans le dashboard web

# En Docker
PRINTPLEX_MEDIA=/chemin/vers/media docker compose up -d --build
```

## Déploiement sur un serveur Docker distant

`.github/workflows/docker-publish.yml` build et publie automatiquement l'image sur GitHub Container
Registry (`ghcr.io`) à chaque push sur `main`, en multi-architecture (`linux/amd64` + `linux/arm64`,
un job natif par architecture — un runner ARM64 hébergé par GitHub plutôt que l'émulation QEMU d'un
buildx multi-platform classique, qui a fait grimper le temps de build à plus de 3h rien que pour le
compilateur Swift). Le serveur cible n'a donc jamais besoin de compiler Swift lui-même : il se
contente d'un `docker compose pull`. Le repo et le paquet GHCR sont publics, donc aucun `docker login`
n'est nécessaire côté serveur distant.

Exemple d'intégration à une stack `docker-compose` existante, avec des chemins hôte explicites plutôt
que des volumes nommés Docker (plus simple à localiser/sauvegarder) :

```yaml
services:
  printplex:
    image: ghcr.io/mac-s/printplex-server:latest
    container_name: printplex-server
    restart: unless-stopped
    ports:
      - "8080:8080"
    volumes:
      - /chemin/vers/tes/fichiers-3d:/media
      - /chemin/vers/printplex-data:/data
    environment:
      PRINTPLEX_MEDIA_PATH: /media
      PRINTPLEX_DATA_PATH: /data
      PRINTPLEX_SCAN_INTERVAL_MIN: "15"
      # PUID/PGID (façon linuxserver.io) : évite d'avoir à chown/chmod les
      # dossiers ci-dessus sur l'hôte — voir "Utilisateur du conteneur" plus bas.
      PUID: "1000"
      PGID: "1000"
      # Optionnel — configurable aussi depuis Réglages → Shopify dans l'interface,
      # ces variables ne servent qu'à préremplir la toute première configuration :
      SHOPIFY_STORE_DOMAIN: ${SHOPIFY_STORE_DOMAIN:-}
      SHOPIFY_ACCESS_TOKEN: ${SHOPIFY_ACCESS_TOKEN:-}
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:8080/health"]
      interval: 30s
      timeout: 5s
      retries: 3
```

### Utilisateur du conteneur (PUID/PGID)

Le conteneur ne tourne pas en `root` — un utilisateur dédié (`printplex`) exécute le serveur. Sans
rien configurer, cet utilisateur a un UID fixe décidé à la construction de l'image, ce qui provoque
un `Permission denied` (et un crash au démarrage, volontaire — sans accès en écriture à `/data`, ni
la base SQLite ni le cache de vignettes ne peuvent fonctionner) si les dossiers montés sur `/media`/
`/data` appartiennent à un autre utilisateur sur l'hôte — le cas le plus courant étant que Docker les
crée automatiquement en `root` s'ils n'existaient pas avant le premier lancement.

`docker-entrypoint.sh` résout ça façon linuxserver.io : il démarre en `root`, réaligne l'UID/GID de
l'utilisateur `printplex` sur `PUID`/`PGID`, puis bascule dessus (via `gosu`) avant de lancer le
serveur — sans jamais toucher aux permissions des dossiers montés eux-mêmes. Mets simplement l'UID/GID
de l'utilisateur qui possède déjà `/media`/`/data` côté hôte (`id -u` / `id -g` sur ton propre compte
si c'est toi qui as créé ces dossiers) ; défaut `1000:1000` si non précisé (le premier utilisateur
standard sur la plupart des installations Debian/Ubuntu).

Mise à jour : `git push` sur `main` déclenche le build ; sur le serveur distant,
`docker compose pull && docker compose up -d`.

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

## Bug critique corrigé : crash serveur sur déconnexion SSE

`Response.Body.init(asyncStream:)` de Vapor exige que le closure appelle **toujours** `.end` ou
`.error` avant de se terminer — y compris quand le client se déconnecte en cours de route (rechargement
de page, fermeture d'onglet…), auquel cas `writer.write(...)` lève une erreur de pipe brisé. Si cette
erreur remonte sans être interceptée, ce n'est pas juste la requête qui échoue : c'est une assertion
fatale qui **tue tout le process serveur**. `ScanController.events()` (le flux SSE de progression du
scan) a été corrigé pour intercepter toute erreur et toujours écrire `.error(...)` en sortie de
closure. Reproduit et vérifié : plusieurs rechargements de page et déconnexions brutales de
`curl -N` ne font plus tomber le serveur.

## Décision structurante à venir (phase 2)

Le serveur Docker n'a pas accès à iCloud Drive : la bibliothèque devra vivre sur un volume
accessible au conteneur (disque local, NAS…). Le champ `CloudStatus` est conservé dans les modèles
pour le client macOS.
