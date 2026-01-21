DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_owner') THEN
    CREATE ROLE app_owner NOLOGIN;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_user') THEN
    CREATE ROLE app_user NOLOGIN;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_migrator') THEN
    CREATE ROLE app_migrator NOLOGIN;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'table_creator') THEN
    CREATE ROLE table_creator NOLOGIN;
  END IF;

  -- Create schema owned by app_owner
  CREATE SCHEMA IF NOT EXISTS app AUTHORIZATION app_owner;

  -- Lock down public
  REVOKE CREATE ON SCHEMA public FROM PUBLIC;
  -- Only revoke from a role if you actually have that role; using app_migrator here for consistency
  REVOKE CREATE ON SCHEMA public FROM app_migrator;
  REVOKE CREATE ON SCHEMA public FROM table_creator;
  REVOKE CREATE ON SCHEMA public FROM app_user;
  REVOKE CREATE ON SCHEMA app FROM PUBLIC;

  -- Allow migrator / table creator to create in app schema
  GRANT USAGE, CREATE ON SCHEMA app TO app_owner;
  -- see block_disallowed_ddl function sql for details.
  GRANT USAGE, CREATE ON SCHEMA app TO app_migrator;
  GRANT USAGE, CREATE ON SCHEMA app TO table_creator;

  GRANT USAGE ON SCHEMA app TO app_user;
END
$$;
