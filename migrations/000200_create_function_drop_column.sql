DROP FUNCTION IF EXISTS app.drop_column (text, text);

CREATE FUNCTION app.drop_column (_tbl text, _col text)
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalogue, test, app, mae
    AS $$
DECLARE
    v_schema name;
    v_table name;
    v_regclass regclass;
    protected_cols text[] := ARRAY['id', 'sys_client', 'created_at', 'created_by', 'updated_at', 'updated_by', 'status', 'sys_detail', 'tags'];
    invoker_role text := SESSION_USER;
BEGIN
    IF NOT pg_has_role(invoker_role, 'table_creator', 'member') AND NOT pg_has_role(invoker_role, 'app_migrator', 'member') AND invoker_role NOT IN ('app_owner', 'postgres') THEN
        RAISE EXCEPTION 'drop_column not allowed. session_user=%', invoker_role
            USING ERRCODE = '42501';
        END IF;
        -- QUALIFYING SCHEMA <-> TABLE
        SELECT
            o_schema,
            o_table INTO v_schema,
            v_table
        FROM
            app.parse_validate_table_name (_tbl);
        v_regclass := format('%I.%I', v_schema, v_table)::regclass;
        -- SCHEMA <-> TABLE QUALIFIED
        IF _col IS NULL OR _col !~ '^[a-zA-Z_][a-zA-Z0-9_]*$' THEN
            RAISE EXCEPTION 'invalid column name: %', _col;
        END IF;
        IF lower(_col) = ANY (protected_cols) THEN
            RAISE EXCEPTION 'Protected column "%" cannot be dropped.', _col;
        END IF;
        EXECUTE format('ALTER TABLE %I DROP COLUMN %I', v_regclass, _col);
        -- Issue #19: sync table_migration policy — remove dropped column from
        -- immutable_columns so stale entries do not cause trigger errors.
        UPDATE mae._table_column_policies
        SET immutable_columns = array_remove(immutable_columns, _col)
        WHERE schema_name = v_schema AND table_name = v_table;
END;
$$;

DROP FUNCTION IF EXISTS app.rename_column (text, text, text);

CREATE FUNCTION app.rename_column (_tbl text, _col text, _new_col text)
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalogue, test, app, mae
    AS $$
DECLARE
    q text := current_query();
    protected_cols text[] := ARRAY['id', 'sys_client', 'created_at', 'created_by', 'updated_at', 'updated_by', 'status', 'sys_detail', 'tags'];
    invoker_role text := SESSION_USER;
    -- who called the function
    effective_role text := CURRENT_USER;
    -- function owner due to SECURITY DEFINER
    v_schema name;
    v_table name;
    v_regclass regclass;
BEGIN
    IF NOT (pg_has_role(invoker_role, 'app_migrator', 'member') OR pg_has_role(invoker_role, 'table_creator', 'member')) THEN
        RAISE EXCEPTION 'DDL "%" not allowed for role "%". Use approved migration functions. query: "%". (effective_role="%")', 'ALTER TABLE ... DROP COLUMN', invoker_role, q, effective_role
            USING ERRCODE = '42501';
            -- insufficient_privilege
        END IF;
        -- QUALIFYING SCHEMA <-> TABLE
        SELECT
            o_schema,
            o_table INTO v_schema,
            v_table
        FROM
            app.parse_validate_table_name (_tbl);
        v_regclass := format('%I.%I', v_schema, v_table)::regclass;
        -- SCHEMA <-> TABLE QUALIFIED
        -- Block protected columns (case-insensitive match).
        IF lower(_col) = ANY (protected_cols) THEN
            RAISE EXCEPTION 'Protected column "%" cannot be renamed.', _col
                USING ERRCODE = '2BP01';
                -- dependent_objects_still_exist (close enough) or pick custom
            END IF;
            -- Perform the DDL with identifier-quoting.
            EXECUTE format('ALTER TABLE %I RENAME COLUMN %I TO %I', v_regclass, _col, _new_col);
            RETURN;
END;
$$;

