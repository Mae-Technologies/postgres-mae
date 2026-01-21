#!/usr/bin/env bash

set +e
/workspace/scripts/run.sh
rc=$?
set -e

app_env_lc="$(printf '%s' "${APP_ENV:-}" | tr '[:upper:]' '[:lower:]')"

if [[ $rc -ne 0 && "${app_env_lc}" == "test" ]]; then

  echo "critical failure, waiting for container reload..."
  while true; do
    sleep 1
  done
fi

exit 1
