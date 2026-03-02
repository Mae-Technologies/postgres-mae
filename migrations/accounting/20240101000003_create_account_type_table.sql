BEGIN;
SELECT create_table(
  'account_type',
  '
  name TEXT NOT NULL,
  default_bal_type BOOLEAN NOT NULL DEFAULT FALSE,
  upper_boundary INTEGER,
  lower_boundary INTEGER,
  parent INTEGER,
  '
);
COMMIT;
