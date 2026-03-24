DROP FUNCTION IF EXISTS app.alter_column_type (text, text, text);

CREATE FUNCTION app.alter_column_type (p_table text, p_column text, p_new_type text)
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalogue, test, app, mae
    AS $$
DECLARE
    v_schema name;
    v_table name;
    v_regclass regclass;
    v_type regtype;
    protected_cols text[] := ARRAY['id', 'sys_client', 'created_at', 'created_by', 'updated_at', 'updated_by', 'status', 'sys_detail', 'tags'];
    invoker_role text := SESSION_USER;
BEGIN
    -- Role gate: allow app_owner/postgres or approved migrator roles.
    IF NOT (
        invoker_role IN ('app_owner', 'postgres') OR
        pg_has_role(invoker_role, 'app_migrator', 'member') OR
        pg_has_role(invoker_role, 'table_creator', 'member') OR
        pg_has_role(invoker_role, 'db_migrator', 'member')
    ) THEN
        RAISE EXCEPTION 'alter_column_type not allowed. session_user=%', invoker_role
            USING ERRCODE = '42501';
    END IF;
    -- QUALIFYING SCHEMA <-> TABLE
    SELECT
        o_schema,
        o_table INTO v_schema,
        v_table
    FROM
        app.parse_validate_table_name (p_table);
    v_regclass := format('%I.%I', v_schema, v_table)::regclass;
    -- SCHEMA <-> TABLE QUALIFIED
    -- Validate column identifier.
    IF p_column IS NULL OR p_column !~ '^[a-zA-Z_][a-zA-Z0-9_]*$' THEN
        RAISE EXCEPTION 'invalid column name: %', p_column;
    END IF;
    -- Block protected columns.
    IF lower(p_column) = ANY (protected_cols) THEN
        RAISE EXCEPTION 'Protected column "%" cannot be altered via alter_column_type.', p_column;
    END IF;
    -- Ensure column exists on the target table.
    PERFORM
        1
    FROM
        pg_attribute
    WHERE
        attrelid = v_regclass
        AND attname = p_column
        AND NOT attisdropped;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'column "%" does not exist on table "%"', p_column, v_regclass::text;
    END IF;
    -- Resolve target type safely.
    v_type := to_regtype(p_new_type);
    IF v_type IS NULL THEN
        RAISE EXCEPTION 'unknown or invalid type: %', p_new_type;
    END IF;
    -- Perform the ALTER TABLE using identifier-quoting and explicit cast.
    EXECUTE format(
        'ALTER TABLE %s ALTER COLUMN %I TYPE %s USING (%I::%s)',
        v_regclass::text,
        p_column,
        p_new_type,
        p_column,
        p_new_type
    );
END;
$$;

ALTER FUNCTION app.alter_column_type (text, text, text) OWNER TO app_owner;

REVOKE ALL ON FUNCTION app.alter_column_type (text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.alter_column_type (text, text, text) TO db_migrator;
