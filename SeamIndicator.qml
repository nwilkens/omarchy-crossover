import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons

// A brief glow along the screen edge the cursor crossed. This is the whole
// reason the setup reads as "another monitor" rather than "a remote control":
// without it, a cursor that arrives from nowhere is disorienting.
Variants {
  id: root

  property string position: ""
  property color glow: Color.accent
  property bool enabled: true

  model: Quickshell.screens

  // Only the screen that actually owns the outer edge should light up, so a
  // three-monitor desk does not flash all three at once.
  function ownsEdge(screen, pos) {
    if (!screen) return false
    var screens = Quickshell.screens
    var best = null
    for (var i = 0; i < screens.length; i++) {
      var candidate = screens[i]
      if (best === null) { best = candidate; continue }
      switch (pos) {
        case "left": if (candidate.x < best.x) best = candidate; break
        case "right": if (candidate.x + candidate.width > best.x + best.width) best = candidate; break
        case "top": if (candidate.y < best.y) best = candidate; break
        case "bottom": if (candidate.y + candidate.height > best.y + best.height) best = candidate; break
      }
    }
    return best === screen
  }

  PanelWindow {
    id: panel
    required property var modelData

    screen: modelData
    visible: root.enabled && root.position !== "" && root.ownsEdge(modelData, root.position)
    color: "transparent"

    WlrLayershell.namespace: "crossover-seam"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    // Purely decorative, so the input region stays empty and clicks pass to
    // whatever is underneath.
    mask: Region {}

    anchors {
      left: root.position !== "right"
      right: root.position !== "left"
      top: root.position !== "bottom"
      bottom: root.position !== "top"
    }

    readonly property bool vertical: root.position === "left" || root.position === "right"
    implicitWidth: vertical ? Style.space(14) : 0
    implicitHeight: vertical ? 0 : Style.space(14)

    Rectangle {
      anchors.fill: parent
      opacity: panel.visible ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

      gradient: Gradient {
        orientation: panel.vertical ? Gradient.Horizontal : Gradient.Vertical
        GradientStop {
          position: 0
          color: root.position === "left" || root.position === "top"
                 ? Qt.rgba(root.glow.r, root.glow.g, root.glow.b, 0.85)
                 : "transparent"
        }
        GradientStop {
          position: 1
          color: root.position === "right" || root.position === "bottom"
                 ? Qt.rgba(root.glow.r, root.glow.g, root.glow.b, 0.85)
                 : "transparent"
        }
      }
    }
  }
}
