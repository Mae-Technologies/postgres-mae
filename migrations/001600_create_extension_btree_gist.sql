-- btree_gist enables GIST exclusion constraints on scalar columns (partial unique indexes).
-- Install into app schema so gist_* opclasses resolve under create_table_from_spec search_path.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'btree_gist') THEN
        CREATE EXTENSION btree_gist SCHEMA app;
    ELSE
        ALTER EXTENSION btree_gist SET SCHEMA app;
    END IF;
END;
$$;