-- table_creator role tests (stub — expand as privilege checks are defined)
SELECT * FROM no_plan();

-- placeholder: ensure table_creator role exists
SELECT has_role('table_creator', 'role table_creator exists');

SELECT * FROM finish();
