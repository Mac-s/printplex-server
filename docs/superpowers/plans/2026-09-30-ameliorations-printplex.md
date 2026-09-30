# PrintPlex — améliorations à implémenter (plan du 30/09/2026)

Issu du bilan de bibliothèque du 30/09/2026 (285 projets, 11 264 fichiers, 141 Go).
Classé par ordre de valeur. Chaque point liste les fichiers à toucher et les critères d'acceptation.

---

## 1. Champ « Personnage » (priorité haute)

**Pourquoi.** 117 tags sur 245 ne servent qu'à un seul projet, et ce sont presque tous des personnages (Luigi, Marowak, Sally, Bane, Jean Grey…). Ils noient les tags transverses dans la liste de filtres. Un champ dédié les sort des tags et leur donne leur propre section.

**Modèle de données**
- `ProjectModel` : nouveau champ `characters: [String]` (même forme que `tags`), optionnel, par défaut `[]`.
- Migration `AddCharactersToProjects.swift`, sur le modèle de `AddSourceInfoToProjects.swift`.
- `info.json` : nouvelle clé `personnages`, miroir de `tags` (voir `LibraryScanner.updateProjectInfo`).

**API**
- `ProjectDTO` (PrintPlexCore/DTOs.swift) : exposer `characters`.
- `ProjectUpdateRequest` + `ProjectController.applyUpdate` : accepter `characters` (liste complète, remplace, comme `tags`).
- Tool MCP `update_project` et `get_project` (MCP/ProjectMCPTools.swift) : ajouter `characters`.

**Interface (Public/app.js)**
- Ajouter une entrée dans `FILTER_FIELDS` : clé `characters`, `multivalued: true`, libellé « Personnages ». La logique de facettes (`projectsMatchingOtherFilters`, `visibleFilterValues`, `countForCandidate`) est générique, elle suivra toute seule.
- `projectMatchesSearch` : inclure `characters` dans la recherche texte.
- Éditeur de projet : même widget que les tags, avec autocomplétion sur les personnages déjà utilisés.

**Migration des données existantes.** Une fois le champ en place, je peux déplacer les tags-personnages vers le nouveau champ depuis le MCP (environ 120 tags à répartir), avec une proposition à valider avant application, comme pour le ménage du 16/09.

**Critères d'acceptation**
- Un projet peut avoir 0..n personnages ; la valeur survit à un rescan (lue et réécrite dans `info.json`).
- La section « Personnages » apparaît dans le menu de gauche avec les mêmes compteurs que les autres filtres.
- La recherche texte trouve un projet par son personnage.

---

## 2. `list_projects` : filtres et pagination (priorité haute)

**Pourquoi.** Le tool renvoie les 285 projets d'un bloc, environ 300 Ko. C'est déjà trop pour être lu par un agent en une fois, et ça grossit avec la collection.

**À faire** (MCP/ProjectMCPTools.swift)
- Paramètres optionnels : `category`, `creator`, `tag`, `character`, `search`, `limit` (défaut 50, max 200), `offset`.
- Réponse : `{ items, total, limit, offset }`.
- Mode compact : ne renvoyer par défaut que `id, name, category, creator, tags, characters, totalFileCount` ; le détail reste dans `get_project`.

**Critères d'acceptation** : `list_projects` sans argument renvoie au plus 50 projets et le total réel ; les filtres se combinent.

---

## 3. `/api/mcp` : répondre 405 sur GET et DELETE (priorité moyenne, rapide)

**Pourquoi.** La spec Streamable HTTP demande un 405 quand le serveur n'ouvre pas de flux SSE. Aujourd'hui ces deux verbes tombent sur le 404 par défaut de Vapor, ce qui fait croire à certains clients que l'endpoint n'existe pas.

**À faire** (MCP/MCPController.swift) : enregistrer `.GET` et `.DELETE` sur la même route et renvoyer `Abort(.methodNotAllowed)`.

**Critères d'acceptation** : `curl -X GET /api/mcp` renvoie 405 ; `POST` inchangé.

---

## 4. Exposer `shopifyProductId` et `alreadyPrinted` dans le MCP (priorité moyenne)

**Pourquoi.** Les deux champs existent côté serveur mais ne sont ni renvoyés par `get_project`, ni modifiables par `update_project`. Conséquence : impossible de lier un produit Shopify à un projet depuis un agent, et impossible de savoir combien de projets sont marqués « déjà imprimé ».

**À faire** (MCP/ProjectMCPTools.swift, PrintPlexCore/DTOs.swift) : ajouter `shopifyProductId` (string) et `alreadyPrinted` (bool) en lecture et en écriture.

**Critères d'acceptation** : un agent peut lire et écrire ces deux champs ; les valeurs restent cohérentes avec l'interface web.

---

## 5. Rapprochement Shopify explicite (priorité moyenne)

