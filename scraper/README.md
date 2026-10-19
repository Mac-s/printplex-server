# scraper (sidecar docker-compose)

Relais qui scrape les fiches source (ForgeCore `prinnit.com`, MakerWorld) à la
demande du tableau de bord : le bouton « Lancer le scraping » d'un projet le
marque « en attente », ce service le voit, scrape avec Chromium headless et
renvoie photos + métadonnées au serveur. Aucune connexion aux sites n'est
nécessaire (vérifié : tout est public hors téléchargement des fichiers).

1. Réglages → Compte : copier la clé d'API.
2. La mettre dans `.env` à côté de `docker-compose.yml` : `PRINTPLEX_API_KEY=ppx_...`
3. `docker compose pull && docker compose up -d` (image publiée par la CI) ou `docker compose up -d --build` pour construire sur place — tant que la clé est absente, le service attend.

Le tag de l'image dans `Dockerfile` (`playwright:vX.Y.Z-noble`) doit rester égal à
la version de `playwright` épinglée dans `package.json`.
Pour un test hors Docker : `npm ci && PRINTPLEX_URL=http://localhost:8080 PRINTPLEX_API_KEY=ppx_... npm run relay`.
