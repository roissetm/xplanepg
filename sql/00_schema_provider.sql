-- ============================================================================
-- CROSSPLANE-STYLE POSTGRESQL PROVIDER IN PL/pgSQL
-- ============================================================================
-- Ce provider implémente un système de réconciliation inspiré de Crossplane
-- pour provisionner des ressources PostgreSQL : Databases, Schemas, Roles/RBAC,
-- Service Accounts et Extensions.
--
-- Architecture :
--   1. Table de registre des ressources (Managed Resources)
--   2. Conditions de status (Synced, Ready) comme Crossplane
--   3. Boucle de réconciliation via pg_cron ou appel manuel
--   4. Actions CRUD avec status codes normalisés
-- ============================================================================

-- Schema dédié au provider
CREATE SCHEMA IF NOT EXISTS crossplane;

-- ============================================================================
-- ENUMS & TYPES
-- ============================================================================

-- Types de ressources gérées
CREATE TYPE crossplane.resource_kind AS ENUM (
    'Database',
    'Schema',
    'Role',
    'ServiceAccount',
    'Extension'
);

-- Status codes des actions (inspirés HTTP mais adaptés IaC)
-- 1xx : En cours / Informatif
-- 2xx : Succès
-- 4xx : Erreur client (spec invalide)
-- 5xx : Erreur serveur (provider/infra)
CREATE TYPE crossplane.status_code AS ENUM (
    -- Informatif / En cours
    '100_PENDING',          -- Ressource en attente de traitement
    '101_RECONCILING',      -- Réconciliation en cours
    '102_CREATING',         -- Création en cours
    '103_UPDATING',         -- Mise à jour en cours
    '104_DELETING',         -- Suppression en cours

    -- Succès
    '200_SYNCED',           -- Synced avec l'état désiré
    '201_CREATED',          -- Ressource créée avec succès
    '202_UPDATED',          -- Ressource mise à jour
    '203_DELETED',          -- Ressource supprimée
    '204_NO_CHANGE',        -- Aucun changement nécessaire (drift = 0)

    -- Erreurs client (spec)
    '400_INVALID_SPEC',     -- Spec invalide (champs manquants, valeurs incorrectes)
    '404_NOT_FOUND',        -- Ressource externe introuvable (pour update/delete)
    '409_CONFLICT',         -- Conflit (ressource existe déjà, dépendance circulaire)
    '422_UNPROCESSABLE',    -- Spec valide syntaxiquement mais impossible à appliquer

    -- Erreurs serveur (provider)
    '500_INTERNAL_ERROR',   -- Erreur interne du provider
    '503_UNAVAILABLE',      -- Service cible indisponible
    '504_TIMEOUT'           -- Timeout de l'opération
);

-- Condition types (comme Crossplane)
CREATE TYPE crossplane.condition_type AS ENUM (
    'Synced',       -- Communication avec le système cible
    'Ready'         -- Ressource opérationnelle
);

CREATE TYPE crossplane.condition_status AS ENUM (
    'True',
    'False',
    'Unknown'
);

-- Desired state
CREATE TYPE crossplane.desired_state AS ENUM (
    'present',      -- La ressource doit exister
    'absent'        -- La ressource doit être supprimée
);

-- ============================================================================
-- TABLE PRINCIPALE : MANAGED RESOURCES
-- ============================================================================

CREATE TABLE IF NOT EXISTS crossplane.managed_resources (
    -- Identité
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    kind            crossplane.resource_kind NOT NULL,
    name            TEXT NOT NULL,

    -- Spec (état désiré) - JSONB pour flexibilité
    spec            JSONB NOT NULL DEFAULT '{}',

    -- Desired state (present/absent pour le delete)
    desired_state   crossplane.desired_state NOT NULL DEFAULT 'present',

    -- Provider config reference
    provider_config TEXT NOT NULL DEFAULT 'default',

    -- Status
    status_code     crossplane.status_code NOT NULL DEFAULT '100_PENDING',
    status_message  TEXT,

    -- Observed state (ce qui existe réellement)
    at_provider     JSONB DEFAULT '{}',

    -- Metadata
    generation      BIGINT NOT NULL DEFAULT 1,
    observed_generation BIGINT DEFAULT 0,
    reconcile_count INTEGER DEFAULT 0,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at      TIMESTAMPTZ,

    -- Contrainte d'unicité par kind + name
    UNIQUE (kind, name)
);

-- ============================================================================
-- TABLE DES CONDITIONS
-- ============================================================================

CREATE TABLE IF NOT EXISTS crossplane.conditions (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    resource_id         UUID NOT NULL REFERENCES crossplane.managed_resources(id) ON DELETE CASCADE,
    condition_type      crossplane.condition_type NOT NULL,
    status              crossplane.condition_status NOT NULL DEFAULT 'Unknown',
    reason              TEXT,
    message             TEXT,
    last_transition_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (resource_id, condition_type)
);

-- ============================================================================
-- TABLE DES EVENTS
-- ============================================================================

CREATE TABLE IF NOT EXISTS crossplane.events (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    resource_id UUID NOT NULL REFERENCES crossplane.managed_resources(id) ON DELETE CASCADE,
    event_type  TEXT NOT NULL,  -- Normal, Warning
    reason      TEXT NOT NULL,
    message     TEXT,
    status_code crossplane.status_code,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================================
-- TABLE PROVIDER CONFIGS
-- ============================================================================

CREATE TABLE IF NOT EXISTS crossplane.provider_configs (
    name            TEXT PRIMARY KEY,
    host            TEXT NOT NULL DEFAULT 'localhost',
    port            INTEGER NOT NULL DEFAULT 5432,
    admin_role      TEXT NOT NULL DEFAULT 'postgres',
    default_tablespace TEXT,
    connection_limit INTEGER DEFAULT -1,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Config par défaut
INSERT INTO crossplane.provider_configs (name)
VALUES ('default')
ON CONFLICT (name) DO NOTHING;

-- ============================================================================
-- INDEX
-- ============================================================================

CREATE INDEX IF NOT EXISTS idx_mr_kind ON crossplane.managed_resources(kind);
CREATE INDEX IF NOT EXISTS idx_mr_status ON crossplane.managed_resources(status_code);
CREATE INDEX IF NOT EXISTS idx_mr_desired ON crossplane.managed_resources(desired_state);
CREATE INDEX IF NOT EXISTS idx_events_resource ON crossplane.events(resource_id, created_at DESC);
