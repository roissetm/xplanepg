-- ============================================================================
-- UNIT TESTS : Database Actions (create, update, delete)
-- ============================================================================
-- NOTE: CREATE/DROP DATABASE cannot run inside a transaction.
-- dblink executes outside the current transaction, and ALTER DATABASE
-- requires exclusive locks incompatible with open transactions.
-- Therefore these tests run WITHOUT BEGIN/ROLLBACK and use explicit cleanup.
-- ============================================================================

-- Ensure clean state
SELECT crossplane.delete_database('{"name":"test_xplane_db1"}'::JSONB);

SELECT plan(7);

-- ============================================================================
-- Test 1: create_database returns 201_CREATED
-- ============================================================================
SELECT is(
    (SELECT status FROM crossplane.create_database(
        '{"name":"test_xplane_db1","owner":"postgres","encoding":"UTF8"}'::JSONB
    )),
    '201_CREATED'::crossplane.status_code,
    'create_database: returns 201_CREATED'
);

-- ============================================================================
-- Test 2: create_database when exists returns 409_CONFLICT
-- ============================================================================
SELECT is(
    (SELECT status FROM crossplane.create_database(
        '{"name":"test_xplane_db1","owner":"postgres"}'::JSONB
    )),
    '409_CONFLICT'::crossplane.status_code,
    'create_database: existing returns 409_CONFLICT'
);

-- ============================================================================
-- Test 3: create_database with non-existent owner returns 422_UNPROCESSABLE
-- ============================================================================
SELECT is(
    (SELECT status FROM crossplane.create_database(
        '{"name":"test_xplane_db_bad_owner","owner":"nonexistent_role_xplane_test"}'::JSONB
    )),
    '422_UNPROCESSABLE'::crossplane.status_code,
    'create_database: bad owner returns 422_UNPROCESSABLE'
);

-- ============================================================================
-- Test 4: update_database with no drift returns 204_NO_CHANGE
-- ============================================================================
SELECT is(
    (SELECT status FROM crossplane.update_database(
        '{"name":"test_xplane_db1","owner":"postgres"}'::JSONB,
        crossplane.observe_resource('Database', '{"name":"test_xplane_db1"}'::JSONB)
    )),
    '204_NO_CHANGE'::crossplane.status_code,
    'update_database: no drift returns 204_NO_CHANGE'
);

-- ============================================================================
-- Test 5: update_database changing connection_limit returns 202_UPDATED
-- ============================================================================
SELECT is(
    (SELECT status FROM crossplane.update_database(
        '{"name":"test_xplane_db1","owner":"postgres","connection_limit":50}'::JSONB,
        '{"exists":true,"name":"test_xplane_db1","owner":"postgres","connection_limit":-1}'::JSONB
    )),
    '202_UPDATED'::crossplane.status_code,
    'update_database: connection_limit change returns 202_UPDATED'
);

-- ============================================================================
-- Test 6: delete_database returns 203_DELETED
-- ============================================================================
SELECT is(
    (SELECT status FROM crossplane.delete_database('{"name":"test_xplane_db1"}'::JSONB)),
    '203_DELETED'::crossplane.status_code,
    'delete_database: returns 203_DELETED'
);

-- ============================================================================
-- Test 7: delete_database non-existent returns 204_NO_CHANGE
-- ============================================================================
SELECT is(
    (SELECT status FROM crossplane.delete_database('{"name":"test_xplane_db1"}'::JSONB)),
    '204_NO_CHANGE'::crossplane.status_code,
    'delete_database: non-existent returns 204_NO_CHANGE'
);

SELECT * FROM finish();
