BEGIN;
SELECT create_table(
  'widget_model',
  '
  widget_abstract INTEGER NOT NULL,
  name TEXT NOT NULL,
  unit_of_measure TEXT NOT NULL,
  revenue_account INTEGER,
  expense_account INTEGER,
  revenue_amount NUMERIC(19,4),
  expense_amount NUMERIC(19,4),
  description TEXT,
  '
);
COMMIT;
