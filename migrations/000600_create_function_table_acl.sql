DROP FUNCTION IF EXISTS app.apply_table_acl (text, text[], text[]);

CREATE FUNCTION app.apply_table_acl (p_table_name text, p_insertable_columns text[], p_updatable_columns text[])
    RETURNS VOID
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalogue, test, app, mae
    AS $$
DECLARE
    v_schema name;
    v_table name;
    v_regclass regclass;
    owner_role text := 'app_owner';
    user_role text := 'app_user';
    default_insertable text[] := ARRAY['sys_client', 'status', 'comment', 'tags', 'sys_detail', 'created_by', 'updated_by'];
    default_updatable text[] := ARRAY['status', 'comment', 'tags', 'sys_detail', 'updated_by'];
    final_insertable text[];
    final_updatable text[];
    insert_list text;
    update_list text;
    v_seq_name text;
BEGIN
    -- Qualify the table into the dedicated schema.
    -- QUALIFYING SCHEMA <-> TABLE
    SELECT
        o_schema,
        o_table INTO v_schema,
        v_table
    FROM
        app.parse_validate_table_name (p_table_name);
    v_regclass := format('%I.%I', v_schema, v_table)::regclass;
    -- SCHEMA <-> TABLE QUALIFIED
    final_insertable := COALESCE(p_insertable_columns, ARRAY[]::text[]) || default_insertable;
    final_updatable := COALESCE(p_updatable_columns, ARRAY[]::text[]) || default_updatable;
    SELECT
        array_agg(DISTINCT c ORDER BY c) INTO final_insertable
    FROM
        unnest(final_insertable) AS t (c);
    SELECT
        array_agg(DISTINCT c ORDER BY c) INTO final_updatable
    FROM
        unnest(final_updatable) AS t (c);
    -- Ensure table ownership.
    EXECUTE format('ALTER TABLE %s OWNER TO %I;', v_regclass, owner_role);
    -- Remove default/public privileges and any existing grants to app_user.
    EXECUTE format('REVOKE ALL ON TABLE %s FROM PUBLIC;', v_regclass);
    EXECUTE format('REVOKE ALL ON TABLE %s FROM %I;', v_regclass, user_role);
    -- Read access (all columns).
    EXECUTE format('GRANT SELECT ON TABLE %s TO %I;', v_regclass, user_role);
    -- Grant DELETE so the _block_delete trigger can fire with a helpful error.
    -- The trigger always raises an exception, so no row is ever deleted.
    -- Without this grant, PostgreSQL rejects DELETE before the trigger runs,
    -- giving only a generic "permission denied" message.
    EXECUTE format('GRANT DELETE ON TABLE %s TO %I;', v_regclass, user_role);
    SELECT
        string_agg(format('%I', c), ', ') INTO insert_list
    FROM
        unnest(final_insertable) AS t (c);
    SELECT
        string_agg(format('%I', c), ', ') INTO update_list
    FROM
        unnest(final_updatable) AS t (c);
    EXECUTE format('GRANT INSERT (%s) ON TABLE %s TO %I;', insert_list, v_regclass, user_role);
    EXECUTE format('GRANT UPDATE (%s) ON TABLE %s TO %I;', update_list, v_regclass, user_role);
    -- Grant identity/serial sequence privileges safely.
    -- Works for GENERATED AS IDENTITY and serial.
    SELECT
        pg_get_serial_sequence(v_regclass::text, 'id') INTO v_seq_name;
    IF v_seq_name IS NOT NULL THEN
        EXECUTE format('GRANT USAGE, SELECT ON SEQUENCE %s TO %I;', v_seq_name, user_role);
    END IF;
    -- Attach delete-block trigger (idempotent; safe if 001300 not yet applied).
    BEGIN
        PERFORM app.apply_delete_guard(format('%I.%I', v_schema, v_table));
    EXCEPTION
        WHEN undefined_function THEN
            NULL; -- 001300 not yet applied; trigger will be attached on next ACL re-run
    END;
    ---------------------------------------------------------------------------
    -- Update immutable-column policy to match the applied ACL
    --
    -- Immutable definition:
    --   - Insertable but NOT updatable (insert-only), plus forced default immutables.
    ---------------------------------------------------------------------------
    DECLARE immutable_cols text[] := ARRAY[]::text[];
    BEGIN
        -- immutable = final_insertable \ final_updatable
        SELECT
            COALESCE(array_agg(c ORDER BY c), ARRAY[]::text[]) INTO immutable_cols
        FROM ( SELECT DISTINCT
                c
            FROM
                unnest(final_insertable) AS t (c)
            EXCEPT
            SELECT DISTINCT
                c
            FROM
                unnest(final_updatable) AS t (c)) s;
        -- Force-include always-immutable defaults (your required list).
        immutable_cols := (
            SELECT
                array_agg(DISTINCT c ORDER BY c)
            FROM
                unnest(immutable_cols || ARRAY['id', 'sys_client', 'created_at', 'created_by', 'status', 'sys_detail', 'tags']) AS t (c));
        PERFORM
            -- WARN: we are passing a string of the varified schema-table pair because that is what the function requires
            app.upsert_table_column_policy (format('%I.%I', v_schema, v_table), immutable_cols);
    END;
END;
$$;

