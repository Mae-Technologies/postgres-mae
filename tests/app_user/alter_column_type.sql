BEGIN;

SELECT plan(1);

-- app_user cannot call app.alter_column_type
SELECT throws_ok(
    $q$ SELECT app.alter_column_type('app.sys_client', 'entity_type', 'text') $q$,
    '42501',
    NULL,
    'app_user: alter_column_type raises permission error'
);

SELECT * FROM finish();

ROLLBACK;
