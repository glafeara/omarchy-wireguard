# Manual checklist

What the fake-nmcli suites cannot prove — run against real tunnels before a
release. A dead endpoint does **not** test rollback: `nmcli connection up`
activates a WireGuard profile successfully even when the peer is
unreachable, which is why the failure paths live in `test-connect.sh`.

## Switching

- [ ] Switch between two tunnels with different interface names — the new
      one comes up before the old one goes down (no VPN-less window).
- [ ] Switch between two tunnels sharing an interface name — old down,
      new up.
- [ ] Switch to a tunnel while several are active (activated via `nmcli`) —
      only WireGuard profiles are touched, wifi/tailscale stay up.
- [ ] Toggle from the bar and via `omarchy-shell glafeara.wireguard toggle`.
- [ ] With `multiTunnel` off, an unconnected row reads "Click to switch"
      while another tunnel is up, "Click to connect" while none is.

## Several tunnels (`multiTunnel` on)

- [ ] `omarchy bar set glafeara.wireguard multiTunnel true`, then connect a
      split tunnel beside a full one — both stay up, rows read "Click to
      connect".
- [ ] Enter on a connected row takes down only that tunnel.
- [ ] Connect a second full tunnel — refused, the error names the tunnel
      already routing everything, nothing changes.
- [ ] Move the cursor onto each connected row — the grid (and its
      "Showing …" note) follows; onto a disconnected row — the grid stays.
      Close and reopen — the grid starts from the first tunnel again.
- [ ] Put the keyboard cursor on the second connected row, close with
      `Esc`, wait past a refresh — `omarchy-shell glafeara.wireguard
      details` still describes the first tunnel.
- [ ] Reopen and press `j` once — the cursor reappears, and if it lands on
      a connected row the grid follows at once, not on the next refresh.
- [ ] `t` and right-click take every tunnel down; `t` again brings back the
      one connected last, not the first in the list.
- [ ] `multiTunnel false` (the string, via `omarchy bar set`) switches back
      to exclusive switching.

## Traffic

- [ ] The connected row reads "Connected — click to disconnect": its numbers
      live in the grid above. Bring a second tunnel up with `nmcli` — that
      row, and only that row, shows `↓ …/s ↑ …/s · ↓ … ↑ …` within ~4s of
      opening the panel.
- [ ] Grid totals reset after a reconnect.

## Connection details

- [ ] The grid appears with the tunnel and disappears with it; every cell
      holds its place from the first frame, reading `--` until its value
      lands — nothing below it jumps as the numbers arrive.
- [ ] Address, endpoint, allowed IPs and DNS match the profile; a full
      tunnel pings in tens of milliseconds, and the figures are the new
      tunnel's within a second of a switch, never the old one's.
- [ ] Ping and packet loss stop moving when the panel closes and start
      from an empty window when it reopens — no stale samples on screen.
      Close the panel mid-probe (within ~2s of a tick) and reopen: the first
      frame shows `--`, never a figure from the previous session.
- [ ] Switch tunnels while a probe is in flight — the old tunnel's latency
      never appears in the new tunnel's window.
- [ ] `omarchy-shell glafeara.wireguard details` with the panel closed for
      more than ten seconds shows `--` for rates, totals and ping, and real
      values for the addresses. Never `0 B` for a tunnel that has moved
      megabytes.
- [ ] A profile with two peers shows `first of 2 peers` under the grid, and
      `details` says `peers=2 (first shown)`.
- [ ] A split tunnel that does not route `pingHost` shows `--`, not 100%.
- [ ] `pingHost` set to `""` drops the Ping and Packet Loss row entirely and
      spawns no `ping` process while the panel is open.
- [ ] Clicking the address, endpoint, routes or DNS copies the value
      (`wl-paste` to check); a hostname endpoint long enough to elide shows
      in full in the tooltip.
- [ ] The values' right edge lines up with the hero switch's track, not with
      the invisible box around it.
