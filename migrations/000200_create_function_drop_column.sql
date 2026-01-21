DROP FUNCTION IF EXISTS app.drop_column (text, text);

CREATE FUNCTION app.drop_column (_tbl text, _col text)
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = app
    AS $$
DECLARE
    protected_cols text[] := ARRAY['id', 'sys_client', 'created_at', 'created_by', 'updated_at', 'updated_by', 'status', 'sys_detail', 'tags'];
    invoker_role text := SESSION_USER;
BEGIN
    IF NOT pg_has_role(invoker_role, 'table_creator', 'member') AND NOT pg_has_role(invoker_role, 'app_migrator', 'member') AND invoker_role NOT IN ('app_owner', 'postgres') THEN
        RAISE EXCEPTION 'drop_column not allowed. session_user=%', invoker_role
            USING ERRCODE = '42501';
        END IF;
        IF _tbl IS NULL OR _tbl !~ '^[a-zA-Z_][a-zA-Z0-9_]*$' THEN
            RAISE EXCEPTION 'invalid table name: %', _tbl;
        END IF;
        IF _col IS NULL OR _col !~ '^[a-zA-Z_][a-zA-Z0-9_]*$' THEN
            RAISE EXCEPTION 'invalid column name: %', _col;
        END IF;
        IF lower(_col) = ANY (protected_cols) THEN
            RAISE EXCEPTION 'Protected column "%" cannot be dropped.', _col;
        END IF;
        EXECUTE format('ALTER TABLE app.%I DROP COLUMN %I', _tbl, _col);
        -- Optional: re-apply ACL if your apply_table_acl expects updated allowlists
        -- (You likely have migrations controlling this, so no-op by default.)
END;
$$;

DROP FUNCTION IF EXISTS app.rename_column (text, text, text);

CREATE FUNCTION app.rename_column (_tbl text, _col text, _new_col text)
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $$
DECLARE
    q text := current_query();
    protected_cols text[] := ARRAY['id', 'sys_client', 'created_at', 'created_by', 'updated_at', 'updated_by', 'status', 'sys_detail', 'tags'];
    invoker_role text := SESSION_USER;
    -- who called the function
    effective_role text := CURRENT_USER;
    -- function owner due to SECURITY DEFINER
BEGIN
    -- Allow only a specific invoker role (or membership) to run this DDL wrapper.
    -- Adjust 'app_ddl' to your actual migrator/runner role.
    IF NOT (pg_has_role(invoker_role, 'app_migrator', 'member') OR pg_has_role(invoker_role, 'table_creator', 'member')) THEN
        RAISE EXCEPTION 'DDL "%" not allowed for role "%". Use approved migration functions. query: "%". (effective_role="%")', 'ALTER TABLE ... DROP COLUMN', invoker_role, q, effective_role
            USING ERRCODE = '42501';
            -- insufficient_privilege
        END IF;
        -- Block protected columns (case-insensitive match).
        IF lower(_col) = ANY (protected_cols) THEN
            RAISE EXCEPTION 'Protected column "%" cannot be renamed.', _col
                USING ERRCODE = '2BP01';
                -- dependent_objects_still_exist (close enough) or pick custom
            END IF;
            -- Perform the DDL with identifier-quoting.
            EXECUTE format('ALTER TABLE app.%I RENAME COLUMN %I TO %I', _tbl, _col, _new_col);
END;
$$;

DROP FUNCTION IF EXISTS app.add_column_from_spec (jsonb);

CREATE FUNCTION app.add_column_from_spec (p_spec jsonb)
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = app
    AS $$
DECLARE
    v_table_name text;
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
        v_table_name := p_spec ->> 'table_name';
        IF v_table_name IS NULL OR length(v_table_name) = 0 THEN
            RAISE EXCEPTION 'spec.table_name is required';
        END IF;
        IF v_table_name !~ '^[a-zA-Z_][a-zA-Z0-9_]*$' THEN
            RAISE EXCEPTION 'invalid table_name: %', v_table_name;
        END IF;
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
        v_sql := format('ALTER TABLE app.%I ADD COLUMN %I %s', v_table_name, c_name, c_type::text);
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
        PERFORM
            app.apply_table_acl (v_table_name, ARRAY[c_name], ARRAY[c_name]);
END;
$$;

