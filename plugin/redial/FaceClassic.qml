import QtQuick
import qs.Commons
import qs.Ui

// CLASSIC face - the original instrument in a rectangular window.
//
// Horizontal labels on the circumference, a graduated bar scale, concentric
// rings, sector spokes, and an elbowed leader out to a callout column that
// DialMenu places to the right. That callout column is why this face is
// landscape rather than square.
//
// Kept as a peer of FaceCapsule rather than as branches inside one file: the
// two differ in geometry, in what the rings mean, and in where the callout
// lives, so gating them together would be a parallel implementation tangled
// into one scope rather than two readable ones.
//
// Built to the two reference plates: information lives *around* the dial and is
// carried by lines. Radiating bars form the scale, tool names are set radially
// on the circumference, and construction lines run well past the circle to the
// plate edges with nodes at their ends. The dial resolves to 0.1 degrees, so a
// real graduated scale is an honest readout of the hardware, not decoration.
Item {
  id: face

  // Settings object (see Settings.qml). Every read goes through it, so there
  // are no tunables baked into this file.
  required property var cfg

  property var tools: []
  property int index: 0
  // Continuous angular position in tool units, fed over the socket. When `live`
  // the needle follows it directly - no animation, because the hand is already
  // supplying the motion and interpolating on top only adds lag.
  property real position: 0
  property bool live: false

  readonly property int n: Math.max(1, tools.length)
  // The circle is sized by height and sits left in a wider item; the space to
  // its right carries the leader line out to the annotation block.
  readonly property real cx: height / 2
  readonly property real cy: height / 2

  readonly property int rHub: Style.space(74)
  readonly property int rInner: Style.space(112)
  readonly property int rGlyph: Style.space(150)
  readonly property int rBand: Style.space(186)
  readonly property int rBarBase: Style.space(200)
  readonly property int rBarMin: Style.space(210)
  readonly property int rBarMaj: Style.space(220)
  readonly property int rBarAct: Style.space(236)
  readonly property int rRule: Style.space(246)
  readonly property int rLabel: Style.space(258)
  // How far ring labels may reach, in this face's own coordinates, so they stay on the
  // plate. The face sits 30 units in from the plate's left edge (DialMenu's faceLoader.x)
  // and the callout column starts 56 units past the face's 580-unit ring; both keep a
  // 16-unit margin. Without this a long name on the left grew off the plate.
  readonly property real labelLeftReach: Style.space(30) - Style.space(16)
  readonly property real labelRightLimit: Style.space(580) + Style.space(56) - Style.space(16)

  function angleOf(i) { return -Math.PI / 2 + i * 2 * Math.PI / n }

  // Needle angle in degrees.
  //
  // Live: taken straight from the continuous position, so the needle tracks the
  // hand at rotation rate.
  // Stepped (IPC only, no socket): advanced by the shortest way round, so the
  // last tool to the first sweeps one sector forward rather than unwinding all
  // the way back.
  //
  // Either way it is a rotation on an Item, never a canvas repaint.
  readonly property real liveDeg: -90 + position * (360 / n)
  property real steppedDeg: angleOf(0) * 180 / Math.PI
  readonly property real needleDeg: live ? liveDeg : steppedDeg

  property int _lastIndex: 0
  onIndexChanged: {
    if (!live) {
      var step = 360 / n
      var d = (index - _lastIndex) % n
      if (d > n / 2) d -= n
      if (d < -n / 2) d += n
      steppedDeg += d * step
    }
    _lastIndex = index
    canvas.requestPaint()
  }

  // Where the leader line runs out to, so the callout can align to it.
  readonly property real leaderY: cy + Math.sin(angleOf(index)) * (rRule + Style.space(10))

  onToolsChanged: canvas.requestPaint()

  // A settings edit must redraw the scale; the canvas samples colours and
  // widths at paint time, so a binding alone would not reach it.
  Connections {
    target: face.cfg
    function onChanged() { canvas.requestPaint() }
  }
  onCfgChanged: canvas.requestPaint()

  Canvas {
    id: canvas
    anchors.fill: parent
    renderStrategy: Canvas.Cooperative

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      ctx.clearRect(0, 0, width, height)

      var accent = String(face.cfg.accentColor)
      var fg = String(face.cfg.lineColor)
      var cx = face.cx, cy = face.cy
      var seg = Math.PI * 2 / face.n
      var actA = face.angleOf(face.index)

      function line(x1, y1, x2, y2, w, style, alpha) {
        ctx.beginPath(); ctx.globalAlpha = alpha; ctx.lineWidth = w
        ctx.strokeStyle = style
        ctx.moveTo(x1, y1); ctx.lineTo(x2, y2); ctx.stroke(); ctx.globalAlpha = 1
      }
      function ring(r, w, style, alpha) {
        ctx.beginPath(); ctx.globalAlpha = alpha; ctx.lineWidth = w
        ctx.strokeStyle = style
        ctx.arc(cx, cy, r, 0, Math.PI * 2); ctx.stroke(); ctx.globalAlpha = 1
      }
      function node(x, y, r, style, alpha) {
        ctx.beginPath(); ctx.globalAlpha = alpha; ctx.fillStyle = style
        ctx.arc(x, y, r, 0, Math.PI * 2); ctx.fill(); ctx.globalAlpha = 1
      }

      // --- construction lines ---------------------------------------------
      // Run past the circle to the plate edges, with nodes at their ends, as in
      // the ink plate. These are what make the dial read as drawn rather than
      // placed.
      var lw = face.cfg.ringWidth
      // Only run these to the item bounds on the rectangular plate they were
      // drawn for; on any other backing they would terminate outside it.
      if (face.cfg.constructionLines && face.cfg.plate === "rect") {
        line(0, cy, width, cy, lw, fg, 0.13)
        line(cx, 0, cx, height, lw, fg, 0.13)
        node(width - Style.space(10), cy, 3, fg, 0.35)
        node(cx, Style.space(10), 2.5, fg, 0.30)
        node(cx, height - Style.space(10), 2.5, fg, 0.30)

        // Offset rules, echoing the plate's stacked horizontals.
        line(Style.space(18), cy - face.rInner, cx + face.rRule, cy - face.rInner, lw, fg, 0.07)
        line(Style.space(18), cy + face.rInner, cx + face.rRule, cy + face.rInner, lw, fg, 0.07)
      }

      // --- concentric rings -------------------------------------------------
      ring(face.rHub, lw, fg, 0.22)
      ring(face.rInner, lw, fg, 0.10)
      ring(face.rBand, lw, fg, 0.14)
      ring(face.rRule, lw, fg, 0.30)

      // --- radiating scale --------------------------------------------------
      // 180 bars, one every 2 degrees. Bars inside the selected tool's sector
      // extend further and take the accent, so the selection is read as a
      // region of the scale rather than a separate widget.
      var barCount = face.cfg.barCount
      for (var b = 0; b < barCount; b++) {
        var a = -Math.PI / 2 + b * Math.PI * 2 / barCount
        // shortest angular distance to the active sector centre
        var d = Math.atan2(Math.sin(a - actA), Math.cos(a - actA))
        var inSector = Math.abs(d) <= seg / 2 * face.cfg.sectorFill
        var major = (b % face.cfg.majorEvery) === 0
        var r2 = inSector ? face.rBarAct : (major ? face.rBarMaj : face.rBarMin)
        ctx.beginPath()
        ctx.lineWidth = inSector ? face.cfg.barWidthActive
                                 : (major ? face.cfg.barWidthMajor : face.cfg.barWidthMinor)
        ctx.strokeStyle = inSector ? accent : fg
        ctx.globalAlpha = inSector ? 0.95 : (major ? 0.45 : 0.20)
        ctx.moveTo(cx + Math.cos(a) * face.rBarBase, cy + Math.sin(a) * face.rBarBase)
        ctx.lineTo(cx + Math.cos(a) * r2, cy + Math.sin(a) * r2)
        ctx.stroke()
      }
      ctx.globalAlpha = 1

      // --- sector divisions -------------------------------------------------
      // A hairline spoke between tools, from hub to scale.
      for (var s = 0; s < face.n; s++) {
        var sa = face.angleOf(s) - seg / 2
        line(cx + Math.cos(sa) * face.rHub, cy + Math.sin(sa) * face.rHub,
             cx + Math.cos(sa) * face.rBarBase, cy + Math.sin(sa) * face.rBarBase,
             lw, fg, 0.10)
      }

      // --- leader out to the callout ----------------------------------------
      if (!face.cfg.showCallout) return
      var lx = cx + Math.cos(actA) * (face.rRule + Style.space(10))
      var ly = cy + Math.sin(actA) * (face.rRule + Style.space(10))
      var diagX = lx + Math.cos(actA) * Style.space(26)
      var diagY = ly + Math.sin(actA) * Style.space(26)
      var elbowX = face.height + Style.space(26)
      // short diagonal off the circle, then a horizontal run to the margin
      line(lx, ly, diagX, diagY, lw, accent, 0.6)
      line(diagX, diagY, elbowX, diagY, lw, accent, 0.6)
      node(lx, ly, 3, accent, 1)
      node(elbowX, diagY, 2, accent, 0.8)
    }
  }

  // --- needle ---------------------------------------------------------------
  Item {
    x: face.cx
    y: face.cy
    width: 0; height: 0
    transformOrigin: Item.TopLeft
    rotation: face.needleDeg
    Behavior on rotation {
      enabled: !face.live
      NumberAnimation { duration: cfg.motionSlow; easing.type: Easing.OutCubic }
    }

    Rectangle {
      x: face.rHub
      y: -face.cfg.needleWidth / 2
      width: face.rBarBase - face.rHub
      height: face.cfg.needleWidth
      color: face.cfg.accentColor
      opacity: 0.55
    }
    Rectangle {
      x: face.rBarBase - Style.space(3)
      y: -Style.space(3)
      width: Style.space(6); height: width
      radius: width / 2
      color: face.cfg.accentColor
    }
  }

  // --- tool labels on the circumference ------------------------------------
  // Set horizontally rather than along their radius: the reference plate can
  // rotate its labels because it has hundreds of them forming a texture, but
  // with five they have to be read, not just seen. The radial motion is carried
  // by the bars, the spokes and the selected radius instead.
  //
  // The selected tool's label is omitted - it is already named in the hub and
  // again in the callout, and it is exactly where the leader line takes off.
  Repeater {
    model: face.tools
    delegate: Item {
      required property int index
      required property var modelData
      readonly property bool active: index === face.index
      readonly property real a: face.angleOf(index)
      readonly property real px: face.cx + Math.cos(a) * face.rLabel
      readonly property real py: face.cy + Math.sin(a) * face.rLabel
      // Anchor the label on the side of the ring it sits on, so the text grows
      // outward from the circle instead of across it.
      readonly property bool rightSide: Math.cos(a) >= -0.05

      // Room left for the text before it would leave the plate (or reach the callout).
      readonly property real room: rightSide ? face.labelRightLimit - px : px + face.labelLeftReach

      visible: !active && face.cfg.showLabels
      width: Math.max(Style.space(24), Math.min(probe.implicitWidth, room))
      height: label.implicitHeight
      x: rightSide ? px : px - width
      y: py - height / 2

      // Natural, unwrapped width -- what the label would like. If that is more than
      // `room`, the label wraps at a space (two lines), and elides only as a last
      // resort (a single long word).
      Text {
        id: probe
        visible: false
        text: label.text
        font: label.font
      }
      Text {
        id: label
        width: parent.width
        text: (modelData.name || "").toUpperCase()
        wrapMode: Text.WordWrap
        maximumLineCount: 2
        elide: Text.ElideRight
        // Lines hug the ring: right-aligned on the left side, left-aligned on the right.
        horizontalAlignment: rightSide ? Text.AlignLeft : Text.AlignRight
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1.5
        color: Util.alpha(face.cfg.lineColor, 0.42)
      }
    }
  }

  // --- tool glyphs ----------------------------------------------------------
  Repeater {
    model: face.tools
    delegate: Item {
      required property int index
      required property var modelData
      readonly property bool active: index === face.index
      readonly property real a: face.angleOf(index)

      visible: face.cfg.showGlyphs
      width: Style.space(52); height: width
      x: face.cx + Math.cos(a) * face.rGlyph - width / 2
      y: face.cy + Math.sin(a) * face.rGlyph - height / 2

      Text {
        anchors.centerIn: parent
        text: modelData.icon || ""
        font.family: Style.font.family
        font.pixelSize: active ? Style.font.displayLarge : Style.font.title
        color: active ? face.cfg.accentColor : Util.alpha(face.cfg.lineColor, 0.34)
        Behavior on font.pixelSize { NumberAnimation { duration: cfg.motionFast; easing.type: Easing.OutCubic } }
        Behavior on color { ColorAnimation { duration: cfg.motionFast } }
      }
    }
  }

  // --- hub ------------------------------------------------------------------
  Column {
    x: face.cx - width / 2
    y: face.cy - height / 2
    spacing: Style.space(3)
    width: face.rHub * 1.9

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: face.tools.length > face.index ? (face.tools[face.index].name || "") : ""
      font.family: Style.font.family
      font.pixelSize: Style.font.subtitle
      font.bold: true
      color: face.cfg.lineColor
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      visible: text !== ""
      text: face.tools.length > face.index && face.tools[face.index].valueText !== undefined
            ? face.tools[face.index].valueText : ""
      font.family: Style.font.family
      font.pixelSize: Style.font.display
      color: face.cfg.accentColor
    }
  }
}
