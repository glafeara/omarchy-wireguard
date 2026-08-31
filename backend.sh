#!/bin/bash
# AmneziaWG backend for the Omazia bar widget.
#
# AmneziaWG has no usable NetworkManager plugin, so tunnels are driven with
# the AmneziaWG userspace tools (`awg`, `awg-quick`). Those need root, so
# every privileged operation goes through a single small root helper
# (helper/omarchy-amneziawg-helper) invoked via `pkexec` (or `sudo` when
# OMAWG_PRIV=sudo). A polkit policy grants the active local session
# passwordless use — the same "an active session controls its own VPN
# without a password" posture NetworkManager + polkit gave us.
#
# Tunnels are addressed by their **interface name** everywhere (= the conf
# basename, /etc/amnezia/amneziawg/<iface>.conf, [A-Za-z0-9_=+.-]{1,15}).
# A user-side display-name sidecar (~/.local/state/omarchy/amneziawg-names,
# "iface<TAB>label") keeps rename cosmetic and duplicate-checked.
#
# The helper re-validates every config body it is handed: awg-quick *does*
# eval PostUp/PreUp/... hooks as root, so the helper refuses a body that
# carries one even though this script never emits them.
#
# Secrets (PrivateKey, PresharedKey) are fed to the helper on stdin, never
# as arguments — argv is world-readable in /proc.
#
# Mutating commands serialize on a per-user flock: the bar builds one widget
# instance per monitor, so two connects can race each other.
#
# Commands:
#   status                      list tunnels + active interface names
#   details <iface>             key=value facts for the detail grid
#   connect <iface>             transactional exclusive switch (exit 0 /
#                               20 restored / 21 unknown state)
#   down <iface>                deactivate one tunnel
#   down-all                    deactivate every active tunnel
#   delete <iface>              delete a tunnel (deactivates it first)
#   rename <iface> <label>      set the display label (sidecar only, no root)
#   import <iface> [old] [file] build a tunnel from wg-quick/awg-quick config
#                               text (stdin, or [file]); replaces [old],
#                               carrying its label, reconnecting if it was up
#                               (exit 5 saved-not-reconnected, 6 manual
#                               recovery)
#   export <iface>              print the tunnel as awg-quick config text
#   export-file <iface> <path>  write the config to a file, mode 0600
#   qr-png <iface>              render the config as a QR PNG in XDG_RUNTIME_DIR
#   cleanup-runtime             remove QR/editor files owned by a dead shell
#   edit <iface> <name>         zenity editor round-trip (seed text on stdin)
#   notify-drop <iface> <name>  decide whether a deactivation was external

set -u
set -o pipefail
set -f
export LC_ALL=C
umask 077

die() { printf '%s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is not installed"; }

# ---------------------------------------------------------------------------
# Privilege wrapper: every root operation is one verb of the helper.
# OMAWG_PRIV=pkexec (default) prompts nothing on an active local session
# thanks to the polkit policy; =sudo uses the shipped sudoers drop-in;
# =direct runs the helper as-is (the test suite points OMAWG_HELPER at a
# fake and never needs root).
# ---------------------------------------------------------------------------
OMAWG_PRIV="${OMAWG_PRIV:-pkexec}"
HELPER="${OMAWG_HELPER:-/usr/local/lib/omarchy-amneziawg-helper}"

PRIV() {
  case "$OMAWG_PRIV" in
    pkexec) need pkexec; pkexec "$HELPER" "$@" ;;
    sudo)   need sudo;   sudo -n "$HELPER" "$@" ;;
    direct) "$HELPER" "$@" ;;
    *) die "Unknown OMAWG_PRIV: $OMAWG_PRIV" ;;
  esac
}

RUNTIME_DIR=""

