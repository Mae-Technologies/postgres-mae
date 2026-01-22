DROP FUNCTION IF EXISTS app.parse_validate_table_name (text, boolean);

CREATE OR REPLACE FUNCTION app.parse_validate_table_name (p_table_name text, check_exists boolean DEFAULT TRUE)
    RETURNS TABLE (
        o_schema name,
        o_table name)
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog,
    test,
    app,
    mae
    AS $$
DECLARE
    parts text[];
BEGIN
    IF p_table_name IS NULL OR p_table_name = '' THEN
        RAISE EXCEPTION 'table_name must not be null or empty';
    END IF;
    parts := string_to_array(p_table_name, '.');
    IF array_length(parts, 1) <> 2 THEN
        RAISE EXCEPTION 'table_name must be exactly schema-qualified (one dot): %', p_table_name;
    END IF;
    o_schema := parts[1];
    o_table := parts[2];
    -- Optional: stricter identifier validation
    IF o_schema !~ '^[a-zA-Z_][a-zA-Z0-9_]*$' OR o_table !~ '^[a-zA-Z_][a-zA-Z0-9_]*$' THEN
        RAISE EXCEPTION 'invalid identifier format in %', p_table_name;
    END IF;
    IF o_schema NOT IN ('app', 'test') THEN
        RAISE EXCEPTION 'only schemas app and test are allowed, got: %', o_schema;
    END IF;
    -- Existence check only when requested
    IF check_exists THEN
        -- Option A: regclass cast(throws undefined_table)
        BEGIN
            PERFORM
                format('%I.%I', o_schema, o_table)::regclass;
        EXCEPTION
            WHEN undefined_table THEN
                RAISE EXCEPTION 'table "%"."%" does not exist', o_schema, o_table;
        END;
        -- -- Option B (non-throwing): IF to_regclass(...) IS NULL THEN ...
        -- IF to_regclass(format('%I.%I', o_schema, o_table)) IS NULL THEN
        --     RAISE EXCEPTION 'table "%"."%" does not exist', o_schema, o_table;
        -- END IF;
    END IF;
    -- Emit exactly one row
    RETURN NEXT;
END;

$$;

