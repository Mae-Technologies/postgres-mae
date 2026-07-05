-- SMOKE TEST
BEGIN;
SELECT
    plan (4);
SELECT
    ok (1 = 1,
        'sanity: 1=1');
SELECT
    has_schema ('app', 'app schema exists');
SELECT
    ok (EXISTS (
            SELECT
                1
            FROM
                pg_extension
            WHERE
                extname = 'pgtap'), 'pgtap extension installed');
SELECT
    ok (EXISTS (
            SELECT
                1
            FROM
                pg_extension
            WHERE
                extname = 'btree_gist'), 'btree_gist extension installed');
SELECT
    *
FROM
    finish ();
ROLLBACK;

