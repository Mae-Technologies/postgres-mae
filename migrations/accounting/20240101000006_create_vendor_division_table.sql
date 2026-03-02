BEGIN;
SELECT create_table(
  'vendor_division',
  '
  vendor_id INTEGER NOT NULL,
  default_payment_method TEXT,
  name TEXT NOT NULL,
  is_accrual BOOLEAN,
  postal_code TEXT,
  street TEXT,
  street_more TEXT,
  city TEXT,
  province TEXT,
  country INTEGER,
  '
);
COMMIT;
