-- Blocks table/sequence creation unless the executing role is allowed.
-- Install this in the "admin up-to-05" phase (superuser/admin connection).
DROP EVENT TRIGGER IF EXISTS trg_block_disallowed_ddl;

DROP FUNCTION IF EXISTS mae._block_disallowed_ddl ();

CREATE FUNCTION mae._block_disallowed_ddl ()
    RETURNS event_trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    effective_role text := CURRENT_USER;
    -- definer/effective
    invoker_role text := SESSION_USER;
    -- original login
    q text := current_query();
    protected_cols text[] := ARRAY['id', 'sys_client', 'created_at', 'created_by', 'updated_at', 'updated_by', 'status', 'sys_detail', 'tags'];
    col text;
BEGIN
    -- Allow if the effective role is privileged (SECURITY DEFINER => app_owner)
    IF effective_role IN ('app_owner', 'postgres') THEN
        RETURN;
    END IF;
    -- Allow SQLx bookkeeping DDL for any recognised migrator role (robust: uses object identity).
    -- app_migrator: internal mae migrations.
    -- db_migrator:  service-level role used by ru_api_service and similar consumers.
    --               db_migrator is intentionally NOT a member of app_migrator (separate role hierarchy),
    --               so it must be listed explicitly here.
    IF (pg_has_role(invoker_role, 'app_migrator', 'member') OR pg_has_role(invoker_role, 'db_migrator', 'member')) AND TG_TAG IN ('CREATE TABLE', 'ALTER TABLE', 'CREATE INDEX') AND EXISTS (
        SELECT
            1
        FROM
            pg_event_trigger_ddl_commands () c
        WHERE
        -- SQLx bookkeeping table (schema-qualified or not depending on search_path)
        c.object_identity LIKE 'test._sqlx_migrations%' OR c.object_identity LIKE 'app._sqlx_migrations%' OR c.object_identity LIKE '_sqlx_migrations%') THEN
        RETURN;
    END IF;
    -- Allow PGTap tests DDL for all role memberships (robust: uses object identity)
    IF TG_TAG IN ('CREATE TABLE', 'ALTER TABLE', 'CREATE INDEX', 'CREATE TEMP TABLE', 'CREATE TEMP SEQUENCE', 'CREATE UNIQUE INDEX') AND EXISTS (
        SELECT
            1
        FROM
            pg_event_trigger_ddl_commands () c
        WHERE
        -- SQLx bookkeeping table (schema-qualified or not depending on search_path)
        c.object_identity LIKE '%_tresults__%' OR c.object_identity LIKE '%_tcache__%') THEN
        RETURN;
    END IF;
    -- NOTE: anything under this line is pretty well redundant. the create_table_function_acl() makes the app_owner the owner of the table when it is created, there is a permission denied from SQL before it ever gets to here.
    -- Block direct CREATE/DROP for non-privileged effective roles
    IF TG_TAG IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO') THEN
        RAISE EXCEPTION 'DDL "%": not allowed for role "%". query: "%". Use create_table_from_spec/apply_table_acl.', TG_TAG, invoker_role, q;
    END IF;
    -- Block direct CREATE/DROP for non-privileged effective roles
    IF TG_TAG IN ('DROP TABLE', 'DROP SEQUENCE') THEN
        RAISE EXCEPTION 'DDL "%": not allowed for role "%". query: "%". DROPPING DATA DEFINITIONS IS NOT ALLOWED.', TG_TAG, invoker_role, q;
    END IF;

    -- Handle ALTER TABLE separately
    IF TG_TAG = 'ALTER TABLE' THEN
        RAISE EXCEPTION 'DDL "%": not allowed for role "%". query: "%". Altering Tables use drop_column/rename_column.', TG_TAG, invoker_role, q;
        -- Optional: if you only care about app schema, gate on object identity instead of regex.
        -- If you keep the regex, do the protected column checks BEFORE raising.
        IF q ~* '\malter\s+table\s+app\.' THEN
            -- protected column checks here (drop/rename)
            FOREACH col IN ARRAY protected_cols LOOP
                IF q ~* format('\mdrop\s+column\s+(if\s+exists\s+)?%I\b', col) THEN
                    RAISE EXCEPTION 'DDL blocked: cannot DROP protected column "%" on app tables', col;
                END IF;
            END LOOP;
            FOREACH col IN ARRAY protected_cols LOOP
                IF q ~* format('\mrename\s+column\s+%I\s+to\b', col) THEN
                    RAISE EXCEPTION 'DDL blocked: cannot RENAME protected column "%" on app tables', col;
                END IF;
            END LOOP;
        END IF;
        -- Then block any ALTER TABLE regardless (since you want DDL via elevated functions)
        RAISE EXCEPTION 'DDL "%": not allowed for role "%". query: "%". Use elevated functions.', TG_TAG, invoker_role, q;
    END IF;
END;
$$;

CREATE EVENT TRIGGER trg_block_disallowed_ddl ON ddl_command_end
    EXECUTE FUNCTION mae._block_disallowed_ddl ();
