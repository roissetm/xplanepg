-- ============================================================================
-- UNIT TESTS : Helpers (set_condition, emit_event, set_status, validate_spec, observe_resource)
-- ============================================================================

BEGIN;
SELECT plan(28);

-- ============================================================================
-- Setup: insert a test managed resource
-- ============================================================================
INSERT INTO crossplane.managed_resources (id, kind, name, spec)
VALUES ('00000000-0000-0000-0000-000000000001'::UUID, 'Schema', 'test-helpers-res',
        '{"name":"test_xplane_helpers","database":"postgres"}'::JSONB);

-- ============================================================================
-- set_condition() tests
-- ============================================================================

-- Test 1: Insert a new condition
SELECT lives_ok(
    $$SELECT crossplane.set_condition('00000000-0000-0000-0000-000000000001'::UUID, 'Synced', 'True', 'TestReason', 'Test message')$$,
    'set_condition: insert new condition succeeds'
);

-- Test 2: Condition was actually inserted
SELECT is(
    (SELECT status FROM crossplane.conditions WHERE resource_id = '00000000-0000-0000-0000-000000000001'::UUID AND condition_type = 'Synced'),
    'True'::crossplane.condition_status,
    'set_condition: condition status is True'
);

-- Test 3: Upsert with same status — transition time should NOT change
SELECT lives_ok(
    $$SELECT crossplane.set_condition('00000000-0000-0000-0000-000000000001'::UUID, 'Synced', 'True', 'SameReason', 'Same status')$$,
    'set_condition: upsert same status succeeds'
);

-- Test 4: Upsert with different status — transition time SHOULD change
SELECT lives_ok(
    $$SELECT crossplane.set_condition('00000000-0000-0000-0000-000000000001'::UUID, 'Synced', 'False', 'NewReason', 'Changed')$$,
    'set_condition: upsert different status succeeds'
);

SELECT is(
    (SELECT status FROM crossplane.conditions WHERE resource_id = '00000000-0000-0000-0000-000000000001'::UUID AND condition_type = 'Synced'),
    'False'::crossplane.condition_status,
    'set_condition: condition status updated to False'
);

-- Test 5: Insert a Ready condition (second condition type)
SELECT lives_ok(
    $$SELECT crossplane.set_condition('00000000-0000-0000-0000-000000000001'::UUID, 'Ready', 'Unknown', 'Init', 'Initializing')$$,
    'set_condition: insert Ready condition succeeds'
);

SELECT is(
    (SELECT count(*)::INTEGER FROM crossplane.conditions WHERE resource_id = '00000000-0000-0000-0000-000000000001'::UUID),
    2,
    'set_condition: two conditions exist for resource'
);

-- ============================================================================
-- emit_event() tests
-- ============================================================================

-- Test 6: Emit a normal event
SELECT isnt(
    crossplane.emit_event('00000000-0000-0000-0000-000000000001'::UUID, 'Normal', 'TestEvent', 'Test event message', '200_SYNCED'),
    NULL::UUID,
    'emit_event: returns a UUID'
);

-- Test 7: Event was inserted
SELECT is(
    (SELECT count(*)::INTEGER FROM crossplane.events WHERE resource_id = '00000000-0000-0000-0000-000000000001'::UUID AND reason = 'TestEvent'),
    1,
    'emit_event: event was inserted'
);

-- Test 8: Emit a warning event
SELECT isnt(
    crossplane.emit_event('00000000-0000-0000-0000-000000000001'::UUID, 'Warning', 'TestWarning', 'Warning message'),
    NULL::UUID,
    'emit_event: warning event returns UUID'
);

-- ============================================================================
-- set_status() tests
-- ============================================================================

-- Test 9: Update status_code
SELECT lives_ok(
    $$SELECT crossplane.set_status('00000000-0000-0000-0000-000000000001'::UUID, '200_SYNCED', 'All good')$$,
    'set_status: update status_code succeeds'
);

SELECT is(
    (SELECT status_code FROM crossplane.managed_resources WHERE id = '00000000-0000-0000-0000-000000000001'::UUID),
    '200_SYNCED'::crossplane.status_code,
    'set_status: status_code is 200_SYNCED'
);

-- Test 10: set_status with at_provider
SELECT lives_ok(
    $$SELECT crossplane.set_status('00000000-0000-0000-0000-000000000001'::UUID, '201_CREATED', 'Created', '{"exists":true}'::JSONB)$$,
    'set_status: update with at_provider succeeds'
);

SELECT is(
    (SELECT (at_provider->>'exists')::BOOLEAN FROM crossplane.managed_resources WHERE id = '00000000-0000-0000-0000-000000000001'::UUID),
    TRUE,
    'set_status: at_provider was updated'
);

-- Test 11: set_status with NULL at_provider preserves existing
SELECT lives_ok(
    $$SELECT crossplane.set_status('00000000-0000-0000-0000-000000000001'::UUID, '202_UPDATED', 'Updated')$$,
    'set_status: NULL at_provider preserves existing'
);

