#!/bin/bash
# Tests for helper/omarchy-amneziawg-helper — the root helper — exercised
# directly (not via pkexec) with fake awg/awg-quick on PATH and AWG_CONFDIR
# pointed at a tmp dir. Covers the body re-validation (hook rejection, unknown
# keys), iface-name rejection (traversal, over-length), atomic 0600 write and
# temp-file cleanup on a rejected write.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
helper="$here/../helper/omarchy-amneziawg-helper"
pass=0 fail=0

expect() { # name condition-expr
  if eval "$2"; then echo "PASS $1"; pass=$((pass+1))
  else echo "FAIL $1"; fail=$((fail+1)); fi
}

# --- sandbox with fake awg / awg-quick ------------------------------------
BIN="$(mktemp -d)"
cat > "$BIN/awg" <<'EOF'
#!/bin/bash
# fake awg: `show interfaces` prints nothing
[ "$1" = "show" ] && [ "$2" = "interfaces" ] && exit 0
exit 0
EOF
cat > "$BIN/awg-quick" <<'EOF'
#!/bin/bash
echo "awg-quick $*" >> "${HELPER_LOG:-/dev/null}"
exit 0
EOF
chmod +x "$BIN/awg" "$BIN/awg-quick"
export PATH="$BIN:$PATH"

CONF="$(mktemp -d)"
export AWG_CONFDIR="$CONF"
export HELPER_LOG="$CONF/log"

VALID_BODY='[Interface]
PrivateKey = aaaa
Address = 10.0.0.2/32
Jc = 4
S1 = 50
H1 = 12345
# a comment

[Peer]
PublicKey = bbbb
Endpoint = 1.2.3.4:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25'

# (a) valid writeconf -> 0600 file, matching content
printf '%s\n' "$VALID_BODY" | bash "$helper" writeconf tun0
rc=$?
expect "writeconf valid: exit 0" "[ $rc = 0 ]"
expect "writeconf valid: file exists" '[ -f "$CONF/tun0.conf" ]'
mode="$(stat -c '%a' "$CONF/tun0.conf" 2>/dev/null)"
expect "writeconf valid: mode 0600" '[ "$mode" = 600 ]'
expect "writeconf valid: content round-trips" \
  '[ "$(cat "$CONF/tun0.conf")" = "$VALID_BODY" ]'

# (e) getconf prints back what writeconf stored
got="$(bash "$helper" getconf tun0)"
expect "getconf returns stored body" '[ "$got" = "$VALID_BODY" ]'

# (b) bad iface names rejected, nothing written
for bad in "../etc/passwd" "foo/bar" "aaaaaaaaaaaaaaaa"; do
  before="$(ls -A "$CONF")"
  printf '%s\n' "$VALID_BODY" | bash "$helper" writeconf "$bad" >/dev/null 2>&1
  rc=$?
  after="$(ls -A "$CONF")"
  expect "iface '$bad' rejected non-zero" "[ $rc != 0 ]"
  expect "iface '$bad' wrote nothing" '[ "$before" = "$after" ]'
done

# (c) body with PostUp rejected, no file written
HOOK_BODY='[Interface]
PrivateKey = aaaa
PostUp = touch /tmp/pwned'
before="$(ls -A "$CONF")"
printf '%s\n' "$HOOK_BODY" | bash "$helper" writeconf hooky >/dev/null 2>&1
rc=$?
expect "PostUp body rejected non-zero" "[ $rc != 0 ]"
expect "PostUp body: no file written" '[ ! -e "$CONF/hooky.conf" ]'
expect "PostUp body: confdir unchanged" '[ "$before" = "$(ls -A "$CONF")" ]'

# (d) unknown key rejected
UNK_BODY='[Interface]
PrivateKey = aaaa
Foo = bar'
printf '%s\n' "$UNK_BODY" | bash "$helper" writeconf unk >/dev/null 2>&1
rc=$?
expect "unknown key rejected non-zero" "[ $rc != 0 ]"
expect "unknown key: no file written" '[ ! -e "$CONF/unk.conf" ]'

# (f) no leftover temp files after a rejected write
leftover="$(ls -A "$CONF" | grep -c '^\.omazia\.' || true)"
expect "no leftover mktemp temp files after rejected writes" '[ "$leftover" = 0 ]'

# list: interfaces, then a --- separator, then conf basenames
list_out="$(bash "$helper" list)"
expect "list includes stored conf basename" 'printf "%s\n" "$list_out" | grep -qx tun0'
expect "list emits a --- separator line" 'printf "%s\n" "$list_out" | grep -qx -- ---'
expect "list: conf basename appears after the separator" \
  '[ "$(printf "%s\n" "$list_out" | grep -nx -- --- | cut -d: -f1)" -lt "$(printf "%s\n" "$list_out" | grep -nx tun0 | cut -d: -f1)" ]'

rm -rf "$BIN" "$CONF"
echo "----"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
