BEGIN;

CREATE SEQUENCE IF NOT EXISTS sys_user_seq START 1 INCREMENT BY 1 MINVALUE 1;

CREATE TABLE IF NOT EXISTS sys_user (
  id INTEGER DEFAULT nextval('sys_user_seq') PRIMARY KEY,
  username TEXT NOT NULL UNIQUE,
  hash_pass TEXT NOT NULL,
  first_name TEXT NOT NULL,
  last_name TEXT NOT NULL,
  mobile TEXT NOT NULL,
  email TEXT NOT NULL,
  tags JSONB,
  timezone TEXT DEFAULT 'GMT-4:00'
);

COMMIT;