ensure_runtime_dir() {
  [ -n "$RUNTIME_DIR" ] && return 0
  local dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" mode
  [ -n "$dir" ] && [ -d "$dir" ] && [ ! -L "$dir" ] && [ -O "$dir" ] ||
    die "A private XDG_RUNTIME_DIR is required for AmneziaWG state"
  mode="$(stat -Lc '%a' -- "$dir" 2>/dev/null)" ||
    die "Cannot inspect XDG_RUNTIME_DIR"
  case "$mode" in
    ''|*[!0-7]*) die "XDG_RUNTIME_DIR has unsafe permissions" ;;
  esac
  [ $((8#$mode & 0077)) -eq 0 ] ||
    die "XDG_RUNTIME_DIR has unsafe permissions"
  RUNTIME_DIR="$dir"
}

lock() {
  need flock
  ensure_runtime_dir
  exec 9>>"$RUNTIME_DIR/omarchy-amneziawg.$(id -u).lock" || die "Cannot open the lock file"
  flock -w 30 9 || die "Another AmneziaWG operation is already running"
}

# ---------------------------------------------------------------------------
# Display-name sidecar: rename is cosmetic and never touches the conf. Lines
# are "iface<TAB>label".
# ---------------------------------------------------------------------------
names_file() {
  printf '%s/omarchy/amneziawg-names' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

ensure_state_dir() {
  local d
  d="$(dirname -- "$(names_file)")"
  [ -d "$d" ] || mkdir -p -- "$d" || die "Cannot create $d"
}

# ---------------------------------------------------------------------------
# Intent markers: immediately before this script deactivates a tunnel it
# records the iface, under the flock; notify-drop consults the file to tell
# a user-initiated drop from an external one. A marker is cleared the moment
# the same iface comes up again. The TTL is only a garbage-collection
# backstop; it must exceed the widget's slowest poll (refreshIntervalSec
# caps at 3600).
# ---------------------------------------------------------------------------
INTENT_TTL=7200

runtime_state() {
  ensure_runtime_dir
  printf '%s/omarchy-amneziawg.%s.%s' "$RUNTIME_DIR" "$(id -u)" "$1"
}

mark_down() { # <iface>
  local iface="$1" f now u t keep=""
  f="$(runtime_state intent)"
  now="$(date +%s)"
  if [ -f "$f" ]; then
    while read -r u t; do
      case "$t" in ''|*[!0-9]*) continue ;; esac
      [ "$u" = "$iface" ] && continue
      [ $((now - t)) -gt "$INTENT_TTL" ] && continue
      keep="$keep$u $t"$'\n'
    done < "$f"
  fi
  printf '%s' "$keep$iface $now"$'\n' > "$f" 2>/dev/null || true
}

# clear_intent <iface> [observed-epoch]: drop the iface's marker. With an
# observation timestamp, only a marker strictly older is dropped (a tie
# keeps the marker — the conservative miss is a suppressed toast).
clear_intent() {
  local iface="$1" obs="${2:-}" f now u t keep=""
  f="$(runtime_state intent)"
  now="$(date +%s)"
  [ -f "$f" ] || return 0
  case "$obs" in *[!0-9]*) obs="" ;; esac
  while read -r u t; do
    case "$t" in ''|*[!0-9]*) continue ;; esac
    [ $((now - t)) -gt "$INTENT_TTL" ] && continue
    if [ "$u" = "$iface" ]; then
      if [ -z "$obs" ] || [ "$t" -lt "$obs" ]; then continue; fi
    fi
    keep="$keep$u $t"$'\n'
  done < "$f"
  printf '%s' "$keep" > "$f" 2>/dev/null || true
}

cmd_notify_drop() {
  local iface="$1" name="$2" f now t u
  now="$(date +%s)"
  f="$(runtime_state intent)"
  if [ -f "$f" ]; then
    while read -r u t; do
      case "$t" in ''|*[!0-9]*) continue ;; esac
      if [ "$u" = "$iface" ] && [ $((now - t)) -le "$INTENT_TTL" ]; then exit 1; fi
    done < "$f"
  fi
  f="$(runtime_state notified)"
  if [ -f "$f" ]; then
    t="$(cat "$f" 2>/dev/null)" || t=0
    case "$t" in ''|*[!0-9]*) t=0 ;; esac
    [ $((now - t)) -lt 30 ] && exit 0
  fi
  printf '%s' "$now" > "$f" 2>/dev/null || true
  command -v notify-send >/dev/null 2>&1 || exit 0
  notify-send -a Omazia "Omazia" "Tunnel $name was deactivated" 2>/dev/null || true
  exit 0
}

valid_key() { printf '%s\n' "$1" | awg pubkey >/dev/null 2>&1; }

is_num() { [[ "$1" =~ ^[0-9]+$ ]]; }

valid_iface() { [[ "$1" =~ ^[A-Za-z0-9_=+.-]{1,15}$ ]] && [ "$1" != "." ] && [ "$1" != ".." ]; }

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  printf '%s' "${s%"${s##*[![:space:]]}"}"
}

