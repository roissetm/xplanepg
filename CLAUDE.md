# CLAUDE.md — XplanePLPG

## Vision du projet

**XplanePLPG** est un provider Crossplane-like implémenté **entièrement en SQL pur** dans PostgreSQL.
Il permet de gérer des ressources PostgreSQL (databases, schemas, roles, extensions, service accounts) via un modèle déclaratif inspiré de Kubernetes, avec boucle de réconciliation, conditions de statut et gestion d'événements — le tout sans dépendance externe, sans binaire Go, sans contrôleur Kubernetes.

**Philosophie** : _"Your database IS the control plane."_

---

## Note on Schema Naming

The SQL code uses the schema name `crossplane` (not `xplane` as described elsewhere in this document). This is intentional for v0.1.0. A rename to `xplane` is planned for v0.2.0, after the test suite is in place to safely validate the change.

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    XplanePLPG                            │
│                                                         │
│  ┌──────────┐   ┌────────────┐   ┌───────────────────┐  │
│  │  apply()  │──▶│ reconcile()│──▶│ observe/diff/act  │  │
│  │  delete() │   │            │   │                   │  │
│  └──────────┘   └─────┬──────┘   └───────┬───────────┘  │
│       API             │                  │               │
│                 ┌─────▼──────┐    ┌──────▼────────┐     │
│                 │ conditions │    │  actions CRUD  │     │
│                 │  events    │    │  (par kind)    │     │
│                 └────────────┘    └───────────────┘     │
│                                                         │
│  ┌─────────────────────────────────────────────────┐    │
│  │              managed_resources                   │    │
│  │  + provider_configs + conditions + events        │    │
│  │  (tables fondatrices — source of truth)          │    │
│  └─────────────────────────────────────────────────┘    │
│                                                         │
│  ┌─────────────────────────────────────────────────┐    │
│  │         pg_cron (réconciliation auto 30s)        │    │
│  └─────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────┘
```

---

## Kinds gérés (Managed Resources)

| Kind              | Description                                         |
|-------------------|-----------------------------------------------------|
| `Database`        | Création/suppression de databases PostgreSQL         |
| `Schema`          | Namespaces logiques au sein d'une database           |
| `Role`            | Rôles NOLOGIN (groupes RBAC hiérarchiques)           |
| `Extension`       | Extensions PostgreSQL (`pgcrypto`, `uuid-ossp`, etc.)|
| `ServiceAccount`  | Rôle LOGIN + CONNECT + grants granulaires par schema |

---

## Modèle de statuts (inspiré Crossplane/Kubernetes)

### Conditions

Chaque managed resource expose des conditions dans `status.conditions` :

| Condition            | `True`                                      | `False`                                           |
|----------------------|---------------------------------------------|---------------------------------------------------|
| `Synced`             | L'action SQL a réussi                       | Erreur SQL (permissions, réseau, quota…)           |
| `Ready`              | La ressource existe et est opérationnelle   | En cours de création ou en erreur                  |
| `LastAsyncOperation` | Opération async terminée avec succès        | Opération async en cours ou échouée               |

### Status codes retournés par les actions

Chaque action CRUD retourne un tuple `(status_code, message, observed)` :

| Code                   | Signification                                     |
|------------------------|---------------------------------------------------|
| `success`              | Action réalisée avec succès                       |
| `already_exists`       | La ressource existe déjà (create idempotent)      |
| `not_found`            | Ressource introuvable (delete idempotent)         |
| `updated`              | Mise à jour appliquée                             |
| `no_change`            | Spec désirée = état observé, rien à faire         |
| `error`                | Erreur SQL capturée                               |
| `permission_denied`    | Droits insuffisants                               |
| `invalid_spec`         | Spec invalide (validation échouée)                |
| `dependency_not_ready` | Dépendance non satisfaite (ex: DB pas encore prête)|

### Boucle de réconciliation

```
observe() → diff(desired, observed) → act(create|update|delete) → set_conditions()
```

Le reconciler ne lève jamais d'exception. Il capture toutes les erreurs et les traduit en conditions + événements.

---

## Structure du projet

```
XplanePLPG/
├── CLAUDE.md                    # Ce fichier — contexte projet pour Claude
├── README.md                    # Documentation utilisateur
├── LICENSE                      # Apache 2.0
├── CONTRIBUTING.md              # Guide de contribution
├── CHANGELOG.md                 # Historique des versions
├── Makefile                     # Commandes : install, test, lint, clean
│
├── sql/                         # Code SQL source (exécuter dans l'ordre)
│   ├── 00_schema_provider.sql   # Tables, enums, index, contraintes
│   ├── 01_helpers.sql           # Fonctions utilitaires (set_condition, emit_event, observe…)
│   ├── 02_actions.sql           # CRUD par kind (create/update/delete pour chaque resource)
│   ├── 03_reconciler.sql        # reconcile(), reconcile_all(), apply(), delete(), vues
│   ├── 04_cron_setup.sql        # Configuration pg_cron (réconciliation automatique)
│   └── 05_examples.sql          # Scénario complet de provisioning
│
├── migrations/                  # Migrations versionnées (pour upgrades)
│   ├── 001_initial_schema.sql
│   └── ...
│
├── tests/                       # Tests SQL
│   ├── framework/
│   │   └── tap.sql              # Framework de test TAP (pgTAP ou custom)
│   ├── unit/
│   │   ├── test_helpers.sql
│   │   ├── test_actions_database.sql
│   │   ├── test_actions_schema.sql
│   │   ├── test_actions_role.sql
│   │   ├── test_actions_extension.sql
│   │   ├── test_actions_service_account.sql
│   │   └── test_reconciler.sql
│   ├── integration/
│   │   ├── test_full_lifecycle.sql
│   │   ├── test_idempotency.sql
│   │   ├── test_dependency_ordering.sql
│   │   └── test_error_recovery.sql
│   └── e2e/
│       └── test_complete_stack.sql
│
├── docs/
│   ├── architecture.md          # Design decisions et ADRs
│   ├── kinds/
│   │   ├── database.md
│   │   ├── schema.md
│   │   ├── role.md
│   │   ├── extension.md
│   │   └── service-account.md
│   ├── status-model.md          # Détail du modèle Synced/Ready/conditions
│   ├── security.md              # Modèle de sécurité, least privilege
│   ├── operations.md            # Guide opérationnel (monitoring, troubleshooting)
│   └── crossplane-comparison.md # Mapping concepts Crossplane → XplanePLPG
│
├── docker/
│   ├── Dockerfile               # Image PostgreSQL + XplanePLPG préinstallé
│   └── docker-compose.yml       # Stack locale (PG + pgAdmin optionnel)
│
├── .github/
│   ├── workflows/
│   │   ├── ci.yml               # Tests sur PR (matrix PG 14/15/16/17)
│   │   ├── release.yml          # Publication des releases
│   │   └── security.yml         # Audit de sécurité SQL
│   ├── ISSUE_TEMPLATE/
│   │   ├── bug_report.md
│   │   └── feature_request.md
│   └── PULL_REQUEST_TEMPLATE.md
│
└── examples/
    ├── multi-tenant-saas/       # Provisioning multi-tenant complet
    ├── microservices-rbac/      # Roles hiérarchiques pour microservices
    └── data-platform/           # Setup data warehouse avec schemas séparés
