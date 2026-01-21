DROP FUNCTION IF EXISTS app.upsert_table_column_policy (text, text[]);

CREATE FUNCTION app.upsert_table_column_policy (p_table_name text, p_immutable_columns text[])
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = app, public
    AS $$
BEGIN
    INSERT INTO app.table_column_policies (table_name, immutable_columns)
        VALUES (p_table_name, p_immutable_columns)
    ON CONFLICT (table_name)
        DO UPDATE SET
            immutable_columns = EXCLUDED.immutable_columns;
END;
$$;

