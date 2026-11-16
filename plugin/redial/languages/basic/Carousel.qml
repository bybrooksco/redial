pragma ComponentBehavior: Bound

import QtQuick
import "Basic.js" as Basic

// re:dial basic: the Carousel layout on the quiet track (spec 2026-11-06). A straight track; the
// icons ride above it and scroll so the chosen tool is centred over a fixed accent marker; the
// shared card sits centred below.
LookBase {
  id: look

  readonly property size plateSize: Qt.size(340, 230)
  readonly property bool wantsCallout: false
  readonly property string kind: "layout"

  readonly property real ty: u(96)
  readonly property real x0: u(26)
  readonly property real x1: u(314)
  readonly property real midX: (x0 + x1) / 2
  readonly property real pitch: (x1 - x0) / Math.max(n, 5)
  readonly property int litCount: litOf(100)

  // The row's position in tool units: live, straight from the hand; stepped, the short way, eased.
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
  readonly property int half: Math.floor(n / 2)

  readonly property Item selection: marker
  readonly property alias slots: slotRep
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
      Basic.bar(ctx, look.x0, look.ty, look.x1, look.ty, String(look.tone.track), look.trackW)
      ctx.globalAlpha = 1
      if (look.levelShown && look.level > 0)
        Basic.bar(ctx, look.x0, look.ty, look.x0 + (look.x1 - look.x0) * look.level / 100, look.ty, String(look.tone.accent), look.trackW)
    }
  }

  Canvas {
    id: marker
    z: 1
    width: look.u(22) + look.trackW; height: look.trackW * 2
    x: look.midX - width / 2; y: look.ty - height / 2
    visible: look.stateDrawn === "ring" && look.tools.length > 0
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d"), c = height / 2
      ctx.reset()
      Basic.bar(ctx, look.trackW / 2, c, width - look.trackW / 2, c, String(look.tone.accent), look.trackW)
    }
  }

  // n slots round the middle, one per tool; each shows the tool that scrolled into it.
  Repeater {
    id: slotRep
    model: look.tools.length > 0 ? look.n : 0
    delegate: Icon {
      id: slotIcon
      required property int index
      readonly property int slot: slotIcon.index - look.half
      readonly property int tool: (((look.base + slotIcon.slot) % look.n) + look.n) % look.n
      readonly property real offset: slotIcon.slot - look.frac
      z: 2
      host: look
      i: slotIcon.tool
      on: slotIcon.tool === look.chosen && Math.abs(slotIcon.offset) < 0.5
      cx: look.midX + slotIcon.offset * look.pitch
      cy: look.ty - look.iconGap - look.u(2)
      visible: look.iconsShown && cx >= look.x0 - 1 && cx <= look.x1 + 1
      opacity: Math.abs(slotIcon.offset) > look.half - 0.5 ? 0.4 : 1
    }
  }

  Card {
    id: cardItem
    z: 3
    host: look
    showSign: true
    maxWidth: look.width - look.u(24)
    x: look.midX - width / 2; y: look.u(132)
  }

  onWidthChanged: { track.requestPaint(); marker.requestPaint() }
  onToneChanged: { track.requestPaint(); marker.requestPaint() }
  onTrackWChanged: { track.requestPaint(); marker.requestPaint() }
  onLevelChanged: track.requestPaint()
  onLevelShownChanged: track.requestPaint()
  onTrackInkChanged: track.requestPaint()
}
