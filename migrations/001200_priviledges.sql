-- DEFAULT -- REVOKE ALL
-- Lock down public
REVOKE ALL ON SCHEMA public FROM PUBLIC;

-- Only revoke from a role if you actually have that role; using app_migrator here for consistency
REVOKE ALL ON SCHEMA public FROM app_migrator;

REVOKE ALL ON SCHEMA public FROM table_creator;

REVOKE ALL ON SCHEMA public FROM app_user;

REVOKE ALL ON SCHEMA app FROM PUBLIC;

REVOKE ALL ON SCHEMA test FROM PUBLIC;

-- Allow migrator / table creator to create in app schema
GRANT USAGE, CREATE ON SCHEMA app TO app_owner;

GRANT USAGE, CREATE ON SCHEMA test TO app_owner;

-- see block_disallowed_ddl function sql for details.
GRANT USAGE, CREATE ON SCHEMA app TO app_migrator;

GRANT USAGE, CREATE ON SCHEMA test TO app_migrator;

-- see block_disallowed_ddl function sql for details.
GRANT USAGE, CREATE ON SCHEMA app TO table_creator;

GRANT USAGE, CREATE ON SCHEMA test TO table_creator;

-- almost nothing for the app_user
GRANT USAGE ON SCHEMA app TO app_user;

GRANT USAGE ON SCHEMA test TO app_user;

--- ADD EVERYING BACK IN
-- Lock down apply_table_acl; factory/ACL are schema-scoped to app.
REVOKE ALL ON FUNCTION app.apply_table_acl (TEXT, TEXT[], TEXT[]) FROM PUBLIC;

-- Only allow the factory callers to adjust ACLs (per your requirement).
GRANT EXECUTE ON FUNCTION app.apply_table_acl (TEXT, TEXT[], TEXT[]) TO app_owner;

GRANT EXECUTE ON FUNCTION app.apply_table_acl (TEXT, TEXT[], TEXT[]) TO app_migrator;

GRANT EXECUTE ON FUNCTION app.apply_table_acl (TEXT, TEXT[], TEXT[]) TO table_creator;

ALTER FUNCTION app.apply_table_acl (text, text[], text[]) OWNER TO app_owner;

-- Lock down execution of the factory function.
REVOKE ALL ON FUNCTION app.create_table_from_spec (jsonb) FROM PUBLIC;

-- Factory can be invoked only by migrator + app_owner.
GRANT EXECUTE ON FUNCTION app.create_table_from_spec (jsonb) TO app_owner;

GRANT EXECUTE ON FUNCTION app.create_table_from_spec (jsonb) TO app_migrator;

GRANT EXECUTE ON FUNCTION app.create_table_from_spec (jsonb) TO table_creator;

ALTER FUNCTION app.create_table_from_spec (jsonb) OWNER TO app_owner;

-- Lock down audit trigger function (trigger-only; not callable by PUBLIC).
REVOKE ALL ON FUNCTION mae._audit_enforce_timestamps_and_immutables () FROM PUBLIC;

GRANT EXECUTE ON FUNCTION mae._audit_enforce_timestamps_and_immutables () TO app_owner;

ALTER FUNCTION mae._audit_enforce_timestamps_and_immutables () OWNER TO app_owner;

-- Lock down audit trigger function (trigger-only; not callable by PUBLIC).
REVOKE ALL ON FUNCTION app.upsert_table_column_policy (text, text[]) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION app.upsert_table_column_policy (text, text[]) TO app_owner;

ALTER FUNCTION app.upsert_table_column_policy (text, text[]) OWNER TO app_owner;

-- Lock down the policy table; only app_owner should have direct access.
REVOKE ALL ON TABLE mae._table_column_policies FROM PUBLIC;

ALTER TABLE mae._table_column_policies OWNER TO app_owner;

-- ALTER TABLE ACCESS
REVOKE ALL ON FUNCTION app.add_column_from_spec (jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION app.drop_column (text, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION app.rename_column (text, text, text) FROM PUBLIC;

-- CAN ADD COLUMNS
ALTER FUNCTION app.add_column_from_spec (jsonb) OWNER TO app_owner;

GRANT EXECUTE ON FUNCTION app.add_column_from_spec (jsonb) TO app_migrator;

GRANT EXECUTE ON FUNCTION app.add_column_from_spec (jsonb) TO table_creator;

-- CAN DROP COLUMNS
ALTER FUNCTION app.drop_column (text, text) OWNER TO app_owner;

GRANT EXECUTE ON FUNCTION app.drop_column (text, text) TO app_migrator;

GRANT EXECUTE ON FUNCTION app.drop_column (text, text) TO table_creator;

-- CAN RENAME COLUMNES
ALTER FUNCTION app.rename_column (text, text, text) OWNER TO app_owner;

GRANT EXECUTE ON FUNCTION app.rename_column (text, text, text) TO app_migrator;

GRANT EXECUTE ON FUNCTION app.rename_column (text, text, text) TO table_creator;

