DO $$
DECLARE
  public_oid oid;
  app_oid    oid;
BEGIN
  -- Ensure target schema exists (no-op if already present)
  EXECUTE 'CREATE SCHEMA IF NOT EXISTS app';

  -- Does app.status already exist?
  SELECT t.oid
  INTO app_oid
  FROM pg_type t
  JOIN pg_namespace n ON n.oid = t.typnamespace
  WHERE t.typname = 'status' AND n.nspname = 'app';

  IF app_oid IS NOT NULL THEN
    -- Already moved/created in app; nothing to do.
    RETURN;
  END IF;

  -- Does public.status exist?
  SELECT t.oid
  INTO public_oid
  FROM pg_type t
  JOIN pg_namespace n ON n.oid = t.typnamespace
  WHERE t.typname = 'status' AND n.nspname = 'public';

  IF public_oid IS NULL THEN
    -- Neither exists; create it in app.
    CREATE TYPE app.status AS ENUM ('incomplete', 'active', 'deleted', 'archived');
    RETURN;
  END IF;

  -- Move public.status -> app.status (preserves OID and all dependencies)
  EXECUTE 'ALTER TYPE public.status SET SCHEMA app';
END
$$;
