pragma ComponentBehavior: Bound

import QtQuick
import "Drafting.js" as Drafting

// re:dial classic: the Finger wheel look, a rotary dial in plan. Holes with centre marks on a
// wheel that turns with the hand (no easing: the wheel is the hand), a hatched finger stop that
// does not, and an angle dimension reading how far it has been dialled from rest. Letting go eases
// the wheel onto the chosen hole. Turning a level swaps the wheel for a 100-bar scale. The host
// draws the callout; the look runs the leader out from the stop. Mockup: DWHL in classic3.js.
LookBase {
  id: face

  readonly property size plateSize: Qt.size(640, 440)
  readonly property bool wantsCallout: true
  readonly property string kind: "face"
  readonly property real calloutX: 220 + 168 + 80

  readonly property real cx: u(220)
  readonly property real cy: u(220)
  readonly property real stop: 40
  readonly property real step: 360 / n
  // The level scale: 10 majors, the marks between them set by the scale density (Medium: 100).
  readonly property int majorStep: Math.max(2, Math.round(10 * density))
  readonly property int marks: 10 * majorStep
  readonly property int litCount: litOf(marks)
  readonly property Item selection: wheel

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
  // Letting go: from the hand's angle onto the chosen hole (the equivalent nearest the hand).
  property real _releaseFrom: 0
  property real releaseT: 1
  NumberAnimation { id: release; target: face; property: "releaseT"; from: 0; to: 1; duration: 260; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.32, 0.72, 0, 1, 1, 1] }
  onLiveChanged: {
    if (live) { release.stop(); releaseT = 1; return }
    var from = position * step, rest = _holes * step
    _holes += Math.round((from - rest) / 360) * 360 / step   // the rest angle nearest the hand
    _releaseFrom = from
    if (cfg.motionBase > 0) release.restart(); else releaseT = 1
  }
  readonly property real restDeg: noteKind === "cant" || noteKind === "hint" ? 0 : _holes * step
  readonly property real wheelDeg: live ? position * step
                                 : releaseT < 1 ? _releaseFrom + (restDeg - _releaseFrom) * releaseT
                                 : restDeg
  readonly property real turned: ((wheelDeg % 360) + 360) % 360

  readonly property var leadFrom: levelShown ? Drafting.polar(cx, cy, u(160), -90 + level * 3.6) : Drafting.polar(cx, cy, u(141), stop)
  readonly property var leadKnee: levelShown ? Drafting.polar(cx, cy, u(184), -90 + level * 3.6) : Drafting.polar(cx, cy, u(186), stop)
  readonly property real leaderY: leadKnee[1]
  readonly property real leaderEndY: landY >= 0 ? landY : leaderY
  readonly property real leaderEndX: u(220 + 168 + 68)

  Canvas {
    id: back
    anchors.fill: parent
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d"), L = String(face.line), A = String(face.accent)
      var cx = face.cx, cy = face.cy
      ctx.reset(); ctx.__w = face.lineScale
      ctx.fillStyle = face.plateFill; ctx.fillRect(0, 0, width, height)
      if (face.cfg.constructionLines) {
        Drafting.regMarks(ctx, width, height, face.u(10), face.u(14), L)
        Drafting.construction(ctx, width, height, cx, cy, face.u(70), face.u(168), face.u(18), L)
      }
      Drafting.ring(ctx, cx, cy, face.u(168), L, 0.3, 1)
      Drafting.ring(ctx, cx, cy, face.u(160), L, 0.12, 1)
      if (face.levelShown) {
        Drafting.scaleBars(ctx, cx, cy, -90, 270, face.marks, face.u(132), face.u(138), face.u(146), face.majorStep, L)
        Drafting.litBars(ctx, cx, cy, -90, 270, face.marks, face.u(132), face.u(152), face.litCount, A, 1.5)
        Drafting.dimArc(ctx, cx, cy, face.u(82), -88, Math.max(-86, -92 + face.level * 3.6), A, face.u(7))
      } else {
        // The finger stop: a hatched hook outside the wheel, and the ring round the hole at it.
        var fp = Drafting.polar(cx, cy, face.u(112), face.stop)
        Drafting.ring(ctx, fp[0], fp[1], face.u(29), A, 1, 1.6)
        var hp = Drafting.polar(cx, cy, face.u(158), face.stop + 27), k = face.unit
        ctx.save(); ctx.translate(hp[0], hp[1]); ctx.rotate((face.stop + 27 + 90) * Math.PI / 180)
        function hook(g) { g.moveTo(-7 * k, -24 * k); g.lineTo(7 * k, -24 * k); g.lineTo(7 * k, 6 * k); g.arc(0, 6 * k, 7 * k, 0, Math.PI, false); g.closePath() }
        Drafting.hatch(ctx, hook, face.u(40), face.u(40), A, 0.5, face.u(5))
        ctx.beginPath(); hook(ctx); ctx.strokeStyle = Drafting.ink(A, 1); ctx.lineWidth = (1.4) * face.lineScale; ctx.stroke()
        ctx.restore()
      }
      Drafting.ring(ctx, cx, cy, face.u(64), L, 0.6, 1.2)
      Drafting.ring(ctx, cx, cy, face.u(58), L, 0.25, 1)
      var tb = Drafting.titleBlock(ctx, width, height, face.unit, L)
      titleLeft.x = tb[0]; titleRight.x = tb[1]; titleLeft.y = titleRight.y = tb[2] - titleLeft.baselineOffset
    }
  }

  // The wheel: it turns; its glyphs stay upright.
  Item {
    id: wheel
    visible: !face.levelShown
    x: face.cx; y: face.cy
    rotation: face.wheelDeg
    opacity: face.noteKind === "cant" ? 0.4 : face.noteKind === "hint" ? 0.55 : 1
    Canvas {
      id: wheelArt
      x: -width / 2; y: -height / 2
      width: face.u(330); height: width
      renderStrategy: Canvas.Cooperative
      onPaint: {
        var ctx = getContext("2d"), L = String(face.line), c = width / 2
        ctx.reset(); ctx.__w = face.lineScale
        Drafting.ring(ctx, c, c, face.u(150), L, 0.5, 1.2)
        for (var i = 0; i < face.tools.length; i++) {
          var h = Drafting.polar(c, c, face.u(112), face.stop - i * face.step)
          Drafting.ring(ctx, h[0], h[1], face.u(24), L, 0.55, 1)
          Drafting.line(ctx, h[0] - face.u(28), h[1], h[0] - face.u(24), h[1], L, 0.3, 1)
          Drafting.line(ctx, h[0] + face.u(24), h[1], h[0] + face.u(28), h[1], L, 0.3, 1)
        }
      }
    }
    Repeater {
      model: face.levelShown ? 0 : face.tools.length
      delegate: Text {
        id: glyph
        required property int index
        readonly property var at: Drafting.polar(0, 0, face.u(112), face.stop - glyph.index * face.step)
        x: at[0] - width / 2; y: at[1] - height / 2
        rotation: -face.wheelDeg
        visible: face.cfg.showGlyphs
        text: face.toolIcon(glyph.index)
        textFormat: Text.PlainText
        font.family: face.fontFamily; font.pixelSize: face.u(17)
        color: glyph.index === face.index && face.noteKind === "" ? face.accent : face.ink(0.7)
      }
    }
  }

  // Section hatching over the resting wheel when the dial can't act.
  Canvas {
    id: cantArt
    anchors.fill: parent
    visible: face.noteKind === "cant"
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset(); ctx.__w = face.lineScale
      Drafting.hatch(ctx, function (c) { c.arc(face.cx, face.cy, face.u(150), 0, Math.PI * 2) }, width, height, String(face.line), 0.14, face.u(7))
    }
  }

  // The angle dimension: how far the wheel has been dialled from rest.
  Canvas {
    id: dial
    anchors.fill: parent
    visible: face.stateDrawn === "ring" && face.turned >= 1
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d"), A = String(face.accent), R = face.u(78)
      ctx.reset(); ctx.__w = face.lineScale
      var s = face.stop * Math.PI / 180, e = (face.stop - Math.max(0.1, face.turned)) * Math.PI / 180
      ctx.beginPath(); ctx.strokeStyle = Drafting.ink(A, 0.8); ctx.lineWidth = (1) * face.lineScale
      ctx.arc(face.cx, face.cy, R, s, e, true); ctx.stroke()
      var px = face.cx + Math.cos(e) * R, py = face.cy + Math.sin(e) * R, tx = Math.sin(e), ty = -Math.cos(e), k = face.u(7), w = k / 3
      ctx.fillStyle = Drafting.ink(A, 0.8); ctx.beginPath(); ctx.moveTo(px, py)
      ctx.lineTo(px - tx * k - ty * w, py - ty * k + tx * w); ctx.lineTo(px - tx * k + ty * w, py - ty * k - tx * w); ctx.closePath(); ctx.fill()
    }
  }
  Text {
    visible: dial.visible || face.levelShown
    readonly property var at: face.levelShown ? Drafting.polar(face.cx, face.cy, face.u(96), -90 + face.level * 1.8)
                                              : Drafting.polar(face.cx, face.cy, face.u(90), face.stop - face.turned / 2)
    x: at[0] - width / 2; y: at[1] - height / 2
    text: face.levelShown ? Math.round(face.level) + "%" : Math.round(face.turned) + "°"
    textFormat: Text.PlainText
    font.family: face.fontFamily; font.pixelSize: face.u(11); font.letterSpacing: face.u(1.1)
    color: face.accent
  }

  // The hub card.
  Column {
    anchors.centerIn: parent
    anchors.horizontalCenterOffset: face.cx - face.width / 2
    anchors.verticalCenterOffset: face.cy - face.height / 2
    width: face.u(112)
    Canvas {
      id: sign
      anchors.horizontalCenter: parent.horizontalCenter
      visible: face.noteKind === "hint" || face.noteKind === "cant"
      width: face.u(28); height: width
      renderStrategy: Canvas.Cooperative
      onPaint: {
        var ctx = getContext("2d")
        ctx.reset(); ctx.__w = face.lineScale
        if (face.noteKind === "cant") { ctx.fillStyle = String(face.ground); ctx.beginPath(); ctx.arc(width / 2, height / 2, width / 2, 0, Math.PI * 2); ctx.fill() }
        Drafting.sign(ctx, face.noteKind, face.note, width, String(face.accent), String(face.alert))
      }
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      visible: face.stateDrawn === "ring"
      text: "RE:DIAL"; textFormat: Text.PlainText
      font.family: face.fontFamily; font.pixelSize: face.u(9.5); font.letterSpacing: face.u(1.1)
      color: face.ink(face.inkKey)
    }
    Text {
      width: parent.width; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
      visible: face.stateDrawn === "ring" || face.levelShown
      text: face.levelShown ? String(face.note.name || "").toUpperCase() : face.toolName(face.index)
      textFormat: Text.PlainText
      font.family: face.fontFamily; font.bold: true
      font.pixelSize: face.levelShown ? face.u(11) : face.u(15)
      font.letterSpacing: face.levelShown ? face.u(1.3) : 0
      color: face.line
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      visible: face.levelShown
      text: face.valueText; textFormat: Text.PlainText
      font.family: face.fontFamily; font.pixelSize: face.u(24); color: face.accent
    }
  }

  // The leader out to the host's callout.
  Canvas {
    id: lead
    anchors.fill: parent
    visible: face.cfg.showCallout && (face.tools.length > 0 || face.noteKind !== "")
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d"), A = String(face.accent)
      ctx.reset(); ctx.__w = face.lineScale
      var p = face.leadFrom, kn = face.leadKnee, ey = face.leaderEndY, ex = face.leaderEndX
      var bent = Math.abs(ey - kn[1]) > 0.5, kx = bent ? Math.max(p[0], kn[0]) + face.u(18) : kn[0], ky = bent ? ey : kn[1]
      ctx.strokeStyle = Drafting.ink(A, 0.65); ctx.lineWidth = (1) * face.lineScale
      ctx.beginPath(); ctx.moveTo(p[0], p[1]); ctx.lineTo(kx, ky); ctx.lineTo(ex, ey); ctx.stroke()
      Drafting.node(ctx, p[0], p[1], face.u(3), A, 1)
      Drafting.node(ctx, ex, ey, face.u(2.2), A, 0.85)
    }
  }

  Text {
    id: titleLeft
    text: "RE:DIAL"; textFormat: Text.PlainText
    font.family: face.fontFamily; font.pixelSize: face.u(11); font.letterSpacing: face.u(1.3)
    color: face.ink(0.7)
  }
  Text {
    id: titleRight
    width: face.u(118); elide: Text.ElideRight
    readonly property string stamp: ({ asleep: "ASLEEP", waiting: "NO DIAL" })[face.note.reason] || "CAN'T ACT"
    text: face.noteKind === "cant" ? "STATUS: " + stamp
        : face.levelShown ? "DIAL 1/1"
        : face.noteKind === "hint" ? "NOTE " + (face.note.step || 1)
        : "HOLE " + (Math.min(face.index, face.n - 1) + 1) + "/" + face.n
    textFormat: Text.PlainText
    font.family: face.fontFamily; font.pixelSize: face.u(11); font.letterSpacing: face.u(1.3)
    color: face.ink(0.7)
  }

  function repaint() { back.requestPaint(); wheelArt.requestPaint(); cantArt.requestPaint(); dial.requestPaint(); sign.requestPaint(); lead.requestPaint() }
  onWidthChanged: repaint()
  onHeightChanged: repaint()
  onNoteKindChanged: repaint()
  onNoteChanged: repaint()
  onNChanged: repaint()
  onLineChanged: repaint()
  onAccentChanged: repaint()
  onTurnedChanged: dial.requestPaint()
  onLeaderEndYChanged: lead.requestPaint()
  onLeadFromChanged: lead.requestPaint()
  Connections { target: face.cfg; function onChanged() { face.repaint() } }
}
