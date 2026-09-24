#!/bin/bash
# Tests for backend.sh notify-drop and the intent markers: marked on the
# actual `down`, cleared on activation (ours or reported via mark-active),
# long-TTL backstop, cross-instance toast cooldown. XDG_RUNTIME_DIR points
# at the sandbox; notify-send is the fake in ./fake, which logs the toast
# instead of showing one.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
backend="$here/../backend.sh"
export PATH="$here/fake:$PATH"
export FAKE_DIR="$(mktemp -d)"
export XDG_RUNTIME_DIR="$FAKE_DIR"
: > "$FAKE_DIR/active"; : > "$FAKE_DIR/log"
trap 'rm -rf "$FAKE_DIR"' EXIT
pass=0 fail=0
uid="$(id -u)"
intent="$FAKE_DIR/omarchy-wireguard.$uid.intent"
notified="$FAKE_DIR/omarchy-wireguard.$uid.notified"

check() { # name uuid expected-exit expected-total-toasts
  local name="$1" uuid="$2" want="$3" toasts="$4" got count
  bash "$backend" notify-drop "$uuid" tunnel >/dev/null 2>&1
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

# No marker at all: external, one toast.
check "external drop notifies" U1 0 1
# Second observation within the cooldown: still external, no second toast.
check "cooldown suppresses the second toast" U1 0 1

# Fresh intent marker: our own doing, quiet.
rm -f "$notified"
printf 'U1 %s\n' "$(date +%s)" > "$intent"
check "fresh intent marker stays quiet" U1 1 1

# Marker older than the TTL backstop (7200s): external again.
printf 'U1 %s\n' "$(( $(date +%s) - 8000 ))" > "$intent"
check "expired marker notifies" U1 0 2

# down-all marks what it actually deactivates.
rm -f "$intent" "$notified"
echo U1 > "$FAKE_DIR/active"
bash "$backend" down-all >/dev/null 2>&1
expect "down-all records its intent" 'grep -q "^U1 " "$intent"'
check "drop after down-all stays quiet" U1 1 2

# connect marks only the tunnels it takes down — never the new target, so
# an external drop right after a successful switch still notifies.
rm -f "$intent" "$notified"
echo OLD > "$FAKE_DIR/active"
echo wg-t > "$FAKE_DIR/ifname.TARGET"; echo wg-o > "$FAKE_DIR/ifname.OLD"
bash "$backend" connect TARGET >/dev/null 2>&1
expect "connect marks the departing tunnel" 'grep -q "^OLD " "$intent"'
expect "connect leaves the target unmarked" '! grep -q "^TARGET " "$intent"'
check "target drop after a switch notifies" TARGET 0 3
check "switched-away tunnel stays quiet" OLD 1 3

# mark-active re-arms: an activation the widget observed clears the marker.
bash "$backend" mark-active OLD >/dev/null 2>&1
rm -f "$notified"
check "re-armed after mark-active" OLD 0 4

# A delayed mark-active carries its observation time and must not erase a
# marker written by a down that happened after the observation.
rm -f "$intent" "$notified"
echo U1 > "$FAKE_DIR/active"
bash "$backend" down U1 >/dev/null 2>&1
bash "$backend" mark-active U1 "$(( $(date +%s) - 100 ))" >/dev/null 2>&1
expect "stale mark-active keeps a newer marker" 'grep -q "^U1 " "$intent"'
check "drop after the newer down stays quiet" U1 1 4

# Same-second tie: with one-second timestamps "same second" cannot be told
# from "after", so the marker must survive an equal observation time.
rm -f "$intent" "$notified"
echo U1 > "$FAKE_DIR/active"
bash "$backend" down U1 >/dev/null 2>&1
ts="$(awk '$1=="U1"{print $2}' "$intent")"
bash "$backend" mark-active U1 "$ts" >/dev/null 2>&1
expect "same-second mark-active keeps the marker" 'grep -q "^U1 " "$intent"'
check "same-second drop stays quiet" U1 1 4

# up (multiTunnel) takes nothing down, so it marks nothing — and like any
# activation it clears the target's old marker, so a later external drop of
# the tunnel it just brought up is not mistaken for ours.
rm -f "$intent" "$notified"
echo OLD > "$FAKE_DIR/active"
echo wg-t > "$FAKE_DIR/ifname.TARGET"; echo wg-o > "$FAKE_DIR/ifname.OLD"
printf 'wireguard.peers:AAAA= allowed-ips=10.0.0.0/8\n' > "$FAKE_DIR/props.TARGET"
printf 'wireguard.peers:BBBB= allowed-ips=198.51.100.0/24\n' > "$FAKE_DIR/props.OLD"
printf 'TARGET %s\n' "$(date +%s)" > "$intent"
bash "$backend" up TARGET >/dev/null 2>&1
expect "up clears the target's marker" '! grep -q "^TARGET " "$intent"'
expect "up marks no other tunnel" '! grep -q "^OLD " "$intent"'
check "target drop after up notifies" TARGET 0 5

# A refused up changes nothing, the target's marker included.
rm -f "$intent" "$notified"
echo OLD > "$FAKE_DIR/active"
echo wg-t > "$FAKE_DIR/ifname.OLD"
printf 'TARGET %s\n' "$(date +%s)" > "$intent"
bash "$backend" up TARGET >/dev/null 2>&1
expect "refused up keeps the target's marker" 'grep -q "^TARGET " "$intent"'

echo "----"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
