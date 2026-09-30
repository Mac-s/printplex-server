# PrintPlex — bilan de la bibliothèque (30 septembre 2026)

## 1. L'état des lieux

| | |
|---|---|
| Projets | 285 (+8 depuis le 16/09) |
| Fichiers | 11 264 — 6 645 STL, 757 3MF, 3 520 images, 23 docs/notes, 27 vidéos |
| Volume | 141 Go, dont 4 Go d'images |
| Bibliothèques | Yosh Studios 170 projets / 133 Go · ForgeCore 87 / 4,6 Go · Budwin 19 / 3,1 Go · MakerWorld 5 · Le Front Fuyant 4 |
| Scan | automatique toutes les 15 min, dernier passage le 30/09 à 09 h 58, 0 fichier non trié |
| Shopify | connecté, 68 produits (18 actifs, 50 brouillons), dernière synchro le 29/09 |

**Répartition par catégorie :** Cosplay 123, Jeux 31, Figurine Life Size 25, Figurines 24, Cuisine 13, Maison 11, Poster 3D 9, Fidget Toys 8, 3D Cards 7, Décoration 7, Bureau 7, Accessoire Écran 5, Accessoires 5, Salle de bain 5, Jardin & Plantes 3, Porte-clés 2.

**Qualité des métadonnées :** 100 % des projets ont une catégorie, un créateur, des tags, des matériaux suggérés et une image de couverture. Moyenne de 5,4 tags par projet, 10,8 images par projet.

**Ce qui manque :** 176 projets sans URL source, 99 sans description, 5 sans aucune image (Pokeball clicker, Printed Clickers, Porte Serviettes, Batman 2022 concept, Car Brands), 5 projets seulement avec une estimation manuelle.

## 2. Points d'amélioration, par ordre d'importance

### 2.1 Le lien PrintPlex ↔ Shopify ne tient qu'au nom (le plus rentable à corriger)

Seuls **12 projets sur 285** sont reliés à un produit, et **56 produits sur 68 n'ont aucun projet en face**. La cause est simple : tes titres Shopify sont commerciaux et en français (« Échecs - Livre-Jeu Aimanté Playbook »), alors que le rapprochement se fait en cherchant le nom du projet dans le titre du produit.

Pire, ce rapprochement produit déjà **un faux positif** : le projet « Horloge » (Le Front Fuyant) est associé au produit « Grove - Horloge de Table Design », qui correspond en réalité au projet Grove Clock de ForgeCore. « Brand New Day » correspond aussi à plusieurs produits à la fois.

À faire :
- lier explicitement les produits aux projets (le champ `shopifyProductId` existe déjà côté serveur, mais il n'est pas exposé dans le tool MCP `update_project` — une fois exposé, je peux faire les 50 rapprochements d'un coup) ;
- n'utiliser le rapprochement par nom qu'en dernier recours, et ignorer les correspondances où le nom du projet fait moins de ~12 caractères ;
- ajouter dans le dashboard une liste « produits Shopify sans projet », qui est aujourd'hui la vraie liste de travail.

### 2.2 Les conventions de tags se perdent déjà sur les nouveaux projets

