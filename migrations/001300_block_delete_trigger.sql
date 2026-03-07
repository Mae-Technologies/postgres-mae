-- Migration 001300: Block direct DELETE for app_user
--
-- Carter's decision (issue #10):
--   app_user must NOT have DELETE privileges.
--   When DELETE is attempted, a clear error must tell the developer to
--   set status to 'deleted' or 'archived' instead.

-- ── 1. Trigger function ──────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION mae._block_delete ()
    RETURNS trigger
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $$
BEGIN
    RAISE EXCEPTION 'Direct DELETE is not permitted. To remove a record, set its status to ''deleted'' or ''archived'' instead.'
        USING ERRCODE = '42501';
END;
$$;

ALTER FUNCTION mae._block_delete () OWNER TO app_owner;

REVOKE ALL ON FUNCTION mae._block_delete () FROM PUBLIC;

GRANT EXECUTE ON FUNCTION mae._block_delete () TO app_owner;

-- ── 2. Helper: app.apply_delete_guard(table_name text) ──────────────────────

DROP FUNCTION IF EXISTS app.apply_delete_guard (text);

CREATE FUNCTION app.apply_delete_guard (p_table_name text)
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalogue, test, app, mae
    AS $$
DECLARE
    v_schema name;
    v_table  name;
    v_regclass regclass;
    v_trig_name text;
BEGIN
    SELECT o_schema, o_table INTO v_schema, v_table
    FROM app.parse_validate_table_name (p_table_name);

    v_regclass  := format('%I.%I', v_schema, v_table)::regclass;
    v_trig_name := v_regclass::text || '_block_delete_trg';

    EXECUTE format($fmt$
        DO $do$
        BEGIN
            IF NOT EXISTS (
                SELECT 1 FROM pg_trigger
                WHERE tgname = %L AND tgrelid = %L::regclass
            ) THEN
                CREATE TRIGGER %I
                    BEFORE DELETE ON %s
                    FOR EACH ROW
                    EXECUTE FUNCTION mae._block_delete();
            END IF;
        END $do$;
    $fmt$,
        v_trig_name,
        v_regclass,
        v_trig_name,
        v_regclass);
END;
$$;

ALTER FUNCTION app.apply_delete_guard (text) OWNER TO app_owner;

REVOKE ALL ON FUNCTION app.apply_delete_guard (text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION app.apply_delete_guard (text) TO app_owner;
GRANT EXECUTE ON FUNCTION app.apply_delete_guard (text) TO app_migrator;
GRANT EXECUTE ON FUNCTION app.apply_delete_guard (text) TO table_creator;