- [ ] With two tunnels up the grid names the one it describes.

## List order

- [ ] Connecting a profile from the middle of the list moves it to the top;
      the rest stay in name order and nothing else reshuffles on a poll.
- [ ] With the keyboard cursor on that profile, connecting it keeps the
      cursor **on it** as it moves up — Enter right after disconnects the
      same tunnel, not the row that took its old place.
- [ ] Deleting the profile under the cursor leaves the cursor in range.

## Export / QR

- [ ] The header's QR button appears only while a tunnel is up, targets the
      tunnel named in the header, and is gone again after disconnecting.
- [ ] `q` on a profile (or the QR button) opens the code centred on screen
      and closes the panel; `Esc`, `q` or a click outside closes it and
      deletes `$XDG_RUNTIME_DIR/wg-qr.*.png`. The panel stays closed.
- [ ] `omarchy-shell glafeara.wireguard qr <name>` with the panel closed
      opens the window without flashing the panel; on a second monitor the
      window lands on the screen whose bar was used.
- [ ] Without `qrencode` the window still opens and shows the install hint;
      the bar icon does not turn urgent.
- [ ] Two `qr` calls back to back: the second answers
      `error: another QR code is still rendering`, never a false `ok`.
- [ ] Opening the panel while a code is up (IPC `open`, or an import
      landing) closes the code rather than hiding the panel beneath it.
- [ ] Scanning with the phone's WireGuard app imports a working tunnel.
- [ ] `omarchy-shell glafeara.wireguard exportConfig <name> <path>` writes a
      0600 file that re-imports losslessly.
- [ ] Close a QR window, then reload the shell while another QR is visible;
      the known `$XDG_RUNTIME_DIR/wg-qr.*.png` disappears in both cases. With
      two monitors, closing or reloading one instance never deletes the
      other instance's visible QR. Kill the shell while a code is visible,
      then start it again: the new shell removes the dead shell's QR, while
      a code owned by a live sibling shell remains. (A reused PID is the
      residual, extremely narrow limitation.)

## Notifications

- [ ] With a tunnel up, `nmcli connection down <name>` from a terminal →
      one toast "Profile <name> was deactivated", bar icon turns urgent.
- [ ] Disconnecting from the panel/bar produces **no** toast.
- [ ] With two monitors (two widget instances), the external drop still
      produces exactly one toast.
- [ ] Restart NetworkManager with a tunnel up — toast appears, widget
      recovers on the next poll.

## Editing

- [ ] Pencil → Config closes the panel, and zenity comes up focused rather
      than behind the popup; the save goes over a running tunnel and the
      tunnel comes back up on the new profile.
- [ ] Pencil → Name closes the panel and opens the prompt centred on screen,
      field focused with the name selected. Renames without touching the
      interface; duplicates are refused. `Esc` or a click outside cancels,
      and the panel stays closed either way.
- [ ] `e` and `n` on the selected row do the same as the pencil's two
      answers, panel closing included.
- [ ] With `zenity` uninstalled, Config reopens the panel on "zenity is not
      installed" rather than leaving a closed popup and an urgent bar icon.
      Cancelling the editor, or saving unchanged text, does **not** reopen
      it. `omarchy-shell glafeara.wireguard edit <name>` with the panel
      closed stays headless either way.
- [ ] Opening the panel while the rename prompt is up (IPC `open`, or an
      import landing) closes the prompt rather than hiding the panel beneath
      it; `qr` while it is up does the same.
- [ ] The import prompt (`i` / `v`) still lives inside the panel and gets the
      focus back on cancel.
- [ ] Start a slow import or switch, then call every IPC action that uses the
      control worker (`down`, `importConfig`, `rename`, `importPick`,
      `importPaste`): each replies `error: …`. An editor and an export may
      start independently during that operation; a second editor or export
      rejects its already-running worker. While an editor save is queued,
      another `edit` reports the pending-save error and cannot overwrite it.
