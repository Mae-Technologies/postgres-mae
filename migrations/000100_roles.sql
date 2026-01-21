DO $$
BEGIN
    IF NOT EXISTS (
        SELECT
            1
        FROM
            pg_roles
        WHERE
            rolname = 'app_user') THEN
    CREATE ROLE app_user NOLOGIN;
END IF;
    IF NOT EXISTS (
        SELECT
            1
        FROM
            pg_roles
        WHERE
            rolname = 'app_migrator') THEN
    CREATE ROLE app_migrator NOLOGIN;
END IF;
    IF NOT EXISTS (
        SELECT
            1
        FROM
            pg_roles
        WHERE
            rolname = 'table_creator') THEN
    CREATE ROLE table_creator NOLOGIN;
END IF;
END
$$;

