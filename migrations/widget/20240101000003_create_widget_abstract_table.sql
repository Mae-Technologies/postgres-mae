BEGIN;
SELECT create_table(
  'widget_abstract',
  '
  name TEXT NOT NULL,
  widget_type TEXT NOT NULL,
  unit_of_measure TEXT NOT NULL,
  description TEXT,
  revenue_account INTEGER,
  expense_account INTEGER,
  revenue_amount NUMERIC(19,4),
  expense_amount NUMERIC(19,4),
  '
);
COMMIT;
