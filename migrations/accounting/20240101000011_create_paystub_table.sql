BEGIN;
SELECT create_table(
  'paystub',
  '
  doc_ref TEXT NOT NULL,
  employee_id INTEGER NOT NULL,
  payment_method INTEGER NOT NULL,
  rate_count NUMERIC(10,2) NOT NULL DEFAULT 0,
  paystub_date DATE NOT NULL,
  store_id_ref TEXT NOT NULL,
  accounting_entries JSONB NOT NULL DEFAULT ''[]''::JSONB,
  total_net_value NUMERIC(19,4) NOT NULL DEFAULT 0,
  total_accounting_value NUMERIC(19,4) NOT NULL DEFAULT 0,
  rate NUMERIC(10,2) NOT NULL DEFAULT 0,
  vacation_rate NUMERIC(10,2) NOT NULL DEFAULT 0,
  '
);
COMMIT;
