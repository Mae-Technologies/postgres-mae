-- SMOKE TEST
BEGIN;

SELECT plan(3);

SELECT ok(1 = 1, 'sanity: 1=1');

SELECT has_schema('app', 'app schema exists');

SELECT ok(
  EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pgtap'),
  'pgtap extension installed'
);

SELECT * FROM finish();

ROLLBACK;
