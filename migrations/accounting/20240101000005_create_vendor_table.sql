BEGIN;
SELECT create_table(
  'vendor',
  '
  name TEXT NOT NULL,
  url TEXT,
  default_division INTEGER,
  '
);
COMMIT;
