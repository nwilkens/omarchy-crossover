import QtQuick
import qs.Commons

// Two screens with a cursor crossing the gap between them. Drawn with plain
// rectangles rather than a Shape because it has to stay crisp at bar size.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground
  property bool linked: false

  implicitWidth: iconSize * 1.32
  implicitHeight: iconSize
  width: implicitWidth
  height: implicitHeight

  readonly property real stroke: Math.max(1, Math.round(iconSize * 0.09))
  readonly property real screenWidth: Math.round(width * 0.40)
  readonly property real screenHeight: Math.round(height * 0.66)

  Rectangle {
    id: here
    width: root.screenWidth
    height: root.screenHeight
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    radius: Math.max(1, Math.round(root.iconSize * 0.12))
    color: root.color
    opacity: 0.9
  }

  Rectangle {
    id: there
    width: root.screenWidth
    height: root.screenHeight
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    radius: here.radius
    color: "transparent"
    border.width: root.stroke
    border.color: root.color
    opacity: root.linked ? 0.9 : 0.45
  }

  // The crossing dot only fills in once a peer is actually linked, so the bar
  // shows link state without a second glyph.
  Rectangle {
    width: root.stroke * 2
    height: width
    radius: width / 2
    anchors.centerIn: parent
    color: root.color
    opacity: root.linked ? 1 : 0.3
    Behavior on opacity { NumberAnimation { duration: 180 } }
  }
}
