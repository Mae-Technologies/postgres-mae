CREATE OR REPLACE FUNCTION app.block_disallowed_grants()
RETURNS event_trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_user text := current_user;
BEGIN
  IF v_user IN ('app_owner', 'postgres') THEN
    RETURN;
  END IF;

  -- Block privilege/role manipulation from non-admin roles.
  IF TG_TAG IN (
    'GRANT',
    'REVOKE',
    'ALTER DEFAULT PRIVILEGES'
  ) THEN
    RAISE EXCEPTION 'Privilege changes ("%") not allowed for role "%".', TG_TAG, v_user;
  END IF;
END;
$$;

DROP EVENT TRIGGER IF EXISTS trg_block_disallowed_grants;

CREATE EVENT TRIGGER trg_block_disallowed_grants
ON ddl_command_start
EXECUTE FUNCTION app.block_disallowed_grants();
