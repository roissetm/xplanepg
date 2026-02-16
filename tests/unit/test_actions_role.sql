-- ============================================================================
-- UNIT TESTS : Role Actions (create, update, delete)
-- ============================================================================
-- NOTE: Role operations cannot be fully rolled back in a transaction.
-- CREATE ROLE is transactional in PostgreSQL, but we use explicit cleanup
-- to be safe and consistent.
-- ============================================================================

BEGIN;
SELECT plan(8);

-- ============================================================================
-- Test 1: create_role returns 201_CREATED
-- ============================================================================
SELECT is(
    (SELECT status FROM crossplane.create_role('{"name":"test_xplane_role1"}'::JSONB)),
    '201_CREATED'::crossplane.status_code,
    'create_role: returns 201_CREATED'
);

-- ============================================================================
-- Test 2: create_role when exists returns 409_CONFLICT
-- ============================================================================
SELECT is(
    (SELECT status FROM crossplane.create_role('{"name":"test_xplane_role1"}'::JSONB)),
    '409_CONFLICT'::crossplane.status_code,
    'create_role: existing role returns 409_CONFLICT'
);

-- ============================================================================
-- Test 3: create_role with all options
-- ============================================================================
SELECT is(
    (SELECT status FROM crossplane.create_role(
        '{"name":"test_xplane_role_opts","createdb":true,"login":false,"inherit":true,"connection_limit":5}'::JSONB
    )),
    '201_CREATED'::crossplane.status_code,
    'create_role: with options returns 201_CREATED'
);

-- Verify the attributes were set
SELECT ok(
    (SELECT rolcreatedb FROM pg_roles WHERE rolname = 'test_xplane_role_opts'),
    'create_role: createdb attribute is set'
);

-- ============================================================================
-- Test 4: create_role with memberOf
-- ============================================================================
SELECT is(
    (SELECT status FROM crossplane.create_role(
        '{"name":"test_xplane_role_member","memberOf":["test_xplane_role1"]}'::JSONB
    )),
    '201_CREATED'::crossplane.status_code,
    'create_role: with memberOf returns 201_CREATED'
);

-- ============================================================================
-- Test 5: update_role changing attributes returns 202_UPDATED
-- ============================================================================
SELECT is(
    (SELECT status FROM crossplane.update_role(
        '{"name":"test_xplane_role1","login":true}'::JSONB,
        '{"exists":true,"name":"test_xplane_role1","login":false,"superuser":false,"createdb":false,"createrole":false,"connection_limit":-1}'::JSONB
    )),
    '202_UPDATED'::crossplane.status_code,
    'update_role: attribute change returns 202_UPDATED'
);

-- ============================================================================
-- Test 6: update_role no change returns 204_NO_CHANGE
-- ============================================================================
SELECT is(
    (SELECT status FROM crossplane.update_role(
        '{"name":"test_xplane_role1"}'::JSONB,
        crossplane.observe_resource('Role', '{"name":"test_xplane_role1"}'::JSONB)
    )),
    '204_NO_CHANGE'::crossplane.status_code,
    'update_role: no change returns 204_NO_CHANGE'
);

-- ============================================================================
-- Test 7: delete_role returns 203_DELETED
-- ============================================================================
-- Delete member role first (dependency)
SELECT status FROM crossplane.delete_role('{"name":"test_xplane_role_member"}'::JSONB);

SELECT is(
    (SELECT status FROM crossplane.delete_role('{"name":"test_xplane_role1"}'::JSONB)),
    '203_DELETED'::crossplane.status_code,
    'delete_role: returns 203_DELETED'
);

-- Cleanup remaining test roles
SELECT status FROM crossplane.delete_role('{"name":"test_xplane_role_opts"}'::JSONB);

SELECT * FROM finish();
ROLLBACK;