```

---

## Tables fondatrices (schéma `xplane`)

### `managed_resources`
Table centrale — chaque ligne est une ressource déclarative :

```sql
CREATE TABLE xplane.managed_resources (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    kind            xplane.resource_kind NOT NULL,          -- enum: Database, Schema, Role, Extension, ServiceAccount
    name            TEXT NOT NULL,
    spec            JSONB NOT NULL,                         -- état désiré
    status          JSONB DEFAULT '{}',                     -- état observé
    deletion_policy xplane.deletion_policy DEFAULT 'delete', -- delete | orphan
    provider_config TEXT REFERENCES xplane.provider_configs(name),
    finalizers      TEXT[] DEFAULT '{}',
    created_at      TIMESTAMPTZ DEFAULT now(),
    updated_at      TIMESTAMPTZ DEFAULT now(),
    deleted_at      TIMESTAMPTZ,                            -- soft delete (deletion timestamp)
    UNIQUE(kind, name)
);
```

### `conditions`
Conditions Synced/Ready par ressource (modèle Kubernetes) :

```sql
CREATE TABLE xplane.conditions (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    resource_id     UUID REFERENCES xplane.managed_resources(id) ON DELETE CASCADE,
    condition_type  xplane.condition_type NOT NULL,         -- Synced, Ready, LastAsyncOperation
    status          BOOLEAN NOT NULL,
    reason          TEXT,
    message         TEXT,
    last_transition TIMESTAMPTZ DEFAULT now(),
    UNIQUE(resource_id, condition_type)
);
```

### `events`
Journal d'audit complet :

```sql
CREATE TABLE xplane.events (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    resource_id UUID REFERENCES xplane.managed_resources(id) ON DELETE CASCADE,
    event_type  xplane.event_type NOT NULL,                -- Normal, Warning
    reason      TEXT NOT NULL,
    message     TEXT,
    created_at  TIMESTAMPTZ DEFAULT now()
);
```

### `provider_configs`
Configuration de connexion (équivalent ProviderConfig Crossplane) :

```sql
CREATE TABLE xplane.provider_configs (
    name        TEXT PRIMARY KEY,
    spec        JSONB NOT NULL,        -- credentials, connection info
    created_at  TIMESTAMPTZ DEFAULT now()
);
```

---

## Fonctions clés

### API publique

| Fonction | Signature | Description |
|----------|-----------|-------------|
| `apply(kind, name, spec, provider_config?)` | `→ UUID` | Crée ou met à jour une ressource, puis lance `reconcile()` |
| `delete(kind, name)` | `→ BOOLEAN` | Marque pour suppression (soft delete + reconcile) |
| `reconcile(resource_id)` | `→ TABLE(status_code, message)` | Réconcilie une ressource : observe → diff → act |
| `reconcile_all()` | `→ TABLE(id, kind, name, status_code, message)` | Réconcilie toutes les ressources pending/en erreur |

### Helpers internes

| Fonction | Rôle |
|----------|------|
| `observe_resource(kind, name, spec)` | Inspecte l'état réel via `pg_catalog` (`pg_database`, `pg_roles`, `pg_namespace`, `pg_extension`) |
| `set_condition(resource_id, type, status, reason, message)` | Met à jour une condition (upsert) |
| `emit_event(resource_id, type, reason, message)` | Insère un événement d'audit |
| `validate_spec(kind, spec)` | Valide la spec JSONB selon le kind |
| `set_status(resource_id, observed)` | Met à jour le champ `status` avec l'état observé |

### Actions CRUD (par kind)

Chaque kind a 3 fonctions internes qui retournent `(status_code, message, observed)` :

- `create_<kind>(name, spec)` — Création (idempotente, retourne `already_exists` si existant)
- `update_<kind>(name, spec, observed)` — Mise à jour (retourne `no_change` si rien à faire)
- `delete_<kind>(name, spec)` — Suppression (idempotente, retourne `not_found` si absent)

Aucune action ne lève d'exception. Les erreurs sont capturées via `EXCEPTION WHEN OTHERS` et retournées comme `error` ou `permission_denied`.

---

## Spécificités du kind `ServiceAccount`

Le `ServiceAccount` est le kind le plus riche. Il :

1. Crée un rôle `LOGIN` avec mot de passe
2. Accorde `CONNECT` sur la database cible
3. Accorde `USAGE` sur les schemas listés
4. Applique des privileges granulaires (SELECT, INSERT, UPDATE, DELETE) par schema
5. Supporte les wildcards (`schema.*`) avec `DEFAULT PRIVILEGES` pour les tables futures
6. Gère l'héritage de roles (GRANT role TO service_account)

**Exemple de spec :**

```json
{
  "database": "myapp",
  "password": "s3cur3!",
  "schemas": ["public", "api"],
  "grants": [
    {"schema": "public", "privileges": ["SELECT", "INSERT"]},
    {"schema": "api", "privileges": ["SELECT"]},
    {"schema": "public.*", "privileges": ["SELECT"]}
  ],
  "roles": ["readonly"]
}
```

---

## Prérequis

- **PostgreSQL 14+** (testé sur 14, 15, 16, 17)
- Extension `pgcrypto` (pour `gen_random_uuid()`) ou PG 13+ natif
- Extension `pg_cron` (optionnel, pour réconciliation automatique)
- Rôle avec `CREATEROLE` et `CREATEDB` pour les actions de provisioning

---

## Conventions de code

### SQL

- **Schema dédié** : tout le code vit dans le schema `xplane`
- **Nommage** : `snake_case` pour tout (tables, colonnes, fonctions, enums)
- **Fonctions** : PL/pgSQL, `SECURITY DEFINER` pour les actions nécessitant des privileges élevés
- **Pas d'exception non gérée** : chaque action capture `EXCEPTION WHEN OTHERS` et retourne un status code
- **Idempotence** : toute opération peut être rejouée sans effet de bord
- **JSONB** : les specs et status utilisent JSONB pour la flexibilité
- **Enums PostgreSQL** : utilisés pour les types fermés (`resource_kind`, `condition_type`, `event_type`, `status_code`, `deletion_policy`)
- **Index** : index sur `(kind, name)`, `(resource_id, condition_type)`, et `deleted_at IS NOT NULL`
- **Commentaires** : chaque fonction a un `COMMENT ON FUNCTION` expliquant son rôle

### Git

- **Conventional Commits** : `feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `ci:`
- **Branches** : `main` (stable), `develop` (intégration), `feat/<nom>`, `fix/<nom>`
- **Semver** : `MAJOR.MINOR.PATCH` — MAJOR pour breaking changes sur le schéma

