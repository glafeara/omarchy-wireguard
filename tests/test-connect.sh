#!/bin/bash
# Tests for backend.sh up: non-exclusive activation. Bringing one tunnel up
# must never touch the other active tunnels — multi-tunnel is just "up this
# one", and the panel drives each tunnel from its own row toggle.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
backend="$here/../backend.sh"
export PATH="$here/fake:$PATH"
export OMAWG_PRIV=direct OMAWG_HELPER="$here/fake/helper"
pass=0 fail=0

run_case() { # name expected-exit setup-fn [check-expr]
  local name="$1" want="$2" setup="$3" check="${4:-true}"
  export FAKE_DIR="$(mktemp -d)"
  export XDG_RUNTIME_DIR="$FAKE_DIR"
  export XDG_STATE_HOME="$FAKE_DIR/state"
  : > "$FAKE_DIR/active"; : > "$FAKE_DIR/log"
  printf '[Interface]\nPrivateKey = k\n' > "$FAKE_DIR/conf.target"
  printf '[Interface]\nPrivateKey = k\n' > "$FAKE_DIR/conf.old"
  "$setup"
  bash "$backend" up target >/dev/null 2>"$FAKE_DIR/stderr"
  local got=$?
  local ok=1
  [ "$got" = "$want" ] || { echo "  exit: want $want got $got"; ok=0; }
  eval "$check" || ok=0
  if [ "$ok" = 1 ]; then echo "PASS $name"; pass=$((pass+1))
  else echo "FAIL $name"; sed 's/^/    /' "$FAKE_DIR/log"; sed 's/^/    stderr: /' "$FAKE_DIR/stderr"; fail=$((fail+1)); fi
  rm -rf "$FAKE_DIR"
}

active_is() { [ "$(sort "$FAKE_DIR/active" | grep -v '^$')" = "$(printf '%s\n' "$@" | sort)" ] || { echo "  active: $(tr '\n' ' ' < "$FAKE_DIR/active") want: $*"; return 1; }; }
no_down() { ! grep -q "awg-quick down" "$FAKE_DIR/log" || { echo "  a down ran but no tunnel should have been deactivated"; return 1; }; }

s_fresh() { :; }
run_case "no active, up ok" 0 s_fresh 'active_is target'

s_other() { echo old > "$FAKE_DIR/active"; }
run_case "another tunnel up: target joins it, old untouched" 0 s_other 'active_is old target && no_down'

s_noop() { echo target > "$FAKE_DIR/active"; }
run_case "target already up: no-op, exit 0" 0 s_noop 'active_is target && no_down'

s_among() { printf 'target\nold\n' > "$FAKE_DIR/active"; }
run_case "target already up among others: no-op" 0 s_among 'active_is target old && no_down'

s_upfail() { echo old > "$FAKE_DIR/active"; : > "$FAKE_DIR/fail-up.target"; }
c_upfail() { active_is old && grep -q "Could not activate" "$FAKE_DIR/stderr"; }
run_case "up fails: old untouched, exit 1" 1 s_upfail c_upfail

echo "----"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
