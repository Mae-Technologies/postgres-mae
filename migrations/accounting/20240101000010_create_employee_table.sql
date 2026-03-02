BEGIN;
SELECT create_table(
  'employee',
  '
  sir_name TEXT NOT NULL,
  given_name TEXT NOT NULL,
  street TEXT,
  city TEXT,
  postal_zip TEXT,
  phone TEXT,
  email TEXT,
  building_number TEXT,
  rate NUMERIC(10,2),
  rate_type TEXT,
  expense_account INTEGER,
  '
);
COMMIT;
