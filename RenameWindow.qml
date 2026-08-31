import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// The rename prompt as a screen-centred window of its own, not a card inside
// the bar popup: the popup is a 340px column pinned under its bar icon, so a
// prompt centred in it lands in a corner of the screen with a cramped field.
// The panel closes as this opens — same exclusion the QR window gets, and for
// the same reason: two layer-shell surfaces with exclusive keyboard focus
// fight over it.
//
// Frame copied from QrWindow.qml; only the namespace and the contents differ.
PanelWindow {
  id: root

  // Only used to pick the monitor: the prompt belongs on the screen whose bar
  // the user just clicked.
  required property Item anchorItem
  property bool open: false
  property alias title: prompt.title
  property alias placeholder: prompt.placeholder
  property alias hint: prompt.hint
  property alias accepted: prompt.accepted
  property alias confirmLabel: prompt.confirmLabel
  property alias value: prompt.value
  property color foreground: Color.foreground
  property color dim: Qt.darker(foreground, 1.55)
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family

  signal confirmed()
  signal canceled()

  function openWith(text) { prompt.openWith(text) }
  function dismiss() { prompt.dismiss() }

  visible: open
  screen: anchorItem && anchorItem.QsWindow.window ? anchorItem.QsWindow.window.screen : null
  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "omazia-rename"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

  // openWith() runs while the window is still hidden, so the focus it asks
  // for lands nowhere and the field would open cold. Ask again once the
  // surface is mapped, as QrWindow does.
  onOpenChanged: {
    if (open) Qt.callLater(function() {
      if (root.open) prompt.focusField()
    })
  }

  NamePrompt {
    id: prompt
    anchors.fill: parent
    // Room for a full connection name, which the panel-bound card never had.
    maxCardWidth: Style.space(420)
    foreground: root.foreground
    dim: root.dim
    urgent: root.urgent
    fontFamily: root.fontFamily
    onConfirmed: root.confirmed()
    onCanceled: root.canceled()
  }
}