# ---------------------------------------------------------------------------
# helper `list` output: active interface names, a "---" line, then every
# stored conf basename.
# ---------------------------------------------------------------------------
active_ifaces() {
  local l
  l="$(PRIV list)" || return 1
  printf '%s\n' "$l" | awk '/^---$/{exit} NF'
}

all_tunnels() {
  local l
  l="$(PRIV list)" || return 1
  printf '%s\n' "$l" | awk 'f&&NF{print} /^---$/{f=1}'
}

# ---------------------------------------------------------------------------
# status: one section the QML parser consumes.
#   iface:amneziawg:device:label      (device = iface when up, else empty)
#   ---
#   <active iface>                     (one per line)
# ---------------------------------------------------------------------------
cmd_status() {
  local raw active confs line part=head
  raw="$(PRIV list)" || exit 1
  active="" confs=""
  while IFS= read -r line; do
    if [ "$line" = "---" ]; then part=confs; continue; fi
    [ -n "$line" ] || continue
    case "$part" in
      head) active="$active$line"$'\n' ;;
      confs) confs="$confs$line"$'\n' ;;
    esac
  done <<< "$raw"

  declare -A LABELS
  local f i l
  f="$(names_file)"
  if [ -f "$f" ]; then
    while IFS=$'\t' read -r i l || [ -n "$i" ]; do
      [ -n "$i" ] && LABELS[$i]="$l"
    done < "$f"
  fi

  local iface dev label
  for iface in $confs; do
    dev=""
    printf '%s\n' "$active" | grep -qxF "$iface" && dev="$iface"
    # The QML parser splits on the first three colons and takes the label
    # verbatim; escape any colon or backslash a label happens to contain.
    label="${LABELS[$iface]:-$iface}"
    label="${label//\\/\\\\}"
    label="${label//:/\\:}"
    printf '%s:amneziawg:%s:%s\n' "$iface" "$dev" "$label"
  done
  echo ---
  for iface in $active; do printf '%s\n' "$iface"; done
}

# Read-only facts for the panel's detail grid. Live values from
# /sys/class/net win over the stored conf; the peer endpoint / allowed-ips /
# count come from `awg show <iface> dump`.
cmd_details() {
  local iface="$1"
  valid_iface "$iface" || die "Invalid interface name: $iface"
  local dump conf line key value item
  local addr4="" addr6="" dns4="" dns6="" mtu="" live
  dump="$(PRIV dump "$iface" 2>/dev/null)" || dump=""
  conf="$(PRIV getconf "$iface" 2>/dev/null)" || conf=""
  [ -z "$dump" ] && [ -z "$conf" ] && die "No such tunnel: $iface"

  while IFS= read -r line; do
    line="${line%%#*}"
    key="$(trim "${line%%=*}")"
    [ "$key" = "$(trim "$line")" ] && continue
    value="$(trim "${line#*=}")"
    case "${key,,}" in
      address)
        for item in ${value//,/ }; do
          case "$item" in *:*) addr6="${addr6:+$addr6,}$item" ;; *) addr4="${addr4:+$addr4,}$item" ;; esac
        done ;;
      dns)
        for item in ${value//,/ }; do
          if [[ "$item" == *:* ]]; then dns6="${dns6:+$dns6,}$item"
          elif [[ "$item" =~ ^[0-9.]+$ ]]; then dns4="${dns4:+$dns4,}$item"; fi
        done ;;
      mtu) mtu="$value" ;;
    esac
  done <<< "$conf"

  if [ -d "/sys/class/net/$iface" ]; then
    live="$(ip -o -4 addr show dev "$iface" 2>/dev/null | awk '{print $4; exit}')"
    [ -n "$live" ] && addr4="$live"
    live="$(ip -o -6 addr show dev "$iface" scope global 2>/dev/null | awk '{print $4; exit}')"
    [ -n "$live" ] && addr6="$live"
    live="$(cat "/sys/class/net/$iface/mtu" 2>/dev/null)" && [ -n "$live" ] && mtu="$live"
  fi

  local n=0 endpoint="" allowed="" pub psk ep aips rest
  if [ -n "$dump" ]; then
    while read -r pub psk ep aips rest; do
      n=$((n + 1))
      [ "$n" -le 1 ] && continue
      if [ "$n" -eq 2 ]; then
        [ -n "$ep" ] && [ "$ep" != "(none)" ] && endpoint="$ep"
        [ -n "$aips" ] && [ "$aips" != "(none)" ] && allowed="${aips//,/, }"
      fi
    done <<< "$dump"
  fi
  local peers=0
  [ "$n" -gt 1 ] && peers=$((n - 1))

  local dns="$dns4"
  [ -n "$dns6" ] && dns="${dns:+$dns,}$dns6"
  printf 'ip=%s\n' "${addr4%%,*}"
  printf 'ip6=%s\n' "${addr6%%,*}"
  printf 'endpoint=%s\n' "$endpoint"
  printf 'allowed=%s\n' "$allowed"
  printf 'dns=%s\n' "${dns//,/, }"
  printf 'mtu=%s\n' "$mtu"
  printf 'peers=%s\n' "$peers"
}

