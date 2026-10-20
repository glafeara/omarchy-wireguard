#!/bin/bash
# Tests for backend.sh connect: exit codes 0/20/21, branch selection,
# rollback. Runs against the fake nmcli in ./fake — a broken endpoint can't
# exercise these paths (nmcli up succeeds even when the peer is dead), only
# a failing nmcli can. XDG_RUNTIME_DIR is pointed at the sandbox so lock,
# intent and notification state never touch the real session's files.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
backend="$here/../backend.sh"
export PATH="$here/fake:$PATH"
pass=0 fail=0

run_case() { # name expected-exit setup-fn [check-expr]
  local name="$1" want="$2" setup="$3" check="${4:-true}"
  export FAKE_DIR="$(mktemp -d)"
  export XDG_RUNTIME_DIR="$FAKE_DIR"
  : > "$FAKE_DIR/active"; : > "$FAKE_DIR/log"
  "$setup"
  bash "$backend" connect ${CONNECT_FLAGS:-} TARGET >/dev/null 2>"$FAKE_DIR/stderr"
  local got=$?
  local ok=1
  [ "$got" = "$want" ] || { echo "  exit: want $want got $got"; ok=0; }
  eval "$check" || ok=0
  if [ "$ok" = 1 ]; then echo "PASS $name"; pass=$((pass+1))
  else echo "FAIL $name"; sed 's/^/    /' "$FAKE_DIR/log"; sed 's/^/    stderr: /' "$FAKE_DIR/stderr"; fail=$((fail+1)); fi
  rm -rf "$FAKE_DIR"
}

active_is() { [ "$(sort "$FAKE_DIR/active")" = "$(printf '%s\n' "$@" | sort)" ] || { echo "  active: $(tr '\n' ' ' < "$FAKE_DIR/active") want: $*"; return 1; }; }
up_before_down() { # make-before-break order
  local up_line down_line
  up_line=$(grep -n "up TARGET" "$FAKE_DIR/log" | cut -d: -f1 | head -1)
  down_line=$(grep -n "down OLD" "$FAKE_DIR/log" | cut -d: -f1 | head -1)
  [ -n "$up_line" ] && [ -n "$down_line" ] && [ "$up_line" -lt "$down_line" ] || { echo "  order: expected up before down"; return 1; }
}
down_before_up() {
  local up_line down_line
  up_line=$(grep -n "up TARGET" "$FAKE_DIR/log" | cut -d: -f1 | head -1)
  down_line=$(grep -n "down OLD" "$FAKE_DIR/log" | cut -d: -f1 | head -1)
  [ -n "$up_line" ] && [ -n "$down_line" ] && [ "$down_line" -lt "$up_line" ] || { echo "  order: expected down before up"; return 1; }
}

s_fresh() { echo wg-t > "$FAKE_DIR/ifname.TARGET"; }
run_case "no active, up ok" 0 s_fresh 'active_is TARGET'

s_switch() { echo OLD > "$FAKE_DIR/active"; echo wg-t > "$FAKE_DIR/ifname.TARGET"; echo wg-o > "$FAKE_DIR/ifname.OLD"; }
c_switch() { active_is TARGET && up_before_down; }
run_case "distinct ifnames: make-before-break" 0 s_switch c_switch

s_same() { echo OLD > "$FAKE_DIR/active"; echo wg0 > "$FAKE_DIR/ifname.TARGET"; echo wg0 > "$FAKE_DIR/ifname.OLD"; }
c_same() { active_is TARGET && down_before_up; }
run_case "same ifname: break-before-make" 0 s_same c_same

s_empty() { echo OLD > "$FAKE_DIR/active"; : > "$FAKE_DIR/ifname.TARGET"; echo wg-o > "$FAKE_DIR/ifname.OLD"; }
run_case "empty target ifname: break-before-make" 0 s_empty c_same

s_upfail_mbb() { s_switch; : > "$FAKE_DIR/fail-up.TARGET"; }
run_case "make-before-break, up fails: old untouched" 20 s_upfail_mbb 'active_is OLD'

s_upfail_bbm() { s_same; : > "$FAKE_DIR/fail-up.TARGET"; }
c_restored() { active_is OLD && grep -q "were restored" "$FAKE_DIR/stderr"; }
run_case "break-before-make, up fails: old restored" 20 s_upfail_bbm c_restored

s_rb_fail() { s_same; : > "$FAKE_DIR/fail-up.TARGET"; : > "$FAKE_DIR/fail-up.OLD"; }
c_unknown() { grep -q "check your connections" "$FAKE_DIR/stderr"; }
run_case "rollback also fails" 21 s_rb_fail c_unknown

s_already() { printf 'TARGET\nOLD\n' > "$FAKE_DIR/active"; echo wg-t > "$FAKE_DIR/ifname.TARGET"; echo wg-o > "$FAKE_DIR/ifname.OLD"; }
run_case "target already active among others: down others only" 0 s_already 'active_is TARGET'

s_downfail() { s_switch; : > "$FAKE_DIR/fail-down.OLD"; }
c_downfail() { active_is OLD && grep -q "were restored" "$FAKE_DIR/stderr"; }
run_case "old refuses to go down: target rolled back down" 20 s_downfail c_downfail

s_noop() { echo TARGET > "$FAKE_DIR/active"; }
run_case "already exactly the target: no-op" 0 s_noop 'active_is TARGET'

# --parallel: only tunnels with overlapping AllowedIPs are switched off.
peer() { echo "KEY= endpoint=1.2.3.4:51820 allowed-ips=$2" > "$FAKE_DIR/peers.$1"; }
s_disjoint() { s_switch; peer TARGET 10.1.0.0/16; peer OLD 10.2.0.0/16; }
s_overlap() { s_switch; peer TARGET 10.1.0.0/16; peer OLD 10.1.5.0/24; }
s_nopeers() { s_switch; peer TARGET 10.1.0.0/16; }
CONNECT_FLAGS=--parallel
run_case "parallel: disjoint routes stay up" 0 s_disjoint 'active_is TARGET OLD'
run_case "parallel: overlapping routes switch" 0 s_overlap 'active_is TARGET'
run_case "parallel: unreadable routes switch" 0 s_nopeers 'active_is TARGET'
CONNECT_FLAGS=
run_case "default: disjoint routes still switch" 0 s_disjoint 'active_is TARGET'

echo "----"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
