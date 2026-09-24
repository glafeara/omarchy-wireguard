#!/bin/bash
# Tests for backend.sh up: the additive connect behind the multiTunnel
# setting. It must never take another tunnel down, and it refuses the two
# combinations that would: a shared interface name (NetworkManager would
# hand the device over, silently deactivating the other profile) and two
# tunnels that both claim a whole address family.
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
  bash "$backend" up TARGET >/dev/null 2>"$FAKE_DIR/stderr"
  local got=$?
  local ok=1
  [ "$got" = "$want" ] || { echo "  exit: want $want got $got"; ok=0; }
  eval "$check" || ok=0
  if [ "$ok" = 1 ]; then echo "PASS $name"; pass=$((pass+1))
  else echo "FAIL $name"; sed 's/^/    /' "$FAKE_DIR/log"; sed 's/^/    stderr: /' "$FAKE_DIR/stderr"; fail=$((fail+1)); fi
  rm -rf "$FAKE_DIR"
}

active_is() { [ "$(sort "$FAKE_DIR/active")" = "$(printf '%s\n' "$@" | sort)" ] || { echo "  active: $(tr '\n' ' ' < "$FAKE_DIR/active") want: $*"; return 1; }; }
never_down() { ! grep -q "connection down" "$FAKE_DIR/log" || { echo "  a tunnel was taken down"; return 1; }; }
never_up() { ! grep -q "connection up" "$FAKE_DIR/log" || { echo "  activation was attempted"; return 1; }; }
said() { grep -q "$1" "$FAKE_DIR/stderr" || { echo "  stderr lacks: $1"; return 1; }; }

peers() { # uuid allowed-ips [second-peer-allowed-ips]
  local line="wireguard.peers:AAAA= allowed-ips=$2 endpoint=203.0.113.7\\:1234"
  [ -n "${3:-}" ] && line="$line, BBBB= allowed-ips=$3 endpoint=203.0.113.8\\:1234"
  printf '%s\n' "$line" > "$FAKE_DIR/props.$1"
}
# TARGET on wg-t, OLD on wg-o and already up.
beside() { # target-allowed old-allowed
  echo wg-t > "$FAKE_DIR/ifname.TARGET"; peers TARGET "$1"
  echo OLD > "$FAKE_DIR/active"; echo wg-o > "$FAKE_DIR/ifname.OLD"; peers OLD "$2"
}

s_fresh() { echo wg-t > "$FAKE_DIR/ifname.TARGET"; peers TARGET 0.0.0.0/0; }
run_case "nothing active: up" 0 s_fresh 'active_is TARGET'

s_split() { beside 10.0.0.0/8 192.168.5.0/24; }
run_case "beside another tunnel: both stay up" 0 s_split 'active_is OLD TARGET && never_down'

s_full_split() { beside 0.0.0.0/0 192.168.5.0/24; }
run_case "full tunnel beside a split one: allowed" 0 s_full_split 'active_is OLD TARGET && never_down'

s_same_if() { beside 10.0.0.0/8 192.168.5.0/24; echo wg-t > "$FAKE_DIR/ifname.OLD"; }
run_case "same interface name: refused before activation" 1 s_same_if 'active_is OLD && never_up && said "wg-t"'

s_empty_if() { beside 10.0.0.0/8 192.168.5.0/24; : > "$FAKE_DIR/ifname.TARGET"; }
run_case "unset interface name: refused as unknowable" 1 s_empty_if 'active_is OLD && never_up'

s_full4() { beside 0.0.0.0/0 0.0.0.0/0; }
run_case "two full IPv4 tunnels: refused" 1 s_full4 'active_is OLD && never_up && said "OLD"'

s_halves() { beside "0.0.0.0/1;128.0.0.0/1" 0.0.0.0/0; }
run_case "/1 halves count as full" 1 s_halves 'active_is OLD && never_up'

s_second_peer() { beside 10.0.0.0/8 0.0.0.0/0 0.0.0.0/0; peers TARGET 10.0.0.0/8 0.0.0.0/0; }
run_case "full route on the second peer counts" 1 s_second_peer 'active_is OLD && never_up'

s_full6() { beside '\:\:/0' '\:\:/0'; }
run_case "two full IPv6 tunnels (escaped): refused" 1 s_full6 'active_is OLD && never_up'

s_v6_halves() { beside '\:\:/1;8000\:\:/1' '\:\:/0'; }
run_case "IPv6 /1 halves count as full" 1 s_v6_halves 'active_is OLD && never_up'

