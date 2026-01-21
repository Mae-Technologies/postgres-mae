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
REVOKE ALL ON FUNCTION app.audit_enforce_timestamps_and_immutables () FROM PUBLIC;

GRANT EXECUTE ON FUNCTION app.audit_enforce_timestamps_and_immutables () TO app_owner;

ALTER FUNCTION app.audit_enforce_timestamps_and_immutables () OWNER TO app_owner;

-- Lock down audit trigger function (trigger-only; not callable by PUBLIC).
REVOKE ALL ON FUNCTION app.upsert_table_column_policy (text, text[]) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION app.upsert_table_column_policy (text, text[]) TO app_owner;

ALTER FUNCTION app.upsert_table_column_policy (text, text[]) OWNER TO app_owner;

-- Lock down the policy table; only app_owner should have direct access.
REVOKE ALL ON TABLE app.table_column_policies FROM PUBLIC;

ALTER TABLE app.table_column_policies OWNER TO app_owner;

-- Lock down the drop column function
ALTER FUNCTION app.drop_column (text, text) OWNER TO app_owner;

GRANT EXECUTE ON FUNCTION app.drop_column (text, text) TO app_migrator;

GRANT EXECUTE ON FUNCTION app.drop_column (text, text) TO table_creator;

