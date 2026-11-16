pragma ComponentBehavior: Bound

import QtQuick
import "Basic.js" as Basic

// The arc quiet track shared by Sundial and Gauge (spec 2026-11-06): a thin track over part of a
// circle, a marker turned to the choice (an accent segment, or the sun riding the track), each
// tool's icon one gap inside the track on its angle, and the shared card under the arc. A level
// fills the track from its start; a hint or can't act mutes it and puts the sign in the arc.
LookBase {
  id: look

  readonly property size plateSize: Qt.size(320, 250)
  readonly property bool wantsCallout: false
  readonly property string kind: "face"

  property real arcFrom: 180
  property real arcSpan: 180
  property bool sun: false
  property real cx: u(160)
  property real cy: u(150)
  property real r: u(104)
  property real cardTop: u(166)
  property real signY: cy - u(40)

  readonly property real stepDeg: n > 1 ? arcSpan / (n - 1) : 0
  function angleOf(i) { return n > 1 ? arcFrom + i * stepDeg : arcFrom + arcSpan / 2 }
  readonly property int litCount: litOf(100)
  readonly property int picked: live ? Math.round(Math.max(0, Math.min(n - 1, ((position % n) + n) % n))) : chosen

  // Live: straight from the hand, held to the arc. Stepped: eased to the chosen tool; across the
  // wrap (last to first) it lands at once, since an arc has no short way round.
  readonly property real liveDeg: angleOf(0) + Math.max(0, Math.min(n - 1, ((position % n) + n) % n)) * stepDeg
  property real steppedDeg: angleOf(0)
  Behavior on steppedDeg {
    id: stepEase
    NumberAnimation { duration: look.cfg.motionBase; easing.type: Easing.BezierSpline; easing.bezierCurve: look.easeInOut }
  }
  property int _lastIndex: 0
  // Reads index, not chosen: inside onIndexChanged the chosen binding can still hold the old value.
  function _settle() {
    var to = Math.max(0, Math.min(index, n - 1))
    if (Math.abs(to - _lastIndex) > n / 2) stepEase.enabled = false
    steppedDeg = angleOf(to)
    stepEase.enabled = true
    _lastIndex = to
  }
  onIndexChanged: _settle()
  onNChanged: _settle()
  onLiveChanged: if (!live) { stepEase.enabled = false; steppedDeg = liveDeg; stepEase.enabled = true; _settle() }
  readonly property real markerDeg: live ? liveDeg : steppedDeg

  readonly property Item selection: marker
  readonly property alias icons: iconRep
  readonly property Item card: cardItem

  Rectangle { z: -1; anchors.fill: parent; radius: look.plateRadius; color: look.backed(look.tone.ground) }

  Canvas {
    id: track
    anchors.fill: parent
    opacity: look.trackInk
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      Basic.arc(ctx, look.cx, look.cy, look.r, look.arcFrom, look.arcFrom + look.arcSpan, String(look.tone.track), look.trackW)
    }
  }
  Canvas {
    id: fill
    anchors.fill: parent
    visible: look.levelShown
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      if (look.level > 0) Basic.arc(ctx, look.cx, look.cy, look.r, look.arcFrom, look.arcFrom + look.arcSpan * look.level / 100, String(look.tone.accent), look.trackW)
    }
  }

  // The marker, drawn pointing right (0°) and turned to the choice.
  Item {
    id: marker
    z: 1
    x: look.cx; y: look.cy
    rotation: look.markerDeg
    visible: look.stateDrawn === "ring" && look.tools.length > 0
    Rectangle {
      visible: look.sun
      width: look.u(18); height: width; radius: width / 2
      x: look.r - width / 2; y: -height / 2
      color: look.tone.accent
    }
    Canvas {
      id: markerArt
      visible: !look.sun
      width: look.r * 2 + look.trackW * 2; height: width
      x: -width / 2; y: -height / 2
      renderStrategy: Canvas.Cooperative
      onPaint: {
        var ctx = getContext("2d"), c = width / 2
        ctx.reset()
        Basic.arc(ctx, c, c, look.r, -9, 9, String(look.tone.accent), look.trackW)
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
      readonly property real a: look.angleOf(index) * Math.PI / 180
      cx: look.cx + Math.cos(a) * (look.r - look.iconGap)
      cy: look.cy + Math.sin(a) * (look.r - look.iconGap)
      visible: look.iconsShown
    }
  }

  Sign {
    z: 3
    host: look
    visible: look.stateDrawn === "hint" || look.stateDrawn === "cant"
    x: look.cx - width / 2; y: look.signY - height / 2
  }
  Card {
    id: cardItem
    z: 3
    host: look
    maxWidth: look.width - look.u(24)
    x: look.cx - width / 2; y: look.cardTop
  }

  function repaint() { track.requestPaint(); fill.requestPaint(); markerArt.requestPaint() }
  onWidthChanged: repaint()
  onHeightChanged: repaint()
  onToneChanged: repaint()
  onTrackWChanged: repaint()
  onArcFromChanged: repaint()
  onArcSpanChanged: repaint()
  onLevelChanged: fill.requestPaint()
  onLevelShownChanged: fill.requestPaint()
}
