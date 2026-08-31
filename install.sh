#!/bin/bash
# Install the AmneziaWG root helper and its polkit policy. Idempotent.
set -euo pipefail

if [ "$(id -u)" != 0 ]; then
  echo "install.sh must be run as root — try: sudo ./install.sh" >&2
  exit 1
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

install -D -m 0755 "$here/helper/omarchy-amneziawg-helper" \
  /usr/local/lib/omarchy-amneziawg-helper
install -D -m 0644 "$here/polkit/com.omarchy.amneziawg.policy" \
  /usr/share/polkit-1/actions/com.omarchy.amneziawg.policy
install -d -m 0700 /etc/amnezia/amneziawg

cat <<'EOF'
Installed. Log out and back in for polkit to pick up the new action. For the sudo fallback instead: install sudoers/omarchy-amneziawg to /etc/sudoers.d/ and set OMAWG_PRIV=sudo.
EOF
