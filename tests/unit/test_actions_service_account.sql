-- ============================================================================
-- UNIT TESTS : ServiceAccount Actions (create, update, delete)
-- ============================================================================
-- ServiceAccount tests require schemas to exist for GRANT USAGE.
-- We use the 'public' schema which always exists.
-- ============================================================================

BEGIN;
SELECT plan(8);

-- ============================================================================
-- Test 1: create_service_account returns 201_CREATED
-- ============================================================================
SELECT is(
    (SELECT status FROM crossplane.create_service_account(
        '{"name":"test_xplane_sa1","database":"postgres","password":"testpass123","schemas":["public"],"connection_limit":5}'::JSONB
    )),
    '201_CREATED'::crossplane.status_code,
    'create_service_account: returns 201_CREATED'
);

-- ============================================================================
-- Test 2: Verify role has LOGIN attribute
-- ============================================================================
SELECT ok(
    (SELECT rolcanlogin FROM pg_roles WHERE rolname = 'test_xplane_sa1'),
    'create_service_account: role has LOGIN'
);

-- ============================================================================
-- Test 3: Verify connection_limit was set
-- ============================================================================
SELECT is(
    (SELECT rolconnlimit FROM pg_roles WHERE rolname = 'test_xplane_sa1'),
    5,
    'create_service_account: connection_limit is 5'
);

-- ============================================================================
-- Test 4: create_service_account when exists returns 409_CONFLICT
-- ============================================================================
SELECT is(
    (SELECT status FROM crossplane.create_service_account(
        '{"name":"test_xplane_sa1","database":"postgres","schemas":["public"]}'::JSONB
    )),
    '409_CONFLICT'::crossplane.status_code,
    'create_service_account: existing returns 409_CONFLICT'
);

-- ============================================================================
-- Test 5: update_service_account changes connection_limit
-- ============================================================================
SELECT is(
    (SELECT status FROM crossplane.update_service_account(
        '{"name":"test_xplane_sa1","database":"postgres","connection_limit":20,"schemas":["public"]}'::JSONB,
        '{"exists":true,"name":"test_xplane_sa1","login":true,"connection_limit":5}'::JSONB
    )),
    '202_UPDATED'::crossplane.status_code,
    'update_service_account: connection_limit change returns 202_UPDATED'
);

-- ============================================================================
-- Test 6: Verify connection_limit was updated
-- ============================================================================
SELECT is(
    (SELECT rolconnlimit FROM pg_roles WHERE rolname = 'test_xplane_sa1'),
    20,
    'update_service_account: connection_limit is now 20'
);

-- ============================================================================
-- Test 7: delete_service_account returns 203_DELETED
-- ============================================================================
SELECT is(
    (SELECT status FROM crossplane.delete_service_account('{"name":"test_xplane_sa1"}'::JSONB)),
    '203_DELETED'::crossplane.status_code,
    'delete_service_account: returns 203_DELETED'
);

-- ============================================================================
-- Test 8: delete_service_account non-existent returns 204_NO_CHANGE
-- ============================================================================
SELECT is(
    (SELECT status FROM crossplane.delete_service_account('{"name":"test_xplane_sa1"}'::JSONB)),
    '204_NO_CHANGE'::crossplane.status_code,
    'delete_service_account: non-existent returns 204_NO_CHANGE'
);

SELECT * FROM finish();
ROLLBACK;