### Tests

- Utiliser **pgTAP** comme framework de test
- Chaque kind a ses tests unitaires
- Tests d'intégration pour les scénarios cross-kind (ex: ServiceAccount dépend de Database + Schema + Role)
- Tests d'idempotence systématiques (apply 2x = même résultat)
- Tests de recovery (simuler une erreur, vérifier que reconcile_all() corrige)
- CI : matrice PostgreSQL 14/15/16/17

---

## Commandes Makefile

```makefile
install          # Exécute sql/00-05 dans l'ordre sur la DB cible
uninstall        # DROP SCHEMA xplane CASCADE
test             # Lance pgTAP sur tests/
test-unit        # Tests unitaires uniquement
test-integration # Tests d'intégration
test-e2e         # Tests end-to-end
lint             # Vérifie les conventions SQL (plpgsql_check si disponible)
docker-up        # Lance la stack Docker (PG + XplanePLPG)
docker-down      # Arrête la stack
demo             # Exécute sql/05_examples.sql (scénario complet)
clean            # Supprime les artefacts de test
```

---

## Variables d'environnement

```bash
XPLANE_DB_HOST=localhost        # Hôte PostgreSQL
XPLANE_DB_PORT=5432             # Port
XPLANE_DB_NAME=postgres         # Database d'installation
XPLANE_DB_USER=postgres         # Utilisateur avec CREATEROLE + CREATEDB
XPLANE_DB_PASSWORD=             # Mot de passe
XPLANE_SCHEMA=xplane            # Schema d'installation (défaut: xplane)
XPLANE_CRON_INTERVAL=30         # Intervalle pg_cron en secondes (défaut: 30)
```

