-- ============================================================================
-- UNIT TESTS : Extension Actions (create, update, delete)
-- ============================================================================

BEGIN;
SELECT plan(5);

-- ============================================================================
-- Test 1: create_extension returns 201_CREATED
-- ============================================================================
SELECT is(
    (SELECT status FROM crossplane.create_extension('{"name":"hstore","database":"postgres"}'::JSONB)),
    '201_CREATED'::crossplane.status_code,
    'create_extension: returns 201_CREATED'
);

-- ============================================================================
-- Test 2: create_extension when exists returns 409_CONFLICT
-- ============================================================================
SELECT is(
    (SELECT status FROM crossplane.create_extension('{"name":"hstore","database":"postgres"}'::JSONB)),
    '409_CONFLICT'::crossplane.status_code,
    'create_extension: existing returns 409_CONFLICT'
);

-- ============================================================================
-- Test 3: update_extension with no version change returns 204_NO_CHANGE
-- ============================================================================
SELECT is(
    (SELECT status FROM crossplane.update_extension(
        '{"name":"hstore","database":"postgres"}'::JSONB,
        crossplane.observe_resource('Extension', '{"name":"hstore"}'::JSONB)
    )),
    '204_NO_CHANGE'::crossplane.status_code,
    'update_extension: no version change returns 204_NO_CHANGE'
);

-- ============================================================================
-- Test 4: delete_extension returns 203_DELETED
-- ============================================================================
SELECT is(
    (SELECT status FROM crossplane.delete_extension('{"name":"hstore"}'::JSONB)),
    '203_DELETED'::crossplane.status_code,
    'delete_extension: returns 203_DELETED'
);

-- ============================================================================
-- Test 5: delete_extension non-existent returns 204_NO_CHANGE
-- ============================================================================
SELECT is(
    (SELECT status FROM crossplane.delete_extension('{"name":"hstore"}'::JSONB)),
    '204_NO_CHANGE'::crossplane.status_code,
    'delete_extension: non-existent returns 204_NO_CHANGE'
);

SELECT * FROM finish();
ROLLBACK;
