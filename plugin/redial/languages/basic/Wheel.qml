pragma ComponentBehavior: Bound

import QtQuick
import "Basic.js" as Basic

// re:dial basic: the Finger wheel look on the quiet track (spec 2026-11-06). Each tool's icon sits
// in a hole on the track; the whole track turns with the hand (no easing: the wheel is the hand)
// under a fixed accent stop, so the hole at the stop is the armed tool. Let go and it eases onto
// the chosen hole. Clockwise turn, clockwise wheel (54a2e24). The shared card sits at the right.
LookBase {
  id: look

  readonly property size plateSize: Qt.size(340, 248)
  readonly property bool wantsCallout: false
  readonly property string kind: "face"

  readonly property real cx: u(112)
  readonly property real cy: u(124)
  readonly property real r: u(76)
  readonly property real stop: 40   // the finger stop, at about 4 o'clock
  readonly property real step: 360 / n
  readonly property int litCount: litOf(100)
  readonly property Item selection: wheel
  readonly property alias holes: holeRep
  readonly property Item stopMark: stopArt
  readonly property Item card: cardItem

  // The chosen hole, counted the short way round so the wheel never spins the long way.
  property real _holes: 0
  property int _lastIndex: 0
  onIndexChanged: {
    var d = (index - _lastIndex) % n
    if (d > n / 2) d -= n
    if (d < -n / 2) d += n
    _holes += d
    _lastIndex = index
  }
  // Letting go: the wheel spins back from the hand's angle onto the chosen hole (the nearest one).
  property real _releaseFrom: 0
  property real releaseT: 1
  NumberAnimation { id: release; target: look; property: "releaseT"; from: 0; to: 1; duration: 260; easing.type: Easing.BezierSpline; easing.bezierCurve: look.easeDrawer }
  onLiveChanged: {
    if (live) { release.stop(); releaseT = 1; return }
    var from = position * step, rest = _holes * step
    _holes += Math.round((from - rest) / 360) * 360 / step
    _releaseFrom = from
    if (cfg.motionBase > 0) release.restart(); else releaseT = 1
  }
  // A new tool list (Settings edits it while the look stays loaded): land on the choice at once.
  onNChanged: {
    var to = Math.max(0, Math.min(index, n - 1))
    release.stop(); releaseT = 1
    _holes = to; _lastIndex = to
  }
  readonly property real restDeg: noteKind === "cant" || noteKind === "hint" ? 0 : _holes * step
  readonly property real wheelDeg: live ? position * step
                                 : releaseT < 1 ? _releaseFrom + (restDeg - _releaseFrom) * releaseT
                                 : restDeg
  readonly property real turned: ((wheelDeg % 360) + 360) % 360
  readonly property int picked: live ? Math.round(((position % n) + n) % n) % n : chosen

  Rectangle { z: -1; anchors.fill: parent; radius: look.plateRadius; color: look.backed(look.tone.ground) }

  // A level fills the track from the top, clockwise; the wheel's holes hide meanwhile.
  Canvas {
    id: fill
    z: 1
    anchors.fill: parent
    visible: look.levelShown
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      if (look.level > 0) Basic.arc(ctx, look.cx, look.cy, look.r, -90, -90 + look.level * 3.6, String(look.tone.accent), look.trackW)
    }
  }

  // The wheel: the track and its holes, turned by the hand.
  Item {
    id: wheel
    x: look.cx; y: look.cy
    rotation: look.wheelDeg
    Canvas {
      id: trackArt
      width: look.r * 2 + look.trackW * 2; height: width
      x: -width / 2; y: -height / 2
      opacity: look.trackInk
      renderStrategy: Canvas.Cooperative
      onPaint: {
        var ctx = getContext("2d"), c = width / 2
        ctx.reset()
        ctx.beginPath(); ctx.strokeStyle = String(look.tone.track); ctx.lineWidth = look.trackW
        ctx.arc(c, c, look.r, 0, Math.PI * 2); ctx.stroke()
      }
    }
    Repeater {
      id: holeRep
      model: look.tools.length
      delegate: Item {
        id: hole
        required property int index
        readonly property real a: (look.stop - hole.index * look.step) * Math.PI / 180
        readonly property bool on: hole.index === look.picked
        width: look.u(26); height: width
        x: Math.cos(a) * look.r - width / 2; y: Math.sin(a) * look.r - height / 2
        visible: look.iconsShown
        Rectangle {
          anchors.fill: parent; radius: width / 2
          color: look.tone.ground
          border.color: hole.on ? look.tone.accent : look.tone.track
          border.width: hole.on ? look.u(2.5) : look.u(1.5)
        }
        Icon {
          host: look; i: hole.index; on: hole.on
          px: look.iconPx
          cx: hole.width / 2; cy: hole.height / 2
          rotation: -look.wheelDeg
        }
      }
    }
  }

  // The finger stop: fixed, outside the wheel, just past the armed hole.
  Canvas {
    id: stopArt
    anchors.fill: parent
    visible: look.iconsShown && look.tools.length > 0
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d"), a = (look.stop + 15) * Math.PI / 180
      ctx.reset()
      Basic.bar(ctx, look.cx + Math.cos(a) * (look.r + look.u(17)), look.cy + Math.sin(a) * (look.r + look.u(17)),
                look.cx + Math.cos(a) * (look.r + look.u(27)), look.cy + Math.sin(a) * (look.r + look.u(27)),
                String(look.tone.accent), look.u(5))
    }
  }

  Text {
    z: 3
    visible: look.levelShown
    x: look.cx - width / 2; y: look.cy - height / 2
    text: look.valueText; textFormat: Text.PlainText
    font.family: look.face; font.pixelSize: look.u(26); font.weight: Font.DemiBold
    color: look.tone.ink
  }
  Sign {
    z: 3
    host: look
    visible: look.stateDrawn === "hint" || look.stateDrawn === "cant"
    x: look.cx - width / 2; y: look.cy - height / 2
  }
  Card {
    id: cardItem
    z: 3
    host: look
    x: look.u(220); y: look.cy - height / 2
    maxWidth: look.width - x - look.u(12)
  }

  function repaint() { trackArt.requestPaint(); fill.requestPaint(); stopArt.requestPaint() }
  onWidthChanged: repaint()
  onHeightChanged: repaint()
  onToneChanged: repaint()
  onTrackWChanged: repaint()
  onLevelChanged: fill.requestPaint()
  onLevelShownChanged: fill.requestPaint()
}
