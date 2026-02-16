-- ============================================================================
-- ACTIONS CRUD PAR TYPE DE RESSOURCE
-- ============================================================================
-- Chaque action retourne un status_code et un message.
-- Convention : les fonctions ne lèvent PAS d'exception,
-- elles retournent un status code permettant au reconciler de décider.
-- ============================================================================

-- ############################################################################
-- DATABASE
-- ############################################################################

CREATE OR REPLACE FUNCTION crossplane.create_database(p_spec JSONB)
RETURNS TABLE(status crossplane.status_code, message TEXT, observed JSONB)
LANGUAGE plpgsql AS $$
DECLARE
    v_db_name   TEXT := p_spec->>'name';
    v_owner     TEXT := COALESCE(p_spec->>'owner', 'postgres');
    v_encoding  TEXT := COALESCE(p_spec->>'encoding', 'UTF8');
    v_lc_collate TEXT := p_spec->>'lc_collate';
    v_lc_ctype  TEXT := p_spec->>'lc_ctype';
    v_conn_limit INTEGER := COALESCE((p_spec->>'connection_limit')::INTEGER, -1);
    v_sql       TEXT;
BEGIN
    -- Vérifier si la base existe déjà
    IF EXISTS (SELECT 1 FROM pg_database WHERE datname = v_db_name) THEN
        RETURN QUERY SELECT
            '409_CONFLICT'::crossplane.status_code,
            format('Database %I already exists', v_db_name),
            crossplane.observe_resource('Database', p_spec);
        RETURN;
    END IF;

    -- Vérifier que le owner existe
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_owner) THEN
        RETURN QUERY SELECT
            '422_UNPROCESSABLE'::crossplane.status_code,
            format('Owner role %I does not exist', v_owner),
            '{}'::JSONB;
        RETURN;
    END IF;

    -- Construire le DDL
    v_sql := format('CREATE DATABASE %I OWNER %I ENCODING %L CONNECTION LIMIT %s',
                    v_db_name, v_owner, v_encoding, v_conn_limit);

    IF v_lc_collate IS NOT NULL THEN
        v_sql := v_sql || format(' LC_COLLATE %L', v_lc_collate);
    END IF;
    IF v_lc_ctype IS NOT NULL THEN
        v_sql := v_sql || format(' LC_CTYPE %L', v_lc_ctype);
    END IF;

    -- Exécuter (CREATE DATABASE ne peut pas être dans une transaction)
    -- On utilise dblink pour exécuter hors transaction
    BEGIN
        PERFORM dblink_exec('dbname=' || current_database(), v_sql);

        RETURN QUERY SELECT
            '201_CREATED'::crossplane.status_code,
            format('Database %I created successfully', v_db_name),
            crossplane.observe_resource('Database', p_spec);
    EXCEPTION WHEN OTHERS THEN
        RETURN QUERY SELECT
            '500_INTERNAL_ERROR'::crossplane.status_code,
            format('Failed to create database %I: %s', v_db_name, SQLERRM),
            '{}'::JSONB;
    END;
END;
$$;

CREATE OR REPLACE FUNCTION crossplane.update_database(p_spec JSONB, p_observed JSONB)
RETURNS TABLE(status crossplane.status_code, message TEXT, observed JSONB)
LANGUAGE plpgsql AS $$
DECLARE
    v_db_name   TEXT := p_spec->>'name';
    v_owner     TEXT := p_spec->>'owner';
    v_conn_limit INTEGER;
    v_changed   BOOLEAN := FALSE;
BEGIN
    -- Vérifier le changement de owner
    IF v_owner IS NOT NULL AND v_owner != (p_observed->>'owner') THEN
        EXECUTE format('ALTER DATABASE %I OWNER TO %I', v_db_name, v_owner);
        v_changed := TRUE;
    END IF;

    -- Vérifier le changement de connection_limit
    IF p_spec ? 'connection_limit' THEN
        v_conn_limit := (p_spec->>'connection_limit')::INTEGER;
        IF v_conn_limit != (p_observed->>'connection_limit')::INTEGER THEN
            EXECUTE format('ALTER DATABASE %I CONNECTION LIMIT %s', v_db_name, v_conn_limit);
            v_changed := TRUE;
        END IF;
    END IF;

    IF v_changed THEN
        RETURN QUERY SELECT
            '202_UPDATED'::crossplane.status_code,
            format('Database %I updated', v_db_name),
            crossplane.observe_resource('Database', p_spec);
    ELSE
        RETURN QUERY SELECT
            '204_NO_CHANGE'::crossplane.status_code,
            format('Database %I already matches desired state', v_db_name),
            p_observed;
    END IF;

EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT
        '500_INTERNAL_ERROR'::crossplane.status_code,
        format('Failed to update database %I: %s', v_db_name, SQLERRM),
        p_observed;
END;
$$;

CREATE OR REPLACE FUNCTION crossplane.delete_database(p_spec JSONB)
RETURNS TABLE(status crossplane.status_code, message TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    v_db_name TEXT := p_spec->>'name';
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = v_db_name) THEN
        RETURN QUERY SELECT '204_NO_CHANGE'::crossplane.status_code,
                            format('Database %I does not exist, nothing to delete', v_db_name);
        RETURN;
    END IF;

    -- Terminer les connexions actives
    PERFORM pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE datname = v_db_name AND pid != pg_backend_pid();

    BEGIN
        PERFORM dblink_exec('dbname=' || current_database(),
                           format('DROP DATABASE %I', v_db_name));

        RETURN QUERY SELECT '203_DELETED'::crossplane.status_code,
                            format('Database %I deleted', v_db_name);
    EXCEPTION WHEN OTHERS THEN
        RETURN QUERY SELECT '500_INTERNAL_ERROR'::crossplane.status_code,
                            format('Failed to delete database %I: %s', v_db_name, SQLERRM);
    END;
END;
$$;


-- ############################################################################
-- SCHEMA
-- ############################################################################

CREATE OR REPLACE FUNCTION crossplane.create_schema(p_spec JSONB)
RETURNS TABLE(status crossplane.status_code, message TEXT, observed JSONB)
LANGUAGE plpgsql AS $$
DECLARE
    v_schema_name TEXT := p_spec->>'name';
    v_owner       TEXT := COALESCE(p_spec->>'owner', 'postgres');
    v_database    TEXT := p_spec->>'database';
BEGIN
    -- Vérifier existence
    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = v_schema_name) THEN
        RETURN QUERY SELECT
            '409_CONFLICT'::crossplane.status_code,
            format('Schema %I already exists', v_schema_name),
            crossplane.observe_resource('Schema', p_spec);
        RETURN;
    END IF;

    EXECUTE format('CREATE SCHEMA %I AUTHORIZATION %I', v_schema_name, v_owner);

    RETURN QUERY SELECT
        '201_CREATED'::crossplane.status_code,
        format('Schema %I created with owner %I', v_schema_name, v_owner),
        crossplane.observe_resource('Schema', p_spec);

EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT
        '500_INTERNAL_ERROR'::crossplane.status_code,
        format('Failed to create schema %I: %s', v_schema_name, SQLERRM),
        '{}'::JSONB;
END;
$$;

CREATE OR REPLACE FUNCTION crossplane.update_schema(p_spec JSONB, p_observed JSONB)
RETURNS TABLE(status crossplane.status_code, message TEXT, observed JSONB)
LANGUAGE plpgsql AS $$
DECLARE
    v_schema_name TEXT := p_spec->>'name';
    v_owner       TEXT := p_spec->>'owner';
    v_changed     BOOLEAN := FALSE;
BEGIN
    IF v_owner IS NOT NULL AND v_owner != (p_observed->>'owner') THEN
        EXECUTE format('ALTER SCHEMA %I OWNER TO %I', v_schema_name, v_owner);
        v_changed := TRUE;
    END IF;

    IF v_changed THEN
        RETURN QUERY SELECT '202_UPDATED'::crossplane.status_code,
                            format('Schema %I updated', v_schema_name),
                            crossplane.observe_resource('Schema', p_spec);
    ELSE
        RETURN QUERY SELECT '204_NO_CHANGE'::crossplane.status_code,
                            format('Schema %I unchanged', v_schema_name),
                            p_observed;
    END IF;

EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT '500_INTERNAL_ERROR'::crossplane.status_code,
                        format('Failed to update schema %I: %s', v_schema_name, SQLERRM),
                        p_observed;
END;
$$;

