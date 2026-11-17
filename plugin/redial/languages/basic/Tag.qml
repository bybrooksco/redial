pragma ComponentBehavior: Bound

import QtQuick
import "Basic.js" as Basic

// re:dial basic: the List look (key "tag"; it replaced the Repair tag) on the quiet track
// (spec 2026-11-06). A vertical track at the left with a fixed accent marker at the middle row;
// rows of icon and name scroll past it so the chosen tool is always the middle row, its
// neighbours fading out. The shared card at the right carries the click action.
LookBase {
  id: look

  readonly property size plateSize: Qt.size(340, 248)
  readonly property bool wantsCallout: false
  readonly property string kind: "face"

  readonly property real tx: u(34)
  readonly property real y0: u(28)
  readonly property real y1: u(220)
  readonly property real pitch: (y1 - y0) / 5
  readonly property real mid: (y0 + y1) / 2
  readonly property int litCount: litOf(100)

  // The list's position in tool units: live, straight from the hand; stepped, the short way, eased.
  property real steppedPos: 0
  Behavior on steppedPos {
    id: stepEase
    NumberAnimation { duration: look.cfg.motionBase; easing.type: Easing.BezierSpline; easing.bezierCurve: look.easeInOut }
  }
  property int _lastIndex: 0
  onIndexChanged: {
    var d = (index - _lastIndex) % n
    if (d > n / 2) d -= n
    if (d < -n / 2) d += n
    if (!live) steppedPos += d
    _lastIndex = index
  }
  onLiveChanged: {
    if (live) return
    stepEase.enabled = false; steppedPos = position; stepEase.enabled = true
    steppedPos = chosen + n * Math.round((position - chosen) / n)
  }
  // A new tool list (Settings edits it while the look stays loaded): land on the choice at once.
  onNChanged: {
    var to = Math.max(0, Math.min(index, n - 1))
    stepEase.enabled = false; steppedPos = to; stepEase.enabled = true
    _lastIndex = to
  }
  readonly property real listPos: live ? position : steppedPos
  readonly property int base: Math.floor(listPos)
  readonly property real frac: listPos - base

  readonly property Item selection: marker
  readonly property alias rows: rowRep
  readonly property Item card: cardItem

  Rectangle { z: -1; anchors.fill: parent; radius: look.plateRadius; color: look.backed(look.tone.ground) }

  Canvas {
    id: track
    anchors.fill: parent
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      ctx.globalAlpha = look.trackInk
      Basic.bar(ctx, look.tx, look.y0, look.tx, look.y1, String(look.tone.track), look.trackW)
      ctx.globalAlpha = 1
      if (look.levelShown && look.level > 0)
        Basic.bar(ctx, look.tx, look.y0, look.tx, look.y0 + (look.y1 - look.y0) * look.level / 100, String(look.tone.accent), look.trackW)
    }
  }

  Canvas {
    id: marker
    z: 1
    width: look.trackW * 2; height: look.u(24) + look.trackW
    x: look.tx - width / 2; y: look.mid - height / 2
    visible: look.stateDrawn === "ring" && look.tools.length > 0
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d"), c = width / 2
      ctx.reset()
      Basic.bar(ctx, c, look.trackW / 2, c, height - look.trackW / 2, String(look.tone.accent), look.trackW)
    }
  }

  // Seven slots round the middle (-3..3); each shows the tool that scrolled into it.
  Item {
    anchors.fill: parent
    clip: true
    Repeater {
      id: rowRep
      model: look.tools.length > 0 ? 7 : 0
      delegate: Item {
        id: row
        required property int index
        readonly property int slot: row.index - 3
        readonly property int tool: (((look.base + row.slot) % look.n) + look.n) % look.n
        readonly property string name: look.toolName(row.tool)
        readonly property real offset: row.slot - look.frac      // rows from the middle
        readonly property bool on: row.tool === look.chosen && Math.abs(row.offset) < 0.5
        width: look.u(170); height: look.pitch
        x: look.tx; y: look.mid + row.offset * look.pitch - height / 2
        visible: look.iconsShown
        opacity: Math.abs(row.offset) > 2.5 ? 0 : Math.abs(row.offset) > 1.5 ? 0.5 : 1
        Icon {
          host: look; i: row.tool; on: row.on
          cx: look.iconGap + look.u(4); cy: row.height / 2
        }
        Text {
          x: look.iconGap + look.u(20); anchors.verticalCenter: parent.verticalCenter
          width: row.width - x; elide: Text.ElideRight
          text: row.name; textFormat: Text.PlainText
          font.family: look.face; font.pixelSize: row.on ? look.u(13) : look.u(12)
          font.weight: row.on ? Font.DemiBold : Font.Normal
          color: row.on ? look.tone.ink : look.tone.muted
        }
      }
    }
  }

  Card {
    id: cardItem
    z: 3
    host: look
    showSign: true
    ringLine: look.tools[look.chosen] ? String(look.tools[look.chosen].hint || "") : ""
    // Beside the rows; when they hide (a level, a hint, can't act) it takes their space.
    x: look.iconsShown ? look.u(220) : look.tx + look.u(26); y: look.mid - height / 2
    maxWidth: look.width - x - look.u(12)
  }

  onWidthChanged: { track.requestPaint(); marker.requestPaint() }
  onHeightChanged: track.requestPaint()
  onToneChanged: { track.requestPaint(); marker.requestPaint() }
  onTrackWChanged: { track.requestPaint(); marker.requestPaint() }
  onLevelChanged: track.requestPaint()
  onLevelShownChanged: track.requestPaint()
  onTrackInkChanged: track.requestPaint()
}
