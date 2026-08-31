#!/bin/bash
# Remove the AmneziaWG root helper and its polkit policy.
set -euo pipefail

if [ "$(id -u)" != 0 ]; then
  echo "uninstall.sh must be run as root — try: sudo ./uninstall.sh" >&2
  exit 1
fi

rm -f /usr/local/lib/omarchy-amneziawg-helper
rm -f /usr/share/polkit-1/actions/com.omarchy.amneziawg.policy

echo "Removed helper and polkit policy."
echo "/etc/amnezia/amneziawg and its tunnel configs are left in place on purpose."
