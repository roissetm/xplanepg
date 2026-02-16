-- ============================================================================
-- EXEMPLES D'UTILISATION DU PROVIDER
-- ============================================================================

-- ============================================================================
-- 1. PROVISIONNER UNE DATABASE
-- ============================================================================

SELECT crossplane.apply(
    'Database',
    'myapp-production',
    '{
        "name": "myapp_production",
        "owner": "postgres",
        "encoding": "UTF8",
        "connection_limit": 100
    }'::JSONB
);

-- Réconcilier immédiatement
SELECT * FROM crossplane.reconcile(
    (SELECT id FROM crossplane.managed_resources WHERE kind = 'Database' AND name = 'myapp-production')
);

-- ============================================================================
-- 2. CRÉER DES SCHEMAS
-- ============================================================================

SELECT crossplane.apply(
    'Schema',
    'myapp-api-schema',
    '{
        "name": "api",
        "database": "myapp_production",
        "owner": "postgres"
    }'::JSONB
);

SELECT crossplane.apply(
    'Schema',
    'myapp-analytics-schema',
    '{
        "name": "analytics",
        "database": "myapp_production",
        "owner": "postgres"
    }'::JSONB
);

-- ============================================================================
-- 3. CRÉER DES ROLES RBAC
-- ============================================================================

-- Role applicatif (groupe, sans login)
SELECT crossplane.apply(
    'Role',
    'app-readwrite',
    '{
        "name": "app_readwrite",
        "login": false,
        "inherit": true,
        "createdb": false,
        "createrole": false,
        "superuser": false
    }'::JSONB
);

-- Role lecture seule
SELECT crossplane.apply(
    'Role',
    'app-readonly',
    '{
        "name": "app_readonly",
        "login": false,
        "inherit": true,
        "createdb": false,
        "superuser": false
    }'::JSONB
);

-- Role admin applicatif
SELECT crossplane.apply(
    'Role',
    'app-admin',
    '{
        "name": "app_admin",
        "login": false,
        "inherit": true,
        "createdb": true,
        "createrole": true,
        "superuser": false,
        "memberOf": ["app_readwrite"]
    }'::JSONB
);

-- ============================================================================
-- 4. CRÉER DES SERVICE ACCOUNTS
-- ============================================================================

-- Service Account pour l'API backend
SELECT crossplane.apply(
    'ServiceAccount',
    'sa-api-backend',
    '{
        "name": "sa_api_backend",
        "database": "myapp_production",
        "password": "CHANGE_ME_USE_VAULT",
        "connection_limit": 20,
        "valid_until": "2026-12-31",
        "schemas": ["api", "public"],
        "privileges": {
            "select": ["api.*", "public.*"],
            "insert": ["api.*"],
            "update": ["api.*"],
            "delete": ["api.*"]
        }
    }'::JSONB
);

-- Service Account pour les analytics (lecture seule)
SELECT crossplane.apply(
    'ServiceAccount',
    'sa-analytics-reader',
    '{
        "name": "sa_analytics_reader",
        "database": "myapp_production",
        "password": "CHANGE_ME_USE_VAULT",
        "connection_limit": 5,
        "valid_until": "2026-06-30",
        "schemas": ["analytics", "api", "public"],
        "privileges": {
            "select": ["analytics.*", "api.*", "public.*"]
        }
    }'::JSONB
);

-- Service Account pour le job de migration
SELECT crossplane.apply(
    'ServiceAccount',
    'sa-migration',
    '{
        "name": "sa_migration",
        "database": "myapp_production",
        "password": "CHANGE_ME_USE_VAULT",
        "connection_limit": 2,
        "valid_until": "2026-03-31",
        "schemas": ["api", "public"],
        "privileges": {
            "all": ["api.*", "public.*"]
        }
    }'::JSONB
);

-- ============================================================================
-- 5. INSTALLER DES EXTENSIONS
-- ============================================================================

SELECT crossplane.apply(
    'Extension',
    'ext-uuid-ossp',
    '{
        "name": "uuid-ossp",
        "database": "myapp_production",
        "schema": "public"
    }'::JSONB
);

