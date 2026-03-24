-- Ensure db_migrator has a writable schema and stable search_path
-- for SQLx _sqlx_migrations and service-level DDL.

DO $$
BEGIN
    -- Create app schema if it does not exist yet. Ownership stays with app_owner.
    IF NOT EXISTS (
        SELECT 1 FROM pg_namespace WHERE nspname = 'app'
    ) THEN
        CREATE SCHEMA app AUTHORIZATION app_owner;
    END IF;
END
$$;

DO $$
BEGIN
    -- Only apply grants/search_path tweaks when db_migrator exists.
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'db_migrator') THEN
        GRANT USAGE, CREATE ON SCHEMA app TO db_migrator;
        -- Ensure unqualified CREATE TABLE (e.g. _sqlx_migrations) lands in app schema.
        EXECUTE 'ALTER ROLE db_migrator SET search_path = app, public';
    END IF;
END
$$;
