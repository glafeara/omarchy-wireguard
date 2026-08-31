#!/bin/bash
# Regression tests: secret-bearing export never overwrites on failure,
# runtime-state safety, import rollback / exit-code contract (5/6),
# hook rejection, QR + editor cleanup. All privileged calls hit fake/helper.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
backend="$here/../backend.sh"
export PATH="$here/fake:$PATH"
export OMAWG_PRIV=direct OMAWG_HELPER="$here/fake/helper"
pass=0 fail=0

fresh() {
  export FAKE_DIR="$(mktemp -d)"
  export XDG_RUNTIME_DIR="$FAKE_DIR/runtime"
  export XDG_STATE_HOME="$FAKE_DIR/state"
  mkdir "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
  : > "$FAKE_DIR/active"; : > "$FAKE_DIR/log"
}

done_case() {
  local name="$1" check="$2"
  if eval "$check"; then echo "PASS $name"; pass=$((pass + 1))
  else echo "FAIL $name"; fail=$((fail + 1)); [ -f "$FAKE_DIR/log" ] && sed 's/^/    /' "$FAKE_DIR/log"; fi
  rm -rf "$FAKE_DIR"
}

confbody() {
  printf '%s\n' '[Interface]' 'PrivateKey = test-private-key' 'Address = 10.0.0.2/32' \
    'Jc = 4' 'S1 = 50' 'H1 = 123' '' '[Peer]' 'PublicKey = test-peer-key' 'AllowedIPs = 0.0.0.0/0'
}
names_file() { printf '%s/omarchy/amneziawg-names' "$XDG_STATE_HOME"; }

# --- export never overwrites on failure -----------------------------------
fresh
printf 'unchanged' > "$FAKE_DIR/dest.conf"
bash "$backend" export missing >/dev/null 2>&1; export_rc=$?
bash "$backend" export-file missing "$FAKE_DIR/dest.conf" >/dev/null 2>&1; file_rc=$?
done_case "failed export fails and never overwrites the destination" \
  '[ "$export_rc" != 0 ] && [ "$file_rc" != 0 ] && [ "$(cat "$FAKE_DIR/dest.conf")" = unchanged ]'

fresh
confbody | bash "$backend" import wg0 >/dev/null 2>&1
bash "$backend" export-file wg0 "$FAKE_DIR/dest.conf" >/dev/null 2>&1; good_rc=$?
dest_mode="$(stat -Lc '%a' "$FAKE_DIR/dest.conf")"
done_case "successful export-file is complete and mode 0600" \
  '[ "$good_rc" = 0 ] && [ "$dest_mode" = 600 ] && grep -q "PrivateKey = test-private-key" "$FAKE_DIR/dest.conf" \
    && grep -q "\[Peer\]" "$FAKE_DIR/dest.conf" && grep -q "Jc = 4" "$FAKE_DIR/dest.conf"'

# --- AWG param round-trip -------------------------------------------------
fresh
confbody | bash "$backend" import wg0 >/dev/null 2>&1
out="$(bash "$backend" export wg0 2>/dev/null)"
done_case "AmneziaWG params survive import -> export" \
  'printf "%s\n" "$out" | grep -qx "Jc = 4" && printf "%s\n" "$out" | grep -qx "S1 = 50" && printf "%s\n" "$out" | grep -qx "H1 = 123"'

# --- hook rejection ------------------------------------------------------
fresh
printf '%s\n' '[Interface]' 'PrivateKey = k' 'PostUp = /bin/evil' | bash "$backend" import wg0 >/dev/null 2>&1; hook_rc=$?
done_case "a PostUp hook is rejected and nothing is written" \
  '[ "$hook_rc" != 0 ] && ! [ -e "$FAKE_DIR/conf.wg0" ]'

# --- runtime dir refusal ----------------------------------------------------
fresh
mkdir "$FAKE_DIR/unsafe"; chmod 777 "$FAKE_DIR/unsafe"
XDG_RUNTIME_DIR="$FAKE_DIR/unsafe" bash "$backend" down-all >/dev/null 2>&1; unsafe_rc=$?
mkdir "$FAKE_DIR/p755" "$FAKE_DIR/p750"; chmod 755 "$FAKE_DIR/p755"; chmod 750 "$FAKE_DIR/p750"
XDG_RUNTIME_DIR="$FAKE_DIR/p755" bash "$backend" down-all >/dev/null 2>&1; p755_rc=$?
XDG_RUNTIME_DIR="$FAKE_DIR/p750" bash "$backend" down-all >/dev/null 2>&1; p750_rc=$?
ln -s "$FAKE_DIR/p755" "$FAKE_DIR/link"
XDG_RUNTIME_DIR="$FAKE_DIR/link" bash "$backend" down-all >/dev/null 2>&1; link_rc=$?
env -u XDG_RUNTIME_DIR bash "$backend" down-all >/dev/null 2>&1; unset_rc=$?
done_case "unset, non-private, unsafe and symlink runtime directories are refused" \
  '[ "$unsafe_rc" != 0 ] && [ "$p755_rc" != 0 ] && [ "$p750_rc" != 0 ] && [ "$link_rc" != 0 ] && [ "$unset_rc" != 0 ]'

