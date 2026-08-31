import QtQuick
import QtQuick.Effects
import qs.Commons

// The AmneziaWG mark, recoloured to a single flat colour so it can stand in
// for a Nerd Font glyph in the bar slot and the panel hero. The shipped SVG
// (amneziawg.svg) is a white silhouette; MultiEffect tints it the same way
// the tray tints symbolic icons.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  Image {
    id: mark
    anchors.fill: parent
    source: Qt.resolvedUrl("amneziawg.svg")
    fillMode: Image.PreserveAspectFit
    // Decode at physical pixels so the silhouette stays crisp in a tiny slot.
    sourceSize.width: Math.round(width * Screen.devicePixelRatio)
    sourceSize.height: Math.round(height * Screen.devicePixelRatio)
    // Kept as a hidden layer so the effect can sample it as a texture.
    layer.enabled: true
    visible: false
  }

  MultiEffect {
    anchors.fill: mark
    source: mark
    colorization: 1.0
    colorizationColor: root.color
  }
}
