# PrintPlex — éditeur de description riche (HTML ↔ rendu)

Demandé le 30/09/2026, à implémenter dans le projet Claude Code.

## Le problème

Le champ description du projet est aujourd'hui un `<textarea>` de 2 lignes (`Public/app.js` ligne 1411, classe `detail-desc-input`), avec un autosave débouncé (`flushDetailSave`, ligne 1504). Depuis que les descriptions servent de fiches produit Shopify, elles contiennent du HTML (`<p>`, `<strong>`, `<br>`, liens, emoji d'avertissement) : le textarea affiche les balises brutes, sur deux lignes, sans rendu ni aide à la saisie. Impossible de relire une fiche sans la copier ailleurs.

## Ce qu'on veut

Le comportement de l'éditeur Shopify : une barre d'outils, un rendu visuel éditable, et un bouton pour basculer vers le HTML brut — le tout dans le panneau de détail du projet, avec le même autosave qu'aujourd'hui.

## Proposition

### Deux modes, un seul champ

- **Mode rendu** (par défaut) : un `contenteditable` stylé qui affiche la description formatée. Barre d'outils minimale : gras, italique, lien, paragraphe, liste à puces, et un bouton « nettoyer le format » pour le texte collé depuis Word ou Shopify.
- **Mode HTML** : le textarea actuel, en pleine hauteur, avec une police à chasse fixe.
- Un bouton `< >` bascule entre les deux. Le mode choisi est mémorisé dans `localStorage` — c'est une préférence d'affichage, pas une donnée de projet.

### Contraintes

- **Un seul format stocké** : du HTML, comme aujourd'hui. Pas de Markdown, pas de conversion à l'enregistrement, pour que ce qui est dans PrintPlex soit exactement ce qui part sur Shopify.
- **Sous-ensemble de balises autorisé**, celui qu'utilisent déjà les fiches : `p`, `strong`, `em`, `br`, `ul`, `li`, `a[href,title,target]`. Tout le reste est retiré au collage et à l'enregistrement (pas de `<script>`, pas de `style=`, pas de `<div>` imbriqués).
- **Assainissement côté serveur aussi**, dans `ProjectController.applyUpdate` : le champ part sur Shopify et se retrouve dans `info.json`, donc la validation ne peut pas vivre uniquement dans le navigateur.
- **Autosave inchangé** : `flushDetailSave(project.id, () => ({ projectDescription: ... }))`, débounce actuel. En mode rendu, on sérialise le `contenteditable` avant l'envoi.
- **Pas de dépendance externe** si possible. `document.execCommand` est déprécié mais suffit pour gras/italique/lien ; sinon, une petite lib sans dépendance et auto-hébergée dans `Public/` (le serveur n'a pas de bundler, tout est en vanilla JS). Ne pas charger un éditeur depuis un CDN : le serveur doit rester utilisable sans accès internet.

### Détails d'interface

- La zone d'édition passe à environ 12 lignes visibles, avec un bouton pour l'agrandir en plein panneau — les fiches font 1 500 à 1 700 caractères.
- Le rendu réutilise la typographie de `Public/styles.css` pour ressembler à ce que verra le client sur Shopify (titres en gras, paragraphes espacés).
- Un compteur de caractères discret, utile pour les limites SEO.
- Le champ **notes** reçoit le même éditeur, ou au minimum un textarea plus haut : il contient maintenant le bloc SEO (titre, meta description, tags).

## Fichiers concernés

- `Public/app.js` : rendu du panneau de détail (~1411), autosave (~1504), nouveau module d'éditeur.
- `Public/styles.css` : styles de la barre d'outils, du contenteditable et du mode HTML.
- `Sources/PrintPlexServerApp/Controllers/ProjectController.swift` : assainissement du HTML à l'enregistrement.

## Critères d'acceptation

- Une fiche existante (par exemple Umbreon & Snorlax Pumpkins) s'ouvre en mode rendu avec ses titres en gras et ses paragraphes, et bascule en HTML à l'identique, sans perte ni reformatage.
- Coller du contenu depuis l'éditeur Shopify produit du HTML propre, limité aux balises autorisées.
- L'autosave continue de fonctionner dans les deux modes ; un rechargement de page affiche exactement ce qui a été enregistré.
- Une description contenant `<script>` ou un attribut `style` est refusée ou nettoyée côté serveur.

## Suite logique (hors périmètre de cette tâche)

Une fois l'éditeur en place, le bouton « créer le produit Shopify » peut envoyer directement la description du projet dans `bodyHtml`, et le bloc SEO des notes dans le titre et la meta description — ce qui supprime le copier-coller manuel.
