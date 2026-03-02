BEGIN;
SELECT create_table(
  'client',
  '
  name TEXT NOT NULL,
  email TEXT,
  phone TEXT,
  postal_code TEXT,
  street TEXT,
  street_more TEXT,
  city TEXT,
  province TEXT,
  country INTEGER,
  url TEXT,
  '
);
COMMIT;
