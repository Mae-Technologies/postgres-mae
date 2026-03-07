-- app_user role tests (stub — expand as privilege checks are defined)
SELECT * FROM no_plan();

-- placeholder: ensure app_user role exists
SELECT has_role('app_user', 'role app_user exists');

SELECT * FROM finish();