# Transactional exclusive switch. Interface names are the identity, so they
# are always known and distinct: make-before-break (the kernel is fine with
# several awg interfaces at once) unless the target name collides with an
# active one (a re-import edge), where the old one must clear the way first.
cmd_connect() {
  local target="$1" snapshot u out
  valid_iface "$target" || die "Invalid interface name: $target"
  snapshot="$(active_ifaces)" || die "Could not list active tunnels"

  local target_was_active=0 others=""
  for u in $snapshot; do
    if [ "$u" = "$target" ]; then target_was_active=1
    else others="$others$u "; fi
  done
  [ "$target_was_active" = 1 ] && [ -z "$others" ] && exit 0

  local overlap=1 u2
  if [ "$target_was_active" = 0 ]; then
    for u2 in $others; do [ "$u2" = "$target" ] && overlap=0; done
  fi

  restore() {
    local ok=0 u now
    now="$(active_ifaces)" || return 1
    if [ "$target_was_active" = 0 ] && printf '%s\n' "$now" | grep -qxF "$target"; then
      mark_down "$target"
      PRIV down "$target" >/dev/null 2>&1 || { clear_intent "$target"; ok=1; }
      now="$(active_ifaces)" || return 1
    fi
    for u in $snapshot; do
      printf '%s\n' "$now" | grep -qxF "$u" && continue
      if PRIV up "$u" >/dev/null 2>&1; then clear_intent "$u"; else ok=1; fi
    done
    return "$ok"
  }

  fail_switch() {
    printf '%s\n' "$1" >&2
    if restore; then
      echo "The previous tunnels were restored" >&2
      exit 20
    fi
    echo "Restoring the previous tunnels failed too — check your connections" >&2
    exit 21
  }

  if [ "$target_was_active" = 0 ] && [ "$overlap" = 0 ]; then
    for u in $others; do
      mark_down "$u"
      out="$(PRIV down "$u" 2>&1)" || {
        clear_intent "$u"
        fail_switch "Could not deactivate the previous tunnel: $out"
      }
    done
    out="$(PRIV up "$target" 2>&1)" ||
      fail_switch "Could not activate the tunnel: $out"
    clear_intent "$target"
  else
    if [ "$target_was_active" = 0 ]; then
      out="$(PRIV up "$target" 2>&1)" ||
        fail_switch "Could not activate the tunnel: $out"
      clear_intent "$target"
    fi
    for u in $others; do
      mark_down "$u"
      out="$(PRIV down "$u" 2>&1)" || {
        clear_intent "$u"
        fail_switch "Could not deactivate the previous tunnel: $out"
      }
    done
  fi
}

cmd_down() {
  valid_iface "$1" || die "Invalid interface name: $1"
  mark_down "$1"
  PRIV down "$1" || { clear_intent "$1"; exit 1; }
}

cmd_down_all() {
  local rc=0 u active
  active="$(active_ifaces)" || die "Could not list active tunnels"
  for u in $active; do
    mark_down "$u"
    PRIV down "$u" || { clear_intent "$u"; rc=1; }
  done
  exit "$rc"
}

cmd_delete() {
  valid_iface "$1" || die "Invalid interface name: $1"
  mark_down "$1"
  PRIV delconf "$1" || { clear_intent "$1"; exit 1; }
  drop_label "$1"
}

