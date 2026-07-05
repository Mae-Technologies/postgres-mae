-- pgTAP tests executed as app_user
-- app_user has no EXECUTE on add_exclusions_from_spec (migrator-only elevated DDL).

BEGIN;

SELECT plan(1);

SELECT throws_ok(
    $sql$ SELECT app.add_exclusions_from_spec('test.some_table', '[]'::jsonb) $sql$,
    '42501',
    NULL,
    'app_user cannot call add_exclusions_from_spec'
);

SELECT * FROM finish();

ROLLBACK;