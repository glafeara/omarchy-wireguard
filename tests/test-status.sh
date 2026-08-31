#!/bin/bash
# Tests for backend.sh status: a failing helper query must fail the whole
# command — a swallowed error would read as "no tunnels up" (false drop
# toasts) or as an empty tunnel list.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
backend="$here/../backend.sh"
export PATH="$here/fake:$PATH"
export OMAWG_PRIV=direct OMAWG_HELPER="$here/fake/helper"
pass=0 fail=0

fresh() {
  export FAKE_DIR="$(mktemp -d)"
  export XDG_RUNTIME_DIR="$FAKE_DIR"
  export XDG_STATE_HOME="$FAKE_DIR/state"
  : > "$FAKE_DIR/active"; : > "$FAKE_DIR/log"
  printf '[Interface]\nPrivateKey = k\n' > "$FAKE_DIR/conf.pm"
}

expect() { # name condition-expr
  if eval "$2"; then echo "PASS $1"; pass=$((pass+1))
  else echo "FAIL $1"; fail=$((fail+1)); fi
  rm -rf "$FAKE_DIR"
}

fresh
out="$(bash "$backend" status 2>/dev/null)"; rc=$?
expect "happy path: one section separator, tunnel listed, not active" \
  '[ "$rc" = 0 ] && [ "$(printf "%s\n" "$out" | grep -cx -- ---)" = 1 ] \
    && printf "%s\n" "$out" | grep -qx "pm:amneziawg::pm"'

fresh
echo pm > "$FAKE_DIR/active"
out="$(bash "$backend" status 2>/dev/null)"; rc=$?
expect "active tunnel gets a device field and appears in the active section" \
  '[ "$rc" = 0 ] && printf "%s\n" "$out" | grep -qx "pm:amneziawg:pm:pm" \
    && [ "$(printf "%s\n" "$out" | sed -n "/^---$/,\$p" | grep -cx pm)" = 1 ]'

fresh
mkdir -p "$XDG_STATE_HOME/omarchy"
printf 'pm\tWork VPN\n' > "$XDG_STATE_HOME/omarchy/amneziawg-names"
out="$(bash "$backend" status 2>/dev/null)"
expect "sidecar label is merged into the first section" \
  'printf "%s\n" "$out" | grep -qx "pm:amneziawg::Work VPN"'

fresh
: > "$FAKE_DIR/fail-active"
bash "$backend" status >/dev/null 2>&1; rc=$?
expect "failing helper list fails status" '[ "$rc" != 0 ]'

echo "----"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
