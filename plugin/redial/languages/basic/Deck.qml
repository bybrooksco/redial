pragma ComponentBehavior: Bound

import QtQuick

// re:dial basic: the Deck layout on the quiet track (spec 2026-11-06). A still fan of cards; the
// front card is the info card: the chosen tool's icon (the state sign in a hint or can't act), its
// name and line, and a short accent bar as the marker, which becomes the meter for a level.
LookBase {
  id: look

  readonly property size plateSize: Qt.size(320, 230)
  readonly property bool wantsCallout: false
  readonly property string kind: "layout"

  readonly property real cardW: u(108)
  readonly property real cardH: u(130)
  readonly property real pivotX: u(160)
  readonly property real pivotY: u(330)
  readonly property real meterSpan: cardW - u(24)
  readonly property int litCount: litOf(100)

  readonly property Item selection: front
  readonly property alias backs: backRep
  readonly property Item card: cardItem
  readonly property Item frontSign: sign
  readonly property Item meterBar: bar

  Rectangle { z: -1; anchors.fill: parent; radius: look.plateRadius; color: look.backed(look.tone.ground) }

  // The backs: fixed, fanned about a point below the plate.
  Repeater {
    id: backRep
    model: [-14, -7, 7, 14]
    delegate: Item {
      id: backItem
      required property var modelData
      x: look.pivotX; y: look.pivotY
      rotation: modelData
      opacity: 0.75 * look.trackInk
      Rectangle {
        id: back
        x: -look.cardW / 2; y: -look.pivotY + look.u(40)
        width: look.cardW; height: look.cardH; radius: look.u(12)
        color: look.tone.track
        // The tool this back stands for (one or two either side of the chosen one), in the outer
        // top corner: the part the cards in front leave showing.
        Icon {
          host: look
          i: look.tools.length > 0 ? (((look.chosen + Math.round(backItem.modelData / 7)) % look.tools.length) + look.tools.length) % look.tools.length : 0
          px: look.u(13)
          cx: backItem.modelData < 0 ? look.u(16) : back.width - look.u(16)
          cy: look.u(18)
          visible: look.tools.length > 1 && look.stateDrawn === "ring"
        }
      }
    }
  }

  Rectangle {
    id: front
    x: look.pivotX - width / 2; y: look.u(40)
    width: look.cardW; height: look.cardH; radius: look.u(12)
    color: look.backed(look.tone.card)
    Icon {
      host: look; i: look.chosen; on: true
      px: look.u(18)
      cx: look.u(22); cy: look.u(24)
      visible: look.tools.length > 0 && look.stateDrawn !== "hint" && look.stateDrawn !== "cant"
    }
    Sign {
      id: sign
      host: look
      size: look.u(24)
      x: look.u(22) - width / 2; y: look.u(24) - height / 2
      visible: look.stateDrawn === "hint" || look.stateDrawn === "cant"
    }
    Card {
      id: cardItem
      host: look
      framed: false
      stateLines: 3
      maxWidth: look.cardW
      y: look.u(40)
    }
    // The marker; for a level it runs across the card as the meter.
    Rectangle {
      x: look.u(12); y: front.height - look.u(18)
      width: look.meterSpan; height: look.u(5); radius: height / 2
      visible: look.levelShown
      color: look.tone.track
    }
    Rectangle {
      id: bar
      x: look.u(12); y: front.height - look.u(18)
      width: look.levelShown ? look.meterSpan * look.level / 100 : look.u(28)
      height: look.u(5); radius: height / 2
      visible: look.stateDrawn === "ring" ? look.tools.length > 0 : look.levelShown
      color: look.tone.accent
    }
  }
}
