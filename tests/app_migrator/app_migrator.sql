BEGIN;
SELECT
    plan (11);
------------------------------------------------------------------------------
-- 1–3: SQLx bookkeeping DDL is allowed for app_migrator
------------------------------------------------------------------------------
SELECT
    lives_ok ('CREATE TABLE app._sqlx_migrations (version text primary key);', 'app_migrator can CREATE sqlx bookkeeping table');
SELECT
    lives_ok ('ALTER TABLE app._sqlx_migrations ADD COLUMN applied_at timestamptz;', 'app_migrator can ALTER sqlx bookkeeping table');
SELECT
    lives_ok ('CREATE INDEX ON app._sqlx_migrations (applied_at);', 'app_migrator can CREATE INDEX on sqlx bookkeeping table');
------------------------------------------------------------------------------
-- Creating tables through the function
------------------------------------------------------------------------------
SELECT
    app.create_table_from_spec ('{
  "table_name": "repoexample",
  "columns": [
    { "name": "string_value", "type": "text"},
    { "name": "value", "type": "int4"}
  ]
}
  '::jsonb);
SELECT
    has_table ('app', 'repoexample', 'can create tables with the create_table_crop_spec function');
------------------------------------------------------------------------------
-- 4–6: Direct DDL is blocked
------------------------------------------------------------------------------
SELECT
    throws_like ('CREATE TABLE app.__ddl_block_test (id int);', 'DDL "%": not allowed for role "%". query: "%".%', 'app_migrator cannot CREATE TABLE in app schema');
SELECT
    throws_like ('DROP TABLE app.repoexample;', 'must be owner of table%', 'app_migrator cannot drop tables');
SELECT
    lives_ok ('CREATE SEQUENCE app.__ddl_block_seq;', 'app_migrator can create sequences');
------------------------------------------------------------------------------
-- 7–9: ALTER TABLE is blocked (including protected columns)
------------------------------------------------------------------------------
SELECT
    throws_like ('ALTER TABLE app.repoexample ADD COLUMN x int;', 'must be owner of %', 'cannot add coulmns');
SELECT
    throws_like ('ALTER TABLE app.repoexample DROP COLUMN id;', 'must be owner of %', 'cannot drop columns');
SELECT
    throws_like ('ALTER TABLE app.repoexample RENAME COLUMN created_at TO c;', 'must be owner of %', 'cannot rename columns');
------------------------------------------------------------------------------
SELECT
    lives_ok ('SELECT drop_column(''repoexample'', ''string_value'');', 'can drop columns with function');
SELECT
    throws_like ('SELECT drop_column(''repoexample'', ''id'');', 'can drop columns with function');
SELECT
    *
FROM
    finish ();
ROLLBACK;

