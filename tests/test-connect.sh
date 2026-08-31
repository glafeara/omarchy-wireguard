#!/bin/bash
# Tests for backend.sh connect: exit codes 0/20/21, make-before-break,
# rollback. Interface names are the identity now, so a switch between two
# distinct tunnels is always make-before-break; the break-before-make branch
# only fires on a re-import name collision.
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
  bash "$backend" connect target >/dev/null 2>"$FAKE_DIR/stderr"
  local got=$?
  local ok=1
  [ "$got" = "$want" ] || { echo "  exit: want $want got $got"; ok=0; }
  eval "$check" || ok=0
  if [ "$ok" = 1 ]; then echo "PASS $name"; pass=$((pass+1))
  else echo "FAIL $name"; sed 's/^/    /' "$FAKE_DIR/log"; sed 's/^/    stderr: /' "$FAKE_DIR/stderr"; fail=$((fail+1)); fi
  rm -rf "$FAKE_DIR"
}

active_is() { [ "$(sort "$FAKE_DIR/active" | grep -v '^$')" = "$(printf '%s\n' "$@" | sort)" ] || { echo "  active: $(tr '\n' ' ' < "$FAKE_DIR/active") want: $*"; return 1; }; }
up_before_down() {
  local up_line down_line
  up_line=$(grep -n "awg-quick up target" "$FAKE_DIR/log" | cut -d: -f1 | head -1)
  down_line=$(grep -n "awg-quick down old" "$FAKE_DIR/log" | cut -d: -f1 | head -1)
  [ -n "$up_line" ] && [ -n "$down_line" ] && [ "$up_line" -lt "$down_line" ] || { echo "  order: expected up before down"; return 1; }
}

s_fresh() { :; }
run_case "no active, up ok" 0 s_fresh 'active_is target'

s_switch() { echo old > "$FAKE_DIR/active"; }
run_case "switch: make-before-break" 0 s_switch 'active_is target && up_before_down'

s_noop() { echo target > "$FAKE_DIR/active"; }
run_case "already exactly the target: no-op" 0 s_noop 'active_is target'

s_among() { printf 'target\nold\n' > "$FAKE_DIR/active"; }
run_case "target active among others: down others only" 0 s_among 'active_is target'

s_upfail() { echo old > "$FAKE_DIR/active"; : > "$FAKE_DIR/fail-up.target"; }
run_case "up fails: old untouched, exit 20" 20 s_upfail 'active_is old'

s_downfail() { echo old > "$FAKE_DIR/active"; : > "$FAKE_DIR/fail-down.old"; }
c_downfail() { active_is old && grep -q "were restored" "$FAKE_DIR/stderr"; }
run_case "old refuses to go down: target rolled back down, exit 20" 20 s_downfail c_downfail

s_rbfail() { echo old > "$FAKE_DIR/active"; : > "$FAKE_DIR/fail-down.old"; : > "$FAKE_DIR/fail-down.target"; }
run_case "rollback also fails: exit 21" 21 s_rbfail 'grep -q "check your connections" "$FAKE_DIR/stderr"'

echo "----"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