SELECT crossplane.apply(
    'Extension',
    'ext-pgcrypto',
    '{
        "name": "pgcrypto",
        "database": "myapp_production",
        "schema": "public"
    }'::JSONB
);

SELECT crossplane.apply(
    'Extension',
    'ext-pg-trgm',
    '{
        "name": "pg_trgm",
        "database": "myapp_production",
        "schema": "public"
    }'::JSONB
);

SELECT crossplane.apply(
    'Extension',
    'ext-postgis',
    '{
        "name": "postgis",
        "database": "myapp_production",
        "schema": "public",
        "version": "3.4.0"
    }'::JSONB
);

-- ============================================================================
-- 6. RÉCONCILIER TOUT
-- ============================================================================

SELECT * FROM crossplane.reconcile_all();

-- ============================================================================
-- 7. VÉRIFIER LE STATUS
-- ============================================================================

-- Dashboard complet
SELECT kind, name, status_code, synced, ready, status_message
FROM crossplane.resource_status;

-- Résultat attendu :
-- ┌────────────────┬────────────────────┬──────────────┬────────┬───────┬──────────────────────┐
-- │ kind           │ name               │ status_code  │ synced │ ready │ status_message       │
-- ├────────────────┼────────────────────┼──────────────┼────────┼───────┼──────────────────────┤
-- │ Database       │ myapp-production   │ 201_CREATED  │ True   │ True  │ Database created...  │
-- │ Schema         │ myapp-api-schema   │ 201_CREATED  │ True   │ True  │ Schema api created   │
-- │ Schema         │ myapp-analytics... │ 201_CREATED  │ True   │ True  │ Schema analytics...  │
-- │ Role           │ app-readwrite      │ 201_CREATED  │ True   │ True  │ Role created         │
-- │ Role           │ app-readonly       │ 201_CREATED  │ True   │ True  │ Role created         │
-- │ Role           │ app-admin          │ 201_CREATED  │ True   │ True  │ Role created         │
-- │ ServiceAccount │ sa-api-backend     │ 201_CREATED  │ True   │ True  │ SA created with...   │
-- │ Extension      │ ext-uuid-ossp      │ 201_CREATED  │ True   │ True  │ Extension installed  │
-- └────────────────┴────────────────────┴──────────────┴────────┴───────┴──────────────────────┘

-- Events récents
SELECT * FROM crossplane.recent_events;

-- ============================================================================
-- 8. METTRE À JOUR UNE RESSOURCE (drift correction)
-- ============================================================================

-- Changer le connection_limit d'un ServiceAccount
SELECT crossplane.apply(
    'ServiceAccount',
    'sa-api-backend',
    '{
        "name": "sa_api_backend",
        "database": "myapp_production",
        "password": "NEW_PASSWORD_FROM_VAULT",
        "connection_limit": 50,
        "valid_until": "2027-12-31",
        "schemas": ["api", "public", "analytics"],
        "privileges": {
            "select": ["api.*", "public.*", "analytics.*"],
            "insert": ["api.*"],
            "update": ["api.*"],
            "delete": ["api.*"]
        }
    }'::JSONB
);

-- Forcer la réconciliation
SELECT * FROM crossplane.reconcile(
    (SELECT id FROM crossplane.managed_resources WHERE name = 'sa-api-backend')
);

-- ============================================================================
-- 9. SUPPRIMER UNE RESSOURCE
-- ============================================================================

-- Marquer pour suppression
SELECT crossplane.delete('Extension', 'ext-postgis');

-- Réconcilier pour appliquer
SELECT * FROM crossplane.reconcile(
    (SELECT id FROM crossplane.managed_resources WHERE name = 'ext-postgis')
);

-- Vérifier
SELECT kind, name, status_code, synced, ready
FROM crossplane.resource_status
WHERE name = 'ext-postgis';

-- ============================================================================
-- 10. DIAGNOSTIC : RESSOURCES EN ERREUR
-- ============================================================================

SELECT kind, name, status_code, status_message,
       synced, synced_reason,
       ready, ready_reason,
       reconcile_count
FROM crossplane.resource_status
WHERE status_code::TEXT LIKE '4%'
   OR status_code::TEXT LIKE '5%';
