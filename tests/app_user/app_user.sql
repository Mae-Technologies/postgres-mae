-- pgTAP tests executed as app_user
-- Verifies that direct DELETE is blocked with an informative error message.
--
-- Assumes test.delete_guard_test was created by 002_delete_guard_test_setup.sql
-- (run as SUPERUSER before these tests execute).

BEGIN;

SELECT plan(3);

-- ── Test 1: DELETE raises the correct SQLSTATE ────────────────────────────────
SELECT throws_ok(
    $q$ DELETE FROM test.delete_guard_test WHERE sys_client = 1 $q$,
    '42501',
    'Direct DELETE is not permitted. To remove a record, set its status to ''deleted'' or ''archived'' instead.',
    'app_user: DELETE raises 42501 with correct message'
);

-- ── Test 2: error message mentions ''deleted'' ────────────────────────────────
SELECT throws_like(
    $q$ DELETE FROM test.delete_guard_test WHERE sys_client = 1 $q$,
    '%deleted%',
    'app_user: DELETE error message mentions ''deleted'''
);

-- ── Test 3: error message mentions ''archived'' ───────────────────────────────
SELECT throws_like(
    $q$ DELETE FROM test.delete_guard_test WHERE sys_client = 1 $q$,
    '%archived%',
    'app_user: DELETE error message mentions ''archived'''
);

SELECT * FROM finish();

ROLLBACK;
