-- ============================================================================
-- INTEGRATION TEST : Idempotency
-- ============================================================================
-- Verifies that apply() 2x + reconcile 2x = same result for multiple kinds.
-- Also verifies delete idempotency.
-- ============================================================================

BEGIN;
SELECT plan(8);

-- ============================================================================
-- Schema Idempotency
-- ============================================================================

-- Apply + reconcile first time
SELECT crossplane.apply('Schema', 'idempotency-schema',
    '{"name":"test_xplane_idemp_schema","database":"postgres","owner":"postgres"}'::JSONB);

SELECT is(
    (SELECT status_code FROM crossplane.reconcile(
        (SELECT id FROM crossplane.managed_resources WHERE name = 'idempotency-schema')
    )),
    '201_CREATED'::crossplane.status_code,
    'idempotency schema: first reconcile creates (201_CREATED)'
);

-- Apply + reconcile second time — should be NO_CHANGE
SELECT crossplane.apply('Schema', 'idempotency-schema',
    '{"name":"test_xplane_idemp_schema","database":"postgres","owner":"postgres"}'::JSONB);

SELECT is(
    (SELECT status_code FROM crossplane.reconcile(
        (SELECT id FROM crossplane.managed_resources WHERE name = 'idempotency-schema')
    )),
    '204_NO_CHANGE'::crossplane.status_code,
    'idempotency schema: second reconcile is NO_CHANGE (204)'
);

-- Delete + reconcile first time
SELECT crossplane.delete('Schema', 'idempotency-schema');
SELECT is(
    (SELECT status_code FROM crossplane.reconcile(
        (SELECT id FROM crossplane.managed_resources WHERE name = 'idempotency-schema')
    )),
    '203_DELETED'::crossplane.status_code,
    'idempotency schema: first delete reconcile (203_DELETED)'
);

-- Reconcile again after already deleted — resource marked absent, already gone
SELECT is(
    (SELECT status_code FROM crossplane.reconcile(
        (SELECT id FROM crossplane.managed_resources WHERE name = 'idempotency-schema')
    )),
    '204_NO_CHANGE'::crossplane.status_code,
    'idempotency schema: second delete reconcile is NO_CHANGE (204)'
);

-- ============================================================================
-- Extension Idempotency
-- ============================================================================

-- Apply + reconcile first time
SELECT crossplane.apply('Extension', 'idempotency-ext',
    '{"name":"hstore","database":"postgres"}'::JSONB);

SELECT is(
    (SELECT status_code FROM crossplane.reconcile(
        (SELECT id FROM crossplane.managed_resources WHERE name = 'idempotency-ext')
    )),
    '201_CREATED'::crossplane.status_code,
    'idempotency extension: first reconcile creates (201_CREATED)'
);

-- Apply + reconcile second time — should be NO_CHANGE
SELECT crossplane.apply('Extension', 'idempotency-ext',
    '{"name":"hstore","database":"postgres"}'::JSONB);

SELECT is(
    (SELECT status_code FROM crossplane.reconcile(
        (SELECT id FROM crossplane.managed_resources WHERE name = 'idempotency-ext')
    )),
    '204_NO_CHANGE'::crossplane.status_code,
    'idempotency extension: second reconcile is NO_CHANGE (204)'
);

-- Delete + reconcile
SELECT crossplane.delete('Extension', 'idempotency-ext');
SELECT is(
    (SELECT status_code FROM crossplane.reconcile(
        (SELECT id FROM crossplane.managed_resources WHERE name = 'idempotency-ext')
    )),
    '203_DELETED'::crossplane.status_code,
    'idempotency extension: delete reconcile (203_DELETED)'
);

-- Reconcile again after deleted
SELECT is(
    (SELECT status_code FROM crossplane.reconcile(
        (SELECT id FROM crossplane.managed_resources WHERE name = 'idempotency-ext')
    )),
    '204_NO_CHANGE'::crossplane.status_code,
    'idempotency extension: second delete reconcile is NO_CHANGE (204)'
);

SELECT * FROM finish();
ROLLBACK;
