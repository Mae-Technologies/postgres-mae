BEGIN;
SELECT create_table(
  'account',
  '
  type_id INTEGER NOT NULL,
  code INTEGER NOT NULL,
  name TEXT NOT NULL,
  balance_details JSONB NOT NULL DEFAULT ''{}''::JSONB,
  opening_balance_details JSONB NOT NULL DEFAULT ''{}''::JSONB,
  gifi INTEGER,
  '
);
COMMIT;