s_mixed_family() { beside 0.0.0.0/0 '\:\:/0'; }
run_case "full IPv4 beside full IPv6 only: allowed" 0 s_mixed_family 'active_is OLD TARGET && never_down'

s_no_peer_routes() {
  beside 0.0.0.0/0 0.0.0.0/0
  echo 'wireguard.peer-routes:no' >> "$FAKE_DIR/props.OLD"
}
run_case "peer-routes off claims nothing" 0 s_no_peer_routes 'active_is OLD TARGET && never_down'

# Two profiles cut from one config (full and LAN-only) share a key, an
# address and a server: the server sees one peer, so they cannot both be up.
s_same_addr() {
  beside 198.51.100.0/24 0.0.0.0/0
  echo 'ipv4.addresses:10.99.0.2/24' >> "$FAKE_DIR/props.TARGET"
  echo 'ipv4.addresses:10.99.0.2/24' >> "$FAKE_DIR/props.OLD"
}
run_case "same client on the same server: refused" 1 s_same_addr 'active_is OLD && never_up && said "10.99.0.2"'

s_same_addr6() {
  beside 198.51.100.0/24 10.0.0.0/8
  echo 'ipv6.addresses:fd00\:\:4/64' >> "$FAKE_DIR/props.TARGET"
  echo 'ipv6.addresses:fd00\:\:5/64, fd00\:\:4/128' >> "$FAKE_DIR/props.OLD"
}
run_case "same IPv6 address among several: refused" 1 s_same_addr6 'active_is OLD && never_up && said "fd00::4"'

s_other_addr() {
  beside 198.51.100.0/24 10.0.0.0/8
  echo 'ipv4.addresses:10.99.0.2/24' >> "$FAKE_DIR/props.TARGET"
  echo 'ipv4.addresses:10.99.0.3/24' >> "$FAKE_DIR/props.OLD"
}
run_case "different addresses in one subnet: allowed" 0 s_other_addr 'active_is OLD TARGET && never_down'

# Some providers give every client the same address; with different servers
# that is two peers, not one.
s_same_addr_other_server() {
  beside 198.51.100.0/24 10.0.0.0/8
  printf '%s\n' 'wireguard.peers:CCCC= allowed-ips=198.51.100.0/24 endpoint=203.0.113.9\:1234' > "$FAKE_DIR/props.TARGET"
  echo 'ipv4.addresses:10.99.0.2/32' >> "$FAKE_DIR/props.TARGET"
  echo 'ipv4.addresses:10.99.0.2/32' >> "$FAKE_DIR/props.OLD"
}
run_case "same address, different server: allowed" 0 s_same_addr_other_server 'active_is OLD TARGET && never_down'

# A check that cannot read the other tunnel must not pass by default.
s_unreadable() { beside 0.0.0.0/0 0.0.0.0/0; rm "$FAKE_DIR/props.OLD"; }
run_case "unreadable active tunnel: refused" 1 s_unreadable 'active_is OLD && never_up && said "Could not read"'

# OLD was renamed to wg-o after activation but still runs on wg-t.
s_live_device() { beside 10.0.0.0/8 198.51.100.0/24; echo wg-t > "$FAKE_DIR/device.OLD"; }
run_case "interface in use under an old name: refused" 1 s_live_device 'active_is OLD && never_up && said "wg-t"'

# A disabled family gets no routes, whatever allowed-ips says.
s_v6_disabled() {
  beside '\:\:/0' '\:\:/0'
  echo 'ipv6.method:disabled' >> "$FAKE_DIR/props.OLD"
}
run_case "IPv6 disabled claims no IPv6: allowed" 0 s_v6_disabled 'active_is OLD TARGET && never_down'

# Real nmcli does not escape colons inside these values.
s_full6_raw() { beside '::/0' '::/0'; }
run_case "two full IPv6 tunnels (unescaped): refused" 1 s_full6_raw 'active_is OLD && never_up'

s_upfail() { beside 10.0.0.0/8 192.168.5.0/24; : > "$FAKE_DIR/fail-up.TARGET"; }
run_case "activation fails: the other tunnel is untouched" 1 s_upfail 'active_is OLD && never_down && said "activation"'

s_already() { beside 0.0.0.0/0 0.0.0.0/0; printf 'OLD\nTARGET\n' > "$FAKE_DIR/active"; }
run_case "already active: no-op" 0 s_already 'active_is OLD TARGET && never_up && never_down'

echo "----"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
