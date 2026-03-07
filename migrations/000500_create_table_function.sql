-- Creates a table from a validated JSONB spec and automatically applies default ACLs.
--
-- SECURITY MODEL:
--   - This function is SECURITY DEFINER and should be executable only by table_creator.
--   - It calls apply_table_acl which uses fixed roles ('app_owner' / 'app_user').
--
-- EXPECTED JSON SHAPE:
-- {
--   "table_name": "my_table",
--   "columns": [
--     { "name": "title", "type": "text", "nullable": false },
--     { "name": "priority", "type": "int4", "default": 0 }
--   ]
-- }
DROP FUNCTION IF EXISTS app.create_table_from_spec (jsonb);

CREATE FUNCTION app.create_table_from_spec (p_spec jsonb)
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalogue, test, app, mae
    AS $$
DECLARE
    v_schema name;
    v_table name;
    ---------------------------------------------------------------------------
    -- HACK: we're going to cheat here a bit. the casting into a regclass in the --QUALIFYING SCHEMA-- block automatically checks if it actually is a regclass -- which it isn't becuase the table actullay hasn't been built yet.
    -- so, we're going to call this var a string. but the time we get to the bottom of this function, it is a regclass; but no point in recasting it, we're done with the value.
    v_regclass_str text;
    v_regclass regclass;
    ---------------------------------------------------------------------------
    v_cols jsonb;
    -- DDL assembly
    v_sql text;
    -- Per-column fields
    c jsonb;
    c_name text;
    c_type_text text;
    c_type regtype;
    c_nullable boolean;
    c_unique boolean;
    c_has_default boolean;
    c_default jsonb;
    v_kind text;
    -- Rendered extra column definitions
    col_defs text := '';
    sep text := '';
    -- Columns from spec, used to auto-apply ACL.
    -- By default we treat all spec-defined columns as insertable+updatable.
    insertable_extras text[] := ARRAY[]::text[];
    updatable_extras text[] := ARRAY[]::text[];
