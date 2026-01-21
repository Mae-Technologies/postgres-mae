-- Enforces immutable columns and maintains audit timestamps.
-- Assumptions:
--   - Table has columns: id, sys_client, created_at, updated_at, created_by, updated_by.
-- Behavior:
--   - INSERT: updated_at is set to now() (created_at default applies).
--   - UPDATE: updated_at is set to now().
--   - UPDATE: id, sys_client, created_at, created_by are immutable (cannot change).
-- WARN: we don't want to drop then create, internal app data_definitions rely on it, see impl in create_table_acl function
--
CREATE OR REPLACE FUNCTION mae._audit_enforce_timestamps_and_immutables ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        -- Always stamp updated_at at insert time (created_at already has a DEFAULT).
        NEW.updated_at := now();
        NEW.updated_by := NEW.created_by;
        RETURN NEW;
    END IF;
    IF TG_OP = 'UPDATE' THEN
        -- Immutable identifiers / ownership fields.
        IF NEW.id IS DISTINCT FROM OLD.id THEN
            RAISE EXCEPTION 'id is immutable';
        END IF;
        IF NEW.sys_client IS DISTINCT FROM OLD.sys_client THEN
            RAISE EXCEPTION 'sys_client is immutable';
        END IF;
        IF NEW.created_at IS DISTINCT FROM OLD.created_at THEN
            RAISE EXCEPTION 'created_at is immutable';
        END IF;
        IF NEW.created_by IS DISTINCT FROM OLD.created_by THEN
            RAISE EXCEPTION 'created_by is immutable';
        END IF;
        -- updated_by needs to be updated at each update
        IF NEW.updated_by IS NULL THEN
            RAISE EXCEPTION 'updated_by must be updated';
        END IF;
        -- Always bump updated_at on any update.
        NEW.updated_at := now();
        RETURN NEW;
    END IF;
    -- Defensive fallback (should not be reached for INSERT/UPDATE triggers).
    RETURN NEW;
END;
$$;

