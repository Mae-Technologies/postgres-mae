BEGIN;
SELECT create_table(
  'operation_model',
  '
  name TEXT NOT NULL,
  description TEXT,
  timesheet_comment_required BOOLEAN DEFAULT FALSE,
  '
);
COMMIT;
