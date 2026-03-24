-- Create a SECURITY DEFINER helper for safe column type changes.
--
-- This allows less-privileged roles (e.g. db_migrator) to request a
-- column type change while the DDL itself executes as app_owner.

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_proc
        WHERE proname = 'alter_column_type'
          AND pronamespace = 'app'::regnamespace
          AND proargtypes = ARRAY['text'::regtype,'text'::regtype,'text'::regtype]::oid[]
    ) THEN
        DROP FUNCTION app.alter_column_type(text, text, text);
    END IF;
END
$$;

CREATE FUNCTION app.alter_column_type(p_table text, p_column text, p_new_type text)
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, app, mae
AS $$
DECLARE
    v_schema   name;
    v_table    name;
    v_regclass regclass;
    v_type     regtype;
BEGIN
    -- Validate and qualify table name (app.parse_validate_table_name enforces
    -- schema = app/test and identifier rules).
    SELECT o_schema, o_table INTO v_schema, v_table
    FROM app.parse_validate_table_name(p_table, TRUE);

    v_regclass := format('%I.%I', v_schema, v_table)::regclass;

    -- Validate column identifier.
    IF p_column IS NULL OR p_column !~ '^[a-zA-Z_][a-zA-Z0-9_]*$' THEN
        RAISE EXCEPTION 'invalid column name: %', p_column;
    END IF;

    -- Ensure column exists on the target table.
    PERFORM 1
    FROM pg_attribute
    WHERE attrelid = v_regclass
      AND attname  = p_column
      AND NOT attisdropped;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'column "%" does not exist on table "%"', p_column, v_regclass::text;
    END IF;

    -- Resolve target type via parser (to_regtype) to avoid injection.
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

ALTER FUNCTION app.alter_column_type(text, text, text) OWNER TO app_owner;

REVOKE ALL ON FUNCTION app.alter_column_type(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.alter_column_type(text, text, text) TO db_migrator;
