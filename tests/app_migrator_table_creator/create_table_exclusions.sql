CREATE OR REPLACE FUNCTION app.test_create_table_exclusions()
RETURNS SETOF text
LANGUAGE plpgsql
AS $$
DECLARE
    tname text;
    full_table text;
BEGIN
    RETURN NEXT plan(10);

    -- Generate a random table name in test schema
    SELECT 'tmp_excl_' || substring(md5(gen_random_uuid()::text), 1, 8) INTO tname;
    full_table := format('test.%I', tname);

    ---------------------------------------------------------------------------
    -- 1. Happy path: spec with valid exclusions creates the constraint
    ---------------------------------------------------------------------------
    PERFORM app.create_table_from_spec(format('{
      "table_name": "test.%s",
      "columns": [
        {"name": "bounds", "type": "int4range"}
      ],
      "exclusions": [
        {
          "name": "account_type_boundaries_no_overlap",
          "using": "GIST",
          "elements": [
            {"column": "bounds", "op_class": "range_ops", "with": "&&"}
          ]
        }
      ]
    }', tname)::jsonb);

    RETURN NEXT has_table('test', tname, 'table with exclusions created');

    RETURN NEXT ok(EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class r ON r.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = r.relnamespace
        WHERE c.contype = 'x'
          AND c.conname = 'account_type_boundaries_no_overlap'
          AND n.nspname = 'test'
          AND r.relname = tname
    ), 'exclusion constraint created with expected name');

    ---------------------------------------------------------------------------
    -- 2. Constraint is functional: overlapping rows rejected
    ---------------------------------------------------------------------------
    RETURN NEXT lives_ok(
        format('INSERT INTO %s (sys_client, status, comment, tags, sys_detail, created_by, updated_by, bounds)
                VALUES (1, ''active'', NULL, ''{}''::jsonb, ''{}''::jsonb, 1, 1, ''[1,10)''::int4range);', full_table),
        'first row inserts successfully');

    RETURN NEXT throws_like(
        format('INSERT INTO %s (sys_client, status, comment, tags, sys_detail, created_by, updated_by, bounds)
                VALUES (1, ''active'', NULL, ''{}''::jsonb, ''{}''::jsonb, 1, 1, ''[5,15)''::int4range);', full_table),
        '%duplicate key value violates exclusion constraint%', 'overlapping row is rejected');

    ---------------------------------------------------------------------------
    -- 3. No-op: spec without exclusions still works and has no exclusion constraint
    ---------------------------------------------------------------------------
    SELECT 'tmp_excl_' || substring(md5(gen_random_uuid()::text), 1, 8) INTO tname;
    full_table := format('test.%I', tname);

    PERFORM app.create_table_from_spec(format('{
      "table_name": "test.%s",
      "columns": [
        {"name": "value", "type": "int4"}
      ]
    }', tname)::jsonb);

    RETURN NEXT has_table('test', tname, 'table without exclusions created');

    RETURN NEXT ok(NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class r ON r.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = r.relnamespace
        WHERE c.contype = 'x'
          AND n.nspname = 'test'
          AND r.relname = tname
    ), 'no exclusion constraints present when exclusions key omitted');

    ---------------------------------------------------------------------------
    -- 4. Invalid using method
    ---------------------------------------------------------------------------
    RETURN NEXT throws_like(
        $sql$SELECT app.create_table_from_spec('{
          "table_name": "test.excl_invalid_using",
          "columns": [
            {"name": "value", "type": "int4"}
          ],
          "exclusions": [
            {"name": "excl_invalid", "using": "HASH", "elements": [
              {"column": "value", "op_class": "int4_ops", "with": "="}
            ]}
          ]
        }'::jsonb);$sql$,
        '%invalid exclusion using method%',
        'invalid using method is rejected');

    ---------------------------------------------------------------------------
    -- 5. Unknown op_class
    ---------------------------------------------------------------------------
    RETURN NEXT throws_like(
        $sql$SELECT app.create_table_from_spec('{
          "table_name": "test.excl_invalid_opclass",
          "columns": [
            {"name": "value", "type": "int4"}
          ],
          "exclusions": [
            {"name": "excl_invalid_opclass", "using": "GIST", "elements": [
              {"column": "value", "op_class": "unknown_ops", "with": "="}
            ]}
          ]
        }'::jsonb);$sql$,
        '%invalid exclusion op_class%',
        'unknown op_class is rejected');

    ---------------------------------------------------------------------------
    -- 6. Column not in table
    ---------------------------------------------------------------------------
    RETURN NEXT throws_like(
        $sql$SELECT app.create_table_from_spec('{
          "table_name": "test.excl_invalid_column",
          "columns": [
            {"name": "value", "type": "int4"}
          ],
          "exclusions": [
            {"name": "excl_invalid_column", "using": "GIST", "elements": [
              {"column": "missing_col", "op_class": "int4_ops", "with": "="}
            ]}
          ]
        }'::jsonb);$sql$,
        '%exclusion column not found in table%',
        'unknown column in exclusion is rejected');

    ---------------------------------------------------------------------------
    -- 7. Empty elements array
    ---------------------------------------------------------------------------
    RETURN NEXT throws_like(
        $sql$SELECT app.create_table_from_spec('{
          "table_name": "test.excl_empty_elements",
          "columns": [
            {"name": "value", "type": "int4"}
          ],
          "exclusions": [
            {"name": "excl_empty", "using": "GIST", "elements": []}
          ]
        }'::jsonb);$sql$,
        '%exclusion elements must be a non-empty array%',
        'empty elements array is rejected');

    RETURN QUERY SELECT * FROM finish();
END;
$$;

\set ON_ERROR_STOP off
BEGIN;
SELECT * FROM app.test_create_table_exclusions();
ROLLBACK;

DROP FUNCTION app.test_create_table_exclusions();