BEGIN
    -- Allow any LOGIN role that is a member of table_creator or app_migrator.
    IF NOT pg_has_role(SESSION_USER, 'table_creator', 'member') AND NOT pg_has_role(SESSION_USER, 'app_migrator', 'member') AND SESSION_USER NOT IN ('app_owner', 'postgres') THEN
        RAISE EXCEPTION 'create_table_from_spec may only be invoked by app_migrator or table_creator (or app_owner). session_user=%', SESSION_USER;
    END IF;
    ---------------------------------------------------------------------------
    -- 1) Validate presence and type of required keys
    ---------------------------------------------------------------------------
    IF p_spec IS NULL THEN
        RAISE EXCEPTION 'spec must not be null';
    END IF;
    -- QUALIFYING SCHEMA <-> TABLE
    SELECT
        o_schema,
        o_table INTO v_schema,
        v_table
    FROM
        app.parse_validate_table_name (p_spec ->> 'table_name', FALSE);
    v_regclass_str := format('%I.%I', v_schema, v_table)::text;
    -- HACK:
    -- SCHEMA <-> TABLE QUALIFIED
    v_cols := p_spec -> 'columns';
    IF v_cols IS NULL OR jsonb_typeof(v_cols) <> 'array' THEN
        RAISE EXCEPTION 'spec.columns must be an array';
    END IF;
    ---------------------------------------------------------------------------
    -- 2) Build safe column definitions from JSON spec
    ---------------------------------------------------------------------------
    FOR c IN
    SELECT
        value
    FROM
        jsonb_array_elements(v_cols) AS t (value)
        LOOP
            IF jsonb_typeof(c) <> 'object' THEN
                RAISE EXCEPTION 'each item in spec.columns must be an object';
            END IF;
            c_name := c ->> 'name';
            c_type_text := c ->> 'type';
            IF c_name IS NULL OR c_type_text IS NULL THEN
                RAISE EXCEPTION 'each column requires "name" and "type"';
            END IF;
            IF c_name !~ '^[a-zA-Z_][a-zA-Z0-9_]*$' THEN
                RAISE EXCEPTION 'invalid column name: %', c_name;
            END IF;
            -- Resolve type via server parser to avoid injecting tokens into DDL.
            c_type := to_regtype(c_type_text);
            IF c_type IS NULL THEN
                RAISE EXCEPTION 'unknown or invalid type: %', c_type_text;
            END IF;
            c_nullable := COALESCE((c ->> 'nullable')::boolean, TRUE);
            c_unique := COALESCE((c ->> 'unique')::boolean, FALSE);
            c_has_default := c ? 'default';
            IF c_has_default THEN
                c_default := c -> 'default';
                v_kind := jsonb_typeof(c_default);
                -- Only allow JSON scalar defaults (no SQL expressions).
                IF v_kind NOT IN ('string', 'number', 'boolean', 'null') THEN
                    RAISE EXCEPTION 'default for column % must be a JSON scalar', c_name;
                END IF;
            END IF;
            -- Track spec columns for ACL auto-application.
            insertable_extras := insertable_extras || c_name;
            updatable_extras := updatable_extras || c_name;
            -- Emit "<name> <type> [NOT NULL] [DEFAULT literal] [UNIQUE]"
            col_defs := col_defs || sep || format('%I %s', c_name, c_type::text);
            IF NOT c_nullable THEN
                col_defs := col_defs || ' NOT NULL';
            END IF;
            IF c_has_default THEN
                IF jsonb_typeof(c_default) = 'null' THEN
                    col_defs := col_defs || ' DEFAULT NULL';
                ELSIF jsonb_typeof(c_default) = 'string' THEN
                    col_defs := col_defs || format(' DEFAULT %s', quote_literal(c_default #>> '{}'));
                ELSE
                    col_defs := col_defs || format(' DEFAULT %s', quote_literal(c_default::text));
                END IF;
            END IF;
            IF c_unique THEN
                col_defs := col_defs || ' UNIQUE';
            END IF;
            sep := ', ';
        END LOOP;
    ---------------------------------------------------------------------------
    -- 3) Create the table with standard columns + additional safe columns
    ---------------------------------------------------------------------------
    v_sql := format($fmt$ CREATE TABLE IF NOT EXISTS %s (id integer GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY, sys_client int NOT NULL, status app.status NOT NULL, %s %s comment text, tags jsonb NOT NULL DEFAULT '{}'::jsonb, sys_detail jsonb NOT NULL DEFAULT '{}'::jsonb, created_by int NOT NULL, updated_by int NOT NULL, created_at timestamptz NOT NULL DEFAULT now( ), updated_at timestamptz NOT NULL DEFAULT now( )
        );
    $fmt$,
    v_regclass_str,
    CASE WHEN length(col_defs) > 0 THEN
        col_defs || ', '
    ELSE
        ''
    END,
    '');
    EXECUTE v_sql;
    ---------------------------------------------------------------------------
    -- HACK: NOW WE CAN CAST OUR regclass!
    ---------------------------------------------------------------------------
    SELECT
        o_schema,
        o_table INTO v_schema,
        v_table
    FROM
        app.parse_validate_table_name (p_spec ->> 'table_name');
    v_regclass := format('%I.%I', v_schema, v_table)::regclass;
    ---------------------------------------------------------------------------
    -- 4) Attach audit trigger (id/sys_client/created_* immutable; updated_at maintained)
    ---------------------------------------------------------------------------
    EXECUTE format($fmt$ DO $do$
        BEGIN
            IF NOT EXISTS (
                SELECT
                    1
                FROM pg_trigger
                WHERE
                    tgname = %L
                    AND tgrelid = %L::regclass) THEN
            CREATE TRIGGER %I
                BEFORE INSERT OR UPDATE ON %I
                FOR EACH ROW
                EXECUTE FUNCTION mae._audit_enforce_timestamps_and_immutables ( );
END IF;
END $do$;
    $fmt$,
    v_regclass || '_audit_biu_trg',
    v_regclass,
    v_regclass || '_audit_biu_trg',
    v_regclass);
    ---------------------------------------------------------------------------
    -- 4.1)
    -- Immutable-column enforcement (derived from ACL allowlists)
    --
    -- Definition:
    --   - "Immutable" means: insertable but NOT updatable (insert-only).
    --   - We compute: immutable_cols = insertable_extras \ updatable_extras
    --
    -- This allows developers to control immutability by choosing which columns are
    -- included in the updatable allowlist when they (re)apply ACLs.
    -- NOTE: the acl already picks up the default fields and handles that, no need to changed it.
    ---------------------------------------------------------------------------
    DECLARE immutable_cols text[] := ARRAY[]::text[];
    BEGIN
        -- Compute set difference: insertable_extras minus updatable_extras
        SELECT
            COALESCE(array_agg(diff.col_name ORDER BY diff.col_name), ARRAY[]::text[]) INTO immutable_cols
        FROM ( SELECT DISTINCT
                ins.col_name
            FROM
                unnest(COALESCE(insertable_extras, ARRAY[]::text[])) AS ins (col_name)
            EXCEPT
            SELECT DISTINCT
                upd.col_name
            FROM
                unnest(COALESCE(updatable_extras, ARRAY[]::text[])) AS upd (col_name)) AS diff (col_name);
        -- Persist the policy for this table (idempotent).
        -- WARN: we're parsing from the varified string value's of the string back into 1 string becuase the function takes a string.
        PERFORM
            app.upsert_table_column_policy (format('%I.%I', v_schema, v_table), immutable_cols);
        -- Attach the immutable enforcement trigger only if we have any immutables.
        IF array_length(immutable_cols, 1) IS NOT NULL THEN
            EXECUTE format($fmt$ DO $do$
                BEGIN
                    IF NOT EXISTS (
                        SELECT
                            1
                        FROM pg_trigger
                        WHERE
                            tgname = %L
                            AND tgrelid = %L::regclass) THEN
                    CREATE TRIGGER %I
                        BEFORE UPDATE ON %I
                        FOR EACH ROW
                        EXECUTE FUNCTION mae._enforce_immutable_columns ( );
        END IF;
    END $do$;
        $fmt$,
        v_regclass || '_immutable_bu_trg',
        v_regclass,
        v_regclass || '_immutable_bu_trg',
        v_regclass);
END IF;
                END;
    -- EXECUTE format('ALTER TABLE app.%I OWNER TO app_owner;', v_table_name);
    ---------------------------------------------------------------------------
    -- 5) Auto-apply default ACLs (roles fixed inside apply_table_acl)
    --
    -- Developers may re-run apply_table_acl in a later migration to harden:
    --   - remove columns from update list (e.g., make some insert-only)
    --   - grant fewer insertable/updatable columns than the default behavior
    ---------------------------------------------------------------------------
    PERFORM
        -- WARN: we're parsing from the varified string value's of the string back into 1 string becuase the function takes a string.
        app.apply_table_acl (format('%I.%I', v_schema, v_table), insertable_extras, updatable_extras);
    END;
$$;

