import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "antesmd.amneziawg"
  ipcTarget: "antesmd.amneziawg"
  manageIpc: false

  property string focusSection: "header"
  property int configIndex: 0
  property bool cursorActive: false
  // Profile ({ifname, name}) awaiting delete confirmation; non-null opens the
  // dialog. A profile object, not a name — names are not unique.
  property var pendingDelete: null
  // Incoming config awaiting a name; "file" | "text" | "" (no prompt open).
  property string importKind: ""
  property string importPayload: ""
  // Profile ({ifname, name}) awaiting a new display name; non-null while the
  // rename dialog is open.
  property var pendingRename: null
  // Profile whose pencil was clicked — the chooser asks whether to edit
  // the config or the name; keyboard users go straight there with e / n.
  property var pendingEdit: null
  // Set when the panel closed to get out of the editor's way. The panel is
  // where lastError is read, so a handoff that produced no editor has to
  // bring it back; an IPC edit never sets this and stays headless.
  property bool editHandedOff: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color iconColor: wireguard.active ? foreground : dim
  // Urgent trumps everything: a failed operation or an externally dropped
  // tunnel must be visible without opening the panel.
  readonly property color barIconColor: wireguard.lastError !== ""
    ? (bar ? bar.urgent : Color.urgent)
    : (wireguard.active ? barForeground : Qt.darker(barForeground, 1.55))
  readonly property string toggleHint: wireguard.active
    ? "Disconnect"
    : (wireguard.toggleTarget !== "" ? "Connect " + wireguard.toggleTarget : "Connect")
  readonly property bool headerHasCursor: cursorActive && focusSection === "header" && wireguard.profiles.length > 0

  readonly property string importNameClean: importDialog.value.trim()
  readonly property bool importNameValid: wireguard.isValidName(importNameClean)
  // Matching is by configured interface-name: rename can move the display
  // name anywhere, but the interface is what a re-import collides with.
  readonly property int importNameCount: importNameValid ? wireguard.countByIfname(importNameClean) : 0
  readonly property bool importReplaces: importNameCount === 1
  // Several existing profiles use the typed interface — "replace" cannot
  // know which one is meant, so the import is refused under this name.
  readonly property bool importAmbiguous: importNameCount > 1
  readonly property bool importAccepted: importNameValid && !importAmbiguous
  readonly property var importReplaceTarget: importReplaces ? wireguard.findByIfname(importNameClean) : null
  readonly property string importSourceLabel: importKind === "text"
    ? "Import from clipboard"
    : "Import " + String(importPayload).split("/").pop()
  readonly property string importHintText: !importNameValid
    ? "Up to 15 characters: letters, digits and . _ - = +"
    : (importAmbiguous
      ? importNameCount + " profiles use the interface " + importNameClean + " — pick another name"
      : (importReplaces
        ? "Replaces the existing connection " + (importReplaceTarget ? importReplaceTarget.name : importNameClean)
        : "Imports as an AmneziaWG tunnel named " + importNameClean))

  // Rename touches connection.id only — a free-form label, so spaces are
  // fine. Duplicates are refused: every name-based entry point in the
  // widget treats an ambiguous name as an error, so don't let one be made.
  readonly property string renameClean: renameWindow.value.trim()
  readonly property bool renameDuplicate: renameClean !== ""
    && (pendingRename === null || renameClean !== pendingRename.name)
    && wireguard.countByName(renameClean) > 0
  readonly property bool renameAccepted: pendingRename !== null && renameClean !== "" && !renameDuplicate
  readonly property string renameHint: renameClean === ""
    ? "The name must not be empty"
    : (renameDuplicate
      ? "A profile named " + renameClean + " already exists"
      : "Display name only — the interface name does not change")

  // The list re-sorts the moment a tunnel comes up — active first — so the
  // cursor tracks the profile it was on rather than the slot it held. Without
  // this, connecting the third row would move that row to the top and leave
  // the cursor on whatever slid into third place, one Enter away from
  // switching a tunnel nobody pointed at.
  property string cursorIfname: ""

  function rememberCursor() {
    var profile = selectedProfile()
    cursorIfname = profile ? String(profile.ifname) : ""
  }

  function restoreCursor() {
    if (focusSection === "configs" && cursorIfname !== "") {
      for (var i = 0; i < wireguard.profiles.length; i++) {
        if (wireguard.profiles[i].ifname === cursorIfname) {
          configIndex = i
          break
        }
      }
    }
    ensureCursor()
  }

  function ensureCursor() {
    if (wireguard.profiles.length === 0) {
      focusSection = "header"
      configIndex = 0
      return
    }
    if (focusSection !== "configs" && focusSection !== "header") focusSection = "configs"
    if (configIndex >= wireguard.profiles.length) configIndex = Math.max(0, wireguard.profiles.length - 1)
    if (configIndex < 0) configIndex = 0
    // Whatever the cursor ended up on is what it should follow next time —
    // a clamp that lands on a different profile must not keep chasing the
    // one it left behind.
    rememberCursor()
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    ensureCursor()
    if (dy === 0) return
    if (focusSection === "header") {
      if (dy > 0 && wireguard.profiles.length > 0) {
        focusSection = "configs"
        configIndex = 0
        scrollCursorIntoView()
      }
      return
    }
    if (focusSection === "configs") {
      if (dy < 0 && configIndex === 0) {
        setHeaderCursor()
        return
      }
      configIndex = Math.max(0, Math.min(wireguard.profiles.length - 1, configIndex + dy))
      scrollCursorIntoView()
    }
  }

  function setHeaderCursor() {
    cursorActive = true
    focusSection = "header"
    if (panelFlick) panelFlick.contentY = 0
  }

  function setConfigCursor(index) {
    cursorActive = true
    focusSection = "configs"
    configIndex = index
    // Explicit, because hovering the row the cursor already sits on after a
    // reorder changes no index and so fires no change handler.
    rememberCursor()
    scrollCursorIntoView()
  }

  function selectedProfile() {
    if (wireguard.profiles.length === 0) return null
    return wireguard.profiles[Math.max(0, Math.min(configIndex, wireguard.profiles.length - 1))]
  }

  // A click or Enter on a row selects it for the detail grid — connecting and
  // disconnecting is the row's toggle (or the `t` key), never the row itself.
  function activateConfig(profile) {
    if (!profile) return
    wireguard.inspectedIfname = String(profile.ifname)
  }

  // The per-row toggle: bring this one tunnel up or down without touching the
  // others. Also what `t` does when the cursor is on a config row.
  function toggleConfig(profile) {
    if (wireguard.busy || !profile) return
    if (profile.active) wireguard.disconnectOne(profile)
    else wireguard.connectTo(profile)
  }

  function activateCursor() {
    ensureCursor()
    if (focusSection === "header") wireguard.toggle()
    else if (focusSection === "configs") activateConfig(selectedProfile())
  }

  function requestDelete(profile) {
    if (wireguard.busy || !profile) return
    pendingDelete = profile
  }

  function beginImport(kind, payload, suggested) {
    importKind = String(kind)
    importPayload = String(payload)
    // A sanitized provider filename can come back empty ("~/VPN (1).conf");
    // fall back to a free wgN rather than opening the prompt on nothing.
    importDialog.openWith(suggested !== "" ? String(suggested) : wireguard.suggestName())
  }

  function cancelImport() {
    importKind = ""
    importPayload = ""
    importDialog.dismiss()
    keyCatcher.forceActiveFocus()
  }

  function requestEdit(profile) {
    if (wireguard.busy || !profile) return
    pendingEdit = profile
  }

  // Either target takes the panel with it: the config goes to a zenity window
  // that would otherwise open behind a layer surface holding exclusive
  // keyboard focus, and the name goes to a centred window of its own.
  function confirmEdit(kind) {
    var profile = pendingEdit
    pendingEdit = null
    if (!profile || kind === "") return
    // A refused rename (a profile went away, an operation is running) leaves
    // nothing on screen — closing then would just lose the list.
    if (kind === "name") {
      if (!requestRename(profile)) return
    } else {
      if (!handOffToEditor(profile)) return
    }
    close()
  }

  function handOffToEditor(profile) {
    if (!wireguard.editConfig(profile, "")) return false
    editHandedOff = true
    return true
  }

  // Returns whether the prompt opened, so callers know whether the panel has
  // anything to hand over to.
  function requestRename(profile) {
    if (wireguard.busy || !profile) return false
    // Two overlay surfaces with exclusive keyboard focus would fight; the
    // code the user is no longer looking at loses.
    if (wireguard.qrVisible) wireguard.closeQr()
    pendingRename = profile
    renameWindow.openWith(profile.name)
    return true
  }

  function cancelRename() {
    pendingRename = null
    renameWindow.dismiss()
  }

  function confirmRename() {
    if (!renameAccepted) return
    var profile = pendingRename
    var name = renameClean
    cancelRename()
    wireguard.renameConfig(profile, name)
  }

  function confirmImport() {
    if (!importAccepted) return
    var kind = importKind
    var payload = importPayload
    var name = importNameClean
    cancelImport()
    if (kind === "file") wireguard.importFile(payload, name)
    else if (kind === "text") wireguard.importText(payload, name)
  }

  // Detached on purpose: nothing here waits on wl-copy, and a value the user
  // clicked is already on screen — a failure to copy it costs nothing that a
  // second click cannot fix.
  function copyToClipboard(value) {
    var text = String(value || "")
    if (text === "" || text === "--") return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(text) + " | wl-copy"])
  }

  function scrollCursorIntoView() {
    if (focusSection !== "configs" || !configRepeater) return
    // itemAt, not configColumn.children[i]: the Repeater itself sits in the
    // children list ahead of its delegates, so raw indexing is off by one.
    var item = configRepeater.itemAt(configIndex)
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Closing tears down neither the QR nor the rename prompt — both live in
  // windows of their own, and showing either closes this panel, so a teardown
  // here would kill the very thing the user just asked for. Opening is the
  // other half of that exclusion: those windows are full-screen with
  // exclusive keyboard focus, so a panel opened underneath one (IPC `open`,
  // or a `pickConfigFile` landing) would be invisible, unclickable and
  // unfocused until it went away.
  onOpenedChanged: {
    pendingDelete = null
    pendingEdit = null
    cancelImport()
    if (opened) {
      if (wireguard.qrVisible) wireguard.closeQr()
      cancelRename()
      // The error surface is back on screen; whatever happens to the editor
      // now needs no rescue.
      editHandedOff = false
      cursorActive = false
      if (panelFlick) panelFlick.contentY = 0
      wireguard.refresh()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }
  }
  onConfigIndexChanged: {
    rememberCursor()
    scrollCursorIntoView()
  }

  Service {
    id: wireguard
    settings: root.settings
    trafficMonitoring: root.opened
  }

  Connections {
    target: wireguard
    function onProfilesChanged() { root.restoreCursor() }
    // The picker runs whether or not the popup is open (bar right-click,
    // IPC); open the popup so the name prompt has somewhere to appear.
    function onImportReady(kind, payload, suggestedName) {
      if (!root.opened) root.open()
      root.beginImport(kind, payload, suggestedName)
    }
    // The QR window is centred on the screen and takes keyboard focus; the
    // panel behind it is in the way, so it goes — as does a rename prompt,
    // which holds the same kind of surface. One handler covers every entry
    // point — the q key, the row button and IPC.
    function onQrVisibleChanged() {
      if (!wireguard.qrVisible) return
      if (root.opened) root.close()
      if (root.pendingRename !== null) root.cancelRename()
    }
    // The panel stepped aside for an editor that never appeared — and it is
    // the only place lastError is read, so it comes back to say why. Cancel
    // and no-change do not reach this: they are not failures.
    function onEditFailed(reason) {
      if (!root.editHandedOff) return
      root.editHandedOff = false
      if (!root.opened) root.open()
    }
    // Cancel, no-change and completed saves are terminal but not failures.
    // Retire the UI-only marker so a later headless editor failure cannot
    // mistake this panel for the caller that needs reopening.
    function onEditFinished() { root.editHandedOff = false }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    // VPN toggle, not panel visibility — open/close/show/hide already cover
    // the popup, and the bar's left click promises the same thing.
    function toggle(): string {
      return wireguard.toggle() ? "ok" : "error: " + wireguard.actionRejection
    }
    function refresh(): string {
      return wireguard.refresh() ? "ok" : "error: " + wireguard.actionRejection
    }
    function down(): string {
      return wireguard.disconnectAll() ? "ok" : "error: " + wireguard.actionRejection
    }
    // Bring one tunnel up, leaving the rest alone. Takes a display name or an
    // interface name; a name shared by several profiles is refused rather than
    // resolved to an arbitrary one.
    function connect(target: string): string {
      var profile = wireguard.findByIfname(target)
      if (!profile) {
        var n = wireguard.countByName(target)
        if (n === 0) return "error: no such config: " + target
        if (n > 1) return "error: ambiguous name: " + target + " — use an interface name: " + wireguard.ifnamesForName(target).join(" ")
        profile = wireguard.findByName(target)
      }
      return wireguard.connectTo(profile) ? "ok" : "error: " + wireguard.actionRejection
    }
    // Take one tunnel down without touching the others (`down` alone still
    // disconnects everything). Same target resolution as `connect`.
    function disconnect(target: string): string {
      var profile = wireguard.findByIfname(target)
      if (!profile) {
        var n = wireguard.countByName(target)
        if (n === 0) return "error: no such config: " + target
        if (n > 1) return "error: ambiguous name: " + target + " — use an interface name: " + wireguard.ifnamesForName(target).join(" ")
        profile = wireguard.findByName(target)
      }
      return wireguard.disconnectOne(profile) ? "ok" : "error: " + wireguard.actionRejection
    }
    function status(): string { return wireguard.statusText }
    // The connection grid without the panel. Rates and ping only move while
    // something is watching them, so a headless caller sees the totals and
    // the addresses live, and "--" where a sample would have to be paid for.
    function details(): string { return wireguard.detailsText() }
    // Headless import — no prompt, the name is derived from the filename.
    // (`import` is a JS keyword, hence the longer name.)
    function importConfig(path: string): string {
      var name = wireguard.sanitizeName(path)
      if (!wireguard.isValidName(name)) return "error: cannot derive an interface name from " + path
      if (wireguard.countByIfname(name) > 1) return "error: ambiguous: several profiles use the interface " + name
      return wireguard.importFile(path, name) ? name : "error: " + wireguard.actionRejection
    }
    // Takes a display name or an interface name; a name shared by several
    // profiles is refused rather than resolved to an arbitrary one.
    function edit(target: string): string {
      var profile = wireguard.findByIfname(target)
      if (!profile) {
        var n = wireguard.countByName(target)
        if (n === 0) return "error: no such config: " + target
        if (n > 1) return "error: ambiguous name: " + target + " — use an interface name: " + wireguard.ifnamesForName(target).join(" ")
        profile = wireguard.findByName(target)
      }
      return wireguard.editConfig(profile, "") ? "ok" : "error: " + wireguard.actionRejection
    }
    // Same target resolution as edit; the new name is a display label, so
    // anything single-line goes — except a name another profile already
    // holds, which would poison every name-based entry point.
    function rename(target: string, newName: string): string {
      var profile = wireguard.findByIfname(target)
      if (!profile) {
        var n = wireguard.countByName(target)
        if (n === 0) return "error: no such config: " + target
        if (n > 1) return "error: ambiguous name: " + target + " — use an interface name: " + wireguard.ifnamesForName(target).join(" ")
        profile = wireguard.findByName(target)
      }
      var value = String(newName || "").trim()
      if (value === "") return "error: the new name must not be empty"
      if (value !== profile.name && wireguard.countByName(value) > 0) return "error: a profile named " + value + " already exists"
      return wireguard.renameConfig(profile, value) ? "ok" : "error: " + wireguard.actionRejection
    }
    function importPick(): string {
      return wireguard.pickConfigFile() ? "ok" : "error: " + wireguard.actionRejection
    }
    function importPaste(): string {
      return wireguard.pasteConfig() ? "ok" : "error: " + wireguard.actionRejection
    }
    // Headless export — no warning dialog: an explicit path in argv is
    // already deliberate in a way a panel click is not. The file lands 0600.
    function exportConfig(target: string, path: string): string {
      var profile = wireguard.findByIfname(target)
      if (!profile) {
        var n = wireguard.countByName(target)
        if (n === 0) return "error: no such config: " + target
        if (n > 1) return "error: ambiguous name: " + target + " — use an interface name: " + wireguard.ifnamesForName(target).join(" ")
        profile = wireguard.findByName(target)
      }
      if (String(path || "") === "") return "error: no destination path"
      return wireguard.exportToPath(profile, path) ? "ok" : "error: " + wireguard.actionRejection
    }
    // The QR has its own window, so this never touches the panel — a
    // headless caller gets the code centred on screen and nothing else.
    function qr(target: string): string {
      var profile = wireguard.findByIfname(target)
      if (!profile) {
        var n = wireguard.countByName(target)
        if (n === 0) return "error: no such config: " + target
        if (n > 1) return "error: ambiguous name: " + target + " — use an interface name: " + wireguard.ifnamesForName(target).join(" ")
        profile = wireguard.findByName(target)
      }
      // "ok" has to mean a code is coming: with no panel in the way, the
      // return value is the only thing a headless caller gets back.
      var problem = wireguard.showQr(profile)
      return problem === "" ? "ok" : "error: " + problem
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // The AmneziaWG mark, the same one the panel header uses at display size.
    // No tooltip on hover: the icon itself is the status display — full
    // brightness while a tunnel is up, dimmed while disconnected.
    iconComponent: Component {
      Item {
        AmneziaIcon {
          anchors.centerIn: parent
          iconSize: Style.space(13)
          color: root.barIconColor
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) {
        if (wireguard.active) wireguard.disconnectAll()
        else root.open()
      } else if (buttonCode === Qt.MiddleButton) {
        wireguard.refresh()
      } else {
        // Left click opens/closes the panel — the VPN toggle lives on the
        // hero switch, the `t` key, and the IPC `toggle` command.
        root.toggle()
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // Wide enough for the detail grid: two label/value pairs per row, with a
    // real endpoint ("185.55.56.151:51820", not a short TEST-NET one) and a
    // /32 tunnel address both reading in full, and the six pixels the grid
    // gives back to align with the hero switch already deducted. A hostname
    // endpoint can still outgrow it — that is what the tooltip is for.
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(480))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.pendingDelete !== null || root.pendingEdit !== null || importDialog.visible
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onDeleteRequested: {
        if (root.cursorActive && root.focusSection === "configs") root.requestDelete(root.selectedProfile())
      }
      onTextKey: function(t) {
        if (t === "t" || t === "T") {
          if (root.cursorActive && root.focusSection === "configs") root.toggleConfig(root.selectedProfile())
          else wireguard.toggle()
        }
        else if (t === "r" || t === "R") wireguard.refresh()
        else if (t === "d" || t === "D") wireguard.disconnectAll()
        else if (t === "i" || t === "I") wireguard.pickConfigFile()
        else if (t === "v" || t === "V") wireguard.pasteConfig()
        // e and n skip the chooser, but not the closing: the panel is as much
        // in the way of zenity and of the rename window as it is of the QR.
        else if (t === "e" || t === "E") {
          if (root.cursorActive && root.focusSection === "configs") {
            if (root.handOffToEditor(root.selectedProfile())) root.close()
          }
        }
        else if (t === "n" || t === "N") {
          if (root.cursorActive && root.focusSection === "configs"
              && root.requestRename(root.selectedProfile())) root.close()
        }
        else if (t === "q" || t === "Q") {
          if (root.cursorActive && root.focusSection === "configs") wireguard.showQr(root.selectedProfile())
        }
      }

      // The row highlight is the keyboard cursor, and only a cursor target
      // ever moved it — so leaving a row for the hero or the CONFIGS header
      // changed nothing and the row it left stayed lit. This sink lies under
      // the whole panel and takes the hover the instant no cursor target
      // holds it, which is exactly "the pointer left the list". Rows and
      // buttons sit above it and keep their hover, so a row holds its cursor
      // while the pointer is on its own actions. NoButton so clicks still
      // reach the items above it.
      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.NoButton
        hoverEnabled: true
        onEntered: root.cursorActive = false
      }

      // The sink catches an exit that lands somewhere else in the panel; it
      // cannot catch one that lands nowhere. A pointer leaving the window
      // from a row enters nothing, so the row it left kept the cursor and
      // stayed lit under a pointer that was gone. A non-blocking handler,
      // hovered for the whole panel: rows and buttons below it keep their
      // own hover, and this only goes false when the pointer is out.
      HoverHandler {
        onHoveredChanged: if (!hovered) root.cursorActive = false
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            // Exposed for the hero's trailingControl, whose `root` resolves to
            // PanelHero (not this Panel) — reach panel state via `header`.
            readonly property bool ringVisible: root.headerHasCursor
            function focusHero() { root.setHeaderCursor() }

            PanelHero {
              id: hero
              width: parent.width
              title: "Omazia"
              meta: wireguard.active ? "Connected: " + wireguard.activeNames.join(", ") : "Disconnected"
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: wireguard.active ? 1.0 : 0.5
              // The bar's mark, scaled up to display size.
              iconComponent: Component {
                AmneziaIcon {
                  iconSize: Style.font.display
                  color: root.iconColor
                }
              }

              // The switch stays last, hard against the trailing edge — the
              // detail grid below aligns to its track, and anything parked to
              // its right would break that.
              trailingControl: Component {
                Row {
                  spacing: Style.space(4)

                  // The QR of the tunnel the grid is describing, without going
                  // to its row first. Only while something is up: with nothing
                  // connected it would have no subject.
                  PanelActionButton {
                    iconText: "󰐲"
                    tooltipText: "Show " + wireguard.inspectedName + " as a QR code (q)"
                    visible: wireguard.inspectedActive
                    anchors.verticalCenter: parent.verticalCenter
                    // Full brightness at rest, like every other hero control:
                    // dimming until hover is for the row actions, which are
                    // many and would otherwise shout over the list. This one
                    // is alone beside the switch and reads as disabled when
                    // it is merely unhovered. Hover then adds only its fill.
                    foreground: hero.foreground
                    fontFamily: hero.fontFamily
                    // A hero action, not a row action: the same size the
                    // network panel gives the glyph it parks here, rather
                    // than the row-sized default the CONFIGS buttons use.
                    fontSize: Style.font.subtitle * 1.5
                    enabled: !wireguard.busy
                    onHovered: function(on) { if (on) header.focusHero() }
                    onClicked: wireguard.showQr(wireguard.inspectedProfile)
                  }

                  ToggleSwitch {
                    id: powerSwitch
                    visible: wireguard.profiles.length > 0
                    anchors.verticalCenter: parent.verticalCenter
                    checked: wireguard.active
                    busy: wireguard.busy
                    hasCursor: header.ringVisible
                    foreground: hero.foreground
                    onHovered: function(on) { if (on) header.focusHero() }
                    onToggled: wireguard.toggle()

                    PanelToolTip {
                      visible: powerSwitch.containsMouse
                      text: root.toggleHint
                      fontFamily: hero.fontFamily
                    }
                  }
                }
              }
            }
          }

          Text {
            visible: wireguard.actionStatus !== "" || wireguard.lastError !== ""
            width: parent.width
            text: wireguard.actionStatus !== "" ? wireguard.actionStatus : wireguard.lastError
            color: wireguard.lastError !== "" && wireguard.actionStatus === "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // What the tunnel is doing, in the shape the network panel uses for
          // the same job. Rates and totals come from the interface counters,
          // the address and endpoint from the profile — nothing here needs a
          // privilege the widget does not already have. Only the first active
          // tunnel is described: one endpoint and one ping cannot stand for
          // two, and the rows below keep their own traffic lines.
          Column {
            visible: wireguard.inspectedActive
            // Short of the full width by the hero switch's cursor-ring pad:
            // ToggleSwitch reserves that ring outside its track, so the item
            // is flush with the edge while the switch you can see is not.
            // Optical alignment beats geometric here — the numbers and the
            // track are what the eye lines up.
            width: parent.width - Style.space(6)
            spacing: Style.spacing.labelGap

            // Says what the grid leaves out, and only when it leaves
            // something out: which tunnel it picked when several are up, and
            // that the endpoint and routes below belong to the first peer of
            // a profile that has more than one.
            Text {
              visible: text !== ""
              width: parent.width
              text: {
                var notes = []
                if (wireguard.activeNames.length > 1) notes.push("Showing " + wireguard.inspectedName)
                if (wireguard.peerCount > 1) notes.push("first of " + wireguard.peerCount + " peers")
                return notes.join(" · ")
              }
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              bottomPadding: Style.spacing.labelGap
            }

            // Two columns of pairs, not four columns of cells: a four-column
            // grid sizes every column to its own widest value, and one long
            // endpoint then makes the right half visibly wider than the left.
            // Each pair takes exactly half instead, whatever is in it.
            GridLayout {
              width: parent.width
              columns: 2
              columnSpacing: Style.space(14)
              rowSpacing: Style.spacing.labelGap

              // The whole row goes when the probe is off — a permanent pair of
              // dashes would suggest a measurement that failed rather than one
              // nobody asked for. GridLayout skips invisible items, so the
              // rows below close the gap.
              DetailPair {
                visible: wireguard.pingHost !== ""
                label: "Ping"
                value: wireguard.fmtPing(wireguard.pingLatency)
                valueColor: wireguard.pingLoss > 0 ? root.urgent : root.foreground
              }
              DetailPair {
                visible: wireguard.pingHost !== ""
                label: "Packet Loss"
                value: wireguard.fmtLoss(wireguard.pingLoss)
                valueColor: wireguard.pingLoss > 0 ? root.urgent : root.foreground
              }

              // "--" until a rate has actually been measured: the first
              // sample of a session has no interval behind it, and printing
              // its zero would claim an idle tunnel on no evidence.
              DetailPair {
                label: "Receiving"
                value: wireguard.trafficRate(wireguard.inspectedDevice, "rxRate")
              }
              DetailPair {
                label: "Sending"
                value: wireguard.trafficRate(wireguard.inspectedDevice, "txRate")
              }

              // Session totals, not lifetime ones: awg-quick creates the
              // wg interface at activation, so its counters start at zero.
              DetailPair {
                label: "Downloaded"
                value: wireguard.trafficTotal(wireguard.inspectedDevice, "rx")
              }
              DetailPair {
                label: "Uploaded"
                value: wireguard.trafficTotal(wireguard.inspectedDevice, "tx")
              }

              DetailPair {
                label: "IP Address"
                value: root.detailText(wireguard.detail("ip") !== "" ? wireguard.detail("ip") : wireguard.detail("ip6"))
                tooltipText: "Copy the tunnel address"
              }
              DetailPair {
                label: "Endpoint"
                value: root.detailText(wireguard.detail("endpoint"))
                tooltipText: "Copy the endpoint"
              }

              // Copyable like the two above, and for the same reason: a route
              // list is exactly what a user pastes into the next config.
              DetailPair {
                label: "Allowed IPs"
                value: root.detailText(wireguard.detail("allowed"))
                tooltipText: "Copy the routes"
              }
              DetailPair {
                label: "DNS"
                value: root.detailText(wireguard.detail("dns"))
                tooltipText: "Copy the DNS servers"
              }
            }
          }

          PanelSeparator {
            foreground: root.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)

            Item {
              width: parent.width
              implicitHeight: Math.max(sectionLabel.implicitHeight, importActions.implicitHeight)

              PanelSectionHeader {
                id: sectionLabel
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "CONFIGS"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Row {
                id: importActions
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                // These two are not cursor targets, but they are the one thing
                // close enough to the first row that a fast pointer can reach
                // them without ever crossing the sink below. Drop the cursor
                // here too, or that row stays lit while the pointer is here.
                PanelActionButton {
                  iconText: "󰐕"
                  tooltipText: "Import a .conf file (i)"
                  foreground: root.dim
                  hoverColor: root.foreground
                  fontFamily: root.fontFamily
                  enabled: !wireguard.busy
                  onHovered: function(on) { if (on) root.cursorActive = false }
                  onClicked: wireguard.pickConfigFile()
                }

                PanelActionButton {
                  iconText: "󰅌"
                  tooltipText: "Import from clipboard (v)"
                  foreground: root.dim
                  hoverColor: root.foreground
                  fontFamily: root.fontFamily
                  enabled: !wireguard.busy
                  onHovered: function(on) { if (on) root.cursorActive = false }
                  onClicked: wireguard.pasteConfig()
                }
              }
            }

            Text {
              visible: wireguard.profiles.length === 0
              width: parent.width
              text: "No AmneziaWG tunnels in /etc/amnezia/amneziawg\nImport a .conf with + or paste one with v"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WrapAnywhere
              horizontalAlignment: Text.AlignHCenter
            }

            Column {
              id: configColumn
              visible: wireguard.profiles.length > 0
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                id: configRepeater
                model: wireguard.profiles
                ConfigRow {
                  required property var modelData
                  required property int index
                  width: configColumn.width
                  profile: modelData
                  rowIndex: index
                }
              }
            }
          }
        }
      }

      // Name prompt for an incoming config, shared by both import paths.
      // The interface name is derived from the filename, so the name
      // is the one thing neither a picked file nor pasted text can supply
      // reliably — and it doubles as the replace-or-not decision.
      NamePrompt {
        id: importDialog
        anchors.fill: parent
        title: root.importSourceLabel
        placeholder: "Interface name"
        hint: root.importHintText
        accepted: root.importAccepted
        confirmLabel: root.importReplaces ? "Replace" : "Import"
        foreground: root.foreground
        dim: root.dim
        urgent: root.urgent
        fontFamily: root.fontFamily
        onConfirmed: root.confirmImport()
        onCanceled: root.cancelImport()
      }

      // One pencil, two targets: the chooser splits "edit" into the config
      // text (zenity round-trip) and the display name (rename prompt).
      // Keyboard users never see it — e and n go straight to either.
      Item {
        id: editChooser
        anchors.fill: parent
        visible: root.pendingEdit !== null

        property int selectedIndex: 1
        readonly property var choices: [
          { label: "Cancel", kind: "" },
          { label: "Config", kind: "config" },
          { label: "Name", kind: "name" }
        ]

        onVisibleChanged: {
          if (visible) {
            selectedIndex = 1
            editChooser.forceActiveFocus()
          } else {
            // Harmless when a choice closed the panel: reopening puts the
            // focus back on the key catcher anyway.
            keyCatcher.forceActiveFocus()
          }
        }
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) root.pendingEdit = null
          else if (event.key === Qt.Key_Left || event.key === Qt.Key_Backtab)
            selectedIndex = (selectedIndex + choices.length - 1) % choices.length
          else if (event.key === Qt.Key_Right || event.key === Qt.Key_Tab)
            selectedIndex = (selectedIndex + 1) % choices.length
          else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
            root.confirmEdit(choices[selectedIndex].kind)
          else if (event.key === Qt.Key_E || event.key === Qt.Key_C) root.confirmEdit("config")
          else if (event.key === Qt.Key_N) root.confirmEdit("name")
          else return
          event.accepted = true
        }

        Rectangle {
          anchors.fill: parent
          color: Util.alpha(Color.background, 0.7)

          MouseArea { anchors.fill: parent; onClicked: root.pendingEdit = null }

          BorderSurface {
            id: editCard
            width: Math.min(parent.width - Style.space(32), Style.space(340))
            height: editCard.contentTopInset + editCard.contentBottomInset
              + editMessage.implicitHeight + Style.space(20) + Style.space(34)
            anchors.centerIn: parent
            color: Color.background
            borderSpec: Border.flat(Color.accent, Style.normalBorderWidth)
            padding: Style.space(18)
            radius: Style.cornerRadius

            MouseArea { anchors.fill: parent; onClicked: {} }

            Item {
              anchors.fill: parent
              anchors.topMargin: editCard.contentTopInset
              anchors.rightMargin: editCard.contentRightInset
              anchors.bottomMargin: editCard.contentBottomInset
              anchors.leftMargin: editCard.contentLeftInset

              Text {
                id: editMessage
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                text: "Edit " + (root.pendingEdit ? root.pendingEdit.name : "") + "?"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                wrapMode: Text.WordWrap
              }

              Row {
                id: editButtonsRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                spacing: Style.space(10)

                Repeater {
                  model: editChooser.choices

                  BorderSurface {
                    required property int index
                    required property var modelData

                    readonly property bool selected: editChooser.selectedIndex === index

                    // Three equal shares of the card, not the fixed 88 the
                    // two-button ConfirmDialog gets away with — three of
                    // those overflow this card's width.
                    width: (editButtonsRow.width - Style.space(10) * 2) / 3
                    height: Style.space(34)
                    color: selected ? Util.alpha(Color.foreground, 0.08) : "transparent"
                    borderSpec: Border.flat(selected
                      ? Color.accent
                      : Util.alpha(root.foreground, 0.38), Style.normalBorderWidth)
                    radius: 0

                    Text {
                      anchors.centerIn: parent
                      text: modelData.label
                      color: selected ? Color.accent : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    MouseArea {
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onEntered: editChooser.selectedIndex = index
                      onClicked: root.confirmEdit(modelData.kind)
                    }
                  }
                }
              }
            }
          }
        }
      }

      ConfirmDialog {
        id: deleteDialog
        anchors.fill: parent
        opened: root.pendingDelete !== null
        message: "Delete connection " + (root.pendingDelete ? root.pendingDelete.name : "") + "?"
        confirmText: "Delete"
        foreground: root.foreground
        fontFamily: root.fontFamily
        Keys.onPressed: function(event) { event.accepted = deleteDialog.handleKey(event) }
        onOpenedChanged: {
          if (opened) {
            selectedIndex = 0
            forceActiveFocus()
          } else {
            keyCatcher.forceActiveFocus()
          }
        }
        onCanceled: root.pendingDelete = null
        onConfirmed: {
          var profile = root.pendingDelete
          root.pendingDelete = null
          wireguard.deleteConfig(profile)
        }
      }
    }
  }

  // Screen-centred, not panel-bound: an AmneziaWG config makes a far denser
  // code than the popup can show at a scannable size. Closing it deletes
  // the PNG in XDG_RUNTIME_DIR.
  QrWindow {
    id: qrWindow
    anchorItem: button
    open: wireguard.qrVisible
    name: wireguard.qrName
    path: wireguard.qrPath
    loading: wireguard.qrLoading
    error: wireguard.qrError
    foreground: root.foreground
    dim: root.dim
    urgent: root.urgent
    fontFamily: root.fontFamily
    onCloseRequested: wireguard.closeQr()
  }

  // Screen-centred like the QR, and for the same reason: the popup is pinned
  // under its bar icon, so a prompt inside it opens in a corner with a field
  // squeezed to the column's width. Opening it closes the panel; closing it
  // leaves the panel closed.
  RenameWindow {
    id: renameWindow
    anchorItem: button
    open: root.pendingRename !== null
    title: "Rename " + (root.pendingRename ? root.pendingRename.name : "")
    placeholder: "Connection name"
    hint: root.renameHint
    accepted: root.renameAccepted
    confirmLabel: "Rename"
    foreground: root.foreground
    dim: root.dim
    urgent: root.urgent
    fontFamily: root.fontFamily
    onConfirmed: root.confirmRename()
    onCanceled: root.cancelRename()
  }

  // Every cell in the grid holds its place from the moment the tunnel comes
  // up, so a value that is not in yet reads as "--" rather than collapsing
  // the row and shoving the list below it around.
  function detailText(value) {
    var text = String(value || "")
    return text === "" ? "--" : text
  }

  component InfoLabel: Text {
    color: root.foreground
    opacity: 0.6
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  // Label left, value hard against the right edge of its half. The label
  // keeps its natural width and the value takes the rest, so a long endpoint
  // elides inside its own half instead of stealing width from the half next
  // to it.
  component DetailPair: Item {
    id: pair

    property string label: ""
    property string value: ""
    property color valueColor: root.foreground
    // A tooltip is what marks a value as worth copying — the ones that are
    // are exactly the ones a user retypes elsewhere.
    property string tooltipText: ""
    readonly property bool copyable: tooltipText !== "" && value !== "--"

    // Equal preferred widths plus fillWidth is what makes the halves match:
    // ask for nothing, and the layout hands both cells the same share.
    Layout.fillWidth: true
    Layout.preferredWidth: 0
    implicitHeight: Math.max(pairLabel.implicitHeight, pairValue.implicitHeight)

    InfoLabel {
      id: pairLabel
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: pair.label
    }

    Text {
      id: pairValue
      anchors.left: pairLabel.right
      anchors.leftMargin: Style.space(8)
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: pair.value
      color: pair.valueColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideRight

      MouseArea {
        id: valueMouse
        anchors.fill: parent
        enabled: pair.copyable
        hoverEnabled: enabled
        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: root.copyToClipboard(pair.value)
      }

      // An elided value is unreadable, and these are the ones worth reading —
      // so the tooltip carries the whole string when the cell could not.
      PanelToolTip {
        visible: valueMouse.enabled && valueMouse.containsMouse
        text: pairValue.truncated ? pair.value + " · " + pair.tooltipText : pair.tooltipText
        fontFamily: root.fontFamily
      }
    }
  }

  component ConfigRow: CursorSurface {
    id: configRow
    // {ifname, name, active} — the row keeps the whole profile so its actions
    // hit exactly this profile even when names collide.
    property var profile: null
    property int rowIndex: 0
    readonly property bool connected: profile ? profile.active === true : false
    // The row the detail grid above is describing — highlighted so it is clear
    // which tunnel the numbers belong to when several are up.
    readonly property bool inspected: profile
      && wireguard.inspectedActive
      && wireguard.inspectedIfnameEffective === profile.ifname

    hasCursor: root.cursorActive && root.focusSection === "configs" && root.configIndex === rowIndex
    current: inspected
    foreground: root.foreground

    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: wireguard.busy ? Qt.ArrowCursor : Qt.PointingHandCursor
      onEntered: root.setConfigCursor(configRow.rowIndex)
      onClicked: root.activateConfig(configRow.profile)
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        text: configRow.connected ? "󰄬" : "󰌘"
        color: configRow.connected ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: rowContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: configRow.profile ? configRow.profile.name : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          // Connect and disconnect are the toggle on the right; a click on the
          // row only points the grid above at this tunnel. When the grid is
          // already describing this row its numbers are up there in full, so
          // the caption gives a live traffic line for any other active tunnel
          // and a plain word for the rest.
          text: {
            if (!configRow.connected) return "Disconnected"
            if (configRow.inspected) return "Connected — shown above"
            var line = wireguard.trafficLine(configRow.profile ? configRow.profile.ifname : "")
            return line !== "" ? line : "Connected — click to view"
          }
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      // One tunnel, up or down, without touching the others. Its own click
      // target sits above the row's, so flipping the switch never also
      // re-points the detail grid. Hidden until the row is hovered, like the
      // three action buttons — the check glyph on the left already carries
      // "connected" at rest, so a permanent switch on every row is noise.
      ToggleSwitch {
        id: rowSwitch
        checked: configRow.connected
        busy: wireguard.busy
        interactive: true
        cursorRing: false
        foreground: root.foreground
        visible: configRow.hasCursor
        Layout.alignment: Qt.AlignVCenter
        onToggled: root.toggleConfig(configRow.profile)

        PanelToolTip {
          visible: rowSwitch.containsMouse
          text: configRow.connected ? "Disconnect " + (configRow.profile ? configRow.profile.name : "")
                                    : "Connect " + (configRow.profile ? configRow.profile.name : "")
          fontFamily: root.fontFamily
        }
      }

      PanelActionButton {
        iconText: "󰏫"
        foreground: root.dim
        hoverColor: root.foreground
        fontFamily: root.fontFamily
        enabled: !wireguard.busy
        visible: configRow.hasCursor
        Layout.alignment: Qt.AlignVCenter
        onClicked: root.requestEdit(configRow.profile)
      }

      PanelActionButton {
        iconText: "󰐲"
        foreground: root.dim
        hoverColor: root.foreground
        fontFamily: root.fontFamily
        enabled: !wireguard.busy
        visible: configRow.hasCursor
        Layout.alignment: Qt.AlignVCenter
        onClicked: wireguard.showQr(configRow.profile)
      }

      PanelActionButton {
        iconText: "󰆴"
        foreground: root.dim
        hoverColor: root.urgent
        fontFamily: root.fontFamily
        enabled: !wireguard.busy
        visible: configRow.hasCursor
        Layout.alignment: Qt.AlignVCenter
        onClicked: root.requestDelete(configRow.profile)
      }
    }
  }
}
