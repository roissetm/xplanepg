-- ============================================================================
-- FONCTIONS UTILITAIRES DU PROVIDER
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Mise à jour d'une condition (upsert)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crossplane.set_condition(
    p_resource_id UUID,
    p_type        crossplane.condition_type,
    p_status      crossplane.condition_status,
    p_reason      TEXT DEFAULT NULL,
    p_message     TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO crossplane.conditions (resource_id, condition_type, status, reason, message, last_transition_time)
    VALUES (p_resource_id, p_type, p_status, p_reason, p_message, NOW())
    ON CONFLICT (resource_id, condition_type) DO UPDATE SET
        status = EXCLUDED.status,
        reason = EXCLUDED.reason,
        message = EXCLUDED.message,
        last_transition_time = CASE
            WHEN crossplane.conditions.status != EXCLUDED.status THEN NOW()
            ELSE crossplane.conditions.last_transition_time
        END;
END;
$$;

-- ----------------------------------------------------------------------------
-- Émission d'un event
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crossplane.emit_event(
    p_resource_id UUID,
    p_event_type  TEXT,
    p_reason      TEXT,
    p_message     TEXT DEFAULT NULL,
    p_status_code crossplane.status_code DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql AS $$
DECLARE
    v_event_id UUID;
BEGIN
    INSERT INTO crossplane.events (resource_id, event_type, reason, message, status_code)
    VALUES (p_resource_id, p_event_type, p_reason, p_message, p_status_code)
    RETURNING id INTO v_event_id;

    -- Nettoyage : garder seulement les 100 derniers events par ressource
    DELETE FROM crossplane.events
    WHERE resource_id = p_resource_id
      AND id NOT IN (
          SELECT id FROM crossplane.events
          WHERE resource_id = p_resource_id
          ORDER BY created_at DESC
          LIMIT 100
      );

    RETURN v_event_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- Mise à jour du status d'une ressource
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crossplane.set_status(
    p_resource_id   UUID,
    p_status_code   crossplane.status_code,
    p_message       TEXT DEFAULT NULL,
    p_at_provider   JSONB DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE crossplane.managed_resources SET
        status_code    = p_status_code,
        status_message = COALESCE(p_message, status_message),
        at_provider    = COALESCE(p_at_provider, at_provider),
        updated_at     = NOW()
    WHERE id = p_resource_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- Validation de spec selon le kind
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crossplane.validate_spec(
    p_kind crossplane.resource_kind,
    p_spec JSONB
) RETURNS TABLE(valid BOOLEAN, error_message TEXT)
LANGUAGE plpgsql AS $$
BEGIN
    CASE p_kind

    WHEN 'Database' THEN
        IF p_spec->>'name' IS NULL OR p_spec->>'name' = '' THEN
            RETURN QUERY SELECT FALSE, 'spec.name is required for Database';
            RETURN;
        END IF;
        IF p_spec->>'owner' IS NULL THEN
            RETURN QUERY SELECT FALSE, 'spec.owner is required for Database';
            RETURN;
        END IF;

    WHEN 'Schema' THEN
        IF p_spec->>'name' IS NULL THEN
            RETURN QUERY SELECT FALSE, 'spec.name is required for Schema';
            RETURN;
        END IF;
        IF p_spec->>'database' IS NULL THEN
            RETURN QUERY SELECT FALSE, 'spec.database is required for Schema';
            RETURN;
        END IF;

    WHEN 'Role' THEN
        IF p_spec->>'name' IS NULL THEN
            RETURN QUERY SELECT FALSE, 'spec.name is required for Role';
            RETURN;
        END IF;

    WHEN 'ServiceAccount' THEN
        IF p_spec->>'name' IS NULL THEN
            RETURN QUERY SELECT FALSE, 'spec.name is required for ServiceAccount';
            RETURN;
        END IF;
        IF p_spec->>'database' IS NULL THEN
            RETURN QUERY SELECT FALSE, 'spec.database is required for ServiceAccount';
            RETURN;
        END IF;

    WHEN 'Extension' THEN
        IF p_spec->>'name' IS NULL THEN
            RETURN QUERY SELECT FALSE, 'spec.name is required for Extension';
            RETURN;
        END IF;
        IF p_spec->>'database' IS NULL THEN
            RETURN QUERY SELECT FALSE, 'spec.database is required for Extension';
            RETURN;
        END IF;

    END CASE;

    RETURN QUERY SELECT TRUE, NULL::TEXT;
END;
$$;

-- ----------------------------------------------------------------------------
-- Observe : récupérer l'état réel d'une ressource dans PostgreSQL
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crossplane.observe_resource(
    p_kind crossplane.resource_kind,
    p_spec JSONB
) RETURNS JSONB
LANGUAGE plpgsql AS $$
DECLARE
    v_result JSONB := '{}';
    v_exists BOOLEAN := FALSE;
    v_rec RECORD;
BEGIN
    CASE p_kind

    -- ========== DATABASE ==========
    WHEN 'Database' THEN
        SELECT INTO v_rec
            d.datname,
            r.rolname AS owner,
            pg_encoding_to_char(d.encoding) AS encoding,
            d.datcollate AS lc_collate,
            d.datctype AS lc_ctype,
            d.datconnlimit AS connection_limit,
            pg_database_size(d.datname) AS size_bytes
        FROM pg_database d
        JOIN pg_roles r ON d.datdba = r.oid
        WHERE d.datname = p_spec->>'name';

        IF FOUND THEN
            v_result := jsonb_build_object(
                'exists', TRUE,
                'name', v_rec.datname,
                'owner', v_rec.owner,
                'encoding', v_rec.encoding,
                'lc_collate', v_rec.lc_collate,
                'lc_ctype', v_rec.lc_ctype,
                'connection_limit', v_rec.connection_limit,
                'size_bytes', v_rec.size_bytes
            );
        ELSE
            v_result := '{"exists": false}'::JSONB;
        END IF;

    -- ========== SCHEMA ==========
    WHEN 'Schema' THEN
        SELECT INTO v_rec
            n.nspname,
            r.rolname AS owner
        FROM pg_namespace n
        JOIN pg_roles r ON n.nspowner = r.oid
        WHERE n.nspname = p_spec->>'name';

        IF FOUND THEN
            v_result := jsonb_build_object(
                'exists', TRUE,
                'name', v_rec.nspname,
                'owner', v_rec.owner
            );
        ELSE
            v_result := '{"exists": false}'::JSONB;
        END IF;

    -- ========== ROLE ==========
    WHEN 'Role' THEN
        SELECT INTO v_rec
            r.rolname,
            r.rolsuper AS superuser,
            r.rolinherit AS inherit,
            r.rolcreaterole AS createrole,
            r.rolcreatedb AS createdb,
            r.rolcanlogin AS login,
            r.rolreplication AS replication,
            r.rolconnlimit AS connection_limit,
            r.rolvaliduntil AS valid_until
        FROM pg_roles r
        WHERE r.rolname = p_spec->>'name';

        IF FOUND THEN
            v_result := jsonb_build_object(
                'exists', TRUE,
                'name', v_rec.rolname,
                'superuser', v_rec.superuser,
                'inherit', v_rec.inherit,
                'createrole', v_rec.createrole,
                'createdb', v_rec.createdb,
                'login', v_rec.login,
                'replication', v_rec.replication,
                'connection_limit', v_rec.connection_limit,
                'valid_until', v_rec.valid_until
            );
        ELSE
            v_result := '{"exists": false}'::JSONB;
        END IF;

    -- ========== SERVICE ACCOUNT ==========
    WHEN 'ServiceAccount' THEN
        -- Un ServiceAccount est un Role avec login + grants spécifiques
        SELECT INTO v_rec
            r.rolname,
            r.rolcanlogin AS login,
            r.rolconnlimit AS connection_limit,
            r.rolvaliduntil AS valid_until
        FROM pg_roles r
        WHERE r.rolname = p_spec->>'name';

        IF FOUND THEN
            v_result := jsonb_build_object(
                'exists', TRUE,
                'name', v_rec.rolname,
                'login', v_rec.login,
                'connection_limit', v_rec.connection_limit,
                'valid_until', v_rec.valid_until
            );
        ELSE
            v_result := '{"exists": false}'::JSONB;
        END IF;

    -- ========== EXTENSION ==========
    WHEN 'Extension' THEN
        SELECT INTO v_rec
            e.extname,
            e.extversion,
            n.nspname AS schema
        FROM pg_extension e
        JOIN pg_namespace n ON e.extnamespace = n.oid
        WHERE e.extname = p_spec->>'name';

        IF FOUND THEN
            v_result := jsonb_build_object(
                'exists', TRUE,
                'name', v_rec.extname,
                'version', v_rec.extversion,
                'schema', v_rec.schema
            );
        ELSE
            v_result := '{"exists": false}'::JSONB;
        END IF;

    END CASE;

    RETURN v_result;
END;
$$;
