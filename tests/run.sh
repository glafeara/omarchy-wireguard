#!/bin/bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
rc=0
for suite in test-helper.sh test-status.sh test-connect.sh test-notify.sh test-details.sh test-safety.sh test-qml-contracts.sh; do
  bash "$here/$suite" || rc=1
done
exit "$rc"
