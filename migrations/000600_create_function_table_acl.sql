DROP FUNCTION IF EXISTS app.apply_table_acl (text, text[], text[], boolean);

CREATE FUNCTION app.apply_table_acl (
    p_table_name text, 
    p_insertable_columns text[], 
    p_updatable_columns text[],
    root_schema boolean DEFAULT false
)
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

    default_insertable text[] := ARRAY['status', 'comment', 'tags', 'sys_detail', 'created_by', 'updated_by'];
    default_updatable text[] := ARRAY['status', 'comment', 'tags', 'sys_detail', 'updated_by'];

    final_insertable text[];
    final_updatable text[];
    insert_list text;
    update_list text;
    v_seq_name text;
    immutable_cols text[] := ARRAY[]::text[];
BEGIN
    -- Qualify the table
    SELECT o_schema, o_table 
    INTO v_schema, v_table
    FROM app.parse_validate_table_name (p_table_name);

    v_regclass := format('%I.%I', v_schema, v_table)::regclass;

    -- Add sys_client to defaults only when it exists on the table
    IF NOT root_schema THEN
        default_insertable := ARRAY['sys_client'] || default_insertable;
    END IF;

    final_insertable := COALESCE(p_insertable_columns, ARRAY[]::text[]) || default_insertable;
    final_updatable := COALESCE(p_updatable_columns, ARRAY[]::text[]) || default_updatable;

    -- Deduplicate
    SELECT array_agg(DISTINCT c ORDER BY c) INTO final_insertable
    FROM unnest(final_insertable) AS t (c);

    SELECT array_agg(DISTINCT c ORDER BY c) INTO final_updatable
    FROM unnest(final_updatable) AS t (c);

    -- Ensure table ownership
    EXECUTE format('ALTER TABLE %s OWNER TO %I;', v_regclass, owner_role);

    -- Revoke previous privileges
    EXECUTE format('REVOKE ALL ON TABLE %s FROM PUBLIC;', v_regclass);
    EXECUTE format('REVOKE ALL ON TABLE %s FROM %I;', v_regclass, user_role);

    -- Basic grants
    EXECUTE format('GRANT SELECT ON TABLE %s TO %I;', v_regclass, user_role);
    EXECUTE format('GRANT DELETE ON TABLE %s TO %I;', v_regclass, user_role);

    -- Column-level INSERT / UPDATE grants
    SELECT string_agg(format('%I', c), ', ') INTO insert_list
    FROM unnest(final_insertable) AS t (c);

    SELECT string_agg(format('%I', c), ', ') INTO update_list
    FROM unnest(final_updatable) AS t (c);

    EXECUTE format('GRANT INSERT (%s) ON TABLE %s TO %I;', insert_list, v_regclass, user_role);
    EXECUTE format('GRANT UPDATE (%s) ON TABLE %s TO %I;', update_list, v_regclass, user_role);

    -- Sequence privileges for id
    SELECT pg_get_serial_sequence(v_regclass::text, 'id') INTO v_seq_name;
    IF v_seq_name IS NOT NULL THEN
        EXECUTE format('GRANT USAGE, SELECT ON SEQUENCE %s TO %I;', v_seq_name, user_role);
    END IF;

    -- Delete guard trigger
    BEGIN
        PERFORM app.apply_delete_guard(format('%I.%I', v_schema, v_table));
    EXCEPTION
        WHEN undefined_function THEN
            NULL; -- Will be attached later
    END;

---------------------------------------------------------------------------
    -- Update immutable-column policy
    ---------------------------------------------------------------------------
    -- immutable = insertable but not updatable
    SELECT COALESCE(array_agg(c ORDER BY c), ARRAY[]::text[]) INTO immutable_cols
    FROM (
        SELECT DISTINCT c FROM unnest(final_insertable) AS t (c)
        EXCEPT
        SELECT DISTINCT c FROM unnest(final_updatable) AS t (c)
    ) s;

    -- Always-immutable columns (sys_client only when NOT root_schema)
    immutable_cols := (
        SELECT array_agg(DISTINCT c ORDER BY c)
        FROM unnest(
            immutable_cols 
            || ARRAY['id', 'created_at', 'created_by', 'status', 'sys_detail', 'tags']
            || CASE WHEN NOT root_schema THEN ARRAY['sys_client'] ELSE ARRAY[]::text[] END
        ) AS t (c)
    );

    PERFORM app.upsert_table_column_policy(
        format('%I.%I', v_schema, v_table), 
        immutable_cols
    );

END;
$$;
