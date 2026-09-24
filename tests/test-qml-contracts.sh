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
  'printf "%s\n" "$unknown_block" | grep -q "_editRetryUuid = \"\"" \
    && printf "%s\n" "$unknown_block" | grep -q "root.editFailed(reason)" \
    && ! printf "%s\n" "$unknown_block" | grep -q "retryEdit"'

saved_block="$(awk '/if \(exitCode === 0 \|\| savedNotUp\)/,/} else {/' "$service")"
expect "exit 5 clears editor retry state without auto-retry" \
  'printf "%s\n" "$saved_block" | grep -q "_editRetryUuid = \"\"" \
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

panel="$here/../Panel.qml"

connect_block="$(awk '/function connectTo\(profile\)/,/^  }/' "$service")"
expect "multiTunnel connects with up, otherwise the exclusive connect" \
  'printf "%s\n" "$connect_block" | grep -qF "multiTunnel ? \"up\" : \"connect\""'

# The widget's own settings come from `omarchy bar set`, which stores
# strings: "false" must read as false, not as a truthy string.
bool_block="$(awk '/function boolSetting\(name, fallback\)/,/^  }/' "$service")"
if command -v node >/dev/null 2>&1; then
  expect "boolSetting reads string settings" \
    'printf "%s\n" "var settings={}; function setting(n,f){return settings[n]===undefined?f:settings[n]}" "$bool_block" \
      "var cases=[[true,true],[false,false],[\"true\",true],[\"false\",false],[\"1\",true],[\"0\",false],[\" On \",true],[\"off\",false],[\"bogus\",false],[undefined,false]];" \
      "process.exit(cases.every(function(c){settings.x=c[0];return boolSetting(\"x\",false)===c[1]})?0:1)" \
      | node'
else
  echo "SKIP boolSetting reads string settings (node not installed)"
fi

# rememberLast follows what newly came up; with several tunnels up the first
# active one would otherwise win every poll.
status_apply_block="$(awk '/function applyStatus\(raw\)/,/^  }/' "$service")"
expect "last-used tunnel is taken only from newly active profiles" \
  'printf "%s\n" "$status_apply_block" | grep -qF "firstUp === \"\" && _prevActive[uuid] === undefined"'

# Every poll re-runs rememberCursor; a closed panel must not steer the grid.
remember_block="$(awk '/function rememberCursor\(\)/,/^  }/' "$panel")"
opened_block="$(awk '/onOpenedChanged: \{/,/^  }/' "$panel")"
expect "only an open panel with a visible cursor moves the grid focus" \
  'printf "%s\n" "$remember_block" | grep -q "if (opened && cursorActive &&" \
    && [ "$(printf "%s\n" "$remember_block" | grep -c "focusUuid")" = 1 ]'
expect "the cursor is hidden on close as well as on open" \
  'printf "%s\n" "$opened_block" | awk "/cursorActive = false/ && !c {c=NR} /if \\(opened\\)/ && !o {o=NR} END{exit !(c && o && c < o)}"'
expect "revealing the cursor moves the grid to it" \
  'grep -q "onCursorActiveChanged: if (cursorActive) rememberCursor()" "$panel"'

commit_block="$(awk '/commit_import\(\)/,/^  }/' "$here/../backend.sh")"
expect "import commit keeps a terminal signal handler instead of a trap gap" \
  'printf "%s\n" "$commit_block" | grep -q "import_committed=1" \
    && printf "%s\n" "$commit_block" | grep -q "trap - EXIT" \
    && ! printf "%s\n" "$commit_block" | grep -q "trap - EXIT HUP INT TERM"'

echo "----"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
