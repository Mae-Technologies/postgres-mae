BEGIN;

SELECT plan(1);

-- app_user cannot call app.alter_column_type
SELECT throws_like(
    $ SELECT app.alter_column_type('app.sys_client', 'entity_type', 'text') $,
    '%alter_column_type not allowed%',
    'app_user: alter_column_type raises permission error'
);

SELECT * FROM finish();

ROLLBACK;
