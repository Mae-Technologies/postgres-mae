CREATE OR REPLACE FUNCTION app.test_ddl_policies ()
    RETURNS SETOF text
    LANGUAGE plpgsql
    AS $$
DECLARE
    uuid text;
    suffix text;
    tname text;
    full_path_name text;
BEGIN
    RETURN NEXT plan (16);
    SELECT
        substring(md5(gen_random_uuid ()::text), 1, 10) INTO tname;
    tname := 'tmp_' || tname;
    full_path_name := format('%I.%I', 'test', tname);
    ------------------------------------------------------------------------------
    -- 1–3: SQLx bookkeeping DDL is allowed for app_migrator
    ------------------------------------------------------------------------------
    IF pg_has_role(SESSION_USER, 'app_migrator', 'member') THEN
        RETURN NEXT lives_ok (format('CREATE TABLE test._sqlx_migrations_%s (version text primary key);', tname), 'can CREATE sqlx bookkeeping table');
        RETURN NEXT lives_ok (format('ALTER TABLE test._sqlx_migrations_%s ADD COLUMN applied_at timestamptz;', tname), 'can ALTER sqlx bookkeeping table');
        RETURN NEXT lives_ok (format('CREATE INDEX ON test._sqlx_migrations_%s (applied_at);', tname), 'can CREATE INDEX on sqlx bookkeeping table');
    ELSE
        RETURN NEXT throws_like (format('CREATE TABLE test._sqlx_migrations_%s (version text primary key);', tname), 'DDL "CREATE TABLE": not allowed for role%');
        RETURN NEXT pass ('skipped (not app_migrator): create table');
        RETURN NEXT pass ('skipped (not app_migrator): create table');
    END IF;
    ------------------------------------------------------------------------------
    -- Creating tables through the function
    ------------------------------------------------------------------------------
    PERFORM
        app.create_table_from_spec (format('{ "table_name" :"test.%s", "columns" :[{ "name" :"string_value", "type" :"text" }, { "name" :"value", "type" :"int4" }] }', tname)::jsonb);
    RETURN NEXT has_table ('test', format('%s', tname), 'can create tables with create_table_from_spec');
    ------------------------------------------------------------------------------
    -- 4–6: Direct DDL is blocked
    ------------------------------------------------------------------------------
    RETURN NEXT throws_like (format('CREATE TABLE test.__ddl_block_test_%s (id int);', tname), 'DDL "%": not allowed for role "%". query: "%".%', 'cannot CREATE TABLE in app schema');
    RETURN NEXT throws_like (format('DROP TABLE test.%s;', tname), 'must be owner of table%', 'cannot drop tables');
    RETURN NEXT lives_ok (format('CREATE SEQUENCE test.__ddl_block_seq_%s;', tname), 'can create sequences');
    ------------------------------------------------------------------------------
    -- 7–9: ALTER TABLE is blocked
    ------------------------------------------------------------------------------
    RETURN NEXT throws_like (format('ALTER TABLE test.%s ADD COLUMN x int;', tname), 'must be owner of %', 'cannot add columns');
    RETURN NEXT throws_like (format('ALTER TABLE test.%s DROP COLUMN id;', tname), 'must be owner of %', 'cannot drop columns');
    RETURN NEXT throws_like (format('ALTER TABLE test.%s RENAME COLUMN created_at TO c;', tname), 'must be owner of %', 'cannot rename columns');
    ------------------------------------------------------------------------------
    -- 10–12: Protected fields cannot be altered via elevated functions
    ------------------------------------------------------------------------------
    RETURN NEXT throws_like (format('SELECT app.drop_column(''test.%s'', ''id'');', tname), '%Protected column%', 'cannot drop protected column with function');
    RETURN NEXT throws_like (format('SELECT app.add_column_from_spec (''{"table_name": "test.%s", "column": { "name": "sys_client", "type": "text" }}''::jsonb);', tname), '%Protected column%', 'cannot add column with protected name with function');
    RETURN NEXT throws_like (format('SELECT app.rename_column(''test.%s'', ''id'', ''this_id'');', tname), '%Protected column%', 'cannot rename protected column with function');
    ------------------------------------------------------------------------------
    -- 13-15: Non-protected fields can be altered via elevated functions
    ------------------------------------------------------------------------------
    -- Rename column
    PERFORM
        app.rename_column (format('%I.%I', 'test', tname), 'value', 'other_value');
    RETURN NEXT has_column ('test', tname, 'other_value', 'can rename column with function');
    -- ADD COLUMN
    PERFORM
        app.add_column_from_spec (format('{"table_name": "%I.%I", "column": { "name": "another_value", "type": "text" }}', 'test', tname)::jsonb);
    RETURN NEXT has_column ('test', tname, 'other_value', 'can add column with protected name with function');
    -- REMOVE COLUMN
    PERFORM
        app.drop_column (format('%I.%I', 'test', tname), 'string_value');
    RETURN NEXT hasnt_column ('test', 'tname', 'can drop protected column with function');
    ------------------------------------------------------------------------------
    -- RETURN COMPLETE
    ------------------------------------------------------------------------------
    RETURN QUERY
    SELECT
        *
    FROM
        finish ();
END;
$$;

\set ON_ERROR_STOP off
BEGIN;
-- pg_prove should run a file that does:
SELECT
    *
FROM
    app.test_ddl_policies ();
ROLLBACK;

DROP FUNCTION app.test_ddl_policies ();