Les 8 projets ajoutés depuis le ménage du 16/09 s'écartent des règles adoptées :
- **Picnic Chess** : tag « Echec » au lieu de « Échecs » (sans accent et au singulier, donc invisible à côté des autres jeux d'échecs) ;
- **Exodia Screen Buddy** : « Jeu de cartes » alors que « Cartes » existe déjà ;
- **Exodia Screen Buddy**, **Raphael MTG**, **Umbreon & Snorlax Pumpkins** : tag « Décoration » alors que leur catégorie est déjà décorative ;
- **Absolute Bat Bane Helmet** : porte à la fois « Super-héros » et « Méchants », et il manque « Comics » à côté de « DC Comics » ;
- **Tumbling Tower** : il manque « Minimaliste », « Print-in-Place » et « Multi-couleur » que portent les autres PlayBook'd.

Un ménage manuel tous les six mois ne tiendra pas. Trois pistes, de la plus légère à la plus solide :
1. une tâche planifiée qui me fait passer une fois par semaine pour corriger les écarts et te résumer ce qui a bougé ;
2. un tool MCP `lint_tags` dans le serveur, qui liste les écarts sans rien modifier ;
3. des règles dans le serveur : vocabulaire fermé pour les tags transverses (types d'objet, techniques, médias) et tags libres uniquement pour les personnages.

### 2.3 117 tags sur 245 ne servent qu'une seule fois

C'est 48 % du vocabulaire, et ce sont presque tous des personnages (Luigi, Marowak, Sally, Bane…). Ils encombrent la liste de filtres alors qu'ils ne servent qu'à un projet. L'idée la plus propre serait un **champ « Personnages » distinct des tags**, avec sa propre section dans les filtres. Sinon, les laisser vivre : ils deviendront utiles quand la collection grandira.

### 2.4 L'origine des fichiers n'est pas tracée

176 projets n'ont pas d'URL source et 99 pas de description. Pour une collection à 133 Go venant majoritairement de Patreon, c'est ce qui permet de retrouver la fiche d'origine, les consignes d'impression et la licence — en particulier si tu vends des impressions. Le scanner pourrait au moins récupérer ce qui traîne déjà dans les dossiers : plusieurs projets contiennent un `note license.txt`, un `READ BEFORE PRINTING.txt` ou un `Link to Monitor Stand.txt` dont le contenu mériterait d'atterrir dans la description ou les notes.

### 2.5 Ménage de fichiers et de noms

- 3 fichiers `.tmp` restés d'un téléchargement interrompu (COLOSSAL TITAN BUDDY, Catchall Coral, Car Brands) ;
- 1 `.zip` jamais extrait (Spider-Man Popcorn Bucket, version surélevée) et 1 `.psd` (Samus MP4 Cannon) ;
- 5 noms de projets avec une espace parasite en fin (Batman Dark Detective, Chopper Hat, Luigi Helmet, Lego Stormtrooper Helmet, Bowser Jr Helmet) ;
- 3 noms avec un tiret bas à la place de l'apostrophe (Zoro_s Black / Red / White Katana) ;
- 5 noms ForgeCore à rallonge (jusqu'à 86 caractères), qui débordent dans l'interface.

### 2.6 Estimations et prix

Seuls 5 projets ont une estimation manuelle, alors que 84 ont des données de source (poids, temps). Comme le serveur sait déjà calculer temps, filament et coût par imprimante et matériau, il y a de quoi afficher un prix de revient sur chaque projet et le comparer au prix Shopify.

### 2.7 Côté serveur (ce que j'ai constaté en utilisant l'API)

- `list_projects` renvoie les 285 projets d'un bloc, soit environ 300 Ko : trop pour un agent. Un filtre (catégorie, créateur, tag, recherche) et une pagination règleraient ça.
- `GET` et `DELETE` sur `/api/mcp` renvoient 404 au lieu du 405 attendu par la spec Streamable HTTP.
- Le tool `update_project` ne permet ni de lier un produit Shopify, ni de marquer « déjà imprimé » — et ces deux champs ne sont pas non plus renvoyés par `get_project`, donc impossible de savoir combien de projets sont marqués comme imprimés.

### 2.8 Deux échéances à ne pas oublier

- **Le certificat HTTPS expire le 15 octobre**, soit dans un peu plus de deux semaines. Celui qu'on a importé sur le Synology ne se renouvelle pas tout seul : il faudra refaire l'import avec le certificat renouvelé, sinon le connecteur MCP et l'accès au serveur tomberont.
- **La clé API** est toujours celle qui a circulé dans notre conversation du 16/09.
- Les 141 Go sont uniquement en local sur le NAS. Si les fichiers Patreon ne sont pas sauvegardés ailleurs, c'est le vrai point de fragilité de toute la collection.
