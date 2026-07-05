CREATE OR REPLACE FUNCTION app.test_add_exclusions_from_spec()
RETURNS SETOF text
LANGUAGE plpgsql
AS $$
DECLARE
    tname text;
    full_table text;
    excl_spec jsonb;
BEGIN
    RETURN NEXT plan(11);

    excl_spec := '[
      {
        "name": "added_partial_unique",
        "using": "GIST",
        "where": "status <> ''deleted''",
        "elements": [
          {"column": "sys_client", "op_class": "gist_int4_ops", "with": "="},
          {"column": "code", "op_class": "gist_text_ops", "with": "="}
        ]
      }
    ]'::jsonb;

    SELECT 'tmp_add_excl_' || substring(md5(gen_random_uuid()::text), 1, 8) INTO tname;
    full_table := format('test.%I', tname);

    ---------------------------------------------------------------------------
    -- 1. Happy path: add exclusions to an existing table
    ---------------------------------------------------------------------------
    PERFORM app.create_table_from_spec(format('{
      "table_name": "test.%s",
      "columns": [
        {"name": "code", "type": "TEXT", "nullable": false}
      ]
    }', tname)::jsonb);

    RETURN NEXT has_table('test', tname, 'base table created without exclusions');

    RETURN NEXT lives_ok(
        format('SELECT app.add_exclusions_from_spec(''test.%s'', %L::jsonb);', tname, excl_spec::text),
        'add_exclusions_from_spec succeeds on existing table'
    );

    RETURN NEXT ok(EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class r ON r.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = r.relnamespace
        WHERE c.contype = 'x'
          AND c.conname = 'added_partial_unique'
          AND n.nspname = 'test'
          AND r.relname = tname
    ), 'exclusion constraint added with expected name');

    ---------------------------------------------------------------------------
    -- 2. Constraint is functional after add_exclusions_from_spec
    ---------------------------------------------------------------------------
    RETURN NEXT lives_ok(
        format('INSERT INTO %s (sys_client, status, comment, tags, sys_detail, created_by, updated_by, code)
                VALUES (9, ''active'', NULL, ''{}''::jsonb, ''{}''::jsonb, 1, 1, ''INV-1'');', full_table),
        'first active row inserts after add_exclusions_from_spec');

    RETURN NEXT throws_like(
        format('INSERT INTO %s (sys_client, status, comment, tags, sys_detail, created_by, updated_by, code)
                VALUES (9, ''active'', NULL, ''{}''::jsonb, ''{}''::jsonb, 1, 1, ''INV-1'');', full_table),
        '%conflicting key value violates exclusion constraint%',
        'duplicate active row rejected after add_exclusions_from_spec');

    RETURN NEXT lives_ok(
        format(
            'INSERT INTO %s (sys_client, status, comment, tags, sys_detail, created_by, updated_by, code)
             VALUES (9, %L, NULL, ''{}''::jsonb, ''{}''::jsonb, 1, 1, %L);',
            full_table,
            'deleted',
            'INV-1'
        ),
        'deleted row may coexist with active row sharing the same key after add_exclusions_from_spec');

    ---------------------------------------------------------------------------
    -- 3. Idempotent: re-applying the same spec is a no-op
    ---------------------------------------------------------------------------
    RETURN NEXT lives_ok(
        format('SELECT app.add_exclusions_from_spec(''test.%s'', %L::jsonb);', tname, excl_spec::text),
        'add_exclusions_from_spec is idempotent when constraint already exists'
    );

    RETURN NEXT ok((
        SELECT count(*)::int
        FROM pg_constraint c
        JOIN pg_class r ON r.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = r.relnamespace
        WHERE c.contype = 'x'
          AND c.conname = 'added_partial_unique'
          AND n.nspname = 'test'
          AND r.relname = tname
    ) = 1, 'exactly one exclusion constraint remains after idempotent re-apply');

    ---------------------------------------------------------------------------
    -- 4. Validation failures
    ---------------------------------------------------------------------------
    RETURN NEXT throws_like(
        format('SELECT app.add_exclusions_from_spec(''test.%s'', ''{}''::jsonb);', tname),
        '%p_exclusions must be a JSON array%',
        'non-array p_exclusions is rejected');

    RETURN NEXT throws_like(
        $sql$SELECT app.add_exclusions_from_spec('test.nonexistent_table_xyz', '[]'::jsonb);$sql$,
        '%does not exist%',
        'unknown table is rejected'
    );

    RETURN NEXT throws_like(
        format(
            'SELECT app.add_exclusions_from_spec(%L, %L::jsonb);',
            'test.' || tname,
            '[{"name": "bad_column_excl", "using": "GIST", "elements": [{"column": "missing_col", "op_class": "gist_text_ops", "with": "="}]}]'
        ),
        '%exclusion column not found in table%',
        'unknown exclusion column is rejected');

    RETURN QUERY SELECT * FROM finish();
END;
$$;

\set ON_ERROR_STOP off
BEGIN;
SELECT * FROM app.test_add_exclusions_from_spec();
ROLLBACK;

DROP FUNCTION app.test_add_exclusions_from_spec();