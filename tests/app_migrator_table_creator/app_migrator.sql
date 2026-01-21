CREATE OR REPLACE FUNCTION app.test_ddl_policies ()
    RETURNS SETOF text
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN NEXT plan (13);
    ------------------------------------------------------------------------------
    -- 1–3: SQLx bookkeeping DDL is allowed for app_migrator
    ------------------------------------------------------------------------------
    IF pg_has_role(SESSION_USER, 'app_migrator', 'member') THEN
        RETURN NEXT lives_ok ('CREATE TABLE app._sqlx_migrations (version text primary key);', 'can CREATE sqlx bookkeeping table');
        RETURN NEXT lives_ok ('ALTER TABLE app._sqlx_migrations ADD COLUMN applied_at timestamptz;', 'can ALTER sqlx bookkeeping table');
        RETURN NEXT lives_ok ('CREATE INDEX ON app._sqlx_migrations (applied_at);', 'can CREATE INDEX on sqlx bookkeeping table');
    ELSE
        RETURN NEXT pass ('skipped (not app_migrator): create table');
        RETURN NEXT pass ('skipped (not app_migrator): alter table');
        RETURN NEXT pass ('skipped (not app_migrator): create index');
    END IF;
    ------------------------------------------------------------------------------
    -- Creating tables through the function
    ------------------------------------------------------------------------------
    PERFORM
        app.create_table_from_spec ('{
      "table_name": "repoexample",
      "columns": [
        { "name": "string_value", "type": "text"},
        { "name": "value", "type": "int4"}
      ]
    }'::jsonb);
    RETURN NEXT has_table ('app', 'repoexample', 'can create tables with create_table_from_spec');
    ------------------------------------------------------------------------------
    -- 4–6: Direct DDL is blocked
    ------------------------------------------------------------------------------
    RETURN NEXT throws_like ('CREATE TABLE app.__ddl_block_test (id int);', 'DDL "%": not allowed for role "%". query: "%".%', 'cannot CREATE TABLE in app schema');
    RETURN NEXT throws_like ('DROP TABLE app.repoexample;', 'must be owner of table%', 'cannot drop tables');
    RETURN NEXT lives_ok ('CREATE SEQUENCE app.__ddl_block_seq;', 'can create sequences');
    ------------------------------------------------------------------------------
    -- 7–9: ALTER TABLE is blocked
    ------------------------------------------------------------------------------
    RETURN NEXT throws_like ('ALTER TABLE app.repoexample ADD COLUMN x int;', 'must be owner of %', 'cannot add columns');
    RETURN NEXT throws_like ('ALTER TABLE app.repoexample DROP COLUMN id;', 'must be owner of %', 'cannot drop columns');
    RETURN NEXT throws_like ('ALTER TABLE app.repoexample RENAME COLUMN created_at TO c;', 'must be owner of %', 'cannot rename columns');
    ------------------------------------------------------------------------------
    -- 10–12: Protected fields cannot be altered via elevated functions
    ------------------------------------------------------------------------------
    RETURN NEXT throws_like ('SELECT app.drop_column(''repoexample'', ''id'');', '%Protected column%', 'cannot drop protected column with function');
    RETURN NEXT throws_like ('SELECT app.rename_column(''repoexample'', ''id'', ''this_id'');', '%Protected column%', 'cannot rename protected column with function');
    RETURN NEXT throws_like ($sql$
        SELECT
            app.add_column_from_spec ('{
        "table_name": "repoexample",
        "column": { "name": "sys_client", "type": "text" }
      }'::jsonb);
    $sql$,
    '%Protected column%',
    'cannot add column with protected name with function');
    RETURN QUERY
    SELECT
        *
    FROM
        finish ();
END;
$$;

-- pg_prove should run a file that does:
SELECT
    *
FROM
    app.test_ddl_policies ();

