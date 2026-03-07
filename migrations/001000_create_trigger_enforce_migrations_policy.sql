-- We dont want to drop this one first, we want to try a replacement as app data_definitions rely on it
CREATE OR REPLACE FUNCTION mae._enforce_immutable_columns ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    -- WARN: we don't require any other resources, this is an external independent service.
    -- NOTE: if fields are required to be removed, they can be called from an internal function that can handle the logic inside the other schemas
    SET search_path = pg_catalogue, mae
    AS $$
DECLARE
    imm text[];
    col text;
BEGIN
    SELECT
        immutable_columns INTO imm
    FROM
        mae._table_column_policies
    WHERE
        table_name = TG_TABLE_NAME;
    IF imm IS NULL OR array_length(imm, 1) IS NULL THEN
        RETURN NEW;
    END IF;
    FOREACH col IN ARRAY imm LOOP
        -- Compare OLD vs NEW dynamically.
        IF to_jsonb (NEW) -> col IS DISTINCT FROM to_jsonb (OLD) -> col THEN
            RAISE EXCEPTION 'column "%" is immutable on table "%"', col, TG_TABLE_NAME;
        END IF;
    END LOOP;
    RETURN NEW;
END;
$$;