CREATE OR REPLACE FUNCTION crossplane.delete_schema(p_spec JSONB)
RETURNS TABLE(status crossplane.status_code, message TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    v_schema_name TEXT := p_spec->>'name';
    v_cascade     BOOLEAN := COALESCE((p_spec->>'cascade')::BOOLEAN, FALSE);
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = v_schema_name) THEN
        RETURN QUERY SELECT '204_NO_CHANGE'::crossplane.status_code,
                            format('Schema %I does not exist', v_schema_name);
        RETURN;
    END IF;

    IF v_cascade THEN
        EXECUTE format('DROP SCHEMA %I CASCADE', v_schema_name);
    ELSE
        EXECUTE format('DROP SCHEMA %I RESTRICT', v_schema_name);
    END IF;

    RETURN QUERY SELECT '203_DELETED'::crossplane.status_code,
                        format('Schema %I deleted', v_schema_name);

EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT '500_INTERNAL_ERROR'::crossplane.status_code,
                        format('Failed to delete schema %I: %s', v_schema_name, SQLERRM);
END;
$$;


-- ############################################################################
-- ROLE (RBAC)
-- ############################################################################

CREATE OR REPLACE FUNCTION crossplane.create_role(p_spec JSONB)
RETURNS TABLE(status crossplane.status_code, message TEXT, observed JSONB)
LANGUAGE plpgsql AS $$
DECLARE
    v_role_name TEXT := p_spec->>'name';
    v_sql       TEXT;
    v_grant     TEXT;
    v_member_of JSONB;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role_name) THEN
        RETURN QUERY SELECT '409_CONFLICT'::crossplane.status_code,
                            format('Role %I already exists', v_role_name),
                            crossplane.observe_resource('Role', p_spec);
        RETURN;
    END IF;

    -- Construire CREATE ROLE avec options
    v_sql := format('CREATE ROLE %I', v_role_name);

    -- Options booléennes
    IF COALESCE((p_spec->>'superuser')::BOOLEAN, FALSE) THEN
        v_sql := v_sql || ' SUPERUSER';
    ELSE
        v_sql := v_sql || ' NOSUPERUSER';
    END IF;

    IF COALESCE((p_spec->>'createdb')::BOOLEAN, FALSE) THEN
        v_sql := v_sql || ' CREATEDB';
    ELSE
        v_sql := v_sql || ' NOCREATEDB';
    END IF;

    IF COALESCE((p_spec->>'createrole')::BOOLEAN, FALSE) THEN
        v_sql := v_sql || ' CREATEROLE';
    ELSE
        v_sql := v_sql || ' NOCREATEROLE';
    END IF;

    IF COALESCE((p_spec->>'login')::BOOLEAN, FALSE) THEN
        v_sql := v_sql || ' LOGIN';
    ELSE
        v_sql := v_sql || ' NOLOGIN';
    END IF;

    IF COALESCE((p_spec->>'replication')::BOOLEAN, FALSE) THEN
        v_sql := v_sql || ' REPLICATION';
    ELSE
        v_sql := v_sql || ' NOREPLICATION';
    END IF;

    IF COALESCE((p_spec->>'inherit')::BOOLEAN, TRUE) THEN
        v_sql := v_sql || ' INHERIT';
    ELSE
        v_sql := v_sql || ' NOINHERIT';
    END IF;

    -- Connection limit
    IF p_spec ? 'connection_limit' THEN
        v_sql := v_sql || format(' CONNECTION LIMIT %s', (p_spec->>'connection_limit')::INTEGER);
    END IF;

    -- Valid until
    IF p_spec ? 'valid_until' THEN
        v_sql := v_sql || format(' VALID UNTIL %L', p_spec->>'valid_until');
    END IF;

    -- Password (si fourni)
    IF p_spec ? 'password' THEN
        v_sql := v_sql || format(' PASSWORD %L', p_spec->>'password');
    END IF;

    EXECUTE v_sql;

    -- Membership : GRANT parent_role TO this_role
    v_member_of := p_spec->'memberOf';
    IF v_member_of IS NOT NULL AND jsonb_typeof(v_member_of) = 'array' THEN
        FOR v_grant IN SELECT jsonb_array_elements_text(v_member_of) LOOP
            IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_grant) THEN
                EXECUTE format('GRANT %I TO %I', v_grant, v_role_name);
            END IF;
        END LOOP;
    END IF;

    RETURN QUERY SELECT '201_CREATED'::crossplane.status_code,
                        format('Role %I created', v_role_name),
                        crossplane.observe_resource('Role', p_spec);

EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT '500_INTERNAL_ERROR'::crossplane.status_code,
                        format('Failed to create role %I: %s', v_role_name, SQLERRM),
                        '{}'::JSONB;
END;
$$;

CREATE OR REPLACE FUNCTION crossplane.update_role(p_spec JSONB, p_observed JSONB)
RETURNS TABLE(status crossplane.status_code, message TEXT, observed JSONB)
LANGUAGE plpgsql AS $$
DECLARE
    v_role_name TEXT := p_spec->>'name';
    v_sql       TEXT := '';
    v_changed   BOOLEAN := FALSE;
BEGIN
    -- Comparer et construire ALTER ROLE
    v_sql := format('ALTER ROLE %I', v_role_name);

    -- Comparer chaque attribut booléen
    IF (p_spec->>'superuser')::BOOLEAN IS DISTINCT FROM (p_observed->>'superuser')::BOOLEAN THEN
        IF COALESCE((p_spec->>'superuser')::BOOLEAN, FALSE) THEN
            v_sql := v_sql || ' SUPERUSER'; ELSE v_sql := v_sql || ' NOSUPERUSER';
        END IF;
        v_changed := TRUE;
    END IF;

    IF (p_spec->>'login')::BOOLEAN IS DISTINCT FROM (p_observed->>'login')::BOOLEAN THEN
        IF COALESCE((p_spec->>'login')::BOOLEAN, FALSE) THEN
            v_sql := v_sql || ' LOGIN'; ELSE v_sql := v_sql || ' NOLOGIN';
        END IF;
        v_changed := TRUE;
    END IF;

    IF (p_spec->>'createdb')::BOOLEAN IS DISTINCT FROM (p_observed->>'createdb')::BOOLEAN THEN
        IF COALESCE((p_spec->>'createdb')::BOOLEAN, FALSE) THEN
            v_sql := v_sql || ' CREATEDB'; ELSE v_sql := v_sql || ' NOCREATEDB';
        END IF;
        v_changed := TRUE;
    END IF;

    IF (p_spec->>'createrole')::BOOLEAN IS DISTINCT FROM (p_observed->>'createrole')::BOOLEAN THEN
        IF COALESCE((p_spec->>'createrole')::BOOLEAN, FALSE) THEN
            v_sql := v_sql || ' CREATEROLE'; ELSE v_sql := v_sql || ' NOCREATEROLE';
        END IF;
        v_changed := TRUE;
    END IF;

    IF p_spec ? 'connection_limit' AND
       (p_spec->>'connection_limit')::INTEGER != (p_observed->>'connection_limit')::INTEGER THEN
        v_sql := v_sql || format(' CONNECTION LIMIT %s', (p_spec->>'connection_limit')::INTEGER);
        v_changed := TRUE;
    END IF;

    IF v_changed THEN
        EXECUTE v_sql;
        RETURN QUERY SELECT '202_UPDATED'::crossplane.status_code,
                            format('Role %I updated', v_role_name),
                            crossplane.observe_resource('Role', p_spec);
    ELSE
        RETURN QUERY SELECT '204_NO_CHANGE'::crossplane.status_code,
                            format('Role %I unchanged', v_role_name),
                            p_observed;
    END IF;

EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT '500_INTERNAL_ERROR'::crossplane.status_code,
                        format('Failed to update role %I: %s', v_role_name, SQLERRM),
                        p_observed;
END;
$$;

CREATE OR REPLACE FUNCTION crossplane.delete_role(p_spec JSONB)
RETURNS TABLE(status crossplane.status_code, message TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    v_role_name TEXT := p_spec->>'name';
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role_name) THEN
        RETURN QUERY SELECT '204_NO_CHANGE'::crossplane.status_code,
                            format('Role %I does not exist', v_role_name);
        RETURN;
    END IF;

    -- Révoquer les memberships
    EXECUTE format('REASSIGN OWNED BY %I TO postgres', v_role_name);
    EXECUTE format('DROP OWNED BY %I', v_role_name);
    EXECUTE format('DROP ROLE %I', v_role_name);

    RETURN QUERY SELECT '203_DELETED'::crossplane.status_code,
                        format('Role %I deleted', v_role_name);

EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT '500_INTERNAL_ERROR'::crossplane.status_code,
                        format('Failed to delete role %I: %s', v_role_name, SQLERRM);
END;
$$;


-- ############################################################################
-- SERVICE ACCOUNT (Role + Grants ciblés)
-- ############################################################################

CREATE OR REPLACE FUNCTION crossplane.create_service_account(p_spec JSONB)
RETURNS TABLE(status crossplane.status_code, message TEXT, observed JSONB)
LANGUAGE plpgsql AS $$
DECLARE
    v_sa_name    TEXT := p_spec->>'name';
    v_database   TEXT := p_spec->>'database';
    v_schemas    JSONB := p_spec->'schemas';
    v_privileges JSONB := p_spec->'privileges';
    v_schema     TEXT;
    v_priv       TEXT;
    v_password   TEXT := p_spec->>'password';
    v_valid_until TEXT := p_spec->>'valid_until';
    v_conn_limit INTEGER := COALESCE((p_spec->>'connection_limit')::INTEGER, 10);
    v_sql        TEXT;
BEGIN
    -- Vérifier si le role existe
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_sa_name) THEN
        RETURN QUERY SELECT '409_CONFLICT'::crossplane.status_code,
                            format('ServiceAccount role %I already exists', v_sa_name),
                            crossplane.observe_resource('ServiceAccount', p_spec);
        RETURN;
    END IF;

    -- Créer le role avec LOGIN
    v_sql := format('CREATE ROLE %I LOGIN CONNECTION LIMIT %s', v_sa_name, v_conn_limit);

    IF v_password IS NOT NULL THEN
        v_sql := v_sql || format(' PASSWORD %L', v_password);
    END IF;

    IF v_valid_until IS NOT NULL THEN
        v_sql := v_sql || format(' VALID UNTIL %L', v_valid_until);
    END IF;

    EXECUTE v_sql;

    -- GRANT CONNECT sur la database
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO %I', v_database, v_sa_name);

    -- GRANT USAGE sur les schemas spécifiés
    IF v_schemas IS NOT NULL AND jsonb_typeof(v_schemas) = 'array' THEN
        FOR v_schema IN SELECT jsonb_array_elements_text(v_schemas) LOOP
            EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I', v_schema, v_sa_name);
        END LOOP;
    END IF;

    -- Appliquer les privileges
    -- Format attendu : {"select": ["schema.table", ...], "insert": [...], "all": ["schema.*"]}
    IF v_privileges IS NOT NULL THEN
        FOR v_priv IN SELECT jsonb_object_keys(v_privileges) LOOP
            DECLARE
                v_target TEXT;
                v_targets JSONB := v_privileges->v_priv;
            BEGIN
                FOR v_target IN SELECT jsonb_array_elements_text(v_targets) LOOP
                    IF v_target LIKE '%.*' THEN
                        -- Wildcard : GRANT sur ALL TABLES IN SCHEMA
                        EXECUTE format(
                            'GRANT %s ON ALL TABLES IN SCHEMA %I TO %I',
                            UPPER(v_priv),
                            split_part(v_target, '.', 1),
                            v_sa_name
                        );
                        -- Default privileges pour les futures tables
                        EXECUTE format(
                            'ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT %s ON TABLES TO %I',
                            split_part(v_target, '.', 1),
                            UPPER(v_priv),
                            v_sa_name
                        );
                    ELSE
                        -- Table spécifique
                        EXECUTE format(
                            'GRANT %s ON %s TO %I',
                            UPPER(v_priv),
                            v_target,
                            v_sa_name
                        );
                    END IF;
                END LOOP;
            END;
        END LOOP;
    END IF;

    RETURN QUERY SELECT '201_CREATED'::crossplane.status_code,
                        format('ServiceAccount %I created with grants on %s', v_sa_name, v_database),
                        crossplane.observe_resource('ServiceAccount', p_spec);

EXCEPTION WHEN OTHERS THEN
    -- Rollback partiel : tenter de supprimer le role si créé
    BEGIN
        EXECUTE format('DROP ROLE IF EXISTS %I', v_sa_name);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    RETURN QUERY SELECT '500_INTERNAL_ERROR'::crossplane.status_code,
                        format('Failed to create ServiceAccount %I: %s', v_sa_name, SQLERRM),
                        '{}'::JSONB;