SELECT is(
    (SELECT (at_provider->>'exists')::BOOLEAN FROM crossplane.managed_resources WHERE id = '00000000-0000-0000-0000-000000000001'::UUID),
    TRUE,
    'set_status: at_provider still has exists=true'
);

-- ============================================================================
-- validate_spec() tests
-- ============================================================================

-- Test 12: Valid Database spec
SELECT is(
    (SELECT valid FROM crossplane.validate_spec('Database', '{"name":"testdb","owner":"postgres"}'::JSONB)),
    TRUE,
    'validate_spec: valid Database spec'
);

-- Test 13: Database missing name
SELECT is(
    (SELECT valid FROM crossplane.validate_spec('Database', '{"owner":"postgres"}'::JSONB)),
    FALSE,
    'validate_spec: Database missing name returns FALSE'
);

-- Test 14: Database missing owner
SELECT is(
    (SELECT valid FROM crossplane.validate_spec('Database', '{"name":"testdb"}'::JSONB)),
    FALSE,
    'validate_spec: Database missing owner returns FALSE'
);

-- Test 15: Valid Schema spec
SELECT is(
    (SELECT valid FROM crossplane.validate_spec('Schema', '{"name":"testschema","database":"postgres"}'::JSONB)),
    TRUE,
    'validate_spec: valid Schema spec'
);

-- Test 16: Schema missing database
SELECT is(
    (SELECT valid FROM crossplane.validate_spec('Schema', '{"name":"testschema"}'::JSONB)),
    FALSE,
    'validate_spec: Schema missing database returns FALSE'
);

-- Test 17: Valid Role spec
SELECT is(
    (SELECT valid FROM crossplane.validate_spec('Role', '{"name":"testrole"}'::JSONB)),
    TRUE,
    'validate_spec: valid Role spec'
);

-- Test 18: Role missing name
SELECT is(
    (SELECT valid FROM crossplane.validate_spec('Role', '{}'::JSONB)),
    FALSE,
    'validate_spec: Role missing name returns FALSE'
);

-- Test 19: Valid ServiceAccount spec
SELECT is(
    (SELECT valid FROM crossplane.validate_spec('ServiceAccount', '{"name":"testsa","database":"postgres"}'::JSONB)),
    TRUE,
    'validate_spec: valid ServiceAccount spec'
);

-- Test 20: ServiceAccount missing database
SELECT is(
    (SELECT valid FROM crossplane.validate_spec('ServiceAccount', '{"name":"testsa"}'::JSONB)),
    FALSE,
    'validate_spec: ServiceAccount missing database returns FALSE'
);

-- Test 21: Valid Extension spec
SELECT is(
    (SELECT valid FROM crossplane.validate_spec('Extension', '{"name":"hstore","database":"postgres"}'::JSONB)),
    TRUE,
    'validate_spec: valid Extension spec'
);

-- Test 22: Extension missing database
SELECT is(
    (SELECT valid FROM crossplane.validate_spec('Extension', '{"name":"hstore"}'::JSONB)),
    FALSE,
    'validate_spec: Extension missing database returns FALSE'
);

-- ============================================================================
-- observe_resource() tests
-- ============================================================================

-- Test 23: Observe existing database (postgres always exists)
SELECT is(
    (SELECT (crossplane.observe_resource('Database', '{"name":"postgres"}'::JSONB))->>'exists')::BOOLEAN,
    TRUE,
    'observe_resource: postgres database exists'
);

-- Test 24: Observe non-existent database
SELECT is(
    (SELECT (crossplane.observe_resource('Database', '{"name":"nonexistent_db_xplane_test"}'::JSONB))->>'exists')::BOOLEAN,
    FALSE,
    'observe_resource: non-existent database returns exists=false'
);

-- Test 25: Observe existing schema (public always exists)
SELECT is(
    (SELECT (crossplane.observe_resource('Schema', '{"name":"public"}'::JSONB))->>'exists')::BOOLEAN,
    TRUE,
    'observe_resource: public schema exists'
);

-- Test 26: Observe existing role (postgres always exists)
SELECT is(
    (SELECT (crossplane.observe_resource('Role', '{"name":"postgres"}'::JSONB))->>'exists')::BOOLEAN,
    TRUE,
    'observe_resource: postgres role exists'
);

-- Test 27: Observe existing extension (plpgsql is always installed)
SELECT is(
    (SELECT (crossplane.observe_resource('Extension', '{"name":"plpgsql"}'::JSONB))->>'exists')::BOOLEAN,
    TRUE,
    'observe_resource: plpgsql extension exists'
);

-- Test 28: Observe non-existent extension
SELECT is(
    (SELECT (crossplane.observe_resource('Extension', '{"name":"nonexistent_ext_xplane_test"}'::JSONB))->>'exists')::BOOLEAN,
    FALSE,
    'observe_resource: non-existent extension returns exists=false'
);

SELECT * FROM finish();
ROLLBACK;
