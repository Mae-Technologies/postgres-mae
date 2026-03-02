BEGIN;
SELECT create_table(
  'purchase',
  '
  doc_ref TEXT NOT NULL,
  vendor_id INTEGER NOT NULL,
  vendor_division_id INTEGER NOT NULL,
  payment_method INTEGER NOT NULL,
  purchase_date DATE NOT NULL,
  store_id_ref TEXT NOT NULL,
  accounting_entries JSONB NOT NULL DEFAULT ''[]''::JSONB,
  cad_amount NUMERIC(19,4) NOT NULL DEFAULT 0,
  total_accounting_value NUMERIC(19,4) NOT NULL DEFAULT 0,
  '
);
COMMIT;