DROP FUNCTION IF EXISTS app.add_column_from_spec (jsonb);

CREATE FUNCTION app.add_column_from_spec (p_spec jsonb)
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalogue, test, app, mae
    AS $$
DECLARE
    v_schema name;
    v_table name;
    v_regclass regclass;
    c jsonb;
    c_name text;
    c_type_text text;
    c_type regtype;
    c_nullable boolean;
    c_unique boolean;
    c_has_default boolean;
    c_default jsonb;
    v_kind text;
    v_sql text;
    invoker_role text := SESSION_USER;
BEGIN
    -- Role gate: same as create_table_from_spec
    IF NOT pg_has_role(invoker_role, 'table_creator', 'member') AND NOT pg_has_role(invoker_role, 'app_migrator', 'member') AND invoker_role NOT IN ('app_owner', 'postgres') THEN
        RAISE EXCEPTION 'add_column_from_spec may only be invoked by app_migrator or table_creator (or app_owner). session_user=%', invoker_role
            USING ERRCODE = '42501';
        END IF;
        IF p_spec IS NULL THEN
            RAISE EXCEPTION 'spec must not be null';
        END IF;
        -- QUALIFYING SCHEMA <-> TABLE
        SELECT
            o_schema,
            o_table INTO v_schema,
            v_table
        FROM
            app.parse_validate_table_name (p_spec ->> 'table_name');
        v_regclass := format('%I.%I', v_schema, v_table)::regclass;
        -- SCHEMA <-> TABLE QUALIFIED
        c := p_spec -> 'column';
        IF c IS NULL OR jsonb_typeof(c) <> 'object' THEN
            RAISE EXCEPTION 'spec.column must be an object';
        END IF;
        c_name := c ->> 'name';
        c_type_text := c ->> 'type';
        IF c_name IS NULL OR c_type_text IS NULL THEN
            RAISE EXCEPTION 'spec.column requires "name" and "type"';
        END IF;
        IF c_name !~ '^[a-zA-Z_][a-zA-Z0-9_]*$' THEN
            RAISE EXCEPTION 'invalid column name: %', c_name;
        END IF;
        -- Resolve type safely
        c_type := to_regtype(c_type_text);
        IF c_type IS NULL THEN
            RAISE EXCEPTION 'unknown or invalid type: %', c_type_text;
        END IF;
        -- Disallow adding protected columns (reuse your list)
        IF lower(c_name) = ANY (ARRAY['id', 'sys_client', 'created_at', 'created_by', 'updated_at', 'updated_by', 'status', 'sys_detail', 'tags']::text[]) THEN
            RAISE EXCEPTION 'Protected column "%" cannot be added.', c_name;
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
        -- Build: ALTER TABLE app.<tbl> ADD COLUMN <col> <type> [NOT NULL] [DEFAULT ...] [UNIQUE]
        v_sql := format('ALTER TABLE %I ADD COLUMN %I %s', v_regclass, c_name, c_type::text);
        IF NOT c_nullable THEN
            v_sql := v_sql || ' NOT NULL';
        END IF;
        IF c_has_default THEN
            IF jsonb_typeof(c_default) = 'null' THEN
                v_sql := v_sql || ' DEFAULT NULL';
            ELSIF jsonb_typeof(c_default) = 'string' THEN
                v_sql := v_sql || format(' DEFAULT %s', quote_literal(c_default #>> '{}'));
            ELSE
                v_sql := v_sql || format(' DEFAULT %s', quote_literal(c_default::text));
            END IF;
        END IF;
        IF c_unique THEN
            v_sql := v_sql || ' UNIQUE';
        END IF;
        EXECUTE v_sql;
        -- Update ACL/policy: by default, new spec column is insertable+updatable.
        -- WARN: we're not passing a regclass, we're passing a string becuase that is what this function expects
        -- NOTE: running v_regclass::text JUST returns the table, not the schema...
        PERFORM
            app.apply_table_acl (format('%I.%I', v_schema, v_table), ARRAY[c_name], ARRAY[c_name]);
END;
$$;