# ---------------------------------------------------------------------------
# rename: sidecar only. No helper, no privilege. Trim, single line, refuse a
# label that collides with another tunnel's label or with any interface name.
# ---------------------------------------------------------------------------
sidecar_rewrite() { # <iface> <label|"">   ("" deletes the line)
  local iface="$1" label="$2" f keep="" ln tmp
  f="$(names_file)"
  ensure_state_dir
  if [ -f "$f" ]; then
    while IFS= read -r ln || [ -n "$ln" ]; do
      [ -n "$ln" ] || continue
      case "$ln" in "$iface"$'\t'*) continue ;; esac
      keep="$keep$ln"$'\n'
    done < "$f"
  fi
  [ -n "$label" ] && keep="$keep$iface"$'\t'"$label"$'\n'
  tmp="$(mktemp -- "$f.XXXXXX")" || die "Cannot write the name sidecar"
  printf '%s' "$keep" > "$tmp" && mv -f -- "$tmp" "$f" || { rm -f -- "$tmp"; die "Cannot write the name sidecar"; }
}

drop_label() { # best-effort
  local f
  f="$(names_file)"
  [ -f "$f" ] || return 0
  sidecar_rewrite "$1" "" 2>/dev/null || true
}

cmd_rename() {
  local iface="$1" label="$2" f i l t
  valid_iface "$iface" || die "Invalid interface name: $iface"
  label="$(trim "$label")"
  [ -n "$label" ] || die "The new name must not be empty"
  case "$label" in *$'\n'*) die "The name must be a single line" ;; esac

  local tunnels
  tunnels="$(all_tunnels)" || die "Could not list existing tunnels"
  for t in $tunnels; do
    [ "$t" != "$iface" ] && [ "$t" = "$label" ] &&
      die "A tunnel named $label already exists"
  done
  f="$(names_file)"
  if [ -f "$f" ]; then
    while IFS=$'\t' read -r i l || [ -n "$i" ]; do
      [ "$i" != "$iface" ] && [ "$l" = "$label" ] &&
        die "A tunnel named $label already exists"
    done < "$f"
  fi
  sidecar_rewrite "$iface" "$label"
}

# ---------------------------------------------------------------------------
# import: parse awg-quick/wg-quick config text, emit canonical text, hand it
# to the helper. Hooks (PreUp/PostUp/...) are rejected with a clear message.
# AmneziaWG obfuscation keys (Jc Jmin Jmax S1..S4 H1..H4 I1..I5) pass through
# verbatim under canonical casing.
# ---------------------------------------------------------------------------
PK="" PORT="" MTU="" FWMARK="" TABLE=""
ADDR4="" ADDR6="" DNS4="" DNS6="" DNSSEARCH=""
AWG_PARAMS=()
PEERS=()
P_PUB="" P_PSK="" P_ALLOWED="" P_ENDPOINT="" P_KA=""

append() { # append <varname> <value> [separator]
  local -n ref="$1"
  ref="${ref:+$ref${3-,}}$2"
}

flush_peer() {
  if [ -z "$P_PUB$P_PSK$P_ALLOWED$P_ENDPOINT$P_KA" ]; then return 0; fi
  [ -n "$P_PUB" ] || die "A [Peer] section has no PublicKey"
  local s="PublicKey = $P_PUB"
  [ -n "$P_PSK" ] && s+=$'\n'"PresharedKey = $P_PSK"
  [ -n "$P_ALLOWED" ] && s+=$'\n'"AllowedIPs = $P_ALLOWED"
  [ -n "$P_ENDPOINT" ] && s+=$'\n'"Endpoint = $P_ENDPOINT"
  [ -n "$P_KA" ] && s+=$'\n'"PersistentKeepalive = $P_KA"
  PEERS+=("$s")
  P_PUB="" P_PSK="" P_ALLOWED="" P_ENDPOINT="" P_KA=""
}