---

## Roadmap

### v0.1.0 — MVP
- [ ] Schema fondateur (tables, enums, index)
- [ ] Helpers (set_condition, emit_event, observe_resource)
- [ ] Actions CRUD pour les 5 kinds
- [ ] Reconciler (reconcile, reconcile_all)
- [ ] Tests unitaires pgTAP
- [ ] Dockerfile + docker-compose
- [ ] CI GitHub Actions (matrix PG 14-17)

### v0.2.0 — Production Hardening
- [ ] `pg_cron` intégration
- [ ] Gestion des `finalizers` (pre-delete hooks)
- [ ] Politique de retry avec backoff exponentiel
- [ ] Vues de monitoring (`resource_status`, `recent_events`, `stale_resources`)
- [ ] `SECURITY DEFINER` audit + least privilege
- [ ] Tests d'intégration et e2e complets
- [ ] Documentation complète des kinds

### v0.3.0 — Observabilité
- [ ] Métriques exposables (nombre de ressources par état, temps de réconciliation)
- [ ] Intégration Prometheus via `pg_stat_statements` ou custom
- [ ] Alerting rules (ressources stuck en `Synced=False`)
- [ ] Dashboard Grafana (template)

### v0.4.0 — Extensibilité
- [ ] Système de plugins pour kinds custom
- [ ] Kind `Table` (DDL déclaratif)
- [ ] Kind `Publication` / `Subscription` (logical replication)
- [ ] Kind `ForeignServer` / `ForeignTable` (FDW)
- [ ] Webhook/notify sur changement de condition

