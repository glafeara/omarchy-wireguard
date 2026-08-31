#!/bin/bash
# Static regressions for Service control-flow contracts. Quickshell's typed
# IpcHandler prevents standalone Panel.qml linting, so these pin the two
# failure paths that must not be changed into silent UI actions.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
service="$here/../Service.qml"
pass=0 fail=0

expect() {
  local name="$1" condition="$2"
  if eval "$condition"; then echo "PASS $name"; pass=$((pass + 1))
  else echo "FAIL $name"; fail=$((fail + 1)); fi
}

unknown_block="$(awk '/if \(importStateUnknown\)/,/} else if \(op === "import"/' "$service")"
expect "exit 6 clears retry state and returns UI control without auto-retry" \
  'printf "%s\n" "$unknown_block" | grep -q "_editRetryIfname = \"\"" \
    && printf "%s\n" "$unknown_block" | grep -q "root.editFailed(reason)" \
    && ! printf "%s\n" "$unknown_block" | grep -q "retryEdit"'

saved_block="$(awk '/if \(exitCode === 0 \|\| savedNotUp\)/,/} else {/' "$service")"
expect "exit 5 clears editor retry state without auto-retry" \
  'printf "%s\n" "$saved_block" | grep -q "_editRetryIfname = \"\"" \
    && ! printf "%s\n" "$saved_block" | grep -q "retryEdit"'

rename_block="$(awk '/if \(value === profile.name\)/,/return true/' "$service")"
expect "idempotent rename clears stale action errors" \
  'printf "%s\n" "$rename_block" | grep -q "actionRejection = \"\"" \
    && printf "%s\n" "$rename_block" | grep -q "lastError = \"\"" \
    && printf "%s\n" "$rename_block" | grep -q "actionStatus = \"\""'

refresh_block="$(awk '/function refresh\(\)/,/^  }/' "$service")"
change_refresh_block="$(awk '/function refreshAfterChange\(\)/,/^  }/' "$service")"
status_block="$(awk '/id: statusProcess/,/^  }/' "$service")"
expect "only post-control refresh schedules one follow-up poll" \
  'grep -q "property bool _refreshAfterStatus: false" "$service" \
    && ! printf "%s\n" "$refresh_block" | grep -q "_refreshAfterStatus = true" \
    && printf "%s\n" "$change_refresh_block" | grep -q "_refreshAfterStatus = true" \
    && printf "%s\n" "$status_block" | grep -q "_refreshAfterStatus = false" \
    && printf "%s\n" "$status_block" | grep -q "Qt.callLater(root.refreshAfterChange)"'

# The root helper re-validates every config body: awg-quick evaluates
# PostUp/PreUp/... as root, so a compromised user process must not be able
# to plant one even though backend.sh never emits hooks.
helper="$here/../helper/omarchy-amneziawg-helper"
expect "helper writeconf rejects wg-quick hooks in the config body" \
  'grep -Eqi "PreUp|PostUp|PreDown|PostDown|SaveConfig" "$helper" \
    && printf "%s\n" '"'"'[Interface]
PrivateKey = k
PostUp = /bin/evil'"'"' | AWG_CONFDIR="$(mktemp -d)" bash "$helper" writeconf hooky >/dev/null 2>&1; [ $? -ne 0 ]'

# backend.sh emits only canonical, hook-free config text — the parser must
# reject a hook rather than pass it through to the helper.
expect "backend parse_config rejects hooks before the helper is ever called" \
  'grep -q "awg-quick would run it as root" "$here/../backend.sh"'

echo "----"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
