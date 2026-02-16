-- ============================================================================
-- INTEGRATION TEST : Full Lifecycle (apply → reconcile → update → delete)
-- ============================================================================
-- Tests the complete lifecycle of a Schema resource through the public API.
-- Schema is used because it's fully transactional (unlike Database).
-- ============================================================================

BEGIN;
SELECT plan(10);

-- ============================================================================
-- Step 1: Apply a new Schema resource
-- ============================================================================
SELECT isnt(
    crossplane.apply('Schema', 'lifecycle-test-schema',
        '{"name":"test_xplane_lifecycle","database":"postgres","owner":"postgres"}'::JSONB),
    NULL::UUID,
    'lifecycle: apply returns UUID'
);

-- Resource exists in managed_resources with PENDING status
SELECT is(
    (SELECT status_code FROM crossplane.managed_resources WHERE name = 'lifecycle-test-schema'),
    '100_PENDING'::crossplane.status_code,
    'lifecycle: resource is PENDING after apply'
);

-- ============================================================================
-- Step 2: Reconcile — should CREATE the schema
-- ============================================================================
SELECT is(
    (SELECT status_code FROM crossplane.reconcile(
        (SELECT id FROM crossplane.managed_resources WHERE name = 'lifecycle-test-schema')
    )),
    '201_CREATED'::crossplane.status_code,
    'lifecycle: first reconcile creates schema (201_CREATED)'
);

-- Schema actually exists in pg_namespace
SELECT ok(
    EXISTS(SELECT 1 FROM pg_namespace WHERE nspname = 'test_xplane_lifecycle'),
    'lifecycle: schema exists in pg_namespace after reconcile'
);

-- Conditions are correct
SELECT is(
    (SELECT c.status FROM crossplane.conditions c
     JOIN crossplane.managed_resources mr ON c.resource_id = mr.id
     WHERE mr.name = 'lifecycle-test-schema' AND c.condition_type = 'Ready'),
    'True'::crossplane.condition_status,
    'lifecycle: Ready=True after creation'
);

-- ============================================================================
-- Step 3: Update the spec — change owner
-- ============================================================================
CREATE ROLE test_xplane_lifecycle_owner NOLOGIN;

SELECT crossplane.apply('Schema', 'lifecycle-test-schema',
    '{"name":"test_xplane_lifecycle","database":"postgres","owner":"test_xplane_lifecycle_owner"}'::JSONB);

SELECT is(
    (SELECT status_code FROM crossplane.reconcile(
        (SELECT id FROM crossplane.managed_resources WHERE name = 'lifecycle-test-schema')
    )),
    '202_UPDATED'::crossplane.status_code,
    'lifecycle: reconcile after spec change returns 202_UPDATED'
);

-- Verify owner changed
SELECT is(
    (SELECT r.rolname FROM pg_namespace n JOIN pg_roles r ON n.nspowner = r.oid WHERE n.nspname = 'test_xplane_lifecycle'),
    'test_xplane_lifecycle_owner',
    'lifecycle: schema owner updated in pg_namespace'
);

-- ============================================================================
-- Step 4: Reconcile again — no drift, should be NO_CHANGE
-- ============================================================================
SELECT is(
    (SELECT status_code FROM crossplane.reconcile(
        (SELECT id FROM crossplane.managed_resources WHERE name = 'lifecycle-test-schema')
    )),
    '204_NO_CHANGE'::crossplane.status_code,
    'lifecycle: reconcile with no drift returns 204_NO_CHANGE'
);

-- ============================================================================
-- Step 5: Delete — mark absent, then reconcile
-- ============================================================================
SELECT crossplane.delete('Schema', 'lifecycle-test-schema');

SELECT is(
    (SELECT status_code FROM crossplane.reconcile(
        (SELECT id FROM crossplane.managed_resources WHERE name = 'lifecycle-test-schema')
    )),
    '203_DELETED'::crossplane.status_code,
    'lifecycle: reconcile after delete returns 203_DELETED'
);

-- Schema no longer exists in pg_namespace
SELECT ok(
    NOT EXISTS(SELECT 1 FROM pg_namespace WHERE nspname = 'test_xplane_lifecycle'),
    'lifecycle: schema removed from pg_namespace after delete'
);

SELECT * FROM finish();
ROLLBACK;
