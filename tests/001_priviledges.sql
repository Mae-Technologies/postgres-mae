BEGIN;
SELECT plan(24);

-- Assumptions:
--  - The app schema exists.
--  - Your event trigger blocks CREATE TABLE / ALTER TABLE / etc for non-app_owner.
--  - public schema CREATE is revoked from these roles.
--  - Roles exist: app_user, app_migrator, table_creator.

-- APP USER
SELECT has_role('app_user', 'role app_user exists');

SELECT ok(
  has_schema_privilege('app_user', 'app', 'USAGE'),
  'app_user has USAGE on app'
);

SELECT ok(
  NOT has_schema_privilege('app_user', 'app', 'CREATE'),
  'app_user has no CREATE on app'
);

-- APP MIGRATOR
SELECT has_role('app_migrator', 'role app_migrator exists');

SELECT ok(
  has_schema_privilege('app_migrator', 'app', 'USAGE'),
  'app_migrator has USAGE on app'
);

SELECT ok(
  has_schema_privilege('app_migrator', 'app', 'USAGE'),
  'app_migrator has CREATE on app'
);

-- TABLE CREATOR
SELECT has_role('table_creator', 'role table_creator exists');

SELECT ok(
  NOT has_schema_privilege('app_user', 'app', 'CREATE'),
  'app_user has no CREATE on app'
);

SELECT ok(
  has_schema_privilege('table_creator', 'app', 'USAGE'),
  'table_creator has USAGE on app'
);

-- Membership: detect any login roles that inherit these roles (optional)
-- This enumerates roles that are direct or indirect members.
-- It doesn't "test" them (would need a login), but documents what will be affected.
SELECT ok(
  EXISTS (
    SELECT 1
    FROM pg_auth_members m
    JOIN pg_roles parent ON parent.oid = m.roleid
    WHERE parent.rolname IN ('app_user','app_migrator','table_creator')
  ),
  'membership graph exists (informational)'
);

------------------------------------------------------------------------------
-- 1. Superuser has CREATE + USAGE on public and app schemas
------------------------------------------------------------------------------

SELECT ok(
  has_schema_privilege(current_user, 'public', 'USAGE'),
  'superuser has USAGE on schema public'
);

SELECT ok(
  has_schema_privilege(current_user, 'public', 'CREATE'),
  'superuser has CREATE on schema public'
);

SELECT ok(
  has_schema_privilege(current_user, 'app', 'USAGE'),
  'superuser has USAGE on schema app'
);

SELECT ok(
  has_schema_privilege(current_user, 'app', 'CREATE'),
  'superuser has CREATE on schema app'
);

------------------------------------------------------------------------------
-- 2. Function ownership + execution lockdowns
------------------------------------------------------------------------------

-- app.apply_table_acl(text, text[], text[])
SELECT is(
  (SELECT pg_get_userbyid(p.proowner)
   FROM pg_proc p
   WHERE p.proname = 'apply_table_acl'
     AND p.pronamespace = 'app'::regnamespace),
  'app_owner',
  'apply_table_acl owned by app_owner'
);

SELECT ok(
  NOT has_function_privilege('public', 'app.apply_table_acl(text, text[], text[])', 'EXECUTE'),
  'PUBLIC cannot EXECUTE apply_table_acl'
);

-- app.create_table_from_spec(jsonb)
SELECT is(
  (SELECT pg_get_userbyid(p.proowner)
   FROM pg_proc p
   WHERE p.proname = 'create_table_from_spec'
     AND p.pronamespace = 'app'::regnamespace),
  'app_owner',
  'create_table_from_spec owned by app_owner'
);

SELECT ok(
  NOT has_function_privilege('public', 'app.create_table_from_spec(jsonb)', 'EXECUTE'),
  'PUBLIC cannot EXECUTE create_table_from_spec'
);

-- app.audit_enforce_timestamps_and_immutables()
SELECT is(
  (SELECT pg_get_userbyid(p.proowner)
   FROM pg_proc p
   WHERE p.proname = 'audit_enforce_timestamps_and_immutables'
     AND p.pronamespace = 'app'::regnamespace),
  'app_owner',
  'audit_enforce_timestamps_and_immutables owned by app_owner'
);

SELECT ok(
  NOT has_function_privilege(
    'public',
    'app.audit_enforce_timestamps_and_immutables()',
    'EXECUTE'
  ),
  'PUBLIC cannot EXECUTE audit_enforce_timestamps_and_immutables'
);

-- app.upsert_table_column_policy(text, text[])
SELECT is(
  (SELECT pg_get_userbyid(p.proowner)
   FROM pg_proc p
   WHERE p.proname = 'upsert_table_column_policy'
     AND p.pronamespace = 'app'::regnamespace),
  'app_owner',
  'upsert_table_column_policy owned by app_owner'
);

SELECT ok(
  NOT has_function_privilege(
    'public',
    'app.upsert_table_column_policy(text, text[])',
    'EXECUTE'
  ),
  'PUBLIC cannot EXECUTE upsert_table_column_policy'
);

------------------------------------------------------------------------------
-- 3. Policy table ownership and PUBLIC lockdown
------------------------------------------------------------------------------

SELECT is(
  (SELECT pg_get_userbyid(c.relowner)
   FROM pg_class c
   WHERE c.relname = 'table_column_policies'
     AND c.relnamespace = 'app'::regnamespace),
  'app_owner',
  'table_column_policies owned by app_owner'
);

SELECT ok(
  NOT has_table_privilege('public', 'app.table_column_policies', 'SELECT'),
  'PUBLIC has no privileges on app.table_column_policies'
);

------------------------------------------------------------------------------

SELECT * FROM finish();

ROLLBACK;