parse_config() {
  local section="" lineno=0 line key value item canon
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line="${line%%#*}"
    line="$(trim "$line")"
    [ -z "$line" ] && continue
    if [[ "$line" == \[*\] ]]; then
      value="${line#[}"; value="${value%]}"
      case "${value,,}" in
        interface) flush_peer; section=interface ;;
        peer) flush_peer; section=peer ;;
        *) die "Unknown section [$value] on line $lineno" ;;
      esac
      continue
    fi
    key="$(trim "${line%%=*}")"
    value="$(trim "${line#*=}")"
    [ "$key" = "$line" ] && die "Line $lineno is not 'Key = value'"
    [ -n "$value" ] || die "$key on line $lineno has no value"
    case "$section" in
      interface)
        case "${key,,}" in
          privatekey)
            valid_key "$value" || die "Invalid PrivateKey — not a valid key"
            PK="$value" ;;
          address)
            for item in ${value//,/ }; do
              case "$item" in
                *:*) append ADDR6 "$item" ;;
                *) append ADDR4 "$item" ;;
              esac
            done ;;
          dns)
            for item in ${value//,/ }; do
              if [[ "$item" == *:* ]]; then append DNS6 "$item"
              elif [[ "$item" =~ ^[0-9.]+$ ]]; then append DNS4 "$item"
              else append DNSSEARCH "$item"; fi
            done ;;
          listenport)
            is_num "$value" || die "Invalid ListenPort: $value"
            PORT="$value" ;;
          mtu)
            is_num "$value" || die "Invalid MTU: $value"
            MTU="$value" ;;
          fwmark)
            FWMARK="$value" ;;
          table)
            TABLE="$value" ;;
          jc|jmin|jmax)
            is_num "$value" || die "Invalid $key: $value"
            canon="J${key:1}"
            AWG_PARAMS+=("$canon = $value") ;;
          s1|s2|s3|s4|h1|h2|h3|h4)
            is_num "$value" || die "Invalid $key: $value"
            canon="${key^^}"
            AWG_PARAMS+=("$canon = $value") ;;
          i1|i2|i3|i4|i5)
            [[ "$value" =~ ^[0-9a-zA-Z\<\>x[:space:]]+$ ]] ||
              die "Invalid $key value: unexpected characters"
            [ "${#value}" -le 1024 ] || die "$key value is too long"
            canon="${key^^}"
            AWG_PARAMS+=("$canon = $value") ;;
          preup|postup|predown|postdown)
            die "$key is not supported: awg-quick would run it as root" ;;
          saveconfig)
            die "SaveConfig is not supported" ;;
          *)
            die "Unsupported [Interface] key: $key" ;;
        esac ;;
      peer)
        case "${key,,}" in
          publickey)
            valid_key "$value" || die "Invalid PublicKey — not a valid key"
            P_PUB="$value" ;;
          presharedkey)
            valid_key "$value" || die "Invalid PresharedKey — not a valid key"
            P_PSK="$value" ;;
          allowedips)
            for item in ${value//,/ }; do
              append P_ALLOWED "$item" ", "
            done ;;
          endpoint)
            P_ENDPOINT="$value" ;;
          persistentkeepalive)
            is_num "$value" || die "Invalid PersistentKeepalive: $value"
            P_KA="$value" ;;
          *)
            die "Unsupported [Peer] key: $key" ;;
        esac ;;
      *)
        die "Line $lineno appears before any [Interface] or [Peer] section" ;;
    esac
  done
  flush_peer
  [ -n "$PK" ] || die "Not an AmneziaWG config (no PrivateKey)"
}

