#!/bin/bash
# Tests for backend.sh notify-drop and the intent markers: marked on the
# actual `down`, cleared on activation (ours or reported via mark-active),
# long-TTL backstop, cross-instance toast cooldown.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
backend="$here/../backend.sh"
export PATH="$here/fake:$PATH"
export OMAWG_PRIV=direct OMAWG_HELPER="$here/fake/helper"
export FAKE_DIR="$(mktemp -d)"
export XDG_RUNTIME_DIR="$FAKE_DIR"
export XDG_STATE_HOME="$FAKE_DIR/state"
: > "$FAKE_DIR/active"; : > "$FAKE_DIR/log"
printf '[Interface]\nPrivateKey = k\n' > "$FAKE_DIR/conf.target"
printf '[Interface]\nPrivateKey = k\n' > "$FAKE_DIR/conf.old"
printf '[Interface]\nPrivateKey = k\n' > "$FAKE_DIR/conf.u1"
trap 'rm -rf "$FAKE_DIR"' EXIT
pass=0 fail=0
uid="$(id -u)"
intent="$FAKE_DIR/omarchy-amneziawg.$uid.intent"
notified="$FAKE_DIR/omarchy-amneziawg.$uid.notified"

check() { # name iface expected-exit expected-total-toasts
  local name="$1" iface="$2" want="$3" toasts="$4" got count
  bash "$backend" notify-drop "$iface" tunnel >/dev/null 2>&1
  got=$?
  count=$(grep -c '^notify-send' "$FAKE_DIR/log")
  if [ "$got" = "$want" ] && [ "$count" = "$toasts" ]; then
    echo "PASS $name"; pass=$((pass+1))
  else
    echo "FAIL $name (exit want $want got $got; toasts want $toasts got $count)"; fail=$((fail+1))
  fi
}

expect() { # name condition-expr
  if eval "$2"; then echo "PASS $1"; pass=$((pass+1))
  else echo "FAIL $1"; fail=$((fail+1)); fi
}

check "external drop notifies" u1 0 1
check "cooldown suppresses the second toast" u1 0 1

rm -f "$notified"
printf 'u1 %s\n' "$(date +%s)" > "$intent"
check "fresh intent marker stays quiet" u1 1 1

printf 'u1 %s\n' "$(( $(date +%s) - 8000 ))" > "$intent"
check "expired marker notifies" u1 0 2

rm -f "$intent" "$notified"
echo u1 > "$FAKE_DIR/active"
bash "$backend" down-all >/dev/null 2>&1
expect "down-all records its intent" 'grep -q "^u1 " "$intent"'
check "drop after down-all stays quiet" u1 1 2

rm -f "$intent" "$notified"
echo old > "$FAKE_DIR/active"
bash "$backend" connect target >/dev/null 2>&1
expect "connect marks the departing tunnel" 'grep -q "^old " "$intent"'
expect "connect leaves the target unmarked" '! grep -q "^target " "$intent"'
check "target drop after a switch notifies" target 0 3
check "switched-away tunnel stays quiet" old 1 3

bash "$backend" mark-active old >/dev/null 2>&1
rm -f "$notified"
check "re-armed after mark-active" old 0 4

rm -f "$intent" "$notified"
echo u1 > "$FAKE_DIR/active"
bash "$backend" down u1 >/dev/null 2>&1
bash "$backend" mark-active u1 "$(( $(date +%s) - 100 ))" >/dev/null 2>&1
expect "stale mark-active keeps a newer marker" 'grep -q "^u1 " "$intent"'
check "drop after the newer down stays quiet" u1 1 4

rm -f "$intent" "$notified"
echo u1 > "$FAKE_DIR/active"
bash "$backend" down u1 >/dev/null 2>&1
ts="$(awk '$1=="u1"{print $2}' "$intent")"
bash "$backend" mark-active u1 "$ts" >/dev/null 2>&1
expect "same-second mark-active keeps the marker" 'grep -q "^u1 " "$intent"'
check "same-second drop stays quiet" u1 1 4

echo "----"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
