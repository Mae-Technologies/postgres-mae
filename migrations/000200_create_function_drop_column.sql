CREATE OR REPLACE FUNCTION app.drop_column (_tbl text, _col text)
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $$
BEGIN
    EXECUTE format('ALTER TABLE app.%I DROP COLUMN %I', _tbl, _col);
END;
$$;