### v1.0.0 — Stable Release
- [ ] API stable, schéma gelé
- [ ] Migration tooling (upgrade entre versions)
- [ ] Documentation exhaustive + tutoriels
- [ ] Benchmarks de performance
- [ ] Security audit

---

## Modèle de sécurité

### Principe du moindre privilège

Le provider s'exécute avec un rôle dédié `xplane_admin` qui possède :
- `CREATEROLE` — pour créer/modifier des rôles et service accounts
- `CREATEDB` — pour créer des databases
- Ownership du schema `xplane` — pour gérer les tables internes

Les fonctions d'action sont `SECURITY DEFINER` et s'exécutent avec les privilèges de `xplane_admin`, permettant aux utilisateurs d'appeler `apply()` / `delete()` sans avoir eux-mêmes `CREATEROLE` / `CREATEDB`.

### Isolation

- Toutes les tables internes sont dans le schema `xplane`
- Les mots de passe dans les specs ServiceAccount doivent être gérés via un secret manager externe (le provider ne stocke jamais de mots de passe en clair dans `status`)
- Les `provider_configs` peuvent contenir des credentials chiffrés (recommandé : `pgcrypto`)

---

## Mapping Crossplane → XplanePLPG

| Concept Crossplane           | Équivalent XplanePLPG                              |
|------------------------------|-----------------------------------------------------|
| Provider                     | Le provider SQL lui-même (installé dans PG)         |
| ProviderConfig               | Table `provider_configs`                            |
| Managed Resource (MR)        | Ligne dans `managed_resources`                      |
| `spec` (desired state)       | Colonne `spec` (JSONB)                              |
| `status` (observed state)    | Colonne `status` (JSONB) + `conditions`             |
| Condition `Synced`           | Condition dans table `conditions`                   |
| Condition `Ready`            | Condition dans table `conditions`                   |
| Reconciler / Controller      | Fonction `reconcile()` + `pg_cron`                  |
| Finalizers                   | Colonne `finalizers` (TEXT[])                        |
| Deletion Policy              | Colonne `deletion_policy` (enum: delete/orphan)     |
| Events                       | Table `events`                                      |
| `kubectl apply`              | `SELECT xplane.apply(...)`                          |
| `kubectl delete`             | `SELECT xplane.delete(...)`                         |
| `kubectl get`                | `SELECT * FROM xplane.resource_status`              |
| `kubectl describe`           | Jointure `managed_resources` + `conditions` + `events`|

---

## Règles pour Claude (contexte de développement)

Quand tu travailles sur ce projet :

1. **Toujours** écrire du SQL PL/pgSQL compatible PostgreSQL 14+
2. **Jamais** lever d'exception non capturée dans les actions — retourner un status code
3. **Toujours** émettre un événement (`emit_event`) pour chaque action significative
4. **Toujours** mettre à jour les conditions (`set_condition`) après chaque réconciliation
5. **Toujours** tester l'idempotence : `apply()` 2 fois de suite = même résultat
6. **Toujours** observer l'état réel via `pg_catalog` (jamais faire confiance au `status` stocké)
7. **Toujours** utiliser le schema `xplane` pour toutes les fonctions et tables
8. **Toujours** documenter chaque fonction avec `COMMENT ON FUNCTION`
9. **Toujours** écrire les tests pgTAP correspondants pour tout nouveau code
10. **Jamais** stocker de secrets (mots de passe) dans la colonne `status`
11. **Toujours** respecter le nommage `snake_case`
12. **Toujours** retourner `(status_code, message, observed)` depuis les actions CRUD
13. **Privilégier** les `UPSERT` (INSERT ... ON CONFLICT) pour l'idempotence
14. **Utiliser** `SECURITY DEFINER` uniquement sur les fonctions qui nécessitent des privilèges élevés
15. **Toujours** inclure `SET search_path = xplane, pg_catalog` dans les fonctions `SECURITY DEFINER`
