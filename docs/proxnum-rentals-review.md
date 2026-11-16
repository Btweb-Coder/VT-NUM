# Locations longue durée Proxnum — revue avant déploiement

## Composants préparés

- `20261016110000_proxnum_rentals_schema.sql` crée les locations, SMS, renouvellements, RLS et publications Realtime.
- `20261016120000_proxnum_rental_wallet.sql` ajoute des réservations, captures, libérations et remboursements idempotents dédiés aux locations. Les RPC d'activation, le ledger des dépôts et les gateways ne sont pas modifiés.
- `proxnum-rentals` expose le catalogue, l'achat, le détail synchronisé, l'annulation et le renouvellement après authentification.
- `monitor-proxnum-rentals` interroge Proxnum côté serveur, déduplique les SMS, réconcilie les achats ambigus avec la liste fournisseur et finalise les remboursements/renouvellements confirmés.
- L'interface séparée est accessible depuis « Plus > Locations longue durée ».

## Sécurité et activation

Les migrations conservent `providers.active` et `providers.config.features.rental_numbers` désactivés. Les RPC financiers ne sont exécutables que par `service_role`; le client ne reçoit que des droits SELECT filtrés par propriétaire. Les achats et renouvellements comparent le prix client confirmé par `pricing_rules` au prix affiché et transmettent `max_price` à Proxnum. Les timeouts gardent les fonds réservés et déclenchent la réconciliation. Un remboursement client ne s'exécute qu'après l'état fournisseur `cancelled`.

La clé Proxnum est lue depuis `PROVIDER_SECRETS` côté Edge Function. Aucune valeur de secret n'est incluse dans ces fichiers. Le job `configure_proxnum_rental_monitor()` est séparé du scheduler des activations/top-ups et doit être appelé manuellement après installation/configuration.

La documentation Proxnum indique le polling de statut/SMS toutes les 5–10 secondes, `202` comme annulation en attente, `max_price` pour empêcher une hausse silencieuse, et des pages de liste jusqu'à 100 locations. Elle ne publie pas de limite chiffrée de débit. Le moniteur est planifié toutes les 10 secondes et limite chaque passe à 20 locations; au-delà de cette charge, la fréquence effective par location dépend du temps de réponse fournisseur et doit être surveillée.

## Vérifications réalisées

- `flutter test` — réussi (3 tests Flutter existants).
- `flutter analyze lib/app/router.dart lib/features/rentals/pages/rentals_page.dart` — aucune erreur ni info.
- `flutter build apk --debug` — réussi.
- `deno check` sur les nouvelles fonctions, l'adaptateur et les fonctions d'activation existantes — réussi.
- Tests Deno Proxnum — 5 réussis (catalogue, plafond de prix, timeout ambigu, annulation `202`, déduplication SMS).

## Vérifications restantes avant toute mise en production

Le dépôt fourni ne contient pas de métadonnées Git; `git status`/`git diff` ne sont donc pas disponibles. Un inventaire manuel des fichiers modifiés a été fait. Aucun fichier du parcours top-up, des paiements, des gateways, de leurs callbacks ou du monitor top-up n'a été modifié dans cette implémentation.

Le dump de schéma Supabase en lecture seule n'a pas pu aboutir : la CLI exige Docker ou Podman pour lancer `pg_dump`, absents de l'environnement. Le schéma de production et les permissions réelles restent à confirmer par l'équipe. Les migrations SQL n'ont pas été exécutées ni validées contre PostgreSQL; Docker n'étant pas disponible, aucun test transactionnel local n'a été possible. Tester notamment les soldes insuffisants, captures/libérations répétées, collisions concurrentes, rejeu de clés, prix modifié, annulation différée, renouvellement tardif, RLS inter-utilisateurs et remboursement idempotent.

## Commandes à exécuter manuellement après revue

Ne pas lancer `db push` tant que `supabase migration list --linked` n'a pas confirmé que toutes les migrations en attente ont été examinées et qu'aucune migration de paiement/top-up ne serait appliquée par la même commande.

```powershell
npx supabase migration list --linked
npx supabase db push --linked
npx supabase functions deploy proxnum-rentals
npx supabase functions deploy monitor-proxnum-rentals
```

Après application, configurer `PROVIDER_SECRETS` côté Edge Functions, puis appeler explicitement `select public.configure_proxnum_rental_monitor();` uniquement après validation des extensions Vault/Cron/Net. Activer Proxnum et `rental_numbers` séparément, manuellement, après tests d'intégration sans fonds réels. Aucun de ces déploiements, appels de configuration, achat, renouvellement ou annulation n'a été effectué ici.
# Revue complémentaire — deuxième passe

Les migrations et fonctions SQL restent des fichiers préparatoires et n'ont
pas été exécutés. La passe a ajouté des garde-fous explicites pour la devise
USD, la règle tarifaire et l'extension `pg_cron`, ainsi qu'un test transactionnel
local : `supabase/tests/proxnum_rental_wallet_transactional.sql`.

Avant toute validation de migration, confirmer sur un clone/snapshot du schéma
cible que `profiles(user_id)`, `wallets(currency, available_balance,
held_balance)`, `pricing_rules(active, markup_type, markup_value)` et les rôles
Supabase ont bien les formes et permissions attendues. Les seuls schémas du
dépôt consultés sont les migrations historiques locales; aucune connexion
PostgreSQL ni CLI `psql` n'est disponible dans cet environnement.

Le job « 10 seconds » est accepté par pg_cron à partir de la version 1.5.0.
La fonction de configuration échoue volontairement si pg_cron est trop ancien,
ou si `net.http_post`, `cron.job` ou `vault.decrypted_secrets` ne sont pas
installés. Vérifier leurs versions réelles et leurs privilèges sur le projet
cible avant de planifier le job. Les migrations précédentes du dépôt déclarent
`pg_cron` et `pg_net`, mais cela ne prouve pas leur disponibilité dans la base
de production.

Le test SQL requiert une base Supabase locale jetable ayant appliqué les deux
migrations Proxnum et possédant au moins un profil/portefeuille seedé. Il
encadre ses écritures dans une transaction annulée à la fin; il ne doit jamais
être exécuté sur production. Les scénarios de concurrence réelle doivent aussi
être lancés depuis deux sessions PostgreSQL distinctes afin de vérifier le
verrouillage et l'index partiel dans le moteur cible.


## Résultats de la deuxième passe

`deno check` des deux Edge Functions et du module partagé Proxnum réussit. `deno test` ne démarre pas : Deno 2.9.7 plante sur son canal IPC Windows (`Unexpected client pipe failure`, handle invalide/accès refusé), avant l'exécution des tests. `flutter test` ne compile pas ses tests, faute d'espace disque dans `%TEMP%` (erreur OS 112). Ni `psql`, serveur PostgreSQL, Docker/Podman ni CLI Supabase ne sont disponibles; le script SQL transactionnel est préparé mais non exécuté. Aucun test Proxnum n'a fait de requête réseau réelle.