# --- rename fails closed ---------------------------------------------------
fresh
: > "$FAKE_DIR/fail-active"
bash "$backend" rename wg0 renamed >/dev/null 2>&1; rename_rc=$?
done_case "rename fails closed when the tunnel listing fails" \
  '[ "$rename_rc" != 0 ] && ! [ -e "$(names_file)" ]'

# --- import: fresh -------------------------------------------------------
fresh
confbody | bash "$backend" import wg0 >/dev/null 2>&1; import_rc=$?
count="$(find "$FAKE_DIR" -maxdepth 1 -name 'conf.*' | wc -l)"
done_case "fresh import writes exactly one config" '[ "$import_rc" = 0 ] && [ "$count" = 1 ] && [ -e "$FAKE_DIR/conf.wg0" ]'

# --- import: replace, reconnect ok --------------------------------------
fresh
printf '[Interface]\nPrivateKey = k\n' > "$FAKE_DIR/conf.old"; echo old > "$FAKE_DIR/active"
mkdir -p "$XDG_STATE_HOME/omarchy"; printf 'old\tMy Label\n' > "$(names_file)"
confbody | bash "$backend" import wg0 old >/dev/null 2>&1; rc=$?
done_case "replace: old removed, new up, label carried" \
  '[ "$rc" = 0 ] && [ -e "$FAKE_DIR/conf.wg0" ] && ! [ -e "$FAKE_DIR/conf.old" ] \
    && grep -qx wg0 "$FAKE_DIR/active" && grep -q "^wg0	My Label" "$(names_file)"'

# --- import: replace, new refuses to come up -> exit 5 -----------------
fresh
printf '[Interface]\nPrivateKey = k\n' > "$FAKE_DIR/conf.old"; echo old > "$FAKE_DIR/active"
: > "$FAKE_DIR/fail-up.wg0"
confbody | bash "$backend" import wg0 old >/dev/null 2>"$FAKE_DIR/stderr"; rc=$?
done_case "replace, reconnect fails: exit 5, replacement kept, old gone" \
  '[ "$rc" = 5 ] && [ -e "$FAKE_DIR/conf.wg0" ] && ! [ -e "$FAKE_DIR/conf.old" ] && grep -qi "saved" "$FAKE_DIR/stderr"'

# --- import: replace, old delete fails -> rollback --------------------
fresh
printf '[Interface]\nPrivateKey = k\n' > "$FAKE_DIR/conf.old"; echo old > "$FAKE_DIR/active"
: > "$FAKE_DIR/fail-delete.old"
confbody | bash "$backend" import wg0 old >/dev/null 2>&1; rc=$?
done_case "replace, old cannot be removed: rolled back, old restored" \
  '[ "$rc" != 0 ] && [ -e "$FAKE_DIR/conf.old" ] && ! [ -e "$FAKE_DIR/conf.wg0" ] \
    && ! find "$FAKE_DIR" -maxdepth 1 -name "conf..import*" | grep -q . && grep -qx old "$FAKE_DIR/active"'

# --- import: replace, staged config vanishes after old removed -> exit 6
fresh
printf '[Interface]\nPrivateKey = k\n' > "$FAKE_DIR/conf.old"; echo old > "$FAKE_DIR/active"
: > "$FAKE_DIR/fail-getconf-any"
confbody | bash "$backend" import wg0 old >/dev/null 2>"$FAKE_DIR/stderr"; rc=$?
done_case "replace, staged config unreadable after old removed: exit 6" \
  '[ "$rc" = 6 ] && ! [ -e "$FAKE_DIR/conf.old" ] && grep -qi "check /etc/amnezia" "$FAKE_DIR/stderr"'

