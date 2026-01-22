-- TODO:
BEGIN;
SELECT
    plan (1);
SELECT
    ok (1 = 1,
        'sanity: 1=1');
SELECT
    *
FROM
    finish ();
ROLLBACK;

