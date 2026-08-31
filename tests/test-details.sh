#!/bin/bash
# Tests for backend.sh details: the read-only query behind the panel's
# connection grid. It runs on a timer while the panel is open. What matters:
# it never prints secret key material, and a missing tunnel fails loudly
# instead of printing a grid of blanks.
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
  cat > "$FAKE_DIR/conf.pm" <<'EOF'
[Interface]
PrivateKey = SECRETPRIVATEKEYvalue=
Address = 10.8.0.13/32
DNS = 8.8.8.8, 1.1.1.1
EOF
  cat > "$FAKE_DIR/dump.pm" <<'EOF'
PRIVKEY= PUBKEY= 51820 off
PEERPUB= (none) 185.55.56.151:51820 0.0.0.0/0,192.0.2.0/24 1699999999 100 200 25
EOF
}

expect() { # name condition-expr
  if eval "$2"; then echo "PASS $1"; pass=$((pass+1))
  else echo "FAIL $1"; fail=$((fail+1)); fi
  rm -rf "$FAKE_DIR"
}

field() { printf '%s\n' "$out" | sed -n "s/^$1=//p"; }

fresh
out="$(bash "$backend" details pm 2>/dev/null)"; rc=$?
expect "happy path: address, endpoint, routes, dns, peer count" \
  '[ "$rc" = 0 ] && [ "$(field ip)" = "10.8.0.13/32" ] \
    && [ "$(field endpoint)" = "185.55.56.151:51820" ] \
    && [ "$(field allowed)" = "0.0.0.0/0, 192.0.2.0/24" ] \
    && [ "$(field dns)" = "8.8.8.8, 1.1.1.1" ] \
    && [ "$(field peers)" = "1" ]'

fresh
out="$(bash "$backend" details pm 2>/dev/null)"
expect "every key is printed even when the tunnel has no value for it" \
  '[ "$(printf "%s\n" "$out" | wc -l)" = 7 ] && [ "$(field mtu)" = "" ] && [ "$(field ip6)" = "" ]'

fresh
out="$(bash "$backend" details pm 2>/dev/null)"
expect "never prints private key material" '! printf "%s\n" "$out" | grep -q SECRETPRIVATEKEY'

fresh
bash "$backend" details nope >/dev/null 2>&1; rc=$?
expect "unknown tunnel fails instead of printing blanks" '[ "$rc" != 0 ]'

fresh
cat > "$FAKE_DIR/dump.pm" <<'EOF'
PRIVKEY= PUBKEY= 51820 off
AAAA= (none) 203.0.113.7:1234 192.0.2.0/24 1699999999 1 2 25
BBBB= (none) 203.0.113.8:1234 198.51.100.0/24 0 3 4 25
EOF
out="$(bash "$backend" details pm 2>/dev/null)"
expect "multi-peer tunnel: first peer described, all peers counted" \
  '[ "$(field peers)" = "2" ] && [ "$(field endpoint)" = "203.0.113.7:1234" ] \
    && [ "$(field allowed)" = "192.0.2.0/24" ]'

echo "----"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