# --- delete drops the sidecar label ------------------------------------
fresh
printf '[Interface]\nPrivateKey = k\n' > "$FAKE_DIR/conf.wg0"
mkdir -p "$XDG_STATE_HOME/omarchy"; printf 'wg0\tGone\nkeep\tKept\n' > "$(names_file)"
bash "$backend" delete wg0 >/dev/null 2>&1; rc=$?
done_case "delete removes the config and its label, leaving others" \
  '[ "$rc" = 0 ] && ! [ -e "$FAKE_DIR/conf.wg0" ] && ! grep -q "^wg0	" "$(names_file)" && grep -q "^keep	Kept" "$(names_file)"'

# --- QR cleanup ---------------------------------------------------------
fresh
printf '[Interface]\nPrivateKey = k\n' > "$FAKE_DIR/conf.wg0"
: > "$FAKE_DIR/fail-qr"
bash "$backend" qr-png wg0 >/dev/null 2>&1; qr_rc=$?
png_count="$(find "$XDG_RUNTIME_DIR" -name 'omazia-qr.*.png' | wc -l)"
done_case "failed QR encoding removes the private-key PNG" '[ "$qr_rc" != 0 ] && [ "$png_count" = 0 ]'

fresh
printf '[Interface]\nPrivateKey = k\n' > "$FAKE_DIR/conf.wg0"
: > "$FAKE_DIR/slow-qr"
bash "$backend" qr-png wg0 >/dev/null 2>&1 & pid=$!
sleep 0.2; kill -TERM "$pid"; wait "$pid"; sig_rc=$?
png_count="$(find "$XDG_RUNTIME_DIR" -name 'omazia-qr.*.png' | wc -l)"
done_case "interrupted QR encoding removes the private-key PNG" '[ "$sig_rc" != 0 ] && [ "$png_count" = 0 ]'

fresh
live="$XDG_RUNTIME_DIR/omazia-qr.$$.aaaaaa.png"; dead="$XDG_RUNTIME_DIR/omazia-qr.99999999.bbbbbb.png"
printf PNG > "$live"; printf PNG > "$dead"
bash "$backend" cleanup-runtime >/dev/null 2>&1; c_rc=$?
done_case "runtime cleanup keeps the live QR owner and removes the dead one" \
  '[ "$c_rc" = 0 ] && [ -f "$live" ] && ! [ -e "$dead" ]'

# --- editor secret files ---------------------------------------------------
fresh
printf '[Interface]\nPrivateKey = k\n' > "$FAKE_DIR/conf.wg0"
: > "$FAKE_DIR/slow-zenity"
bash "$backend" edit wg0 tunnel </dev/null >/dev/null 2>&1 & epid=$!
for _ in $(seq 1 20); do [ -f "$FAKE_DIR/edit-buffer-path" ] && break; sleep 0.05; done
edit_count="$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -name 'omazia-edit.*' | wc -l)"
bpath="$(cat "$FAKE_DIR/edit-buffer-path" 2>/dev/null || true)"
bmode="$(stat -Lc '%a' "$bpath" 2>/dev/null || true)"
kill -TERM "$epid"; wait "$epid"; e_rc=$?
post_count="$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -name 'omazia-edit.*' | wc -l)"
done_case "editor secrets use private runtime files, cleaned on signal" \
  '[ "$e_rc" != 0 ] && [ "$edit_count" = 2 ] && [ "$post_count" = 0 ] && [ "$bmode" = 600 ] && [[ "$bpath" == "$XDG_RUNTIME_DIR"/* ]]'

fresh
printf '[Interface]\nPrivateKey = k\n' > "$FAKE_DIR/conf.wg0"
: > "$FAKE_DIR/fail-second-mktemp"
bash "$backend" edit wg0 tunnel </dev/null >/dev/null 2>&1; sm_rc=$?
edit_count="$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -name 'omazia-edit.*' | wc -l)"
done_case "failed second editor mktemp cleans the first secret file" \
  '[ "$sm_rc" != 0 ] && [ "$edit_count" = 0 ]'

fresh
live="$XDG_RUNTIME_DIR/omazia-edit.$$.cccccc"; dead="$XDG_RUNTIME_DIR/omazia-edit.99999999.dddddd"
printf secret > "$live"; printf secret > "$dead"
bash "$backend" cleanup-runtime >/dev/null 2>&1; ec_rc=$?
done_case "runtime cleanup keeps the live editor owner and removes the dead one" \
  '[ "$ec_rc" = 0 ] && [ -f "$live" ] && ! [ -e "$dead" ]'

echo "----"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
