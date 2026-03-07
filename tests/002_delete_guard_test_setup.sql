-- Setup file (runs as SUPERUSER): creates a persistent test table for the
-- delete-guard tests that execute as app_user.
-- Uses COMMIT (not ROLLBACK) so the table survives across test files.

BEGIN;
SELECT plan(1);

SELECT app.create_table_from_spec(
    '{"table_name": "test.delete_guard_test", "columns": [{"name": "label", "type": "text"}]}'::jsonb
);

-- Insert a row so app_user tests have a target row.
INSERT INTO test.delete_guard_test (sys_client, status, created_by, updated_by)
VALUES (1, 'active', 1, 1);

SELECT has_table('test', 'delete_guard_test', 'delete_guard_test table created for app_user tests');

SELECT * FROM finish();

COMMIT;
