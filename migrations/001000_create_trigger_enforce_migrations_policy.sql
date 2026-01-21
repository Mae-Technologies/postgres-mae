CREATE OR REPLACE FUNCTION app.enforce_immutable_columns()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = app, public
AS $$
DECLARE
  imm text[];
  col text;
BEGIN
  SELECT immutable_columns INTO imm
  FROM app.table_column_policies
  WHERE table_name = TG_TABLE_NAME;

  IF imm IS NULL OR array_length(imm, 1) IS NULL THEN
    RETURN NEW;
  END IF;

  FOREACH col IN ARRAY imm LOOP
    -- Compare OLD vs NEW dynamically.
    IF to_jsonb(NEW) -> col IS DISTINCT FROM to_jsonb(OLD) -> col THEN
      RAISE EXCEPTION 'column "%" is immutable on table "%"', col, TG_TABLE_NAME;
    END IF;
  END LOOP;

  RETURN NEW;
END;
$$;
