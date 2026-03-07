DROP FUNCTION IF EXISTS app.upsert_table_column_policy (text, text[]);

CREATE FUNCTION app.upsert_table_column_policy (p_table_name text, p_immutable_columns text[])
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    -- WARN: we only need mae here -- validation to the table name is outsoursed to a function with the correct search_path and so with be the columns
    SET search_path = pg_catalogue, mae
    AS $$
DECLARE
    v_schema name;
    v_table name;
    v_regclass regclass;
BEGIN
    -- QUALIFYING SCHEMA <-> TABLE
    SELECT
        o_schema,
        o_table INTO v_schema,
        v_table
    FROM
        app.parse_validate_table_name (p_table_name);
    v_regclass := format('%I.%I', v_schema, v_table)::regclass;
    -- SCHEMA <-> TABLE QUALIFIED
    -- they may verywell be validated before coming into here, it requires authentication internal to the function to prevent abuse.
    INSERT INTO mae._table_column_policies (table_name, schema_name, immutable_columns)
        VALUES (v_table, v_schema, p_immutable_columns)
    ON CONFLICT (table_name)
        DO UPDATE SET
            immutable_columns = EXCLUDED.immutable_columns;
END;
$$;

