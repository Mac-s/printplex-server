# Serveur MCP pour PrintPlexServer

**Date**: 2026-09-08
**Statut**: Approuvé

## Contexte

PrintPlexServer expose déjà une API REST (`/api/*`) consommée par le dashboard web et le client natif. On veut ajouter un serveur MCP (Model Context Protocol) qui expose cette même bibliothèque à des agents LLM (Claude Desktop, Claude Code, ou tout autre client compatible MCP) en accès lecture + écriture complet, sur les ~25 endpoints existants.

## Décisions

- **Périmètre** : mapping complet des endpoints existants (Projects, Files, Scan, Libraries, Printers, Materials, Settings, Shopify, ForgeCore) — pas seulement le cœur bibliothèque.
- **Accès** : lecture + écriture complète, y compris les opérations destructrices (suppression de printer/library).
- **Clients cibles** : Claude Desktop / Claude Code, et tout autre agent compatible MCP (pas de dépendance à un client spécifique).

## Architecture

- Nouveau `MCPController: RouteCollection`, monté sur `/api/mcp` dans `routes.swift`. Comme il vit sous `/api/*`, il hérite automatiquement de la protection `AuthMiddleware` existante (session ou `X-API-Key`) — aucun nouveau code d'authentification.
- Dépendance ajoutée à `Package.swift` : le SDK Swift officiel MCP (`modelcontextprotocol/swift-sdk`). Le SDK porte le framing JSON-RPC 2.0, la négociation de capacités `initialize`, et le transport HTTP distant (Streamable HTTP). On ne réimplémente aucun détail de protocole à la main — seule la couche d'adaptation entre le SDK et le cycle requête/réponse Vapor est écrite ici.

## Surface de tools

~25 tools, mapping 1:1 avec les endpoints REST existants. Chaque handler de tool appelle directement la même logique que les contrôleurs REST utilisent déjà (aucune logique métier dupliquée) — là où cette logique est aujourd'hui inline dans la closure de route, elle est extraite en méthode réutilisable appelée à la fois par la route HTTP et le tool MCP.

Nommage `verbe_ressource` :

| Contrôleur | Tools |
|---|---|
| Projects | `list_projects`, `get_project`, `update_project`, `get_project_estimate`, `get_project_shopify_match` |
| Files | `list_files`, `list_unsorted_files`, `get_file_stats`, `get_file`, `update_file`, `get_file_estimate` |
| Scan | `trigger_scan`, `get_scan_status`, `get_scan_events` |
| Libraries | `list_libraries`, `create_library`, `browse_library`, `delete_library` |
| Printers | `list_printers`, `create_printer`, `update_printer`, `delete_printer` |
| Materials | `list_materials`, `update_material` |
| Settings | `get_settings`, `update_scan_settings`, `get_shopify_settings`, `update_shopify_settings` |
| Shopify | `list_shopify_products`, `create_shopify_product`, `sync_shopify` |
| ForgeCore | `get_forgecore_pending` |

Liste finale affinée à l'implémentation (nom exact, forme des paramètres) au fil du branchement de chaque contrôleur.

Les tools destructeurs (`delete_library`, `delete_printer`) portent l'annotation MCP `destructiveHint: true`, pour qu'un client bien élevé demande confirmation avant l'appel.

Les endpoints binaires (`download`, `thumbnail`, `original` de FileController) ne deviennent pas des tools — un agent MCP n'a pas d'usage direct pour un flux binaire d'image/vidéo ; les métadonnées de fichier (`get_file`) suffisent à contextualiser.

## Auth

Réutilisation de la clé API `X-API-Key` existante — même mécanisme déjà utilisé par le relay ForgeCore et le client natif. La configuration MCP distante de Claude Desktop/Code accepte un header custom, donc la connexion se résume à : URL du serveur + clé API existante.

## Gestion des erreurs

Les erreurs `Abort` déjà levées par la logique existante (404, 400, etc.) sont traduites en résultats d'erreur MCP (`isError: true` avec message) plutôt qu'en codes HTTP bruts — un appel JSON-RPC ne peut pas exposer un status HTTP comme le ferait un client REST. Les requêtes JSON-RPC malformées sont gérées par le SDK lui-même (réponses conformes au spec), pas par du code applicatif.

## Tests

- Smoke test manuel avec le MCP Inspector CLI (`npx @modelcontextprotocol/inspector`) pointé sur un serveur de test (scratch server), pour vérifier `initialize` / `tools/list` / quelques `tools/call` avant de brancher un agent réel.
- Un ou deux tests XCTVapor couvrant le branchement lui-même (auth gate, un tool en lecture, un tool en écriture) — pas de nouvelle suite complète, la logique métier reste couverte par les tests REST existants.

## Hors périmètre (v1)

- Pas de gestion OAuth (la clé API existante suffit pour un serveur mono-utilisateur).
- Pas de tools sur les endpoints binaires (download/thumbnail/original).
- Pas de resources MCP (juste des tools) — pas de besoin identifié pour l'instant.