emit_conf() {
  local j i
  echo "[Interface]"
  echo "PrivateKey = $PK"
  j="$ADDR4"
  [ -n "$ADDR6" ] && j="${j:+$j, }$ADDR6"
  [ -n "$j" ] && echo "Address = $j"
  j="$DNS4"
  [ -n "$DNS6" ] && j="${j:+$j, }$DNS6"
  [ -n "$DNSSEARCH" ] && j="${j:+$j, }$DNSSEARCH"
  [ -n "$j" ] && echo "DNS = $j"
  [ -n "$PORT" ] && echo "ListenPort = $PORT"
  [ -n "$MTU" ] && echo "MTU = $MTU"
  [ -n "$FWMARK" ] && echo "FwMark = $FWMARK"
  [ -n "$TABLE" ] && echo "Table = $TABLE"
  for ((i = 0; i < ${#AWG_PARAMS[@]}; i++)); do printf '%s\n' "${AWG_PARAMS[$i]}"; done
  for ((i = 0; i < ${#PEERS[@]}; i++)); do
    echo
    echo "[Peer]"
    printf '%s\n' "${PEERS[$i]}"
  done
}

carry_label() { # <old> <new>
  local f i l lbl=""
  f="$(names_file)"
  [ -f "$f" ] || return 0
  while IFS=$'\t' read -r i l || [ -n "$i" ]; do
    [ "$i" = "$1" ] && lbl="$l"
  done < "$f"
  [ -n "$lbl" ] || return 0
  sidecar_rewrite "$1" ""
  sidecar_rewrite "$2" "$lbl"
}

cmd_import() {
  local iface="$1" old="${2:-}" src="${3:-}"
  need awg
  valid_iface "$iface" || die "Invalid interface name: $iface"
  if [ -n "$old" ]; then
    valid_iface "$old" || die "Invalid interface name: $old"
  fi
  if [ -n "$src" ]; then
    [ -f "$src" ] || die "No such file: $src"
    exec < "$src"
  fi
  parse_config
  local body
  body="$(emit_conf)"

  local active old_was_active=0 iface_was_active=0
  active="$(active_ifaces)" || die "Could not list active tunnels"
  [ -n "$old" ] && printf '%s\n' "$active" | grep -qxF "$old" && old_was_active=1
  printf '%s\n' "$active" | grep -qxF "$iface" && iface_was_active=1

  if [ -n "$old" ] && [ "$old" != "$iface" ]; then
    # Replace a differently-named tunnel: stage under a temp name, then swap.
    # A short, valid interface name (<=15 chars) for the staged conf; it is
    # never brought up, only written then promoted to <iface>.
    local stage=".import.$$"
    printf '%s\n' "$body" | PRIV writeconf "$stage" || die "Could not stage the new config"
    if [ "$old_was_active" = 1 ]; then
      mark_down "$old"
      PRIV down "$old" || {
        clear_intent "$old"
        PRIV delconf "$stage" >/dev/null 2>&1 || true
        die "Could not deactivate the old tunnel"
      }
    fi
    PRIV delconf "$old" || {
      PRIV delconf "$stage" >/dev/null 2>&1 || true
      if [ "$old_was_active" = 1 ] && PRIV up "$old" >/dev/null 2>&1; then clear_intent "$old"; fi
      die "Could not remove the old tunnel"
    }
    local staged
    staged="$(PRIV getconf "$stage")" || {
      echo "Staged config vanished after the old tunnel was removed; check /etc/amnezia/amneziawg" >&2
      exit 6
    }
    printf '%s\n' "$staged" | PRIV writeconf "$iface" || {
      echo "Could not finalize $iface after removing $old; check /etc/amnezia/amneziawg" >&2
      exit 6
    }
    PRIV delconf "$stage" >/dev/null 2>&1 || true
    carry_label "$old" "$iface"
    if [ "$old_was_active" = 1 ]; then
      PRIV up "$iface" || { echo "Saved, but reconnecting failed" >&2; exit 5; }
      clear_intent "$iface"
    fi
  else
    # Fresh import, or an in-place edit (old == iface).
    printf '%s\n' "$body" | PRIV writeconf "$iface" || die "Could not write the config"
    if [ "$iface_was_active" = 1 ]; then
      mark_down "$iface"
      PRIV down "$iface" >/dev/null 2>&1 || true
      PRIV up "$iface" || { echo "Saved, but reconnecting failed" >&2; exit 5; }
      clear_intent "$iface"
    fi
  fi
}

# ---------------------------------------------------------------------------
# export: the helper hands back canonical awg-quick text already; normalize
# spacing so import -> export -> import is lossless including AWG params.
# ---------------------------------------------------------------------------
cmd_export() {
  local iface="$1" conf
  valid_iface "$iface" || die "Invalid interface name: $iface"
  conf="$(PRIV getconf "$iface")" || die "Could not read the tunnel config"
  printf '%s\n' "$conf" | awk '
    /^[[:space:]]*$/ { print ""; next }
    /^[[:space:]]*[#;]/ { sub(/^[ \t]+/, ""); print; next }
    /^[[:space:]]*\[/ { gsub(/^[ \t]+|[ \t]+$/, ""); print; next }
    {
      e = index($0, "=")
      if (e > 0) {
        k = substr($0, 1, e - 1); v = substr($0, e + 1)
        gsub(/^[ \t]+|[ \t]+$/, "", k); gsub(/^[ \t]+|[ \t]+$/, "", v)
        print k " = " v
      } else print
    }'
}

cmd_export_file() {
  local iface="$1" dest="$2" dir tmp
  [ -n "$dest" ] || die "No destination path"
  [ -d "$dest" ] && die "Destination is a directory: $dest"
  [ -e "$dest" ] && [ ! -f "$dest" ] && die "Destination is not a regular file: $dest"
  dir="$(dirname -- "$dest")"
  [ -d "$dir" ] || die "No such directory: $dir"
  umask 077
  tmp="$(mktemp -- "$dir/.omazia-export.XXXXXX")" || die "Cannot create a file in $dir"
  trap 'rm -f "$tmp"; exit 1' HUP INT TERM
  trap 'rm -f "$tmp"' EXIT
  cmd_export "$iface" > "$tmp" || die "Could not export the tunnel"
  mv -fT -- "$tmp" "$dest" || die "Could not write $dest"
  trap - EXIT HUP INT TERM
}

cmd_qr_png() {
  local iface="$1" dir png
  command -v qrencode >/dev/null 2>&1 ||
    { echo "qrencode is not installed — sudo pacman -S qrencode" >&2; exit 2; }
  ensure_runtime_dir
  dir="$RUNTIME_DIR"
  png="$(mktemp -- "$dir/omazia-qr.$PPID.XXXXXX.png")" || die "Cannot create a file in $dir"
  trap 'rm -f -- "$png"; exit 1' HUP INT TERM
  trap 'rm -f -- "$png"' EXIT
  cmd_export "$iface" | qrencode -t PNG -s 6 -m 2 -o "$png" ||
    die "Could not encode the config as a QR code"
  trap - EXIT HUP INT TERM
  printf '%s\n' "$png"
}

cmd_cleanup_runtime() {
  local dir png base owner now mtime
  ensure_runtime_dir
  dir="$RUNTIME_DIR"
  now="$(date +%s)"
  while IFS= read -r -d '' png; do
    [ -f "$png" ] && [ ! -L "$png" ] || continue
    base="${png##*/}"
    if [[ "$base" =~ ^omazia-qr\.([0-9]+)\.[A-Za-z0-9]{6}\.png$ || "$base" =~ ^omazia-edit\.([0-9]+)\.[A-Za-z0-9]{6}$ ]]; then
      owner="${BASH_REMATCH[1]}"
      kill -0 "$owner" 2>/dev/null && continue
      rm -f -- "$png"
      continue
    fi
    mtime="$(stat -Lc '%Y' -- "$png" 2>/dev/null)" || continue
    case "$mtime" in ''|*[!0-9]*) continue ;; esac
    [ $((now - mtime)) -gt 86400 ] && rm -f -- "$png"
  done < <(find "$dir" -maxdepth 1 -type f \( -name 'omazia-qr.*.png' -o -name 'omazia-edit.*' \) -print0)
}

cmd_edit() {
  local iface="$1" name="$2" seed src dir tmp buf
  seed="$(cat)"
  command -v zenity >/dev/null 2>&1 || exit 2
  src="$(cmd_export "$iface")" || exit 1
  ensure_runtime_dir
  dir="$RUNTIME_DIR"
  tmp="$(mktemp -- "$dir/omazia-edit.$PPID.XXXXXX")" || exit 1
  trap 'rm -f -- "$tmp" "${buf:-}"; exit 1' HUP INT TERM
  trap 'rm -f -- "$tmp" "${buf:-}"' EXIT
  buf="$(mktemp -- "$dir/omazia-edit.$PPID.XXXXXX")" || exit 1
  if [ -n "$seed" ]; then printf '%s\n' "$seed" > "$buf"
  else printf '%s\n' "$src" > "$buf"; fi
  zenity --text-info --editable --filename="$buf" \
    --title="Edit $name" --width=700 --height=560 > "$tmp" || exit 3
  printf '%s\n' "$src" | cmp -s "$tmp" - && exit 4
  cat -- "$tmp"
}

case "${1:-}" in
  status) cmd_status ;;
  details) cmd_details "$2" ;;
  connect) lock; cmd_connect "$2" ;;
  down) lock; cmd_down "$2" ;;
  down-all) lock; cmd_down_all ;;
  delete) lock; cmd_delete "$2" ;;
  rename) lock; cmd_rename "$2" "$3" ;;
  import) lock; cmd_import "$2" "${3:-}" "${4:-}" ;;
  notify-drop) lock; cmd_notify_drop "$2" "$3" ;;
  mark-active) lock; clear_intent "$2" "${3:-}" ;;
  export) cmd_export "$2" ;;
  export-file) cmd_export_file "$2" "$3" ;;
  qr-png) cmd_qr_png "$2" ;;
  cleanup-runtime|cleanup-qr) cmd_cleanup_runtime ;;
  edit) cmd_edit "$2" "$3" ;;
  *) die "Usage: backend.sh status|details|connect|down|down-all|delete|rename|import|export|export-file|qr-png|cleanup-runtime|edit ..." ;;
esac
