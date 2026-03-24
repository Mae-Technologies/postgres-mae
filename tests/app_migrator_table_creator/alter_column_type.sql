CREATE OR REPLACE FUNCTION app.test_alter_column_type ()
    RETURNS SETOF text
    LANGUAGE plpgsql
    AS $$
DECLARE
    tname text;
    full_name text;
BEGIN
    -- Plan: 4 core assertions
    RETURN NEXT plan (4);

    -- Generate a unique test table name in the test schema
    SELECT 'tmp_alter_col_' || substring(md5(gen_random_uuid()::text), 1, 10)
    INTO tname;
    full_name := format('%I.%I', 'test', tname);

    ----------------------------------------------------------------------------
    -- Prepare a simple table for db_migrator/table_creator tests via helper
    -- (same pattern as app_migrator_table_creator.sql)
    ----------------------------------------------------------------------------
    PERFORM app.create_table_from_spec(
        format('{"table_name": "test.%s", "columns": [{"name": "x", "type": "text"}]}', tname)::jsonb
    );

    ----------------------------------------------------------------------------
    -- 1) db_migrator PASSES via helper (TEXT -> INT4)
    ----------------------------------------------------------------------------
    IF pg_has_role(SESSION_USER, 'db_migrator', 'member') THEN
        RETURN NEXT lives_ok(
            format('SELECT app.alter_column_type(''test.%s'', ''x'', ''int4'');', tname),
            'db_migrator can alter non-protected column via app.alter_column_type'
        );
    ELSE
        RETURN NEXT pass('skipped (SESSION_USER is not db_migrator)');
    END IF;

    ----------------------------------------------------------------------------
    -- 2) table_creator PASSES via helper (TEXT -> INT4)
    ----------------------------------------------------------------------------
    IF pg_has_role(SESSION_USER, 'table_creator', 'member') THEN
        RETURN NEXT lives_ok(
            format('SELECT app.alter_column_type(''test.%s'', ''x'', ''int4'');', tname),
            'table_creator can alter non-protected column via app.alter_column_type'
        );
    ELSE
        RETURN NEXT pass('skipped (SESSION_USER is not table_creator)');
    END IF;

    ----------------------------------------------------------------------------
    -- 3) db_migrator FAILS with raw ALTER TABLE
    ----------------------------------------------------------------------------
    IF pg_has_role(SESSION_USER, 'db_migrator', 'member') THEN
        RETURN NEXT throws_ok(
            format('ALTER TABLE %s ALTER COLUMN x TYPE bigint;', full_name),
            NULL,
            'db_migrator cannot ALTER TABLE directly'
        );
    ELSE
        RETURN NEXT pass('skipped (SESSION_USER is not db_migrator)');
    END IF;

    ----------------------------------------------------------------------------
    -- 4) table_creator FAILS with raw ALTER TABLE
    ----------------------------------------------------------------------------
    IF pg_has_role(SESSION_USER, 'table_creator', 'member') THEN
        RETURN NEXT throws_ok(
            format('ALTER TABLE %s ALTER COLUMN x TYPE bigint;', full_name),
            NULL,
            'table_creator cannot ALTER TABLE directly'
        );
    ELSE
        RETURN NEXT pass('skipped (SESSION_USER is not table_creator)');
    END IF;

    -- Cleanup: drop the test column via helper (table ownership stays with app_owner)
    PERFORM app.drop_column(full_name, 'x');

    RETURN QUERY SELECT * FROM finish();
END;
$$;

\set ON_ERROR_STOP off
BEGIN;
SELECT * FROM app.test_alter_column_type ();
ROLLBACK;

DROP FUNCTION app.test_alter_column_type ();
