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
  // A state the daemon reported: "" is the ring; "turn" (note: name, value, valueText), "hint"
  // (prompt, gesture, step, steps) or "cant" (reason, title, line).
  property string noteKind: ""
  property var note: ({})
  // Where the host placed the callout's first line, in this item's coordinates (-1: at leaderY). A
  // callout clamped clear of the plate's edge or title block moves, and the leader bends to meet it.
  property real landY: -1

  function u(px) { return Math.max(1, Math.round(px * unit)) }
  readonly property color line: cfg.roles.line
  readonly property color accent: cfg.roles.accent
  readonly property color alert: cfg.roles.alert
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
  // Turning a tool with a level: the scale becomes its 0-100 range and the hand reads the level.
  readonly property bool levelShown: noteKind === "turn" && note.value !== undefined
  readonly property real levelDeg: -90 + Math.max(0, Math.min(100, Number(note.value) || 0)) * 3.6
  property real levelHand: -90
  Binding on levelHand { value: face.levelDeg; when: face.levelShown }
  Behavior on levelHand {
    NumberAnimation { duration: face.cfg.motionFast; easing.type: Easing.BezierSpline; easing.bezierCurve: face.easeOut }
  }
  readonly property real needleDeg: levelShown ? levelHand : (live ? liveDeg : steppedDeg)
  // How strongly the ring's glyphs and labels read: gone while a level owns the scale, set back
  // behind a hint, further behind section hatching.
  readonly property real ringInk: levelShown ? 0 : noteKind === "cant" ? 0.35 : noteKind === "hint" ? 0.55 : 1
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

  // The leader takes off from the level while one is shown, else from the chosen tool.
  readonly property real leaderAt: levelShown ? levelHand : leaderDeg
  // A take-off on the left would run the leader's level leg straight across the dial. It follows the
  // scale round instead, over the top (up) or under the bottom, to the right side, and leaves there
  // (a): through the gap between two labels next to its mirror point, toward level, so it never runs
  // through another tool's name. A level has no labels round it and leaves from the mirror itself.
  // `land` (optional): the height the callout actually sits at. When the host clamped the callout
  // away from the natural height, the leader runs further round the scale to the point whose level
  // run meets it, rather than cutting across the drawing. `cw`: the way round, clockwise on screen.
  function leaderRoute(deg, land) {
    var take = deg * Math.PI / 180
    var left = Math.cos(take) < -0.05
    var up = Math.sin(take) <= 1e-6
    var a = take
    if (left) {
      var mirror = Math.atan2(Math.sin(Math.PI - take), Math.cos(Math.PI - take))
      a = mirror
      if (!levelShown) {
        var seg = 2 * Math.PI / n, t = (mirror + Math.PI / 2) / seg
        a = -Math.PI / 2 + (up ? Math.floor(t + 1e-9) + 0.5 : Math.ceil(t - 1e-9) - 0.5) * seg
        if (up && a > 1e-9) a -= seg          // stay above level on the way over the top
        if (!up && a < -1e-9) a += seg        // ...and below it on the way under
      }
    }
    var cw = up
    var reach = rRule + u(36)   // where the level run leaves: see leaderY
    if (land !== undefined && land >= 0 && Math.abs(cy + Math.sin(a) * reach - land) > 0.5) {
      a = Math.asin(Math.max(-1, Math.min(1, (land - cy) / reach)))
      if (!left) cw = a > Math.atan2(Math.sin(take), Math.cos(take))
    }
    return { take: take, left: left, up: up, a: a, cw: cw }
  }

  // Where the leader's level run sits, so DialMenu can centre the callout on it.
  readonly property real leaderY: cy + Math.sin(leaderRoute(leaderAt).a) * (rRule + u(36))

  onToolsChanged: base.requestPaint()
  onLineChanged: { base.requestPaint(); leader.requestPaint(); hatch.requestPaint() }
  onAccentChanged: { sector.requestPaint(); leader.requestPaint(); level.requestPaint(); sign.requestPaint() }
  onAlertChanged: sign.requestPaint()
  onLeaderAtChanged: leader.requestPaint()
  onLandYChanged: leader.requestPaint()
  onLevelShownChanged: { base.requestPaint(); level.requestPaint() }
  onLevelDegChanged: if (levelShown) level.requestPaint()   // at most ~10 a second, from the daemon
  onNoteKindChanged: sign.requestPaint()
  onNoteChanged: sign.requestPaint()
  // A settings edit must redraw; the canvases sample widths at paint time.
  Connections {
    target: face.cfg
    function onChanged() { base.requestPaint(); sector.requestPaint(); leader.requestPaint(); level.requestPaint(); hatch.requestPaint() }
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

      // The sector spokes divide the ring into tools; a level has no tools to divide.
      var seg = Math.PI * 2 / face.n
      for (var s = 0; s < (face.levelShown ? 0 : face.n); s++) {
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
    visible: !face.levelShown
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

  // --- a level: the scale lit from zero to it, and a dimension arc with arrowheads spanning it ------
  Canvas {
    id: level
    anchors.fill: parent
    visible: face.levelShown
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      if (!face.levelShown) return
      var cx = face.cx, cy = face.cy, to = (face.levelDeg + 90) * Math.PI / 180
      var step = Math.PI * 2 / face.cfg.barCount
      ctx.strokeStyle = String(face.accent); ctx.fillStyle = String(face.accent)
      ctx.globalAlpha = 0.95; ctx.lineWidth = face.cfg.barWidthActive
      for (var a = 0; a <= to + 1e-6; a += step) {
        var t = -Math.PI / 2 + a
        ctx.beginPath()
        ctx.moveTo(cx + Math.cos(t) * face.rBarBase, cy + Math.sin(t) * face.rBarBase)
        ctx.lineTo(cx + Math.cos(t) * face.rBarAct, cy + Math.sin(t) * face.rBarAct)
        ctx.stroke()
      }
      if (to < 0.08) return   // too short to dimension
      var r = face.rBand, a0 = -Math.PI / 2 + 0.02, a1 = -Math.PI / 2 + to - 0.02
      ctx.lineWidth = face.cfg.ringWidth
      ctx.beginPath(); ctx.arc(cx, cy, r, a0, a1); ctx.stroke()
      function head(at, dir) {   // a filled arrowhead on the arc, pointing along it
        var px = cx + Math.cos(at) * r, py = cy + Math.sin(at) * r
        var tx = -Math.sin(at) * dir, ty = Math.cos(at) * dir, k = face.u(9), w = face.u(3)
        ctx.beginPath(); ctx.moveTo(px, py)
        ctx.lineTo(px - tx * k - ty * w, py - ty * k + tx * w)
        ctx.lineTo(px - tx * k + ty * w, py - ty * k - tx * w)
        ctx.closePath(); ctx.fill()
      }
      head(a0, -1); head(a1, 1)
    }
  }

  // --- can't act: section hatching across the ring, as a drawing shows a cut face --------------------
  Canvas {
    id: hatch
    anchors.fill: parent
    visible: face.noteKind === "cant"
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var cx = face.cx, cy = face.cy, r = face.rBarBase
      ctx.save()
      ctx.beginPath(); ctx.arc(cx, cy, r, 0, Math.PI * 2); ctx.clip()
      ctx.strokeStyle = String(face.line); ctx.globalAlpha = 0.16; ctx.lineWidth = 1
      for (var d = -2 * r; d <= 2 * r; d += face.u(9)) {
        ctx.beginPath(); ctx.moveTo(cx + d - r, cy + r); ctx.lineTo(cx + d + r, cy - r); ctx.stroke()
      }
      ctx.restore()
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
      var r = face.rRule + face.u(10)
      var route = face.leaderRoute(face.leaderAt, face.landY)
      var take = route.take, a = route.a
      var lx = face.cx + Math.cos(a) * r, ly = face.cy + Math.sin(a) * r
      var dx = lx + Math.cos(a) * face.u(26), dy = ly + Math.sin(a) * face.u(26)
      var ex = face.height + face.u(26)
      ctx.strokeStyle = String(face.accent); ctx.fillStyle = String(face.accent); ctx.lineWidth = face.cfg.ringWidth
      ctx.globalAlpha = 0.65
      ctx.beginPath()
      var from = Math.atan2(Math.sin(take), Math.cos(take)), to = Math.atan2(Math.sin(a), Math.cos(a))
      if (Math.abs(to - from) < 1e-6) {
        ctx.moveTo(lx, ly)
      } else {
        // round the scale first; unwrap so the sweep goes the chosen way and under a full turn
        if (route.cw) while (to < from) to += 2 * Math.PI
        else while (to > from) to -= 2 * Math.PI
        ctx.arc(face.cx, face.cy, r, from, to, !route.cw)
      }
      ctx.lineTo(dx, dy); ctx.lineTo(ex, dy); ctx.stroke()
      ctx.globalAlpha = 1
      var tx = face.cx + Math.cos(take) * r, ty = face.cy + Math.sin(take) * r
      ctx.beginPath(); ctx.arc(tx, ty, 3, 0, Math.PI * 2); ctx.fill()
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
      opacity: lab.active && !face.levelShown ? 0 : face.ringInk
      Behavior on opacity { NumberAnimation { duration: face.cfg.motionFast } }
      width: Math.max(face.u(24), Math.min(probe.implicitWidth, lab.room))
      height: label.implicitHeight
      x: lab.rightSide ? lab.px : lab.px - width
      y: lab.py - height / 2

      Text {
        id: probe; visible: false; text: label.text
        font.family: face.fontFamily; font.pixelSize: face.type.caption; font.letterSpacing: 1.5
      }
      // A single word too long for its room (WORKSPACES) is set smaller, down to 75%, before it elides.
      readonly property bool oneWord: label.text.indexOf(" ") < 0
      readonly property real fit: lab.oneWord && probe.implicitWidth > lab.room ? Math.max(0.75, lab.room / probe.implicitWidth) : 1
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
        font.pixelSize: Math.floor(face.type.caption * lab.fit)
        font.letterSpacing: 1.5 * lab.fit
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
      opacity: face.ringInk
      Behavior on opacity { NumberAnimation { duration: face.cfg.motionFast } }
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

  // --- a level's scale figures: 0, 25, 50, 75 at the quarters ------------------------------------------
  Repeater {
    model: face.levelShown ? [0, 25, 50, 75] : []
    delegate: Text {
      id: fig
      required property int modelData
      readonly property real a: (-90 + fig.modelData * 3.6) * Math.PI / 180
      x: face.cx + Math.cos(fig.a) * face.rLabel - (fig.modelData === 75 ? width : fig.modelData === 25 ? 0 : width / 2)
      y: face.cy + Math.sin(fig.a) * face.rLabel - height / 2 + (fig.modelData === 50 ? face.u(6) : fig.modelData === 0 ? -face.u(6) : 0)
      text: fig.modelData
      font.family: face.fontFamily
      font.pixelSize: face.type.caption
      color: face.ink(face.language ? face.language.inkKey : 0.55)
    }
  }

  // --- hub ------------------------------------------------------------------------------------------
  Column {
    x: face.cx - width / 2
    y: face.cy - height / 2
    spacing: face.u(3)
    width: face.rHub * 1.9

    // A hint draws the gesture it asks for; can't-act draws why (asleep: a crescent; else a bar sign).
    Canvas {
      id: sign
      anchors.horizontalCenter: parent.horizontalCenter
      visible: face.noteKind === "hint" || face.noteKind === "cant"
      width: face.u(40); height: width
      renderStrategy: Canvas.Cooperative
      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        var c = width / 2, k = width / 40, g = face.note.gesture
        ctx.lineWidth = 2.5 * k; ctx.lineCap = "round"
        if (face.noteKind === "hint") {
          ctx.strokeStyle = String(face.accent); ctx.fillStyle = String(face.accent)
          if (g === "turn") {   // a part turn with an arrowhead, round a small hub
            ctx.globalAlpha = 0.35; ctx.beginPath(); ctx.arc(c, c, 7 * k, 0, Math.PI * 2); ctx.fill(); ctx.globalAlpha = 1
            ctx.beginPath(); ctx.arc(c, c, 14 * k, -Math.PI * 0.95, -Math.PI * 0.12); ctx.stroke()
            var ax = c + Math.cos(-Math.PI * 0.12) * 14 * k, ay = c + Math.sin(-Math.PI * 0.12) * 14 * k
            ctx.beginPath(); ctx.moveTo(ax, ay); ctx.lineTo(ax + 0.5 * k, ay - 6.5 * k); ctx.moveTo(ax, ay); ctx.lineTo(ax - 6.5 * k, ay - 0.5 * k); ctx.stroke()
          } else if (g === "press") {   // a button and the ring it sends out
            ctx.beginPath(); ctx.arc(c, c, 7 * k, 0, Math.PI * 2); ctx.fill()
            ctx.beginPath(); ctx.arc(c, c, 13 * k, 0, Math.PI * 2); ctx.stroke()
          } else if (g === "hold") {   // a button and a timer filling round it
            ctx.beginPath(); ctx.arc(c, c, 7 * k, 0, Math.PI * 2); ctx.fill()
            ctx.globalAlpha = 0.25; ctx.beginPath(); ctx.arc(c, c, 15 * k, 0, Math.PI * 2); ctx.stroke(); ctx.globalAlpha = 1
            ctx.beginPath(); ctx.arc(c, c, 15 * k, -Math.PI / 2, Math.PI * 0.9); ctx.stroke()
          } else {   // a note with no gesture: a dot
            ctx.beginPath(); ctx.arc(c, c, 4 * k, 0, Math.PI * 2); ctx.fill()
          }
        } else if (face.noteKind === "cant") {
          ctx.strokeStyle = String(face.alert); ctx.fillStyle = String(face.alert)
          if (face.note.reason === "asleep") {
            ctx.beginPath(); ctx.arc(c - 1 * k, c, 13 * k, 0, Math.PI * 2); ctx.fill()
            ctx.globalCompositeOperation = "destination-out"
            ctx.beginPath(); ctx.arc(c + 6 * k, c - 5 * k, 11 * k, 0, Math.PI * 2); ctx.fill()
          } else {
            ctx.beginPath(); ctx.arc(c, c, 13 * k, 0, Math.PI * 2); ctx.stroke()
            ctx.beginPath(); ctx.moveTo(c - 9 * k, c + 9 * k); ctx.lineTo(c + 9 * k, c - 9 * k); ctx.stroke()
          }
        }
      }
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      visible: face.noteKind !== "cant"
      text: face.noteKind === "turn" ? (face.note.name || "")
            : face.tools.length > face.index ? (face.tools[face.index].name || "") : ""
      textFormat: Text.PlainText
      font.family: face.fontFamily
      font.pixelSize: face.type.subtitle
      font.bold: true
      color: face.line
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      visible: text !== "" && (face.noteKind === "" || face.noteKind === "turn")
      text: face.noteKind === "turn" ? (face.note.valueText || "")
            : face.tools.length > face.index && face.tools[face.index].valueText !== undefined
            ? face.tools[face.index].valueText : ""
      textFormat: Text.PlainText
      objectName: "valueText"
      // a level reads large; a window or track name is a line of text and must fit inside the ring
      readonly property bool wordy: text.length > 8
      width: Math.min(implicitWidth, face.rInner * 1.7)
      horizontalAlignment: Text.AlignHCenter
      elide: Text.ElideRight
      maximumLineCount: wordy ? 2 : 1
      wrapMode: wordy ? Text.WordWrap : Text.NoWrap
      font.family: face.fontFamily
      font.pixelSize: wordy ? face.type.subtitle : face.type.display
      color: face.accent
    }
  }
}
