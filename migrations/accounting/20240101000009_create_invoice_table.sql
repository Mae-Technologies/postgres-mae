BEGIN;
SELECT create_table(
  'invoice',
  '
  doc_ref TEXT NOT NULL,
  client_id INTEGER NOT NULL,
  payment_method INTEGER NOT NULL,
  invoice_date DATE NOT NULL,
  store_id_ref TEXT NOT NULL,
  accounting_entries JSONB NOT NULL DEFAULT ''[]''::JSONB,
  cad_amount NUMERIC(19,4) NOT NULL DEFAULT 0,
  total_accounting_value NUMERIC(19,4) NOT NULL DEFAULT 0,
  '
);
COMMIT;
