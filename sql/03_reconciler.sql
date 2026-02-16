-- ============================================================================
-- RECONCILER PRINCIPAL
-- ============================================================================
-- Le reconciler est le cœur du provider. Il implémente la boucle :
--   1. Observer l'état réel (observe)
--   2. Comparer avec l'état désiré (diff)
--   3. Appliquer les changements (create/update/delete)
--   4. Mettre à jour les conditions (Synced, Ready)
--
-- Peut être appelé :
--   - Manuellement : SELECT crossplane.reconcile_all();
--   - Via pg_cron   : toutes les 30 secondes
--   - Par ressource : SELECT crossplane.reconcile(resource_id);
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Réconcilier UNE ressource
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crossplane.reconcile(p_resource_id UUID)
RETURNS TABLE(
    resource_id UUID,
    kind        crossplane.resource_kind,
    name        TEXT,
    action      TEXT,
    status_code crossplane.status_code,
    message     TEXT
)
LANGUAGE plpgsql AS $$
DECLARE
    v_resource  RECORD;
    v_observed  JSONB;
    v_exists    BOOLEAN;
    v_result    RECORD;
    v_valid     RECORD;
BEGIN
    -- Charger la ressource
    SELECT * INTO v_resource
    FROM crossplane.managed_resources mr
    WHERE mr.id = p_resource_id
    FOR UPDATE SKIP LOCKED;  -- Éviter les réconciliations concurrentes

    IF NOT FOUND THEN
        RETURN;
    END IF;

    -- Marquer comme en cours de réconciliation
    PERFORM crossplane.set_status(p_resource_id, '101_RECONCILING', 'Reconciliation started');
    PERFORM crossplane.set_condition(p_resource_id, 'Synced', 'Unknown', 'Reconciling', 'Checking external state');

    -- ========================================================================
    -- ÉTAPE 1 : Validation de la spec
    -- ========================================================================
    SELECT * INTO v_valid
    FROM crossplane.validate_spec(v_resource.kind, v_resource.spec);

    IF NOT v_valid.valid THEN
        PERFORM crossplane.set_status(p_resource_id, '400_INVALID_SPEC', v_valid.error_message);
        PERFORM crossplane.set_condition(p_resource_id, 'Synced', 'False', 'InvalidSpec', v_valid.error_message);
        PERFORM crossplane.set_condition(p_resource_id, 'Ready', 'False', 'InvalidSpec', v_valid.error_message);
        PERFORM crossplane.emit_event(p_resource_id, 'Warning', 'InvalidSpec', v_valid.error_message, '400_INVALID_SPEC');

        RETURN QUERY SELECT p_resource_id, v_resource.kind, v_resource.name,
                            'VALIDATE'::TEXT, '400_INVALID_SPEC'::crossplane.status_code, v_valid.error_message;
        RETURN;
    END IF;

    -- ========================================================================
    -- ÉTAPE 2 : Observer l'état réel
    -- ========================================================================
    BEGIN
        v_observed := crossplane.observe_resource(v_resource.kind, v_resource.spec);
        v_exists := COALESCE((v_observed->>'exists')::BOOLEAN, FALSE);

        -- Synced = True (on a réussi à communiquer)
        PERFORM crossplane.set_condition(p_resource_id, 'Synced', 'True', 'ObserveSuccess', 'External state observed');
    EXCEPTION WHEN OTHERS THEN
        PERFORM crossplane.set_status(p_resource_id, '503_UNAVAILABLE', SQLERRM);
        PERFORM crossplane.set_condition(p_resource_id, 'Synced', 'False', 'ObserveFailed', SQLERRM);
        PERFORM crossplane.emit_event(p_resource_id, 'Warning', 'ObserveFailed', SQLERRM, '503_UNAVAILABLE');

        RETURN QUERY SELECT p_resource_id, v_resource.kind, v_resource.name,
                            'OBSERVE'::TEXT, '503_UNAVAILABLE'::crossplane.status_code, SQLERRM;
        RETURN;
    END;

    -- ========================================================================
    -- ÉTAPE 3 : Décider de l'action
    -- ========================================================================

    -- ----- CAS : DELETION DEMANDÉE -----
    IF v_resource.desired_state = 'absent' THEN
        IF NOT v_exists THEN
            -- Déjà supprimé
            PERFORM crossplane.set_status(p_resource_id, '203_DELETED', 'Resource already absent');
            PERFORM crossplane.set_condition(p_resource_id, 'Ready', 'False', 'Deleted', 'Resource deleted');

            UPDATE crossplane.managed_resources SET deleted_at = NOW() WHERE id = p_resource_id;

            RETURN QUERY SELECT p_resource_id, v_resource.kind, v_resource.name,
                                'DELETE_NOOP'::TEXT, '204_NO_CHANGE'::crossplane.status_code,
                                'Already absent'::TEXT;
            RETURN;
        END IF;

        -- Supprimer
        PERFORM crossplane.set_status(p_resource_id, '104_DELETING', 'Deleting resource');
        PERFORM crossplane.emit_event(p_resource_id, 'Normal', 'DeletingExternalResource', 'Deletion initiated');

        CASE v_resource.kind
            WHEN 'Database' THEN
                SELECT * INTO v_result FROM crossplane.delete_database(v_resource.spec) LIMIT 1;
            WHEN 'Schema' THEN
                SELECT * INTO v_result FROM crossplane.delete_schema(v_resource.spec) LIMIT 1;
            WHEN 'Role' THEN
                SELECT * INTO v_result FROM crossplane.delete_role(v_resource.spec) LIMIT 1;
            WHEN 'ServiceAccount' THEN
                SELECT * INTO v_result FROM crossplane.delete_service_account(v_resource.spec) LIMIT 1;
            WHEN 'Extension' THEN
                SELECT * INTO v_result FROM crossplane.delete_extension(v_resource.spec) LIMIT 1;
        END CASE;

        PERFORM crossplane.set_status(p_resource_id, v_result.status, v_result.message);

        IF v_result.status IN ('203_DELETED', '204_NO_CHANGE') THEN
            PERFORM crossplane.set_condition(p_resource_id, 'Ready', 'False', 'Deleted', v_result.message);
            PERFORM crossplane.emit_event(p_resource_id, 'Normal', 'DeletedExternalResource', v_result.message, v_result.status);
            UPDATE crossplane.managed_resources SET deleted_at = NOW() WHERE id = p_resource_id;
        ELSE
            PERFORM crossplane.set_condition(p_resource_id, 'Synced', 'False', 'DeleteFailed', v_result.message);
            PERFORM crossplane.emit_event(p_resource_id, 'Warning', 'CannotDeleteExternalResource', v_result.message, v_result.status);
        END IF;

        RETURN QUERY SELECT p_resource_id, v_resource.kind, v_resource.name,
                            'DELETE'::TEXT, v_result.status, v_result.message;
        RETURN;
    END IF;

    -- ----- CAS : CREATION (ressource n'existe pas) -----
    IF NOT v_exists THEN
        PERFORM crossplane.set_status(p_resource_id, '102_CREATING', 'Creating resource');
        PERFORM crossplane.emit_event(p_resource_id, 'Normal', 'CreatingExternalResource', 'Creation initiated');

        CASE v_resource.kind
            WHEN 'Database' THEN
                SELECT * INTO v_result FROM crossplane.create_database(v_resource.spec) LIMIT 1;
            WHEN 'Schema' THEN
                SELECT * INTO v_result FROM crossplane.create_schema(v_resource.spec) LIMIT 1;
            WHEN 'Role' THEN
                SELECT * INTO v_result FROM crossplane.create_role(v_resource.spec) LIMIT 1;
            WHEN 'ServiceAccount' THEN
                SELECT * INTO v_result FROM crossplane.create_service_account(v_resource.spec) LIMIT 1;
            WHEN 'Extension' THEN
                SELECT * INTO v_result FROM crossplane.create_extension(v_resource.spec) LIMIT 1;
        END CASE;

        PERFORM crossplane.set_status(p_resource_id, v_result.status, v_result.message, v_result.observed);

        IF v_result.status = '201_CREATED' THEN
            PERFORM crossplane.set_condition(p_resource_id, 'Ready', 'True', 'Available', 'Resource is ready');
            PERFORM crossplane.emit_event(p_resource_id, 'Normal', 'CreatedExternalResource', v_result.message, '201_CREATED');
        ELSE
            PERFORM crossplane.set_condition(p_resource_id, 'Ready', 'False', 'CreateFailed', v_result.message);
            PERFORM crossplane.emit_event(p_resource_id, 'Warning', 'CannotCreateExternalResource', v_result.message, v_result.status);
        END IF;

        RETURN QUERY SELECT p_resource_id, v_resource.kind, v_resource.name,
                            'CREATE'::TEXT, v_result.status, v_result.message;
        RETURN;
    END IF;

    -- ----- CAS : UPDATE (ressource existe, vérifier le drift) -----
    PERFORM crossplane.set_status(p_resource_id, '103_UPDATING', 'Checking for drift');

    CASE v_resource.kind
        WHEN 'Database' THEN
            SELECT * INTO v_result FROM crossplane.update_database(v_resource.spec, v_observed) LIMIT 1;
        WHEN 'Schema' THEN
            SELECT * INTO v_result FROM crossplane.update_schema(v_resource.spec, v_observed) LIMIT 1;
        WHEN 'Role' THEN
            SELECT * INTO v_result FROM crossplane.update_role(v_resource.spec, v_observed) LIMIT 1;
        WHEN 'Extension' THEN
            SELECT * INTO v_result FROM crossplane.update_extension(v_resource.spec, v_observed) LIMIT 1;
        WHEN 'ServiceAccount' THEN
            SELECT * INTO v_result FROM crossplane.update_service_account(v_resource.spec, v_observed) LIMIT 1;
    END CASE;

    PERFORM crossplane.set_status(p_resource_id, v_result.status, v_result.message, v_result.observed);

    IF v_result.status IN ('202_UPDATED', '204_NO_CHANGE', '200_SYNCED') THEN
        PERFORM crossplane.set_condition(p_resource_id, 'Synced', 'True', 'ReconcileSuccess', 'Desired state matches actual state');
        PERFORM crossplane.set_condition(p_resource_id, 'Ready', 'True', 'Available', 'Resource is ready');

        IF v_result.status = '202_UPDATED' THEN
            PERFORM crossplane.emit_event(p_resource_id, 'Normal', 'UpdatedExternalResource', v_result.message, '202_UPDATED');
        END IF;
    ELSE
        PERFORM crossplane.set_condition(p_resource_id, 'Synced', 'False', 'UpdateFailed', v_result.message);
        PERFORM crossplane.emit_event(p_resource_id, 'Warning', 'CannotUpdateExternalResource', v_result.message, v_result.status);
    END IF;

    -- Mettre à jour les compteurs
    UPDATE crossplane.managed_resources SET
        observed_generation = v_resource.generation,
        reconcile_count = reconcile_count + 1,
        updated_at = NOW()
    WHERE id = p_resource_id;

    RETURN QUERY SELECT p_resource_id, v_resource.kind, v_resource.name,
                        'UPDATE'::TEXT, v_result.status, v_result.message;
END;
$$;


-- ----------------------------------------------------------------------------
-- Réconcilier TOUTES les ressources en attente
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crossplane.reconcile_all()
RETURNS TABLE(
    resource_id UUID,
    kind        crossplane.resource_kind,
    name        TEXT,
    action      TEXT,
    status_code crossplane.status_code,
    message     TEXT
)
LANGUAGE plpgsql AS $$
DECLARE
    v_resource RECORD;
BEGIN
    -- Sélectionner les ressources à réconcilier
    -- Priorité : pending > erreurs > synced (pour détecter le drift)
    FOR v_resource IN
        SELECT mr.id
        FROM crossplane.managed_resources mr
        WHERE mr.deleted_at IS NULL
           OR mr.desired_state = 'absent'
        ORDER BY
            CASE
                WHEN mr.status_code = '100_PENDING' THEN 0
                WHEN mr.status_code LIKE '4%' OR mr.status_code LIKE '5%' THEN 1
                ELSE 2
            END,
            mr.updated_at ASC
    LOOP
        RETURN QUERY SELECT * FROM crossplane.reconcile(v_resource.id);
    END LOOP;
END;
$$;


-- ----------------------------------------------------------------------------
-- API : Créer / déclarer une ressource managée
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crossplane.apply(
    p_kind          crossplane.resource_kind,
    p_name          TEXT,
    p_spec          JSONB,
    p_desired_state crossplane.desired_state DEFAULT 'present',
    p_provider_config TEXT DEFAULT 'default'
) RETURNS UUID
LANGUAGE plpgsql AS $$
DECLARE
    v_id UUID;
BEGIN
    INSERT INTO crossplane.managed_resources (kind, name, spec, desired_state, provider_config)
    VALUES (p_kind, p_name, p_spec, p_desired_state, p_provider_config)
    ON CONFLICT (kind, name) DO UPDATE SET
        spec = EXCLUDED.spec,
        desired_state = EXCLUDED.desired_state,
        provider_config = EXCLUDED.provider_config,
        generation = crossplane.managed_resources.generation + 1,
        status_code = '100_PENDING',
        updated_at = NOW(),
        deleted_at = NULL
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;


-- ----------------------------------------------------------------------------
-- API : Supprimer une ressource (marquer pour deletion)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crossplane.delete(
    p_kind crossplane.resource_kind,
    p_name TEXT
) RETURNS UUID
LANGUAGE plpgsql AS $$
DECLARE
    v_id UUID;
BEGIN
    UPDATE crossplane.managed_resources
    SET desired_state = 'absent',
        status_code = '100_PENDING',
        generation = generation + 1,
        updated_at = NOW()
    WHERE kind = p_kind AND name = p_name
    RETURNING id INTO v_id;

    IF v_id IS NULL THEN
        RAISE EXCEPTION 'Resource %.% not found', p_kind, p_name;
    END IF;

    RETURN v_id;
END;
$$;


-- ----------------------------------------------------------------------------
-- VUE : Dashboard des ressources avec conditions
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW crossplane.resource_status AS
SELECT
    mr.id,
    mr.kind,
    mr.name,
    mr.desired_state,
    mr.status_code,
    mr.status_message,
    c_synced.status AS synced,
    c_synced.reason AS synced_reason,
    c_ready.status AS ready,
    c_ready.reason AS ready_reason,
    mr.generation,
    mr.observed_generation,
    mr.reconcile_count,
    mr.at_provider,
    mr.created_at,
    mr.updated_at
FROM crossplane.managed_resources mr
LEFT JOIN crossplane.conditions c_synced
    ON c_synced.resource_id = mr.id AND c_synced.condition_type = 'Synced'
LEFT JOIN crossplane.conditions c_ready
    ON c_ready.resource_id = mr.id AND c_ready.condition_type = 'Ready'
WHERE mr.deleted_at IS NULL
   OR mr.desired_state = 'absent'
ORDER BY mr.kind, mr.name;


-- ----------------------------------------------------------------------------
-- VUE : Events récents
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW crossplane.recent_events AS
SELECT
    e.created_at,
    mr.kind,
    mr.name,
    e.event_type,
    e.reason,
    e.message,
    e.status_code
FROM crossplane.events e
JOIN crossplane.managed_resources mr ON e.resource_id = mr.id
ORDER BY e.created_at DESC
LIMIT 50;
