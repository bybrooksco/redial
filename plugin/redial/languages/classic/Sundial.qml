pragma ComponentBehavior: Bound

import QtQuick
import "Drafting.js" as Drafting

// re:dial classic: the Sundial look. The tools are hours round a hatched gnomon; the sun rides the
// rim a breath behind the hand (τ 60 ms) and its dashed shadow (the hidden-line convention: a
// thing you infer) points away from it. Turning a level and can't act use a half plate: the sun
// climbs a 0-100 arc with a dimension arc under it, or a hatched moon slides over it once (an
// eclipse). The host draws the callout column; this look runs the elbowed leader out to it.
// Mockup: DSUN in classic3.js.
LookBase {
  id: face

  readonly property bool half: levelShown || noteKind === "cant"
  readonly property size plateSize: half ? Qt.size(640, 330) : Qt.size(640, 440)
  readonly property bool wantsCallout: true
  readonly property string kind: "face"
  // The dial's centre, in plate units. 260 leaves the longest left-side name (WORKSPACES) on the plate.
  readonly property real cxUnits: 260
  readonly property real calloutX: cxUnits + 178 + 70

  readonly property real cx: u(cxUnits)
  readonly property real cy: half ? u(236) : u(220)
  readonly property real step: 360 / n
  readonly property int litCount: litOf(100)
  readonly property Item selection: sun

  // The chosen hour, the short way round (the leader eases to it; the sun lags it).
  property real steppedDeg: -90
  Behavior on steppedDeg {
    id: stepEase
    NumberAnimation { duration: face.cfg.motionBase; easing.type: Easing.BezierSpline; easing.bezierCurve: face.easeInOut }
  }
  property int _lastIndex: 0
  property real _hours: 0   // cumulative index, so the sun also goes the short way
  onIndexChanged: {
    var d = (index - _lastIndex) % n
    if (d > n / 2) d -= n
    if (d < -n / 2) d += n
    steppedDeg += d * step
    _hours += d
    _lastIndex = index
  }
  onLiveChanged: if (!live) { stepEase.enabled = false; steppedDeg = -90 + Math.round(position) * step; stepEase.enabled = true }
  readonly property real leaderDeg: live ? -90 + Math.round(position) * step : steppedDeg

  // Where the sun is headed: the hand, the level on the half arc, or the top (eclipse).
  readonly property real sunTarget: noteKind === "cant" ? 270
                                  : levelShown ? 180 + level * 1.8
                                  : -90 + (live ? position : _hours) * step
  readonly property real tau: levelShown ? 50 : 60
  onSunTargetChanged: if (cfg.motionBase <= 0) sun.deg = sunTarget
  onHalfChanged: { sun.deg = sunTarget; repaint() }   // a new plate: the sun starts where it belongs
  FrameAnimation {
    running: face.cfg.motionBase > 0 && Math.abs(face.sunTarget - sun.deg) > 0.01
    onTriggered: {
      var d = face.sunTarget - sun.deg
      sun.deg = Math.abs(d) < 0.05 ? face.sunTarget : sun.deg + d * (1 - Math.exp(-frameTime * 1000 / face.tau))
    }
  }

  // The eclipse: the moon slides over the sun once, 420 ms ease-in-out.
  property real moonX: 40
  NumberAnimation { id: moonIn; target: face; property: "moonX"; from: 40; to: 2; duration: 420; easing.type: Easing.BezierSpline; easing.bezierCurve: face.easeInOut }
  onNoteKindChanged: {
    if (noteKind !== "cant") { moonIn.stop(); moonX = 40 }
    else if (cfg.motionBase > 0) moonIn.restart()
    else moonX = 2
  }

  // The leader: out from the drawing, then level to the host's callout column. When the host
  // clamps the callout (landY), the leader bends to meet it.
  readonly property var leadFrom: half ? (noteKind === "cant" ? Drafting.polar(cx, cy, u(178), -90) : Drafting.polar(cx, cy, u(177), sun.deg))
                                       : Drafting.polar(cx, cy, u(167), leaderDeg)
  readonly property var leadKnee: {
    if (noteKind === "cant") return [leadFrom[0] + u(16), leadFrom[1] - u(14)]
    if (half) { var p = Drafting.polar(cx, cy, u(198), sun.deg); return [p[0], Math.min(p[1], cy - u(20))] }
    return Drafting.polar(cx, cy, u(190), leaderDeg)
  }
  readonly property real leaderY: leadKnee[1]
  readonly property real leaderEndY: landY >= 0 ? landY : leaderY
  readonly property real leaderEndX: u(cxUnits + 178 + 58)

  Canvas {
    id: back
    anchors.fill: parent
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d"), L = String(face.line), A = String(face.accent), k = face.unit
      ctx.reset(); ctx.__w = face.lineScale
      ctx.fillStyle = face.plateFill; ctx.fillRect(0, 0, width, height)
      var cx = face.cx, cy = face.cy, i, a, p, q
      if (face.cfg.constructionLines) Drafting.regMarks(ctx, width, height, face.u(10), face.u(14), L)
      if (!face.half) {
        if (face.cfg.constructionLines) Drafting.construction(ctx, width, height, cx, cy, face.u(60), face.u(150), face.u(18), L)
        Drafting.ring(ctx, cx, cy, face.u(60), L, 0.22, 1)
        Drafting.ring(ctx, cx, cy, face.u(150), L, 0.3, 1)
        Drafting.ring(ctx, cx, cy, face.u(162), L, 0.14, 1)
        for (i = 0; i < face.tools.length; i++) {
          a = -90 + i * face.step
          p = Drafting.polar(cx, cy, face.u(60), a); q = Drafting.polar(cx, cy, face.u(150), a)
          Drafting.line(ctx, p[0], p[1], q[0], q[1], L, 0.22, 1)
          p = Drafting.polar(cx, cy, face.u(60), a + face.step / 2); q = Drafting.polar(cx, cy, face.u(150), a + face.step / 2)
          Drafting.line(ctx, p[0], p[1], q[0], q[1], L, 0.12, 1, [6 * k, 4 * k])
        }
        gnomon(ctx, cx, cy, 34, 8, 8, L)
      } else {
        if (face.cfg.constructionLines) {
          Drafting.line(ctx, 0, cy, width, cy, L, 0.13, 1); Drafting.node(ctx, width - face.u(10), cy, face.u(3), L, 0.35)
          Drafting.line(ctx, cx, face.u(10), cx, cy, L, 0.13, 1); Drafting.node(ctx, cx, face.u(10), face.u(2.5), L, 0.3)
        }
        ctx.beginPath(); ctx.strokeStyle = Drafting.ink(L, 0.3); ctx.lineWidth = (1) * face.lineScale
        ctx.arc(cx, cy, face.u(160), Math.PI, Math.PI * 2); ctx.stroke()
        for (i = 0; i < 11; i++) {
          a = 180 + i * 18
          var maj = i % 5 === 0
          p = Drafting.polar(cx, cy, face.u(maj ? 136 : 142), a); q = Drafting.polar(cx, cy, face.u(152), a)
          Drafting.line(ctx, p[0], p[1], q[0], q[1], L, maj ? 0.5 : 0.25, 1)
        }
        gnomon(ctx, cx, cy, 44, 9, 0, L)
        if (face.levelShown) Drafting.dimArc(ctx, cx, cy, face.u(120), 182, Math.max(184, 180 + face.level * 1.8 - 2), A, face.u(7))
      }
      var tb = Drafting.titleBlock(ctx, width, height, face.unit, L)
      titleLeft.x = tb[0]; titleRight.x = tb[1]; titleLeft.y = titleRight.y = tb[2] - titleLeft.baselineOffset
    }
    // The gnomon: a hatched triangle standing on the centre.
    function gnomon(ctx, cx, cy, up, halfW, down, L) {
      function tri(c) { c.moveTo(cx, cy - face.u(up)); c.lineTo(cx - face.u(halfW), cy + face.u(down)); c.lineTo(cx + face.u(halfW), cy + face.u(down)); c.closePath() }
      Drafting.hatch(ctx, tri, width, height, L, 0.22, face.u(7))
      ctx.beginPath(); tri(ctx); ctx.strokeStyle = Drafting.ink(L, 0.6); ctx.lineWidth = (1) * face.lineScale; ctx.stroke()
    }
  }

  // The hours: glyphs inside, names outside; the chosen name moves to the callout.
  Repeater {
    model: face.half ? 0 : face.tools.length
    delegate: Item {
      id: hour
      required property int index
      readonly property bool on: hour.index === face.index && face.noteKind === ""
      readonly property real a: -90 + hour.index * face.step
      readonly property var g: Drafting.polar(face.cx, face.cy, face.u(116), a)
      readonly property var l: Drafting.polar(face.cx, face.cy, face.u(178), a)
      readonly property real c: Math.cos(a * Math.PI / 180)
      opacity: face.ringInk
      Text {
        x: hour.g[0] - width / 2; y: hour.g[1] - height / 2
        visible: face.cfg.showGlyphs
        text: face.toolIcon(hour.index)
        textFormat: Text.PlainText
        font.family: face.fontFamily; font.pixelSize: face.u(16)
        color: hour.on ? face.accent : face.ink(0.4)
        scale: hour.on ? 1.45 : 1
        Behavior on scale { NumberAnimation { duration: face.cfg.motionBase * 0.75; easing.type: Easing.BezierSpline; easing.bezierCurve: face.easeOut } }
      }
      Text {
        visible: face.cfg.showLabels && !(hour.index === face.index && face.cfg.showCallout)
        x: Math.abs(hour.c) < 0.2 ? hour.l[0] - width / 2 : hour.c > 0 ? hour.l[0] : hour.l[0] - width
        y: hour.l[1] - height / 2 + (Math.sin(hour.a * Math.PI / 180) > 0.9 ? face.u(6) : 0)
        // Left-side names stop at the plate edge; a long single word shrinks a little before it elides.
        width: Math.min(implicitWidth, face.u(120), hour.c < -0.2 ? hour.l[0] - face.u(8) : face.u(120)); elide: Text.ElideRight
        fontSizeMode: Text.HorizontalFit; minimumPixelSize: Math.round(face.u(9))
        text: face.toolName(hour.index).toUpperCase()
        textFormat: Text.PlainText
        font.family: face.fontFamily; font.pixelSize: face.u(11); font.letterSpacing: face.u(1.3)
        color: face.ink(face.language ? face.language.inkLabel : 0.58)
      }
    }
  }

  // The shadow, dashed, from the gnomon away from the sun.
  Canvas {
    id: shadow
    anchors.fill: parent
    visible: face.noteKind !== "cant"
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d"), L = String(face.line), k = face.unit
      ctx.reset(); ctx.__w = face.lineScale
      var e
      if (face.half) { e = Drafting.polar(face.cx, face.cy, face.u(70), sun.deg + 180); e[1] = Math.min(e[1], face.cy) }
      else e = Drafting.polar(face.cx, face.cy, face.u(140), sun.deg + 180)
      Drafting.line(ctx, face.cx, face.cy, e[0], e[1], L, 0.55, 1.2, [6 * k, 4 * k])
    }
  }

  // The level's 0 / 50 / 100 figures and its dimension text.
  Repeater {
    model: face.half ? [0, 50, 100] : []
    delegate: Text {
      id: fig
      required property int modelData
      required property int index
      readonly property var at: Drafting.polar(face.cx, face.cy, face.u(174), 180 + fig.modelData * 1.8)
      x: fig.index === 1 ? at[0] - width / 2 : fig.index === 2 ? at[0] : at[0] - width
      y: at[1] - height / 2
      text: String(fig.modelData)
      textFormat: Text.PlainText
      font.family: face.fontFamily; font.pixelSize: face.u(11); font.letterSpacing: face.u(1.1)
      color: face.ink(0.6)
    }
  }
  Text {
    visible: face.levelShown
    readonly property var at: Drafting.polar(face.cx, face.cy, face.u(106), 180 + (sun.deg - 180) / 2)
    x: at[0] - width / 2; y: at[1] - height / 2
    text: Math.round(Math.max(0, Math.min(100, (sun.deg - 180) / 1.8))) + "%"
    textFormat: Text.PlainText
    font.family: face.fontFamily; font.pixelSize: face.u(11); font.letterSpacing: face.u(1.1)
    color: face.accent
  }

  // The sun: a hatched disc with eight rays, on the rim (ring) or the arc (half plate).
  Item {
    id: sun
    property real deg: -90
    Component.onCompleted: deg = face.sunTarget
    readonly property var at: Drafting.polar(face.cx, face.cy, face.u(face.half ? 160 : 150), deg)
    x: at[0]; y: at[1]
    readonly property real r: face.u(face.levelShown ? 13 : 15)
    Canvas {
      id: sunArt
      x: -width / 2; y: -height / 2
      width: sun.r * 2 + face.u(24); height: width
      renderStrategy: Canvas.Cooperative
      onPaint: {
        var ctx = getContext("2d"), A = String(face.accent), c = width / 2, r = sun.r
        ctx.reset(); ctx.__w = face.lineScale
        Drafting.hatch(ctx, function (g) { g.arc(c, c, r, 0, Math.PI * 2) }, width, height, A, 0.5, face.u(5))
        Drafting.ring(ctx, c, c, r, A, 1, 1.4)
        ctx.lineCap = "round"
        for (var i = 0; i < 8; i++) {
          var p = Drafting.polar(c, c, r + face.u(4), i * 45), q = Drafting.polar(c, c, r + face.u(10), i * 45)
          Drafting.line(ctx, p[0], p[1], q[0], q[1], A, 1, 1.4)
        }
      }
    }
  }

  // The moon, hatched, sliding over the sun.
  Item {
    visible: face.noteKind === "cant"
    x: face.cx + face.u(face.moonX); y: face.cy - face.u(162)
    Rectangle {
      x: -width / 2; y: -height / 2; width: face.u(34); height: width; radius: width / 2
      color: face.ground; border.width: 1; border.color: face.ink(0.7)
    }
    Canvas {
      id: moonArt
      x: -width / 2; y: -height / 2; width: face.u(34); height: width
      renderStrategy: Canvas.Cooperative
      onPaint: {
        var ctx = getContext("2d"), c = width / 2
        ctx.reset(); ctx.__w = face.lineScale
        Drafting.hatch(ctx, function (g) { g.arc(c, c, c - 1, 0, Math.PI * 2) }, width, height, String(face.line), 0.22, face.u(7))
      }
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

  // The hub: the chosen hour's name (ring), the level, or the eclipse.
  Column {
    x: face.cx - width / 2
    y: face.half ? face.cy - face.u(104) : face.cy + face.u(14)
    width: face.u(120)
    Text {
      width: parent.width; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
      text: face.noteKind === "cant" ? "ECLIPSE"
          : face.levelShown ? String(face.note.name || "").toUpperCase()
          : face.toolName(face.index)
      textFormat: Text.PlainText
      font.family: face.fontFamily; font.bold: true
      font.pixelSize: face.half ? face.u(11) : face.u(14)
      font.letterSpacing: face.half ? face.u(1.3) : 0
      color: face.noteKind === "cant" ? face.alert : face.line
      opacity: face.half ? 1 : face.ringInk
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      visible: face.levelShown
      text: face.valueText
      textFormat: Text.PlainText
      font.family: face.fontFamily; font.pixelSize: face.u(26)
      color: face.accent
    }
  }

  // The title block's text (its frame is drawn on the plate).
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
        : face.levelShown ? "SUNDIAL"
        : face.noteKind === "hint" ? "NOTE " + (face.note.step || 1)
        : "HOUR " + (Math.min(face.index, face.n - 1) + 1) + "/" + face.n
    textFormat: Text.PlainText
    font.family: face.fontFamily; font.pixelSize: face.u(11); font.letterSpacing: face.u(1.3)
    color: face.ink(0.7)
  }

  function repaint() { back.requestPaint(); shadow.requestPaint(); sunArt.requestPaint(); moonArt.requestPaint(); lead.requestPaint() }
  onWidthChanged: repaint()
  onHeightChanged: repaint()
  onNoteChanged: repaint()
  onNChanged: repaint()
  onLineChanged: repaint()
  onAccentChanged: repaint()
  onLeaderEndYChanged: lead.requestPaint()
  onLeadFromChanged: lead.requestPaint()
  onLeadKneeChanged: lead.requestPaint()
  Connections { target: sun; function onDegChanged() { shadow.requestPaint(); if (face.levelShown) back.requestPaint() } }
  Connections { target: face.cfg; function onChanged() { face.repaint() } }
}
