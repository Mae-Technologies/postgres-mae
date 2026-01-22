CREATE TABLE IF NOT EXISTS mae._table_column_policies (
    table_name text PRIMARY KEY,
    schema_name text,
    immutable_columns text[] NOT NULL DEFAULT ARRAY[]::text[]
);