END;
$$;

CREATE OR REPLACE FUNCTION crossplane.update_service_account(p_spec JSONB, p_observed JSONB)
RETURNS TABLE(status crossplane.status_code, message TEXT, observed JSONB)
LANGUAGE plpgsql AS $$
DECLARE
    v_sa_name     TEXT := p_spec->>'name';
    v_database    TEXT := p_spec->>'database';
    v_conn_limit  INTEGER;
    v_valid_until TEXT;
    v_password    TEXT;
    v_schemas     JSONB;
    v_schema      TEXT;
    v_changed     BOOLEAN := FALSE;
    v_changes     TEXT[] := '{}';
BEGIN
    -- 1. Connection limit
    IF p_spec ? 'connection_limit' THEN
        v_conn_limit := (p_spec->>'connection_limit')::INTEGER;
        IF v_conn_limit IS DISTINCT FROM (p_observed->>'connection_limit')::INTEGER THEN
            EXECUTE format('ALTER ROLE %I CONNECTION LIMIT %s', v_sa_name, v_conn_limit);
            v_changed := TRUE;
            v_changes := array_append(v_changes, 'connection_limit');
        END IF;
    END IF;

    -- 2. Valid until
    v_valid_until := p_spec->>'valid_until';
    IF v_valid_until IS NOT NULL AND v_valid_until IS DISTINCT FROM (p_observed->>'valid_until') THEN
        EXECUTE format('ALTER ROLE %I VALID UNTIL %L', v_sa_name, v_valid_until);
        v_changed := TRUE;
        v_changes := array_append(v_changes, 'valid_until');
    END IF;

    -- 3. Password (always apply if present — cannot compare with pg_catalog)
    v_password := p_spec->>'password';
    IF v_password IS NOT NULL THEN
        EXECUTE format('ALTER ROLE %I PASSWORD %L', v_sa_name, v_password);
        v_changed := TRUE;
        v_changes := array_append(v_changes, 'password');
    END IF;

    -- 4. Schema USAGE grants (add missing schemas)
    v_schemas := p_spec->'schemas';
    IF v_schemas IS NOT NULL AND jsonb_typeof(v_schemas) = 'array' THEN
        FOR v_schema IN SELECT jsonb_array_elements_text(v_schemas) LOOP
            IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = v_schema) THEN
                EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I', v_schema, v_sa_name);
            END IF;
        END LOOP;
        v_changed := TRUE;
        v_changes := array_append(v_changes, 'schemas');
    END IF;

    IF v_changed THEN
        RETURN QUERY SELECT '202_UPDATED'::crossplane.status_code,
                            format('ServiceAccount %I updated: %s', v_sa_name, array_to_string(v_changes, ', ')),
                            crossplane.observe_resource('ServiceAccount', p_spec);
    ELSE
        RETURN QUERY SELECT '204_NO_CHANGE'::crossplane.status_code,
                            format('ServiceAccount %I unchanged', v_sa_name),
                            p_observed;
    END IF;

EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT '500_INTERNAL_ERROR'::crossplane.status_code,
                        format('Failed to update ServiceAccount %I: %s', v_sa_name, SQLERRM),
                        p_observed;
END;
$$;

COMMENT ON FUNCTION crossplane.update_service_account(JSONB, JSONB)
IS 'Update a ServiceAccount: role attributes (connection_limit, valid_until, password) and schema USAGE grants. Full privilege reconciliation deferred to v0.2.0.';


CREATE OR REPLACE FUNCTION crossplane.delete_service_account(p_spec JSONB)
RETURNS TABLE(status crossplane.status_code, message TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    v_sa_name TEXT := p_spec->>'name';
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_sa_name) THEN
        RETURN QUERY SELECT '204_NO_CHANGE'::crossplane.status_code,
                            format('ServiceAccount %I does not exist', v_sa_name);
        RETURN;
    END IF;

    -- Terminer les sessions
    PERFORM pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE usename = v_sa_name AND pid != pg_backend_pid();

    EXECUTE format('REASSIGN OWNED BY %I TO postgres', v_sa_name);
    EXECUTE format('DROP OWNED BY %I', v_sa_name);
    EXECUTE format('DROP ROLE %I', v_sa_name);

    RETURN QUERY SELECT '203_DELETED'::crossplane.status_code,
                        format('ServiceAccount %I deleted', v_sa_name);

EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT '500_INTERNAL_ERROR'::crossplane.status_code,
                        format('Failed to delete ServiceAccount %I: %s', v_sa_name, SQLERRM);
END;
$$;


-- ############################################################################
-- EXTENSION
-- ############################################################################

CREATE OR REPLACE FUNCTION crossplane.create_extension(p_spec JSONB)
RETURNS TABLE(status crossplane.status_code, message TEXT, observed JSONB)
LANGUAGE plpgsql AS $$
DECLARE
    v_ext_name TEXT := p_spec->>'name';
    v_schema   TEXT := p_spec->>'schema';
    v_version  TEXT := p_spec->>'version';
    v_sql      TEXT;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = v_ext_name) THEN
        RETURN QUERY SELECT '409_CONFLICT'::crossplane.status_code,
                            format('Extension %I already exists', v_ext_name),
                            crossplane.observe_resource('Extension', p_spec);
        RETURN;
    END IF;

    v_sql := format('CREATE EXTENSION IF NOT EXISTS %I', v_ext_name);

    IF v_schema IS NOT NULL THEN
        v_sql := v_sql || format(' SCHEMA %I', v_schema);
    END IF;

    IF v_version IS NOT NULL THEN
        v_sql := v_sql || format(' VERSION %L', v_version);
    END IF;

    EXECUTE v_sql;

    RETURN QUERY SELECT '201_CREATED'::crossplane.status_code,
                        format('Extension %I installed', v_ext_name),
                        crossplane.observe_resource('Extension', p_spec);

EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT '500_INTERNAL_ERROR'::crossplane.status_code,
                        format('Failed to create extension %I: %s', v_ext_name, SQLERRM),
                        '{}'::JSONB;
END;
$$;

CREATE OR REPLACE FUNCTION crossplane.update_extension(p_spec JSONB, p_observed JSONB)
RETURNS TABLE(status crossplane.status_code, message TEXT, observed JSONB)
LANGUAGE plpgsql AS $$
DECLARE
    v_ext_name TEXT := p_spec->>'name';
    v_version  TEXT := p_spec->>'version';
BEGIN
    -- Vérifier si une mise à jour de version est nécessaire
    IF v_version IS NOT NULL AND v_version != (p_observed->>'version') THEN
        EXECUTE format('ALTER EXTENSION %I UPDATE TO %L', v_ext_name, v_version);

        RETURN QUERY SELECT '202_UPDATED'::crossplane.status_code,
                            format('Extension %I updated to version %s', v_ext_name, v_version),
                            crossplane.observe_resource('Extension', p_spec);
    ELSE
        RETURN QUERY SELECT '204_NO_CHANGE'::crossplane.status_code,
                            format('Extension %I unchanged', v_ext_name),
                            p_observed;
    END IF;

EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT '500_INTERNAL_ERROR'::crossplane.status_code,
                        format('Failed to update extension %I: %s', v_ext_name, SQLERRM),
                        p_observed;
END;
$$;

CREATE OR REPLACE FUNCTION crossplane.delete_extension(p_spec JSONB)
RETURNS TABLE(status crossplane.status_code, message TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    v_ext_name TEXT := p_spec->>'name';
    v_cascade  BOOLEAN := COALESCE((p_spec->>'cascade')::BOOLEAN, FALSE);
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = v_ext_name) THEN
        RETURN QUERY SELECT '204_NO_CHANGE'::crossplane.status_code,
                            format('Extension %I does not exist', v_ext_name);
        RETURN;
    END IF;

    IF v_cascade THEN
        EXECUTE format('DROP EXTENSION %I CASCADE', v_ext_name);
    ELSE
        EXECUTE format('DROP EXTENSION %I RESTRICT', v_ext_name);
    END IF;

    RETURN QUERY SELECT '203_DELETED'::crossplane.status_code,
                        format('Extension %I removed', v_ext_name);

EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT '500_INTERNAL_ERROR'::crossplane.status_code,
                        format('Failed to delete extension %I: %s', v_ext_name, SQLERRM);
END;
$$;
