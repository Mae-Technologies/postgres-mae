DROP FUNCTION IF EXISTS app.add_exclusions_from_spec (text, jsonb);

CREATE FUNCTION app.add_exclusions_from_spec (
    p_table_name text,
    p_exclusions jsonb
)
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, test, app, mae
    AS $$
DECLARE
    v_schema name;
    v_table name;
    v_regclass regclass;
    table_columns text[];

    ex jsonb;
    ex_name text;
    ex_using text;
    ex_elements jsonb;
    ex_elem jsonb;
    ex_column text;
    ex_op_class text;
    ex_with text;
    ex_where text;
    ex_sql text;
    ex_elem_sql text;
    ex_sep text;
BEGIN
    IF NOT pg_has_role(SESSION_USER, 'table_creator', 'member')
       AND NOT pg_has_role(SESSION_USER, 'app_migrator', 'member')
       AND SESSION_USER NOT IN ('app_owner', 'postgres') THEN
        RAISE EXCEPTION 'add_exclusions_from_spec may only be invoked by app_migrator or table_creator (or app_owner). session_user=%', SESSION_USER;
    END IF;

    IF p_exclusions IS NULL OR jsonb_typeof(p_exclusions) <> 'array' THEN
        RAISE EXCEPTION 'p_exclusions must be a JSON array';
    END IF;

    SELECT o_schema, o_table
    INTO v_schema, v_table
    FROM app.parse_validate_table_name(p_table_name, TRUE);

    v_regclass := format('%I.%I', v_schema, v_table)::regclass;

    SELECT COALESCE(array_agg(a.attname::text ORDER BY a.attname), ARRAY[]::text[])
    INTO table_columns
    FROM pg_attribute a
    WHERE a.attrelid = v_regclass
      AND a.attnum > 0
      AND NOT a.attisdropped;

    FOR ex IN
    SELECT value
    FROM jsonb_array_elements(p_exclusions) AS t (value)
    LOOP
        IF jsonb_typeof(ex) <> 'object' THEN
            RAISE EXCEPTION 'each item in p_exclusions must be an object';
        END IF;

        ex_name := ex ->> 'name';
        ex_using := ex ->> 'using';
        ex_elements := ex -> 'elements';
        ex_where := ex ->> 'where';

        IF ex_name IS NULL OR ex_using IS NULL OR ex_elements IS NULL THEN
            RAISE EXCEPTION 'each exclusion requires "name", "using", and "elements"';
        END IF;

        IF ex_name !~ '^[a-zA-Z_][a-zA-Z0-9_]*$' THEN
            RAISE EXCEPTION 'invalid exclusion name: %', ex_name;
        END IF;

        IF EXISTS (
            SELECT 1
            FROM pg_constraint c
            WHERE c.conrelid = v_regclass
              AND c.conname = ex_name
        ) THEN
            CONTINUE;
        END IF;

        IF upper(ex_using) NOT IN ('GIST', 'SPGIST') THEN
            RAISE EXCEPTION 'invalid exclusion using method: %', ex_using;
        END IF;

        IF jsonb_typeof(ex_elements) <> 'array' OR jsonb_array_length(ex_elements) = 0 THEN
            RAISE EXCEPTION 'exclusion elements must be a non-empty array';
        END IF;

        ex_elem_sql := '';
        ex_sep := '';

        FOR ex_elem IN
        SELECT value
        FROM jsonb_array_elements(ex_elements) AS t2 (value)
        LOOP
            IF jsonb_typeof(ex_elem) <> 'object' THEN
                RAISE EXCEPTION 'each exclusion element must be an object';
            END IF;

            ex_column := ex_elem ->> 'column';
            ex_op_class := ex_elem ->> 'op_class';
            ex_with := ex_elem ->> 'with';

            IF ex_column IS NULL OR ex_op_class IS NULL OR ex_with IS NULL THEN
                RAISE EXCEPTION 'each exclusion element requires "column", "op_class", and "with"';
            END IF;

            IF NOT ex_column = ANY(table_columns) THEN
                RAISE EXCEPTION 'exclusion column not found in table: %', ex_column;
            END IF;

            IF ex_op_class NOT IN (
                'int4_ops', 'range_ops', 'text_ops', 'bool_ops',
                'gist_int4_ops', 'gist_text_ops'
            ) THEN
                RAISE EXCEPTION 'invalid exclusion op_class: %', ex_op_class;
            END IF;

            IF ex_with NOT IN ('=','&&','<<','>>','-|-') THEN
                RAISE EXCEPTION 'invalid exclusion operator: %', ex_with;
            END IF;

            ex_elem_sql := ex_elem_sql || ex_sep || format('%I %s WITH %s', ex_column, ex_op_class, ex_with);
            ex_sep := ', ';
        END LOOP;

        ex_sql := format(
            'ALTER TABLE %s ADD CONSTRAINT %I EXCLUDE USING %s (%s',
            v_regclass::text,
            ex_name,
            upper(ex_using),
            ex_elem_sql
        );

        IF ex_where IS NOT NULL THEN
            IF ex_where !~ '^[a-zA-Z0-9_\. ''()<>!=]*$' THEN
                RAISE EXCEPTION 'invalid characters in exclusion WHERE predicate';
            END IF;
            ex_sql := ex_sql || format(') WHERE (%s)', ex_where);
        ELSE
            ex_sql := ex_sql || ')';
        END IF;

        EXECUTE ex_sql;
    END LOOP;
END;
$$;

ALTER FUNCTION app.add_exclusions_from_spec (text, jsonb) OWNER TO app_owner;

REVOKE ALL ON FUNCTION app.add_exclusions_from_spec (text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.add_exclusions_from_spec (text, jsonb) TO app_owner;
GRANT EXECUTE ON FUNCTION app.add_exclusions_from_spec (text, jsonb) TO app_migrator;
GRANT EXECUTE ON FUNCTION app.add_exclusions_from_spec (text, jsonb) TO table_creator;