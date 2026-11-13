import QtQuick
import "Basic.js" as Basic

// re:dial basic: the Toast layout, the quietest look (spec 2026-11-06). The card alone, as a pill:
// an accent disc with the chosen tool's icon (the state sign in a hint or can't act), the name
// and click action, and a tiny track whose accent segment shows the position. A level fills it.
LookBase {
  id: look

  readonly property size plateSize: Qt.size(300, 72)
  readonly property bool wantsCallout: false
  readonly property string kind: "layout"

  readonly property real pillX: u(28)
  readonly property real pillW: u(244)
  readonly property real cy: u(36)
  readonly property real miniW: u(62)
  readonly property real miniX: pillX + pillW - u(20) - miniW
  readonly property real segW: Math.max(u(8), miniW / n)
  readonly property int litCount: litOf(100)

  property real steppedPos: 0
  Behavior on steppedPos {
    NumberAnimation { duration: look.cfg.motionBase; easing.type: Easing.BezierSpline; easing.bezierCurve: look.easeInOut }
  }
  onIndexChanged: steppedPos = Math.max(0, Math.min(index, n - 1))
  readonly property real markerFrac: (live ? ((position % n) + n) % n : steppedPos) / n

  readonly property Item selection: marker
  readonly property Item card: cardItem
  readonly property Item discSign: sign
  readonly property Item miniTrack: mini
  readonly property bool miniShown: stateDrawn === "ring" || stateDrawn === "turn"

  Rectangle {
    x: look.pillX; y: look.cy - height / 2
    width: look.pillW; height: look.u(56); radius: height / 2
    color: look.tone.card
  }
  Rectangle {
    id: disc
    width: look.u(36); height: width; radius: width / 2
    x: look.pillX + look.u(10); y: look.cy - height / 2
    color: sign.visible ? look.tone.ground : look.tone.accent
    Text {
      anchors.centerIn: parent
      visible: !sign.visible
      text: look.toolIcon(look.chosen); textFormat: Text.PlainText
      font.family: look.fontFamily; font.pixelSize: look.iconOnPx
      color: look.tone.onaccent
    }
    Sign {
      id: sign
      host: look
      size: look.u(26)
      anchors.centerIn: parent
      visible: look.stateDrawn === "hint" || look.stateDrawn === "cant"
    }
  }
  Card {
    id: cardItem
    host: look
    framed: false
    titleLines: 1
    x: disc.x + disc.width - look.u(2)
    y: look.cy - height / 2
    // A hint or can't act has no position to show: the words take the whole pill.
    maxWidth: (look.miniShown ? look.miniX - look.u(4) : look.pillX + look.pillW - look.u(12)) - x
  }

  Canvas {
    id: mini
    anchors.fill: parent
    visible: look.miniShown
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d"), w = look.u(5)
      ctx.reset()
      Basic.bar(ctx, look.miniX, look.cy, look.miniX + look.miniW, look.cy, String(look.tone.track), w)
      if (look.levelShown && look.level > 0)
        Basic.bar(ctx, look.miniX, look.cy, look.miniX + look.miniW * look.level / 100, look.cy, String(look.tone.accent), w)
    }
  }
  Rectangle {
    id: marker
    visible: look.stateDrawn === "ring" && look.tools.length > 0
    width: look.segW; height: look.u(5); radius: height / 2
    x: look.miniX + (look.miniW - width) * (look.n > 1 ? Math.min(1, look.markerFrac * look.n / (look.n - 1)) : 0)
    y: look.cy - height / 2
    color: look.tone.accent
  }

  onWidthChanged: mini.requestPaint()
  onToneChanged: mini.requestPaint()
  onLevelChanged: mini.requestPaint()
  onLevelShownChanged: mini.requestPaint()
}
