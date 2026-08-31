import QtQuick
import Quickshell
import Quickshell.Io

// Headless state for the AmneziaWG widget: lists the amneziawg tunnels
// under /etc/amnezia/amneziawg, tracks which are active, and activates or
// deactivates them through backend.sh (awg-quick via a pkexec helper —
// no sudo shell; the helper re-validates every config it writes).
Item {
  id: root

  property var settings: ({})

  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy"
  readonly property string lastFile: stateDir + "/amneziawg-last"
  readonly property string backendPath: String(Qt.resolvedUrl("backend.sh")).replace(/^file:\/\//, "")

  // The amneziawg tunnels as {ifname, name, active}, sorted by name. Every
  // control operation addresses a tunnel by its interface name — the conf
  // basename — because the display name is a cosmetic label that may be
  // duplicated, never an address.
  property var profiles: []
  // Names of the amneziawg tunnels currently active
  readonly property var activeNames: {
    var out = []
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i].active) out.push(profiles[i].name)
    }
    return out
  }
  readonly property bool active: activeNames.length > 0
  // Interface name of the most recently connected tunnel, persisted across
  // restarts so the hero toggle reconnects what you actually used last. The
  // ifname, not the display name: a duplicated name resolves ambiguously.
  property string lastIfname: ""
  property string actionStatus: ""
  property string lastError: ""
  // Public action methods return true only after they actually started work.
  // IPC uses actionRejection to avoid acknowledging a request that a busy
  // widget would otherwise quietly discard.
  property string actionRejection: ""

  readonly property bool busy: controlProcess.running
  readonly property string statusText: active ? "VPN: " + activeNames.join(" ") : "VPN disconnected"
  // What toggle() would bring up: the last used profile if it still exists,
  // otherwise the first one. A pre-rename state file may hold a display
  // name, so a name match is the fallback before giving up on the value.
  readonly property var toggleProfile: {
    var byName = null
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i].ifname === lastIfname) return profiles[i]
      if (byName === null && profiles[i].name === lastIfname) byName = profiles[i]
    }
    if (byName !== null) return byName
    return profiles.length > 0 ? profiles[0] : null
  }
  readonly property string toggleTarget: toggleProfile ? toggleProfile.name : ""

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 10, 2, 3600)

  // Traffic sampling: byte counters from /sys for the active tunnels'
  // devices — readable without privilege. This is activity, not health:
  // AmneziaWG has no connection state, and a tunnel that is silent is not
  // thereby broken. Sampled on a short timer only while the panel is open.
  property bool trafficMonitoring: false
  // device -> {rx, tx, at, rxRate, txRate}. The raw counters double as
  // session totals: awg-quick creates the interface at activation,
  // so they are zero at connect by construction.
  property var traffic: ({})

  readonly property var activeDevices: {
    var out = []
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i].active && profiles[i].ifname !== "") out.push(profiles[i].ifname)
    }
    return out
  }

  // The tunnel the detail grid describes — the first active profile in the
  // sorted list, which is also the one the hero names first. AmneziaWG can
  // run several at once; the rest keep their per-row traffic line, because
  // one endpoint, one address and one ping cannot describe two tunnels.
  readonly property var primaryProfile: {
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i].active) return profiles[i]
    }
    return null
  }
  readonly property string primaryIfname: primaryProfile ? primaryProfile.ifname : ""
  readonly property string primaryName: primaryProfile ? primaryProfile.name : ""
  readonly property string primaryDevice: primaryProfile ? primaryProfile.ifname : ""

  // The tunnel the detail grid, the ping probe and the grid's traffic rows
  // describe. Several tunnels can be up at once now, so the grid follows an
  // explicit choice — a click on a row — rather than always the first active
  // one. Empty means "no choice made": fall back to the primary, which keeps
  // the old single-tunnel behaviour (grid shows whatever is connected).
  property string inspectedIfname: ""
  // The explicit choice is honoured while that tunnel is up; once it drops
  // (its own toggle, an external down) the grid falls back to the first
  // active tunnel rather than emptying out.
  readonly property var inspectedProfile: {
    var p = findByIfname(inspectedIfname)
    if (p && p.active) return p
    return primaryProfile
  }
  readonly property string inspectedIfnameEffective: inspectedProfile ? inspectedProfile.ifname : ""
  readonly property string inspectedName: inspectedProfile ? inspectedProfile.name : ""
  readonly property string inspectedDevice: inspectedIfnameEffective
  // The grid only has numbers to show for a tunnel that is actually up.
  readonly property bool inspectedActive: inspectedProfile ? inspectedProfile.active === true : false

  // Connection facts from `backend.sh details` — ip, ip6, endpoint, allowed,
  // dns, mtu, peers. Kept with the ifname they describe so a switch shows
  // the new tunnel's numbers or nothing at all, never the old tunnel's.
  property var details: ({})
  property string detailsIfname: ""
  readonly property bool hasDetails: detailsIfname !== "" && detailsIfname === inspectedIfnameEffective

  function detail(key) {
    if (!hasDetails) return ""
    var value = details[String(key)]
    return value === undefined ? "" : String(value)
  }

  // How many peers the profile has. The endpoint and the routes on show
  // belong to the first one, so anything above 1 means the grid is
  // describing part of a tunnel and has to say so.
  readonly property int peerCount: {
    var n = parseInt(detail("peers"), 10)
    return isFinite(n) && n > 0 ? n : 0
  }

  // Latency through the tunnel: ICMP bound to the wg device, so a split
  // tunnel is measured on the path it actually routes. Unprivileged — ping
  // sockets are open to all users on Omarchy. Set pingHost to "" to switch
  // the probe off entirely.
  readonly property string pingHost: String(setting("pingHost", "1.1.1.1")).trim()
  // Rate, not health, again: a lost packet is a lost packet, not a warning
  // about the tunnel. Samples are ms, or -1 for a timeout.
  property var pingSamples: []
  readonly property bool hasPing: pingSamples.length > 0
  readonly property real pingLatency: {
    var total = 0
    var count = 0
    for (var i = 0; i < pingSamples.length; i++) {
      if (pingSamples[i] < 0) continue
      total += pingSamples[i]
      count++
    }
    return count > 0 ? total / count : -1
  }
  readonly property int pingLoss: {
    if (pingSamples.length === 0) return 0
    var lost = 0
    for (var i = 0; i < pingSamples.length; i++) {
      if (pingSamples[i] < 0) lost++
    }
    return Math.round(lost * 100 / pingSamples.length)
  }

  // The grid's static half — endpoint, address, routes — changes only when
  // the profile is edited, so it is fetched on a switch and on opening,
  // never on a timer. Both halves are dropped with the tunnel they describe:
  // showing the old numbers under a new name would be worse than "--".
  onInspectedIfnameEffectiveChanged: {
    details = ({})
    detailsIfname = ""
    pingSamples = []
    fetchDetails()
  }

  onTrafficMonitoringChanged: {
    if (trafficMonitoring) fetchDetails()
    // A window's worth of stale samples would otherwise be the first thing
    // the panel shows on reopening.
    else pingSamples = []
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  function rejectAction(reason) {
    actionRejection = String(reason)
    lastError = actionRejection
    return false
  }

  function refresh() {
    // Timer and manual refreshes coalesce. This is not an operation failure:
    // recording it in lastError would make the bar urgent forever after a
    // normal timer overlap, but IPC can still return the rejection reason.
    if (statusProcess.running) {
      actionRejection = "a refresh is already running"
      return false
    }
    actionRejection = ""
    // The observation time for mark-active is when this snapshot is
    // *requested* — anything that happens while the poll runs or waits to
    // be parsed is "after the observation" and must keep its marker.
    _statusStartedAt = Math.floor(Date.now() / 1000)
    statusProcess.running = true
    return true
  }

  // Control operations need a post-change snapshot, even if an earlier status
  // poll is in flight. Timers and manual refreshes deliberately do not queue:
  // otherwise a slow status command could keep polling forever.
  function refreshAfterChange() {
    if (statusProcess.running) {
      _refreshAfterStatus = true
      return false
    }
    return refresh()
  }

  function sampleTraffic() {
    if (trafficProcess.running || activeDevices.length === 0) return
    trafficProcess.command = ["bash", "-c", trafficScript, "amneziawg"].concat(activeDevices)
    trafficProcess.running = true
  }

  function fetchDetails() {
    if (detailsProcess.running || inspectedIfnameEffective === "") return
    _detailsFor = inspectedIfnameEffective
    detailsProcess.command = ["bash", backendPath, "details", inspectedIfnameEffective, inspectedDevice]
    detailsProcess.running = true
  }

  function applyDetails(raw) {
    var next = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var pos = lines[i].indexOf("=")
      if (pos <= 0) continue
      next[lines[i].slice(0, pos)] = lines[i].slice(pos + 1)
    }
    details = next
    detailsIfname = _detailsFor
  }

  function samplePing() {
    if (pingProcess.running || pingHost === "" || inspectedDevice === "" || !inspectedActive) return
    // Tagged with the tunnel it was sent for: a probe takes up to two
    // seconds, and a switch or a closing panel inside that window clears the
    // samples — the reply must not land in the window that replaced them.
    _pingFor = inspectedIfnameEffective
    // The tunnel address is the fallback binding for kernels that refuse
    // SO_BINDTODEVICE to an unprivileged ping; without either, the probe
    // would measure the physical link and call it the tunnel's latency.
    pingProcess.command = ["bash", "-c", pingScript, "amneziawg",
      inspectedDevice, detail("ip").split("/")[0], pingHost]
    pingProcess.running = true
  }

  // -1 is a timeout, which counts as loss; a probe that could not run at all
  // (no ping binary, a rejected bind) samples nothing rather than reporting
  // a tunnel-shaped problem that is really a local one.
  function addPingSample(ms) {
    var next = pingSamples.slice()
    next.push(ms)
    while (next.length > 10) next.shift()
    pingSamples = next
  }

  function applyTraffic(raw) {
    var now = Date.now()
    var next = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var parts = lines[i].trim().split(/\s+/)
      if (parts.length !== 3) continue
      var dev = parts[0]
      var rx = Number(parts[1])
      var tx = Number(parts[2])
      if (!isFinite(rx) || !isFinite(tx)) continue
      var prev = traffic[dev]
      var dt = prev ? (now - prev.at) / 1000 : 0
      // A first sample, restarted counters (the interface was recreated
      // behind our back) or a gap left by a closed panel all make the delta
      // meaningless: keep the totals, hold the rate at zero for one tick.
      // `rated` marks a rate that was actually measured: the zero a first
      // sample carries means "no interval yet", and reporting that as
      // 0 B/s claims an idle tunnel on no evidence.
      if (!prev || rx < prev.rx || tx < prev.tx || dt <= 0 || dt > 30) {
        next[dev] = { rx: rx, tx: tx, at: now, rxRate: 0, txRate: 0, rated: false }
      } else {
        next[dev] = { rx: rx, tx: tx, at: now, rated: true,
          rxRate: (rx - prev.rx) / dt, txRate: (tx - prev.tx) / dt }
      }
    }
    // Wholesale replacement drops devices that vanished with their tunnels.
    traffic = next
  }

  // Single-letter units and one decimal at most: the line has to share a
  // caption row with three action buttons, so every character counts.
  function fmtBytes(n) {
    var v = Number(n) || 0
    if (v < 1024) return Math.round(v) + "B"
    var units = ["K", "M", "G", "T"]
    for (var i = 0; i < units.length; i++) {
      v /= 1024
      if (v < 1024 || i === units.length - 1) break
    }
    return (v >= 100 ? v.toFixed(0) : v.toFixed(1)) + units[i]
  }

  // The detail grid has a column of its own to fill, so it gets the spaced,
  // two-letter units the rest of the shell uses — fmtBytes stays compact for
  // the row caption it shares with three buttons.
  function fmtSize(n) {
    var v = Number(n)
    if (!isFinite(v) || v < 0) v = 0
    if (v < 1024) return Math.round(v) + " B"
    if (v < 1048576) return (v / 1024).toFixed(1) + " KB"
    if (v < 1073741824) return (v / 1048576).toFixed(1) + " MB"
    return (v / 1073741824).toFixed(2) + " GB"
  }

  function fmtRate(n) {
    return fmtSize(n) + "/s"
  }

  function fmtPing(ms) {
    if (!hasPing) return "--"
    var v = Number(ms)
    if (!isFinite(v) || v < 0) return "Timeout"
    return v.toFixed(v > 0 && v < 10 ? 1 : 0) + " ms"
  }

  function fmtLoss(percent) {
    return hasPing ? String(percent) + "%" : "--"
  }

  // Live counters for one device, or zeros — the grid keeps its rows in
  // place from the moment a tunnel comes up, so it needs an answer before
  // the first sample lands.
  function trafficOf(dev) {
    var t = traffic[String(dev || "")]
    return t ? t : { rx: 0, tx: 0, at: 0, rxRate: 0, txRate: 0, rated: false }
  }

  // Sampling stops with the panel, so a stored sample is only worth printing
  // for as long as it can still be true. Past that the honest answer is
  // "--": zeros would claim a tunnel that has moved nothing, and the last
  // rate would claim traffic that stopped being measured minutes ago.
  readonly property int trafficStaleMs: 10000

  function trafficLive(t) {
    return !!t && t.at > 0 && (Date.now() - t.at) <= trafficStaleMs
  }

  function trafficTotal(dev, key) {
    var t = trafficOf(dev)
    return trafficLive(t) ? fmtSize(t[key]) : "--"
  }

  function trafficRate(dev, key) {
    var t = trafficOf(dev)
    return trafficLive(t) && t.rated ? fmtRate(t[key]) : "--"
  }

  // The panel's grid as one line, for scripts and for anyone who would
  // rather not open a popup to read six numbers.
  function detailsText() {
    if (!active) return "VPN disconnected"
    var parts = [primaryName]
    parts.push("ip=" + (detail("ip") !== "" ? detail("ip") : (detail("ip6") !== "" ? detail("ip6") : "--")))
    parts.push("endpoint=" + (detail("endpoint") !== "" ? detail("endpoint") : "--"))
    parts.push("allowed=" + (detail("allowed") !== "" ? detail("allowed") : "--"))
    parts.push("dns=" + (detail("dns") !== "" ? detail("dns") : "--"))
    // Counters are sampled only while the panel is open, so a headless
    // caller usually gets "--" here rather than a total from whenever it
    // was last looked at. peers says how much of the tunnel the endpoint
    // and the routes above actually describe.
    parts.push("rx=" + trafficTotal(primaryDevice, "rx") + " (" + trafficRate(primaryDevice, "rxRate") + ")")
    parts.push("tx=" + trafficTotal(primaryDevice, "tx") + " (" + trafficRate(primaryDevice, "txRate") + ")")
    parts.push("ping=" + fmtPing(pingLatency) + " loss=" + fmtLoss(pingLoss))
    if (peerCount > 1) parts.push("peers=" + peerCount + " (first shown)")
    return parts.join(" · ")
  }

  // One caption line: current rate, then session totals. Empty until there
  // is something live to say — the row falls back to its plain state text,
  // which beats a line of stale numbers.
  function trafficLine(dev) {
    var t = traffic[String(dev || "")]
    if (!trafficLive(t)) return ""
    return "↓ " + fmtBytes(t.rxRate) + "/s ↑ " + fmtBytes(t.txRate) + "/s"
      + " · ↓ " + fmtBytes(t.rx) + " ↑ " + fmtBytes(t.tx)
  }

  // First profile with this name, or null. Only for the name-based entry
  // points (import replace, IPC), and only once countByName has ruled out
  // duplicates — with several matches the first one is the wrong answer as
  // often as the right one. Everything row-bound carries its own profile.
  function findByName(name) {
    var value = String(name || "")
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i].name === value) return profiles[i]
    }
    return null
  }

  // Replace-or-create on import is decided by the interface name, which is
  // the tunnel's identity now: rename moves the display label freely, but
  // the interface is what a re-imported config actually collides with.
  function findByIfname(ifname) {
    var value = String(ifname || "")
    if (value === "") return null
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i].ifname === value) return profiles[i]
    }
    return null
  }

  function countByIfname(ifname) {
    var value = String(ifname || "")
    if (value === "") return 0
    var n = 0
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i].ifname === value) n++
    }
    return n
  }

  function countByName(name) {
    var value = String(name || "")
    var n = 0
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i].name === value) n++
    }
    return n
  }

  function ifnamesForName(name) {
    var value = String(name || "")
    var out = []
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i].name === value) out.push(profiles[i].ifname)
    }
    return out
  }

  function applyStatus(raw) {
    var lines = String(raw || "").split("\n")
    var sep = lines.indexOf("---")
    if (sep === -1) {
      lastError = "Failed to read AmneziaWG status"
      _pollError = true
      return
    }
    var list = []
    var byIfname = {}
    for (var i = 0; i < sep; i++) {
      // ifname:type:device:label — the label goes last because it is the
      // only field that can contain colons (escaped by the backend as
      // "\:"). type is literally "amneziawg"; the interface name is the
      // tunnel's identity, and for AmneziaWG it is also the device name.
      var line = lines[i]
      var a = line.indexOf(":")
      var b = a === -1 ? -1 : line.indexOf(":", a + 1)
      var c = b === -1 ? -1 : line.indexOf(":", b + 1)
      if (c === -1) continue
      if (line.slice(a + 1, b) !== "amneziawg") continue
      var entry = {
        ifname: line.slice(0, a),
        name: line.slice(c + 1).replace(/\\:/g, ":").replace(/\\\\/g, "\\"),
        active: false
      }
      list.push(entry)
      byIfname[entry.ifname] = entry
    }
    var firstUp = ""
    for (var j = sep + 1; j < lines.length; j++) {
      var ifname = lines[j].trim()
      if (ifname === "" || byIfname[ifname] === undefined) continue
      byIfname[ifname].active = true
      if (firstUp === "") firstUp = ifname
    }
    // Transitions against the previous poll. Every profile that went down
    // is queued for notify-drop — the backend's intent markers decide,
    // under the lock, which drops were ours; judging only the first could
    // hide an external drop behind an intentional one. Every profile that
    // came up re-arms its marker via mark-active, so an activation the
    // widget merely observed (awg-quick up) gets its notifications back.
    var droppedNow = []
    for (var ifname0 in _prevActive) {
      var cur = byIfname[ifname0]
      if (cur === undefined || !cur.active) droppedNow.push({ ifname: ifname0, name: _prevActive[ifname0] })
    }
    var nowActive = {}
    var observedAt = String(_statusStartedAt > 0 ? _statusStartedAt : Math.floor(Date.now() / 1000))
    for (var k = 0; k < list.length; k++) {
      if (!list[k].active) continue
      nowActive[list[k].ifname] = list[k].name
      // Queued, not fired directly: the process may be busy, and a lost
      // activation would leave a stale marker muting a real drop for up to
      // the TTL. The observation time rides along so a delayed mark-active
      // cannot erase the record of a down that happened after it.
      if (_prevActive[list[k].ifname] === undefined) _markQueue.push(list[k].ifname + ":" + observedAt)
    }
    _prevActive = nowActive
    for (var d = 0; d < droppedNow.length; d++) _dropQueue.push(droppedNow[d])
    _flushDrops()
    _flushMarkActive()
    // Sorted after the active flags are in, because the flag is the first
    // sort key: what is up is what the panel is opened for, and the grid
    // above describes the profile that lands at the top. Name breaks ties,
    // so an otherwise unchanged list never reshuffles.
    list.sort(function(a, b) {
      if (a.active !== b.active) return a.active ? -1 : 1
      return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0)
    })
    profiles = list
    // Track connects made outside the widget too (awg-quick, scripts).
    if (firstUp !== "") rememberLast(firstUp)
    // A successful poll retracts only its own earlier failure — an error (or
    // warning) from a control operation must outlive the refresh that every
    // operation triggers, or it flashes for one poll and vanishes.
    if (_pollError) {
      _pollError = false
      lastError = ""
    }
  }

  function rememberLast(ifname) {
    var value = String(ifname || "")
    if (value === "" || value === lastIfname) return
    lastIfname = value
    saveProcess.command = ["bash", "-c",
      "mkdir -p \"$1\" && printf '%s' \"$2\" > \"$1/amneziawg-last\"",
      "amneziawg", stateDir, value]
    saveProcess.running = true
  }

  function connectTo(profile) {
    if (busy) return rejectAction("another AmneziaWG operation is already running")
    if (!profile || !profile.ifname) return rejectAction("no such profile")
    actionRejection = ""
    actionStatus = "Connecting " + profile.name + "…"
    _pendingConnect = String(profile.ifname)
    // A fresh connect is the tunnel the user now wants to look at — point the
    // detail grid at it so it fills in as the tunnel comes up.
    inspectedIfname = String(profile.ifname)
    runControl(["up", profile.ifname])
    return true
  }

  function disconnectOne(profile) {
    if (busy) return rejectAction("another AmneziaWG operation is already running")
    if (!profile || !profile.ifname) return rejectAction("no such profile")
    actionRejection = ""
    actionStatus = "Disconnecting " + profile.name + "…"
    runControl(["down", profile.ifname])
    return true
  }

  function disconnectAll() {
    if (busy) return rejectAction("another AmneziaWG operation is already running")
    actionRejection = ""
    actionStatus = "Disconnecting…"
    runControl(["down-all"])
    return true
  }

  function deleteConfig(profile) {
    if (busy) return rejectAction("another AmneziaWG operation is already running")
    if (!profile || !profile.ifname) return rejectAction("no such profile")
    actionRejection = ""
    actionStatus = "Deleting " + profile.name + "…"
    runControl(["delete", profile.ifname])
    return true
  }

  // Changes connection.id only — a display label, so spaces and length are
  // fine. The interface name never moves; that is import's job.
  function renameConfig(profile, newName) {
    if (busy) return rejectAction("another AmneziaWG operation is already running")
    if (!profile || !profile.ifname) return rejectAction("no such profile")
    var value = String(newName || "").trim()
    if (value === "") return rejectAction("the new name must not be empty")
    // Idempotent success: no backend call is needed when it is already named
    // as requested, but IPC may still honestly answer ok.
    if (value === profile.name) {
      actionRejection = ""
      lastError = ""
      actionStatus = ""
      return true
    }
    actionRejection = ""
    actionStatus = "Renaming " + profile.name + "…"
    runControl(["rename", profile.ifname, value])
    return true
  }

  function toggle() {
    if (active) return disconnectAll()
    if (toggleProfile !== null) return connectTo(toggleProfile)
    return rejectAction("no AmneziaWG tunnel is available")
  }

  // Import: a picked file or pasted text becomes an NM connection profile,
  // and the status poll picks it up on the next tick.
  // Emitted once a source is in hand; the panel then asks for a name,
  // because neither source carries one the kernel will accept.
  signal importReady(string kind, string payload, string suggestedName)

  function pickConfigFile() {
    if (busy) return rejectAction("another AmneziaWG operation is already running")
    if (pickerProcess.running) return rejectAction("the file picker is already open")
    actionRejection = ""
    lastError = ""
    actionStatus = "Waiting for the file picker…"
    pickerProcess.running = true
    return true
  }

  function pasteConfig() {
    if (busy) return rejectAction("another AmneziaWG operation is already running")
    if (clipboardProcess.running) return rejectAction("clipboard import is already running")
    actionRejection = ""
    lastError = ""
    actionStatus = "Reading clipboard…"
    clipboardProcess.running = true
    return true
  }

  // Opens the profile as wg-quick text in zenity's editable view (the
  // backend reconstructs the text from AmneziaWG, secrets included).
  // Saving goes back through import, so an edit gets the same parsing and
  // validation as an import. Whether the tunnel comes back up is the
  // backend's call, made inside the replace transaction from what is active
  // at that moment — not from a snapshot taken when the editor opened.
  // `seedText` reopens the editor on text that was rejected rather than on
  // what is stored, so a refused save costs a keystroke to fix instead of
  // the whole edit.
  //
  // Emitted when the handoff produced no editor at all — the caller may have
  // closed the panel to get out of zenity's way, and lastError has nowhere
  // to be read. A cancelled or unchanged edit is not a failure.
  signal editFailed(string reason)
  // Terminal editor outcomes that need no panel rescue: cancellation,
  // unchanged text, and a completed save. Panel uses this only to retire its
  // handoff marker, so a later headless failure cannot reopen the panel.
  signal editFinished()

  function editConfig(profile, seedText) {
    if (!profile || !profile.ifname) return rejectAction("no such profile")
    if (editProcess.running) return rejectAction("the editor is already open")
    if (_pendingSaveIfname !== "" || _editRetryIfname !== "")
      return rejectAction("a previous editor save is still pending")
    actionRejection = ""
    _editIfname = String(profile.ifname)
    _editName = String(profile.name)
    if (!seedText) lastError = ""
    actionStatus = "Editing " + _editName + "…"
    // The seed goes over stdin — it is config text with a private key in it,
    // and argv is world-readable via /proc.
    _editSeed = String(seedText || "")
    editProcess.stdinEnabled = true
    editProcess.command = ["bash", backendPath, "edit", _editIfname, _editName]
    editProcess.running = true
    return true
  }

  // Export hands the config — private key included — out of AmneziaWG's
  // storage. File export is IPC-only (an explicit path in argv is already a
  // deliberate act); the QR is rendered by the backend into XDG_RUNTIME_DIR
  // and displayed by the centred QR window, which owns the PNG until closeQr.
  property string qrPath: ""
  property string qrName: ""
  // The QR window is the only surface a QR request reports through — the
  // panel closes the moment one starts, so a render failure has to be
  // visible there rather than in lastError (which would also leave the bar
  // icon urgent for a problem the user has already dismissed).
  property bool qrLoading: false
  property string qrError: ""
  readonly property bool qrVisible: qrLoading || qrPath !== "" || qrError !== ""

  function exportToPath(profile, path) {
    if (!profile || !profile.ifname) return rejectAction("no such profile")
    if (exportProcess.running) return rejectAction("an export is already running")
    var dest = String(path || "")
    if (dest === "") return rejectAction("no destination path")
    actionRejection = ""
    lastError = ""
    _exportDest = dest
    actionStatus = "Exporting " + profile.name + "…"
    exportProcess.command = ["bash", backendPath, "export-file", profile.ifname, dest]
    exportProcess.running = true
    return true
  }

  // Returns "" when a code is on its way, or why nothing will appear.
  function showQr(profile) {
    if (!profile || !profile.ifname) return "no such profile"
    if (qrProcess.running) {
      // closeQr retracts a render but lets it finish, so the process can be
      // busy with nothing on screen. Say so there rather than dropping the
      // request silently; while a wanted render is still running the window
      // already says what it is doing, so leave it alone.
      if (!_qrWanted) {
        qrName = String(profile.name)
        qrError = "Another QR code is still rendering — try again in a moment"
      }
      return "another QR code is still rendering"
    }
    closeQr()
    _qrWanted = true
    // Named now, not on exit: the window opens on the request, so its title
    // has to read right while the code is still being rendered.
    qrName = String(profile.name)
    qrLoading = true
    qrProcess.command = ["bash", backendPath, "qr-png", profile.ifname]
    qrProcess.running = true
    return ""
  }

  function closeQr() {
    // Also retracts a request still in flight: the window may close while
    // qr-png runs, and a PNG nobody is waiting for must not linger — the
    // process handler deletes an unwanted result instead of keeping it.
    // The process itself is left to finish: killing qrencode mid-write would
    // strand the file mktemp already created.
    _qrWanted = false
    removeQrFile(qrPath)
    qrPath = ""
    qrName = ""
    qrLoading = false
    qrError = ""
  }

  // Each path gets its own detached remover. A shared Process can have its
  // command overwritten by a second close or an unwanted render result,
  // leaving private-key PNGs behind; detached children also outlive Service
  // destruction long enough to perform this tiny, path-specific cleanup.
  function removeQrFile(path) {
    var knownPath = String(path || "")
    if (knownPath !== "") Quickshell.execDetached(["rm", "-f", "--", knownPath])
  }

  // A shell reload destroys this Service without a window-close signal.  The
  // current PNG is known to this instance, so remove only that path; do not
  // sweep omazia-qr.* broadly because another monitor can legitimately own one.
  Component.onDestruction: closeQr()
  // SIGKILL and a hard shell crash cannot run the destruction handler. The
  // backend identifies PNGs by this shell's parent PID, so startup safely
  // reaps files from a dead previous shell without touching a live monitor.
  Component.onCompleted: Quickshell.execDetached(["bash", backendPath, "cleanup-runtime"])

  function _flushDrops() {
    if (notifyProcess.running || _dropQueue.length === 0) return
    var drop = _dropQueue.shift()
    _notifyDropName = drop.name
    notifyProcess.command = ["bash", backendPath, "notify-drop", drop.ifname, drop.name]
    notifyProcess.running = true
  }

  function _flushMarkActive() {
    if (markActiveProcess.running || _markQueue.length === 0) return
    _markInFlight = _markQueue
    _markQueue = []
    markActiveProcess.command = ["bash", "-c", markActiveScript, "amneziawg", backendPath].concat(_markInFlight)
    markActiveProcess.running = true
  }

  // Puts rejected text back in front of the user with the reason showing.
  // Deferred through a timer because the editor process that produced the
  // text is still winding down when the rejection lands.
  function retryEdit(ifname, name, text, message) {
    lastError = message
    _editRetryIfname = String(ifname)
    _editRetryName = String(name)
    _editRetryText = String(text)
    editRetryTimer.restart()
  }

  // Refuses an ambiguous replace outright: with several profiles sharing
  // the name, "replace the one that matched first" would silently destroy a
  // profile the user never pointed at. The panel blocks this earlier with a
  // clearer message; this is the backstop for the headless entry points.
  function importFile(path, name) {
    if (busy) return rejectAction("another AmneziaWG operation is already running")
    if (!path || !name) return rejectAction("a config path and name are required")
    if (countByIfname(name) > 1) {
      return rejectAction("several profiles use the interface " + name + " — not replacing an ambiguous match")
    }
    actionRejection = ""
    var existing = findByIfname(name)
    actionStatus = "Importing " + name + "…"
    runControl(["import", String(name), existing ? existing.ifname : "", String(path)])
    return true
  }

  // Writes a queued editor save once controlProcess is free. Bypasses
  // importText's silent busy-guard on purpose: by the time the text exists
  // the user has already committed the edit, so it either writes now or
  // stays queued — it never just disappears.
  function _flushPendingSave() {
    if (_pendingSaveIfname === "" || busy) return
    var ifname = _pendingSaveIfname
    var name = _pendingSaveName
    var text = _pendingSaveText
    _pendingSaveIfname = ""
    _pendingSaveName = ""
    _pendingSaveText = ""
    // Held so a rejected save can be handed back to the editor instead of
    // being thrown away.
    _editRetryIfname = ifname
    _editRetryName = name
    _editRetryText = text
    actionStatus = "Saving " + name + "…"
    runControl(["import", name, ifname], text)
  }

  function importText(text, name) {
    if (busy) return rejectAction("another AmneziaWG operation is already running")
    if (!text || !name) return rejectAction("config text and a name are required")
    if (countByIfname(name) > 1) {
      return rejectAction("several profiles use the interface " + name + " — not replacing an ambiguous match")
    }
    actionRejection = ""
    var existing = findByIfname(name)
    actionStatus = "Importing " + name + "…"
    runControl(["import", String(name), existing ? existing.ifname : ""], String(text))
    return true
  }

  // The connection (and interface) is named after the file, and the kernel
  // caps interface names at 15 chars from [A-Za-z0-9_=+.-] — provider
  // configs ("US-New York 03.conf") routinely break both rules.
  function sanitizeName(raw) {
    var base = String(raw || "").split("/").pop()
    if (base.slice(-5).toLowerCase() === ".conf") base = base.slice(0, -5)
    base = base.replace(/[^A-Za-z0-9_=+.-]+/g, "-")
    base = base.replace(/^[-.]+/, "").replace(/[-.]+$/, "")
    // Trim again after the cut so truncation can't leave a trailing "-".
    return base.substring(0, 15).replace(/[-.]+$/, "")
  }

  function isValidName(name) {
    return /^[A-Za-z0-9_=+.-]{1,15}$/.test(String(name || ""))
  }

  function looksLikeConfig(text) {
    var value = String(text || "")
    return /^[ \t]*\[Interface\]/m.test(value) && /PrivateKey[ \t]*=/i.test(value)
  }

  // Pasted text carries no name of its own — offer the first wgN free as
  // both an interface and a label.
  function suggestName() {
    for (var i = 0; i < 100; i++) {
      if (!findByIfname("wg" + i) && !findByName("wg" + i)) return "wg" + i
    }
    return "wg"
  }

  // Config text rides on stdin, never in argv: anything in the command line
  // is world-readable through /proc/<pid>/cmdline for as long as the process
  // lives, and config text contains the private key.
  function runControl(args, stdinData) {
    _controlError = ""
    _controlOperation = String(args[0])
    _controlStdin = stdinData === undefined ? "" : String(stdinData)
    controlProcess.stdinEnabled = true
    controlProcess.command = ["bash", backendPath].concat(args)
    controlProcess.running = true
  }

  function elide(text) {
    var value = String(text || "").replace(/\s+/g, " ").trim()
    return value.length > 140 ? value.substring(0, 137) + "…" : value
  }

  // Everything that touches AmneziaWG lives in backend.sh — status,
  // connect, down, delete, import (with the awg-quick parser) and the
  // editor round-trip. Only the desktop-integration helpers below stay
  // inline.

  // Exit 2 means "no picker installed" — distinct from the user pressing
  // Cancel, which every one of these exits non-zero for.
  readonly property string pickScript:
    "if command -v zenity >/dev/null 2>&1; then\n" +
    "  exec zenity --file-selection --title='Import AmneziaWG config' \\\n" +
    "    --file-filter='AmneziaWG config | *.conf' --file-filter='All files | *'\n" +
    "elif command -v kdialog >/dev/null 2>&1; then\n" +
    "  exec kdialog --getopenfilename \"$HOME\" '*.conf|AmneziaWG config'\n" +
    "elif command -v yad >/dev/null 2>&1; then\n" +
    "  exec yad --file --title='Import AmneziaWG config'\n" +
    "fi\n" +
    "exit 2\n"

  // Device names come from the kernel — no spaces, no globs to worry about.
  readonly property string trafficScript:
    "for d in \"$@\"; do\n" +
    "  s=\"/sys/class/net/$d/statistics\"\n" +
    "  [ -r \"$s/rx_bytes\" ] && [ -r \"$s/tx_bytes\" ] || continue\n" +
    "  printf '%s %s %s\\n' \"$d\" \"$(cat \"$s/rx_bytes\")\" \"$(cat \"$s/tx_bytes\")\"\n" +
    "done\n"

  // ping bound to the tunnel device, falling back to the tunnel address:
  // iputils exits 2 for "could not even send" (no such device, a bind the
  // kernel refused) and 1 for "sent, nothing came back". Only the latter is
  // a timeout worth charting, so the fallback is tried on 2 alone — a real
  // timeout must not cost a second probe on every tick. Prints the average
  // RTT in milliseconds.
  readonly property string pingScript:
    "dev=\"$1\"; src=\"$2\"; host=\"$3\"\n" +
    "command -v ping >/dev/null 2>&1 || exit 2\n" +
    "rc=0\n" +
    "out=\"$(ping -n -q -c 1 -W 2 -I \"$dev\" -- \"$host\" 2>/dev/null)\" || rc=$?\n" +
    "if [ \"$rc\" != 0 ] && [ \"$rc\" != 1 ] && [ -n \"$src\" ]; then\n" +
    "  rc=0\n" +
    "  out=\"$(ping -n -q -c 1 -W 2 -I \"$src\" -- \"$host\" 2>/dev/null)\" || rc=$?\n" +
    "fi\n" +
    "[ \"$rc\" = 0 ] || exit \"$rc\"\n" +
    "printf '%s\\n' \"$out\" | awk -F/ '/^rtt|^round-trip/ {print $5; exit}'\n"

  readonly property string clipboardScript:
    "command -v wl-paste >/dev/null 2>&1 || exit 2\n" +
    "wl-paste --no-newline --type text/plain 2>/dev/null || wl-paste --no-newline\n"

  property string _controlError: ""
  // Which backend command controlProcess is running: special exit codes
  // (5/6 for import) mean nothing outside their command.
  property string _controlOperation: ""
  property string _controlStdin: ""
  // True while lastError describes a failed status poll, so a successful
  // poll knows it may clear it.
  property bool _pollError: false
  // One coalesced poll requested while statusProcess was running. This keeps
  // post-control state fresh even if the normal interval is as high as 3600s.
  property bool _refreshAfterStatus: false
  property string _pendingConnect: ""
  property string _exportDest: ""
  // The ifname the running details query is about — the answer is filed under
  // it, so a query overtaken by a switch cannot label itself with the new
  // tunnel's ifname. _pingFor does the same for the probe in flight.
  property string _detailsFor: ""
  property string _pingFor: ""
  // ifname -> name of the tunnels active at the previous status poll.
  property var _prevActive: ({})
  property string _notifyDropName: ""
  // Observed drops waiting for their notify-drop verdict, one at a time.
  property var _dropQueue: []
  // Observed activations ("ifname:epoch") waiting to re-arm their markers,
  // and the batch currently being processed — returned to the queue if the
  // backend fails (clear_intent is idempotent, so replays are safe).
  property var _markQueue: []
  property var _markInFlight: []
  // Epoch seconds of the moment the running status poll was requested.
  property double _statusStartedAt: 0
  // False once the QR window closed — a result arriving afterwards is
  // deleted, not displayed.
  property bool _qrWanted: false

  // Each argument is "ifname:observed-epoch"; ifnames contain no colons. Every
  // pair is attempted; any failure fails the batch, which the caller then
  // requeues whole — replays are idempotent.
  readonly property string markActiveScript:
    "be=\"$1\"; shift\n" +
    "rc=0\n" +
    "for pair in \"$@\"; do bash \"$be\" mark-active \"${pair%%:*}\" \"${pair#*:}\" || rc=1; done\n" +
    "exit $rc\n"
  property string _editIfname: ""
  property string _editName: ""
  property string _editSeed: ""
  // Edited text waiting for controlProcess to free up. The editor can close
  // while another operation runs (busy only gates controlProcess); a save
  // must queue, not silently vanish.
  property string _pendingSaveIfname: ""
  property string _pendingSaveName: ""
  property string _pendingSaveText: ""
  // Last edited text and its config, kept only until the write is known to
  // have succeeded.
  property string _editRetryIfname: ""
  property string _editRetryName: ""
  property string _editRetryText: ""

  FileView {
    path: root.lastFile
    printErrors: false
    onLoaded: {
      var value = String(text() || "").trim()
      if (value !== "" && root.lastIfname === "") root.lastIfname = value
    }
  }

  Timer {
    id: editRetryTimer
    interval: 60
    repeat: false
    onTriggered: {
      // Still winding down — try again rather than let editConfig's guard
      // silently swallow the retry text.
      if (editProcess.running) {
        editRetryTimer.restart()
        return
      }
      var ifname = root._editRetryIfname
      var name = root._editRetryName
      var text = root._editRetryText
      root._editRetryIfname = ""
      root._editRetryName = ""
      root._editRetryText = ""
      root.editConfig({ ifname: ifname, name: name }, text)
    }
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Short-lived by design: refreshIntervalSec is far too coarse for a rate
  // readout, and a 2s cadence is only worth paying for while someone looks.
  Timer {
    interval: 2000
    repeat: true
    running: root.trafficMonitoring && root.activeDevices.length > 0
    triggeredOnStart: true
    onTriggered: root.sampleTraffic()
  }

  // Slower than the traffic tick on purpose: a probe can sit for its whole
  // 2s timeout, and a 30s window of ten samples is what makes the loss
  // figure mean anything.
  Timer {
    interval: 3000
    repeat: true
    running: root.trafficMonitoring && root.primaryDevice !== "" && root.pingHost !== ""
    triggeredOnStart: true
    onTriggered: root.samplePing()
  }


  Process {
    id: statusProcess
    running: false
    command: ["bash", root.backendPath, "status"]
    stdout: StdioCollector {
      id: statusStdout
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: statusStderr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      // A failed poll must not read as "disconnected" — keep the last known
      // state and say why it could not be refreshed.
      if (exitCode === 0) {
        root.applyStatus(statusStdout.text)
      } else {
        root.lastError = root.elide(statusStderr.text || "Failed to read AmneziaWG status")
        root._pollError = true
      }
      if (root._refreshAfterStatus) {
        root._refreshAfterStatus = false
        Qt.callLater(root.refreshAfterChange)
      }
    }
  }

  // Kept out of runControl: these return data rather than pass/fail, and a
  // file dialog can sit open for a while — `busy` would freeze the panel.
  Process {
    id: pickerProcess
    running: false
    command: ["bash", "-c", root.pickScript, "amneziawg"]
    stdout: StdioCollector {
      id: pickerStdout
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.actionStatus = ""
      if (exitCode === 2) {
        root.lastError = "No file picker found — install zenity, kdialog or yad"
        return
      }
      // Anything else non-zero is Cancel; say nothing.
      if (exitCode !== 0) return
      var path = String(pickerStdout.text || "").trim()
      if (path !== "") root.importReady("file", path, root.sanitizeName(path))
    }
  }

  Process {
    id: editProcess
    running: false
    command: []
    stdinEnabled: false
    onStarted: {
      if (root._editSeed !== "") write(root._editSeed)
      root._editSeed = ""
      stdinEnabled = false
    }
    stdout: StdioCollector {
      id: editStdout
      waitForEnd: true
    }
    onExited: function(exitCode) {
      var ifname = root._editIfname
      var name = root._editName
      root._editIfname = ""
      root._editName = ""
      root.actionStatus = ""
      if (exitCode === 2) {
        root.lastError = "zenity is not installed"
        root.editFailed(root.lastError)
        return
      }
      // 3 = Cancel, 4 = nothing changed; neither is worth a message.
      if (exitCode === 3 || exitCode === 4) {
        root.editFinished()
        return
      }
      if (exitCode !== 0) {
        root.lastError = "Could not open " + name
        root.editFailed(root.lastError)
        return
      }
      var text = String(editStdout.text || "")
      if (!root.looksLikeConfig(text)) {
        root.retryEdit(ifname, name, text, "Not saved: that is not an AmneziaWG config")
        return
      }
      // Queued rather than written directly: busy only gates controlProcess,
      // so another operation may be mid-flight right now. The queue drains
      // from controlProcess.onExited — the save waits its turn instead of
      // being dropped.
      root._pendingSaveIfname = ifname
      root._pendingSaveName = name
      root._pendingSaveText = text
      Qt.callLater(root._flushPendingSave)
    }
  }

  Process {
    id: clipboardProcess
    running: false
    command: ["bash", "-c", root.clipboardScript, "amneziawg"]
    stdout: StdioCollector {
      id: clipboardStdout
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.actionStatus = ""
      if (exitCode === 2) {
        root.lastError = "wl-clipboard is not installed"
        return
      }
      var text = String(clipboardStdout.text || "")
      if (!root.looksLikeConfig(text)) {
        root.lastError = "Clipboard does not contain an AmneziaWG config"
        return
      }
      root.importReady("text", text, root.suggestName())
    }
  }

  Process {
    id: saveProcess
    running: false
    command: []
  }

  Process {
    id: exportProcess
    running: false
    command: []
    stderr: StdioCollector {
      id: exportStderr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      var dest = root._exportDest
      root._exportDest = ""
      if (exitCode === 0) {
        // Success worth stating: the visible outcome is a file somewhere
        // else, not a change in the panel.
        root.actionStatus = "Exported to " + dest
      } else {
        root.actionStatus = ""
        root.lastError = root.elide(exportStderr.text || "Export failed")
      }
    }
  }

  Process {
    id: qrProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: qrStdout
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: qrStderr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.qrLoading = false
      var path = exitCode === 0 ? String(qrStdout.text || "").trim() : ""
      // The window closed while we rendered: nobody is waiting for this, and
      // a successful result is key material — delete it and say nothing.
      if (!root._qrWanted) {
        root.removeQrFile(path)
        return
      }
      if (exitCode === 0 && path !== "") {
        root.qrPath = path
      } else {
        // 2 = qrencode missing, with the install hint on stderr.
        root.qrError = root.elide(qrStderr.text || "Could not render the QR code")
      }
    }
  }

  Process {
    id: notifyProcess
    running: false
    command: []
    onExited: function(exitCode) {
      var name = root._notifyDropName
      root._notifyDropName = ""
      // 0 = the backend judged the drop external. The message lands in
      // lastError so the bar icon turns urgent and the panel says why; any
      // successful operation clears it, like every other error.
      if (exitCode === 0 && name !== "") root.lastError = "Profile " + name + " was deactivated"
      Qt.callLater(root._flushDrops)
    }
  }

  Process {
    id: markActiveProcess
    running: false
    command: []
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root._markInFlight = []
        // Drain whatever queued while this batch ran.
        Qt.callLater(root._flushMarkActive)
      } else {
        // Give the batch back and retry on the next poll — an immediate
        // retry against a persistently failing backend would spin.
        root._markQueue = root._markInFlight.concat(root._markQueue)
        root._markInFlight = []
      }
    }
  }

  Process {
    id: trafficProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: trafficStdout
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode === 0) root.applyTraffic(trafficStdout.text)
    }
  }

  Process {
    id: detailsProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: detailsStdout
      waitForEnd: true
    }
    onExited: function(exitCode) {
      // A failure says nothing in lastError: this is a decoration on a panel
      // whose actual job — listing and switching tunnels — is unaffected,
      // and the grid already reads "--" with no data.
      // A switch mid-query answered about the tunnel that just left, and the
      // fetch that switch triggered was refused by the busy guard — so the
      // stale answer schedules the one the panel is actually waiting for.
      // Only staleness retries: a query that simply failed is left alone,
      // because retrying a persistent failure would spin.
      var stale = root._detailsFor !== root.inspectedIfnameEffective
      if (exitCode === 0 && !stale) root.applyDetails(detailsStdout.text)
      root._detailsFor = ""
      if (stale && root.inspectedIfnameEffective !== "") Qt.callLater(root.fetchDetails)
    }
  }

  Process {
    id: pingProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: pingStdout
      waitForEnd: true
    }
    onExited: function(exitCode) {
      // The tunnel moved, or the panel closed and emptied the window, while
      // this probe was in flight: its answer belongs to neither.
      var stale = root._pingFor !== root.inspectedIfnameEffective || !root.trafficMonitoring
      root._pingFor = ""
      if (stale) return
      if (exitCode === 1) {
        root.addPingSample(-1)
        return
      }
      if (exitCode !== 0) return
      var ms = parseFloat(String(pingStdout.text || "").trim())
      if (isFinite(ms) && ms >= 0) root.addPingSample(ms)
    }
  }

  Process {
    id: controlProcess
    running: false
    command: []
    stdinEnabled: false
    onStarted: {
      if (root._controlStdin !== "") write(root._controlStdin)
      root._controlStdin = ""
      stdinEnabled = false
    }
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector {
      id: controlStderr
      waitForEnd: true
      onStreamFinished: root._controlError = text
    }
    onExited: function(exitCode) {
      var op = root._controlOperation
      root._controlOperation = ""
      // 5 (import only) = the profile was saved but reconnecting it failed.
      // That is a success as far as the edit is concerned — reopening the
      // editor would target the already-deleted old profile — so the retry
      // state is cleared and only the reason is shown.
      var savedNotUp = op === "import" && exitCode === 5
      var completedEditorSave = op === "import" && root._editRetryName !== ""
      // 6 means import needs manual recovery: rollback or incomplete-profile
      // cleanup kept one or more replacements. Never reopen an editor
      // automatically: another save could hide that recovery state.
      var importStateUnknown = op === "import" && exitCode === 6
      if (exitCode === 0 || savedNotUp) {
        if (root._pendingConnect !== "") root.rememberLast(root._pendingConnect)
        root.lastError = savedNotUp
          ? root.elide(root._controlError || "Saved, but reconnecting failed")
          : ""
        root.actionStatus = ""
        root._editRetryIfname = ""
        root._editRetryName = ""
        root._editRetryText = ""
        if (completedEditorSave) root.editFinished()
      } else {
        root.actionStatus = ""
        // A failed `up`/`down` leaves the other tunnels untouched — nothing to
        // roll back — so the poll below just shows what is actually up.
        var reason = root.elide(root._controlError || "AmneziaWG operation failed")
        if (importStateUnknown) {
          root.lastError = reason
          root.editFailed(reason)
          root._editRetryIfname = ""
          root._editRetryName = ""
          root._editRetryText = ""
        // A write refused by wg_check must not cost the edit that produced
        // it; hand the text back to the editor with the reason attached.
        } else if (op === "import" && root._editRetryName !== "") {
          root.retryEdit(root._editRetryIfname, root._editRetryName, root._editRetryText, reason)
        } else root.lastError = reason
      }
      root._pendingConnect = ""
      root.refreshAfterChange()
      // An edit can move the address, the endpoint or the routes without
      // moving the tunnel, so the grid is refetched even when the primary
      // profile is the one it already describes.
      if (root.trafficMonitoring) Qt.callLater(root.fetchDetails)
      // A save queued while this operation ran; write it now.
      if (root._pendingSaveIfname !== "") Qt.callLater(root._flushPendingSave)
    }
  }
}
