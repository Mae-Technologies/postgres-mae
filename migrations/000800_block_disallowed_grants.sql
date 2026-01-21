DROP EVENT TRIGGER IF EXISTS trg_block_disallowed_grants;

DROP FUNCTION IF EXISTS mae._block_disallowed_grants ();

CREATE FUNCTION mae._block_disallowed_grants ()
    RETURNS event_trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_user text := CURRENT_USER;
    invoker_role text := SESSION_USER;
    -- original login
BEGIN
    IF v_user IN ('app_owner', 'postgres') THEN
        RETURN;
    END IF;
    -- Allow PGTap tests DDL for all role memberships (robust: uses object identity)
    IF pg_has_role(invoker_role, 'app_migrator', 'member') OR pg_has_role(invoker_role, 'app_user', 'member') OR pg_has_role(invoker_role, 'table_creator', 'member') AND EXISTS (
        SELECT
            1
        FROM
            pg_event_trigger_ddl_commands () c
        WHERE
        -- PGTap bookkeeping table (schema-qualified or not depending on search_path)
        c.object_identity LIKE '__tresults___' OR c.object_identity LIKE '__tcache___') THEN
        RETURN;
    END IF;
    -- Block privilege/role manipulation from non-admin roles.
    IF TG_TAG IN ('GRANT', 'REVOKE', 'ALTER DEFAULT PRIVILEGES') THEN
        RAISE EXCEPTION 'Privilege changes ("%") not allowed for role "%".app', TG_TAG, v_user;
    END IF;
END;
$$;

CREATE EVENT TRIGGER trg_block_disallowed_grants ON ddl_command_start
    EXECUTE FUNCTION mae._block_disallowed_grants ();

