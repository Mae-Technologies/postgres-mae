CREATE OR REPLACE FUNCTION create_table(table_name TEXT, table_rows_string TEXT) 
RETURNS VOID
LANGUAGE plpgsql
as $$
BEGIN
  EXECUTE format('CREATE SEQUENCE IF NOT EXISTS %I START 1 INCREMENT BY 1 MINVALUE 1;', (table_name || '_seq'));
  EXECUTE format('CREATE TABLE IF NOT EXISTS %I (
    id INTEGER DEFAULT nextval(%L) PRIMARY KEY,
    sys_client INT NOT NULL,
    status status NOT NULL,
    %s
    comment TEXT,
    tags JSONB NOT NULL,
    sys_detail JSONB NOT NULL,
    created_by INT NOT NULL,
    updated_by INT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT current_timestamp,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT current_timestamp
);', table_name, (table_name || '_seq'), table_rows_string);
END;
$$;
