import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// The QR code as a screen-centred window of its own, not an overlay inside
// the bar popup: an AmneziaWG config is ~300-500 bytes, so its code runs to
// 80-100 modules a side and needs far more room than a panel-width card to
// stay scannable. The panel closes as the window opens, so this surface is
// also the only place a request can report progress or failure.
//
// Modelled on the shell's own Wi-Fi share card,
// /usr/share/omarchy/shell/plugins/panels/network/WifiQrPanel.qml:
// full-screen layer-shell on the overlay layer with exclusive keyboard
// focus, dimmed backdrop, card centred inside.
PanelWindow {
  id: root

  // Only used to pick the monitor: the QR belongs on the screen whose bar
  // the user just clicked.
  required property Item anchorItem
  property bool open: false
  property string name: ""
  property string path: ""
  property bool loading: false
  property string error: ""
  property color foreground: Color.foreground
  property color dim: Qt.darker(foreground, 1.55)
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family

  signal closeRequested()

  readonly property bool showingCode: path !== "" && !loading && error === ""
  // The PNG's white quiet-zone margin, kept out of the image itself so the
  // backing rectangle can supply the contrast a phone camera wants.
  readonly property real codeInset: Style.space(6)

  // Side of the largest code square this screen can hold, leaving room for
  // the title above it and the private-key warning below.
  readonly property real availableSide: {
    var w = screen ? screen.width : 0
    var h = screen ? screen.height : 0
    if (w <= 0 || h <= 0) return Style.space(320)
    return Math.max(Style.space(160), Math.min(w - Style.space(120), h - Style.space(280)))
  }

  visible: open
  screen: anchorItem && anchorItem.QsWindow.window ? anchorItem.QsWindow.window.screen : null
  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "omazia-qr"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

  // The window is instantiated hidden, so `focus: true` below is evaluated
  // before the surface is mapped and Escape would land nowhere. Re-acquire
  // after mapping, as KeyboardPanel does.
  onOpenChanged: {
    if (open) Qt.callLater(function() {
      if (root.open) keyCatcher.forceActiveFocus()
    })
  }

  Item {
    id: keyCatcher
    anchors.fill: parent
    focus: true

    // Same keys as every other dismissable surface in the widget: Esc, the
    // q that opened it, and Enter for the muscle memory of a dialog.
    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Escape || event.key === Qt.Key_Q
          || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        root.closeRequested()
        event.accepted = true
      }
    }

    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.45)

      MouseArea { anchors.fill: parent; onClicked: root.closeRequested() }
    }

    BorderSurface {
      id: card

      // Sized from the PNG's natural pixel size, capped to the screen. The
      // backend renders at 6px per module; scaling that by a fraction makes
      // modules of uneven width, which is exactly what a scanner trips on.
      readonly property real codeSide: {
        var natural = qrImage.implicitWidth > 0
          ? qrImage.implicitWidth + root.codeInset * 2
          : Style.space(240)
        return Math.max(Style.space(160), Math.min(natural, root.availableSide))
      }

      width: Math.max(Style.space(320), codeSide) + card.contentLeftInset + card.contentRightInset
      height: card.contentTopInset + card.contentBottomInset + content.implicitHeight
      anchors.centerIn: parent
      color: Color.background
      borderSpec: Border.flat(Color.accent, Style.normalBorderWidth)
      padding: Style.space(18)
      radius: Style.cornerRadius

      // Swallow clicks on the card so they don't reach the dismissal area.
      MouseArea { anchors.fill: parent }

      Column {
        id: content
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: card.contentTopInset
        anchors.leftMargin: card.contentLeftInset
        anchors.rightMargin: card.contentRightInset
        spacing: Style.space(10)

        Text {
          width: parent.width
          text: root.name
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          elide: Text.ElideMiddle
          horizontalAlignment: Text.AlignHCenter
        }

        Text {
          width: parent.width
          visible: root.loading
          text: "Rendering the QR code…"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
        }

        Text {
          width: parent.width
          visible: root.error !== ""
          text: root.error
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          horizontalAlignment: Text.AlignHCenter
        }

        // White backing behind the PNG: phone cameras want contrast, and the
        // card background is dark.
        Rectangle {
          visible: root.showingCode
          width: card.codeSide
          height: width
          color: "white"
          anchors.horizontalCenter: parent.horizontalCenter

          Image {
            id: qrImage
            anchors.fill: parent
            anchors.margins: root.codeInset
            source: root.path !== "" ? "file://" + root.path : ""
            fillMode: Image.PreserveAspectFit
            // Crisp modules beat antialiased mush for a camera — but only
            // while we are magnifying. A code too big for the screen gets
            // scaled down by a fraction, and nearest-neighbour then drops
            // and doubles whole module columns, which no scanner survives;
            // filtering is the lesser evil there.
            smooth: width < implicitWidth
            cache: false
          }
        }

        Text {
          width: parent.width
          visible: root.showingCode
          text: "Scan with the AmneziaWG app. The code holds the private key — this moves the profile; two devices on one key kick each other offline."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