**Pourquoi.** 12 projets sur 285 seulement sont reliés à un produit, et 56 produits sur 68 n'ont aucun projet. Le rapprochement par nom (`matchShopifyProduct`, Public/app.js) cherche l'un dans l'autre, ce qui ne marche pas avec des titres commerciaux français et produit des faux positifs : le projet « Horloge » est associé à « Grove - Horloge de Table Design », qui est en réalité le projet Grove Clock.

**À faire**
- Exiger un nom de projet d'au moins ~12 caractères pour tenter le rapprochement par inclusion, et ne garder le résultat que s'il est unique.
- Afficher dans l'interface un bandeau « correspondance devinée » tant que le lien n'est pas explicite, avec un bouton pour confirmer (écrit `shopifyProductId`).
- Ajouter à Réglages → Shopify la liste des produits sans projet (la fonction `unmatchedShopifyProducts()` existe déjà).

**Critères d'acceptation** : aucun projet n'affiche un produit deviné ambigu ; un lien confirmé survit à un changement de titre côté Shopify.

---

## 6. Garde-fou sur les tags (priorité moyenne)

**Pourquoi.** Deux semaines après le grand ménage du 16/09, 5 des 8 nouveaux projets s'écartaient déjà des conventions (« Echec » au lieu de « Échecs », « Jeu de cartes » au lieu de « Cartes », « Décoration » sur une catégorie déjà décorative, « Super-héros » et « Méchants » ensemble, « Comics » manquant à côté de « DC Comics »).

**À faire** — au choix, du plus léger au plus solide :
1. Tool MCP `lint_tags` en lecture seule, qui renvoie la liste des écarts (règles ci-dessous) sans rien modifier.
2. Vocabulaire contrôlé côté serveur pour les tags transverses (types d'objet, techniques, médias, univers), tags libres uniquement pour le reste.
3. Autocomplétion plus stricte dans l'éditeur : proposer les tags existants avant d'en créer un nouveau, et avertir si le nouveau tag ressemble à un tag connu (accents, singulier/pluriel).

**Règles à encoder**
- un tag identique à la catégorie du projet est interdit ;
- `Pokémon` implique `Nintendo`, `Jeu vidéo`, `Anime` ; `Mario` implique `Nintendo`, `Jeu vidéo` ; `Marvel` ou `DC Comics` implique `Comics` ; `Power Rangers` implique `Tokusatsu` ;
- `Super-héros` et `Méchants` sont exclusifs, **sauf pour les mashups de deux personnages** (Absolute Bat Bane Helmet, Shrekpool, Wolverinepool…) : le linter signale, il ne corrige pas ;
- `Décoration` est interdit dans les catégories déjà décoratives (Poster 3D, 3D Cards, Figurines, Figurine Life Size, Accessoire Écran) ;
- un projet de la catégorie Cosplay doit porter au moins un type d'objet (Casque, Masque, Armure, Props, Arme, Bouclier, Bijou, Chapeau, Présentoir, Outil).

---

## 7. Récupérer les notes qui traînent dans les dossiers (priorité basse)

**Pourquoi.** 99 projets n'ont pas de description, alors que plusieurs dossiers contiennent déjà un `README`, un `note license.txt`, un `READ BEFORE PRINTING.txt` ou un `Link to ....txt` dont le contenu est utile (licence, consignes d'impression, lien vers le modèle complémentaire).

**À faire** (PrintPlexCore/LibraryScanner.swift) : à la découverte d'un projet, si `info.json` n'a pas de description et qu'un fichier texte court (< 4 Ko) est présent à la racine du dossier, le recopier dans `notes`. Ne jamais écraser une description existante.

*(Les URL source ne sont pas un sujet : les projets Yosh Studios viennent d'un Drive partagé, l'absence d'URL est normale.)*

---

## 8. Fichiers à supprimer sur le NAS (à faire à la main)

Le serveur n'expose aucune route de suppression de fichier, et je n'ai pas accès au montage `/media`. À supprimer depuis File Station :

| Projet | Fichier |
|---|---|
| COLOSSAL TITAN BUDDY | `TITAN_COLOSSAL COLOR.3mf.tmp` |
| Catchall Coral | `Catchall Coral.3mf.tmp` |
| Car Brands | `3MF_All_Keychains.3mf.tmp` |

À traiter aussi, mais avec une décision de ta part : `Spider-Man Popcorn Bucket Raised Version Colored 3mf.zip` (jamais extrait — l'extraire puis supprimer l'archive) et `samus canon mechanism.psd` dans Samus MP4 Cannon (source Photoshop, à garder ou déplacer hors de la bibliothèque).

---

## 9. Échéances

- **15 octobre 2026** : expiration du certificat HTTPS importé sur le Synology. Il ne se renouvelle pas automatiquement ; il faudra réimporter le certificat renouvelé avec la chaîne complète (voir `sauvegardes/` et la procédure du 16/09), sinon le connecteur MCP et l'accès distant tombent.
- La clé API actuelle a circulé en clair dans une conversation : à régénérer, puis à reporter dans l'URL du connecteur.
- 141 Go en local uniquement sur le NAS : prévoir une sauvegarde externe de `/media`.
