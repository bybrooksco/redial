pragma ComponentBehavior: Bound

import QtQuick
import "Basic.js" as Basic

// The full-ring quiet track shared by Capsule and Pie (spec 2026-11-06): a flat plate, a thin
// track round the ring, an accent marker turned to the choice, each tool's icon one gap inside
// the track on its own angle, and the shared card at the right. Turning a level fills the track;
// a hint or can't act mutes it and puts the sign in the middle.
LookBase {
  id: look

  readonly property size plateSize: Qt.size(340, 248)
  readonly property bool wantsCallout: false
  readonly property string kind: "face"

  property bool segmented: false
  readonly property real cx: u(112)
  readonly property real cy: u(124)
  readonly property real r: u(90)
  readonly property real seg: 360 / n
  readonly property real markerSpan: segmented ? seg - 12 : seg - 6
  readonly property int litCount: litOf(100)
  readonly property int picked: live ? Math.round(((position % n) + n) % n) % n : chosen

  // The marker's angle from the top, clockwise. Live: straight from the hand. Stepped: the short
  // way round, eased; leaving live settles onto the chosen tool from where the hand left it.
  readonly property real liveDeg: position * seg
  property real steppedDeg: 0
  Behavior on steppedDeg {
    id: stepEase
    NumberAnimation { duration: look.cfg.motionBase; easing.type: Easing.BezierSpline; easing.bezierCurve: look.easeInOut }
  }
  property int _lastIndex: 0
  onIndexChanged: {
    var d = (index - _lastIndex) % n
    if (d > n / 2) d -= n
    if (d < -n / 2) d += n
    if (!live) steppedDeg += d * seg
    _lastIndex = index
  }
  onLiveChanged: {
    if (live) return
    stepEase.enabled = false; steppedDeg = liveDeg; stepEase.enabled = true
    var want = chosen * seg
    steppedDeg = want + 360 * Math.round((liveDeg - want) / 360)
  }
  readonly property real markerDeg: live ? liveDeg : steppedDeg

  readonly property Item selection: marker
  readonly property alias icons: iconRep
  readonly property Item card: cardItem

  Rectangle { z: -1; anchors.fill: parent; radius: look.plateRadius; color: look.tone.ground }

  Canvas {
    id: track
    anchors.fill: parent
    opacity: look.trackInk
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d"), T = String(look.tone.track)
      ctx.reset()
      if (look.segmented) {
        for (var i = 0; i < look.n; i++) {
          var a = -90 + i * look.seg
          Basic.arc(ctx, look.cx, look.cy, look.r, a - look.markerSpan / 2, a + look.markerSpan / 2, T, look.trackW)
        }
      } else {
        ctx.beginPath(); ctx.strokeStyle = T; ctx.lineWidth = look.trackW
        ctx.arc(look.cx, look.cy, look.r, 0, Math.PI * 2); ctx.stroke()
      }
    }
  }

  // A level: the track fills from the top, clockwise.
  Canvas {
    id: fill
    anchors.fill: parent
    visible: look.levelShown
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      if (look.level > 0) Basic.arc(ctx, look.cx, look.cy, look.r, -90, -90 + look.level * 3.6, String(look.tone.accent), look.trackW)
    }
  }

  // The marker: pre-drawn at the top, turned by rotation.
  Item {
    id: marker
    z: 1
    x: look.cx; y: look.cy
    rotation: look.markerDeg
    visible: look.stateDrawn === "ring" && look.tools.length > 0
    Canvas {
      id: markerArt
      width: look.r * 2 + look.trackW * 2; height: width
      x: -width / 2; y: -height / 2
      renderStrategy: Canvas.Cooperative
      onPaint: {
        var ctx = getContext("2d"), c = width / 2
        ctx.reset()
        Basic.arc(ctx, c, c, look.r, -90 - look.markerSpan / 2, -90 + look.markerSpan / 2, String(look.tone.accent), look.trackW)
      }
    }
  }

  Repeater {
    id: iconRep
    model: look.tools.length
    delegate: Icon {
      required property int index
      z: 2
      host: look
      i: index
      on: index === look.picked
      readonly property real a: (-90 + index * look.seg) * Math.PI / 180
      cx: look.cx + Math.cos(a) * (look.r - look.iconGap)
      cy: look.cy + Math.sin(a) * (look.r - look.iconGap)
      visible: look.iconsShown
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

  function repaint() { track.requestPaint(); fill.requestPaint(); markerArt.requestPaint() }
  onWidthChanged: repaint()
  onHeightChanged: repaint()
  onNChanged: repaint()
  onToneChanged: repaint()
  onSegmentedChanged: repaint()
  onLevelChanged: fill.requestPaint()
  onLevelShownChanged: fill.requestPaint()
}
