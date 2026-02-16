-- ============================================================================
-- UNIT TESTS : Schema Actions (create, update, delete)
-- ============================================================================

BEGIN;
SELECT plan(7);

-- ============================================================================
-- Test 1: create_schema returns 201_CREATED
-- ============================================================================
SELECT is(
    (SELECT status FROM crossplane.create_schema('{"name":"test_xplane_schema1","owner":"postgres","database":"postgres"}'::JSONB)),
    '201_CREATED'::crossplane.status_code,
    'create_schema: returns 201_CREATED'
);

-- ============================================================================
-- Test 2: create_schema on existing returns 409_CONFLICT
-- ============================================================================
SELECT is(
    (SELECT status FROM crossplane.create_schema('{"name":"test_xplane_schema1","owner":"postgres","database":"postgres"}'::JSONB)),
    '409_CONFLICT'::crossplane.status_code,
    'create_schema: existing schema returns 409_CONFLICT'
);

-- ============================================================================
-- Test 3: update_schema with owner change returns 202_UPDATED
-- ============================================================================

-- First create a role to be the new owner
CREATE ROLE test_xplane_schema_owner NOLOGIN;

SELECT is(
    (SELECT status FROM crossplane.update_schema(
        '{"name":"test_xplane_schema1","owner":"test_xplane_schema_owner","database":"postgres"}'::JSONB,
        '{"exists":true,"name":"test_xplane_schema1","owner":"postgres"}'::JSONB
    )),
    '202_UPDATED'::crossplane.status_code,
    'update_schema: owner change returns 202_UPDATED'
);

-- ============================================================================
-- Test 4: update_schema with no change returns 204_NO_CHANGE
-- ============================================================================
SELECT is(
    (SELECT status FROM crossplane.update_schema(
        '{"name":"test_xplane_schema1","owner":"test_xplane_schema_owner","database":"postgres"}'::JSONB,
        '{"exists":true,"name":"test_xplane_schema1","owner":"test_xplane_schema_owner"}'::JSONB
    )),
    '204_NO_CHANGE'::crossplane.status_code,
    'update_schema: no change returns 204_NO_CHANGE'
);

-- ============================================================================
-- Test 5: delete_schema returns 203_DELETED
-- ============================================================================
SELECT is(
    (SELECT status FROM crossplane.delete_schema('{"name":"test_xplane_schema1"}'::JSONB)),
    '203_DELETED'::crossplane.status_code,
    'delete_schema: returns 203_DELETED'
);

-- ============================================================================
-- Test 6: delete_schema non-existent returns 204_NO_CHANGE
-- ============================================================================
SELECT is(
    (SELECT status FROM crossplane.delete_schema('{"name":"test_xplane_schema1"}'::JSONB)),
    '204_NO_CHANGE'::crossplane.status_code,
    'delete_schema: non-existent returns 204_NO_CHANGE'
);

-- ============================================================================
-- Test 7: delete_schema with cascade
-- ============================================================================

-- Create schema and a table in it to test cascade
SELECT status FROM crossplane.create_schema('{"name":"test_xplane_schema_cascade","owner":"postgres","database":"postgres"}'::JSONB);
CREATE TABLE test_xplane_schema_cascade.test_table (id INT);

SELECT is(
    (SELECT status FROM crossplane.delete_schema('{"name":"test_xplane_schema_cascade","cascade":true}'::JSONB)),
    '203_DELETED'::crossplane.status_code,
    'delete_schema: cascade deletes schema with objects'
);

SELECT * FROM finish();
ROLLBACK;
