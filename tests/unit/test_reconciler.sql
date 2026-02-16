-- ============================================================================
-- UNIT TESTS : Reconciler (apply, delete, reconcile, reconcile_all, views)
-- ============================================================================

BEGIN;
SELECT plan(14);

-- ============================================================================
-- apply() tests
-- ============================================================================

-- Test 1: apply creates a new managed_resource with 100_PENDING
SELECT isnt(
    crossplane.apply('Schema', 'test-reconciler-schema',
        '{"name":"test_xplane_rec_schema","database":"postgres","owner":"postgres"}'::JSONB),
    NULL::UUID,
    'apply: returns a UUID'
);

SELECT is(
    (SELECT status_code FROM crossplane.managed_resources WHERE kind = 'Schema' AND name = 'test-reconciler-schema'),
    '100_PENDING'::crossplane.status_code,
    'apply: new resource has status 100_PENDING'
);

-- Test 2: apply again with same (kind, name) increments generation
SELECT is(
    (SELECT generation FROM crossplane.managed_resources WHERE kind = 'Schema' AND name = 'test-reconciler-schema'),
    1::BIGINT,
    'apply: initial generation is 1'
);

SELECT crossplane.apply('Schema', 'test-reconciler-schema',
    '{"name":"test_xplane_rec_schema","database":"postgres","owner":"postgres"}'::JSONB);

SELECT is(
    (SELECT generation FROM crossplane.managed_resources WHERE kind = 'Schema' AND name = 'test-reconciler-schema'),
    2::BIGINT,
    'apply: second apply increments generation to 2'
);

-- Test 3: apply resets status to 100_PENDING on update
SELECT is(
    (SELECT status_code FROM crossplane.managed_resources WHERE kind = 'Schema' AND name = 'test-reconciler-schema'),
    '100_PENDING'::crossplane.status_code,
    'apply: re-apply resets status to 100_PENDING'
);

-- ============================================================================
-- reconcile() tests
-- ============================================================================

-- Test 4: reconcile creates the schema resource
SELECT is(
    (SELECT status_code FROM crossplane.reconcile(
        (SELECT id FROM crossplane.managed_resources WHERE kind = 'Schema' AND name = 'test-reconciler-schema')
    )),
    '201_CREATED'::crossplane.status_code,
    'reconcile: creates schema and returns 201_CREATED'
);

-- Test 5: Conditions are set correctly after successful reconcile
SELECT is(
    (SELECT c.status FROM crossplane.conditions c
     JOIN crossplane.managed_resources mr ON c.resource_id = mr.id
     WHERE mr.name = 'test-reconciler-schema' AND c.condition_type = 'Ready'),
    'True'::crossplane.condition_status,
    'reconcile: Ready condition is True after creation'
);

-- Test 6: reconcile with invalid spec sets 400_INVALID_SPEC
SELECT crossplane.apply('Schema', 'test-reconciler-bad',
    '{"database":"postgres"}'::JSONB);  -- missing name

SELECT is(
    (SELECT status_code FROM crossplane.reconcile(
        (SELECT id FROM crossplane.managed_resources WHERE kind = 'Schema' AND name = 'test-reconciler-bad')
    )),
    '400_INVALID_SPEC'::crossplane.status_code,
    'reconcile: invalid spec returns 400_INVALID_SPEC'
);

-- Test 7: reconcile again on synced resource returns 204_NO_CHANGE (no drift)
SELECT is(
    (SELECT status_code FROM crossplane.reconcile(
        (SELECT id FROM crossplane.managed_resources WHERE kind = 'Schema' AND name = 'test-reconciler-schema')
    )),
    '204_NO_CHANGE'::crossplane.status_code,
    'reconcile: already synced returns 204_NO_CHANGE'
);

-- ============================================================================
-- delete() tests
-- ============================================================================

-- Test 8: delete marks desired_state=absent and status=100_PENDING
SELECT isnt(
    crossplane.delete('Schema', 'test-reconciler-schema'),
    NULL::UUID,
    'delete: returns a UUID'
);

SELECT is(
    (SELECT desired_state FROM crossplane.managed_resources WHERE kind = 'Schema' AND name = 'test-reconciler-schema'),
    'absent'::crossplane.desired_state,
    'delete: sets desired_state to absent'
);

SELECT is(
    (SELECT status_code FROM crossplane.managed_resources WHERE kind = 'Schema' AND name = 'test-reconciler-schema'),
    '100_PENDING'::crossplane.status_code,
    'delete: resets status to 100_PENDING'
);

-- Test 9: delete on non-existent resource raises exception
SELECT throws_ok(
    $$SELECT crossplane.delete('Schema', 'nonexistent_resource_xplane_test')$$,
    NULL,
    NULL,
    'delete: non-existent resource raises exception'
);

-- Test 10: reconcile after delete actually deletes the resource
SELECT is(
    (SELECT status_code FROM crossplane.reconcile(
        (SELECT id FROM crossplane.managed_resources WHERE kind = 'Schema' AND name = 'test-reconciler-schema')
    )),
    '203_DELETED'::crossplane.status_code,
    'reconcile: delete action returns 203_DELETED'
);

-- ============================================================================
-- resource_status view test
-- ============================================================================

-- Test 11: resource_status view returns expected columns
SELECT has_column(
    'crossplane', 'resource_status', 'kind',
    'resource_status: has kind column'
);

SELECT * FROM finish();
ROLLBACK;
