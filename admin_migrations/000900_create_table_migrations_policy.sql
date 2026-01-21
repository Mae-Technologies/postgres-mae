CREATE TABLE IF NOT EXISTS app.table_column_policies (
  table_name text PRIMARY KEY,
  immutable_columns text[] NOT NULL DEFAULT ARRAY[]::text[]
);
