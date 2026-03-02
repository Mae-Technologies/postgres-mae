BEGIN;
SELECT create_table(
  'project',
  '
  name TEXT NOT NULL,
  project_type TEXT NOT NULL,
  description TEXT,
  end_date DATE,
  start_date DATE,
  timesheet_comment_required BOOLEAN DEFAULT FALSE,
  '
);
COMMIT;
