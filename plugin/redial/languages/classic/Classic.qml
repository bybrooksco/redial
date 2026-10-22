pragma ComponentBehavior: Bound

import QtQuick

// re:dial classic: the Classic look, the original instrument refreshed.
//
// Horizontal labels on the circumference, a graduated bar scale, concentric rings, sector spokes,
// and an elbowed leader out to the callout column DialMenu places to the right (why this look is
// landscape). The dial resolves to 0.1 degrees, so a real graduated scale is an honest readout of
// the hardware, not decoration.
//
// Refreshed from the first Classic: the lit sector is its own pre-drawn layer turned with the hand
// instead of a repaint of all 180 bars on every detent; the leader eases between tools; the chosen
// glyph grows with a transform instead of re-laying out text; labels are a step darker; colours
// come from the colour scheme's roles. Nothing here imports the Omarchy shell: the host passes the
// unit, font and type sizes in.
Item {
  id: face

  required property var cfg
  property var language: null
  // Host-supplied metrics (DialMenu passes Omarchy's; a standalone host passes its own).
  property real unit: 1
  property string fontFamily: "monospace"
  property var type: ({ caption: 10, subtitle: 13, title: 14, display: 24, displayLarge: 28 })

  property var tools: []
  property int index: 0
  // Continuous angular position in tool units, fed over the socket. When `live` the needle and the
  // lit sector follow it directly - no animation, because the hand already supplies the motion.
  property real position: 0
  property bool live: false

  function u(px) { return Math.max(1, Math.round(px * unit)) }
  readonly property color line: cfg.roles.line
  readonly property color accent: cfg.roles.accent
  function ink(a) { return Qt.rgba(line.r, line.g, line.b, a) }
  readonly property var easeOut: language ? language.easeOut : [0.23, 1, 0.32, 1, 1, 1]
  readonly property var easeInOut: language ? language.easeInOut : [0.77, 0, 0.175, 1, 1, 1]

  readonly property int n: Math.max(1, tools.length)
  // The circle is sized by height and sits left in a wider item; the space to its right carries
  // the leader line out to the annotation block.
  readonly property real cx: height / 2
  readonly property real cy: height / 2

  readonly property int rHub: u(74)
  readonly property int rInner: u(112)
  readonly property int rGlyph: u(150)
  readonly property int rBand: u(186)
  readonly property int rBarBase: u(200)
  readonly property int rBarMin: u(210)
  readonly property int rBarMaj: u(220)
  readonly property int rBarAct: u(236)
  readonly property int rRule: u(246)
  readonly property int rLabel: u(258)
  // How far ring labels may reach so they stay on the plate: the face sits 30 units in from the
  // plate's left edge and the callout column starts 56 units past the 580-unit ring.
  readonly property real labelLeftReach: u(30) - u(16)
  readonly property real labelRightLimit: u(580) + u(56) - u(16)

  function angleOf(i) { return -Math.PI / 2 + i * 2 * Math.PI / n }

  // The hand. Live: straight from the continuous position. Stepped (IPC only): the shortest way
  // round, eased, so the last tool to the first moves one sector forward.
  readonly property real liveDeg: -90 + position * (360 / n)
  property real steppedDeg: -90
  Behavior on steppedDeg {
    id: stepEase
    NumberAnimation { duration: face.cfg.motionBase; easing.type: Easing.BezierSpline; easing.bezierCurve: face.easeInOut }
  }
  readonly property real needleDeg: live ? liveDeg : steppedDeg
  // The leader follows the chosen tool (not the hand), eased, and the callout rides on it.
  property real leaderDeg: -90
  Behavior on leaderDeg {
    NumberAnimation { duration: face.cfg.motionBase; easing.type: Easing.BezierSpline; easing.bezierCurve: face.easeInOut }
  }

  property int _lastIndex: 0
  onIndexChanged: {
    var step = 360 / n
    var d = (index - _lastIndex) % n
    if (d > n / 2) d -= n
    if (d < -n / 2) d += n
    if (!live) steppedDeg += d * step
    leaderDeg += d * step
    _lastIndex = index
  }
  // Leaving live mode: pick the stepped hand up where the live one left it, without a sweep.
  onLiveChanged: if (!live) { stepEase.enabled = false; steppedDeg = liveDeg; stepEase.enabled = true }

  // Where the leader's level run sits, so DialMenu can centre the callout on it.
  readonly property real leaderY: cy + Math.sin(leaderDeg * Math.PI / 180) * (rRule + u(36))

  onToolsChanged: base.requestPaint()
  onLineChanged: { base.requestPaint(); leader.requestPaint() }
  onAccentChanged: { sector.requestPaint(); leader.requestPaint() }
  onLeaderDegChanged: leader.requestPaint()
  // A settings edit must redraw; the canvases sample widths at paint time.
  Connections {
    target: face.cfg
    function onChanged() { base.requestPaint(); sector.requestPaint(); leader.requestPaint() }
  }

  // --- the drawing: construction, rings, the full scale in ink, spokes ------------------------------
  // Painted only when tools, colours or settings change, never per detent.
  Canvas {
    id: base
    anchors.fill: parent
    renderStrategy: Canvas.Cooperative

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var fg = String(face.line)
      var cx = face.cx, cy = face.cy, lw = face.cfg.ringWidth
      function line(x1, y1, x2, y2, w, alpha) {
        ctx.beginPath(); ctx.globalAlpha = alpha; ctx.lineWidth = w; ctx.strokeStyle = fg
        ctx.moveTo(x1, y1); ctx.lineTo(x2, y2); ctx.stroke(); ctx.globalAlpha = 1
      }
      function ring(r, alpha) {
        ctx.beginPath(); ctx.globalAlpha = alpha; ctx.lineWidth = lw; ctx.strokeStyle = fg
        ctx.arc(cx, cy, r, 0, Math.PI * 2); ctx.stroke(); ctx.globalAlpha = 1
      }
      function node(x, y, r, alpha) {
        ctx.beginPath(); ctx.globalAlpha = alpha; ctx.fillStyle = fg
        ctx.arc(x, y, r, 0, Math.PI * 2); ctx.fill(); ctx.globalAlpha = 1
      }

      // Construction lines run past the circle to the plate edges, nodes at their ends: what makes
      // the dial read as drawn rather than placed. Part of the reference lines (reference_lines).
      if (face.cfg.constructionLines && face.cfg.plate === "rect") {
        line(0, cy, width, cy, lw, 0.13)
        line(cx, 0, cx, height, lw, 0.13)
        node(width - face.u(10), cy, 3, 0.35)
        node(cx, face.u(10), 2.5, 0.30)
        node(cx, height - face.u(10), 2.5, 0.30)
        line(face.u(18), cy - face.rInner, cx + face.rRule, cy - face.rInner, lw, 0.07)
        line(face.u(18), cy + face.rInner, cx + face.rRule, cy + face.rInner, lw, 0.07)
      }

      ring(face.rHub, 0.22)
      ring(face.rInner, 0.10)
      ring(face.rBand, 0.14)
      ring(face.rRule, 0.30)

      var barCount = face.cfg.barCount
      for (var b = 0; b < barCount; b++) {
        var a = -Math.PI / 2 + b * Math.PI * 2 / barCount
        var major = (b % face.cfg.majorEvery) === 0
        line(cx + Math.cos(a) * face.rBarBase, cy + Math.sin(a) * face.rBarBase,
             cx + Math.cos(a) * (major ? face.rBarMaj : face.rBarMin), cy + Math.sin(a) * (major ? face.rBarMaj : face.rBarMin),
             major ? face.cfg.barWidthMajor : face.cfg.barWidthMinor, major ? 0.45 : 0.20)
      }

      var seg = Math.PI * 2 / face.n
      for (var s = 0; s < face.n; s++) {
        var sa = face.angleOf(s) - seg / 2
        line(cx + Math.cos(sa) * face.rHub, cy + Math.sin(sa) * face.rHub,
             cx + Math.cos(sa) * face.rBarBase, cy + Math.sin(sa) * face.rBarBase, lw, 0.10)
      }
    }
  }

  // --- the selection: one sector of accent bars, drawn once at the top and turned with the hand -----
  Canvas {
    id: sector
    x: 0; y: 0
    width: face.height; height: face.height   // square about (cx, cy), so it turns about the hub
    rotation: face.needleDeg + 90
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var cx = width / 2, cy = height / 2
      var step = Math.PI * 2 / face.cfg.barCount
      var half = Math.PI / face.n * face.cfg.sectorFill
      ctx.strokeStyle = String(face.accent); ctx.globalAlpha = 0.95; ctx.lineWidth = face.cfg.barWidthActive
      for (var a = -half; a <= half + 1e-6; a += step) {
        var t = -Math.PI / 2 + a
        ctx.beginPath()
        ctx.moveTo(cx + Math.cos(t) * face.rBarBase, cy + Math.sin(t) * face.rBarBase)
        ctx.lineTo(cx + Math.cos(t) * face.rBarAct, cy + Math.sin(t) * face.rBarAct)
        ctx.stroke()
      }
    }
  }

  // --- the leader: a short diagonal off the circle, then level out to the callout ------------------
  Canvas {
    id: leader
    anchors.fill: parent
    visible: face.cfg.showCallout
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var a = face.leaderDeg * Math.PI / 180
      var lx = face.cx + Math.cos(a) * (face.rRule + face.u(10)), ly = face.cy + Math.sin(a) * (face.rRule + face.u(10))
      var dx = lx + Math.cos(a) * face.u(26), dy = ly + Math.sin(a) * face.u(26)
      var ex = face.height + face.u(26)
      ctx.strokeStyle = String(face.accent); ctx.fillStyle = String(face.accent); ctx.lineWidth = face.cfg.ringWidth
      ctx.globalAlpha = 0.65
      ctx.beginPath(); ctx.moveTo(lx, ly); ctx.lineTo(dx, dy); ctx.lineTo(ex, dy); ctx.stroke()
      ctx.globalAlpha = 1
      ctx.beginPath(); ctx.arc(lx, ly, 3, 0, Math.PI * 2); ctx.fill()
      ctx.globalAlpha = 0.85
      ctx.beginPath(); ctx.arc(ex, dy, 2, 0, Math.PI * 2); ctx.fill()
    }
  }

  // --- needle --------------------------------------------------------------------------------------
  Item {
    x: face.cx; y: face.cy
    width: 0; height: 0
    transformOrigin: Item.TopLeft
    rotation: face.needleDeg
    Rectangle {
      x: face.rHub; y: -face.cfg.needleWidth / 2
      width: face.rBarBase - face.rHub; height: face.cfg.needleWidth
      color: face.accent; opacity: 0.6
    }
    Rectangle {
      x: face.rBarBase - face.u(3); y: -face.u(3)
      width: face.u(6); height: width; radius: width / 2
      color: face.accent
    }
  }

  // --- tool labels on the circumference -------------------------------------------------------------
  // Horizontal rather than radial: with eight they have to be read, not just seen. The chosen label
  // is omitted - it is named in the hub and the callout, exactly where the leader takes off.
  Repeater {
    model: face.tools
    delegate: Item {
      id: lab
      required property int index
      required property var modelData
      readonly property bool active: lab.index === face.index
      readonly property real a: face.angleOf(lab.index)
      readonly property real px: face.cx + Math.cos(lab.a) * face.rLabel
      readonly property real py: face.cy + Math.sin(lab.a) * face.rLabel
      readonly property bool rightSide: Math.cos(lab.a) >= -0.05
      readonly property real room: lab.rightSide ? face.labelRightLimit - lab.px : lab.px + face.labelLeftReach

      visible: face.cfg.showLabels
      opacity: lab.active ? 0 : 1
      Behavior on opacity { NumberAnimation { duration: face.cfg.motionFast } }
      width: Math.max(face.u(24), Math.min(probe.implicitWidth, lab.room))
      height: label.implicitHeight
      x: lab.rightSide ? lab.px : lab.px - width
      y: lab.py - height / 2

      Text { id: probe; visible: false; text: label.text; font: label.font }
      Text {
        id: label
        width: parent.width
        text: (lab.modelData.name || "").toUpperCase()
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        maximumLineCount: 2
        elide: Text.ElideRight
        horizontalAlignment: lab.rightSide ? Text.AlignLeft : Text.AlignRight
        font.family: face.fontFamily
        font.pixelSize: face.type.caption
        font.letterSpacing: 1.5
        color: face.ink(face.language ? face.language.inkLabel : 0.58)
      }
    }
  }

  // --- tool glyphs ----------------------------------------------------------------------------------
  Repeater {
    model: face.tools
    delegate: Item {
      id: glyph
      required property int index
      required property var modelData
      readonly property bool active: glyph.index === face.index
      readonly property real a: face.angleOf(glyph.index)

      visible: face.cfg.showGlyphs
      width: face.u(52); height: width
      x: face.cx + Math.cos(glyph.a) * face.rGlyph - width / 2
      y: face.cy + Math.sin(glyph.a) * face.rGlyph - height / 2

      Text {
        anchors.centerIn: parent
        text: glyph.modelData.icon || ""
        textFormat: Text.PlainText
        font.family: face.fontFamily
        font.pixelSize: face.type.title
        // grows by transform, so nothing re-lays out or re-rasterises mid-move
        scale: glyph.active ? face.type.displayLarge / face.type.title : 1
        color: glyph.active ? face.accent : face.ink(0.38)
        Behavior on scale { NumberAnimation { duration: face.cfg.motionBase; easing.type: Easing.BezierSpline; easing.bezierCurve: face.easeOut } }
        Behavior on color { ColorAnimation { duration: face.cfg.motionFast } }
      }
    }
  }

  // --- hub ------------------------------------------------------------------------------------------
  Column {
    x: face.cx - width / 2
    y: face.cy - height / 2
    spacing: face.u(3)
    width: face.rHub * 1.9

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: face.tools.length > face.index ? (face.tools[face.index].name || "") : ""
      textFormat: Text.PlainText
      font.family: face.fontFamily
      font.pixelSize: face.type.subtitle
      font.bold: true
      color: face.line
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      visible: text !== ""
      text: face.tools.length > face.index && face.tools[face.index].valueText !== undefined
            ? face.tools[face.index].valueText : ""
      textFormat: Text.PlainText
      font.family: face.fontFamily
      font.pixelSize: face.type.display
      color: face.accent
    }
  }
}
