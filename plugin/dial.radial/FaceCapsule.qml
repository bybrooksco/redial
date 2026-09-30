import QtQuick
import qs.Commons
import qs.Ui

// CAPSULE face - tools as radial capsules on a round backing.
//
// Structure borrowed from the reference plate: the tools are radial capsules
// around the rim - outline when idle, filled and enlarged when selected - with
// their labels set *on* the capsule and a thin leader running from the centre
// to the selection. The interior rings each carry a different reading rather
// than decoration.
//
// Deliberately absent: full-width construction lines, edge nodes and offset
// rules. Those were geometry from the landscape layout, where they ran out to
// an annotation block on the right. With the callout moved onto the rim they
// terminated on nothing, and past the round backing they ran onto bare desktop.
Item {
  id: face

  required property var cfg

  property var tools: []
  property int index: 0
  property real position: 0
  property bool live: false

  readonly property int n: Math.max(1, tools.length)
  readonly property real cx: width / 2
  readonly property real cy: height / 2
  readonly property real unit: Math.min(width, height) / 760   // design was drawn at 760

  // --- radii, outermost first ---------------------------------------------
  // Pulled in from 286: measured, the selected capsule and its secondary line
  // crossed the backing edge by a couple of pixels. Nothing may render outside
  // the disc - that was the whole point of going round.
  readonly property real rCapsule: 262 * unit     // capsule centres
  readonly property real rSlot:    212 * unit     // one tick per tool
  readonly property real rValue:   196 * unit     // active tool's value, when it has one
  readonly property real rScaleOut:182 * unit     // fine rotation scale, outer
  readonly property real rScaleIn: 150 * unit     // fine rotation scale, inner
  readonly property real rHub:      96 * unit

  // --- capsule geometry ----------------------------------------------------
  readonly property real capLen:    112 * unit
  readonly property real capLenSel: 138 * unit
  // Width is a fraction of the arc each tool owns at the capsule radius, so
  // "the pills are too separated" is a number rather than a rebuild. At 1.0
  // neighbours touch; the gap between them is (1 - capsuleSpan) of that arc.
  readonly property real arcPerTool: 2 * Math.PI * rCapsule / n
  readonly property real capWide:    arcPerTool * cfg.capsuleSpan
  readonly property real capWideSel: capWide * 1.26

  function angleOf(i) { return -Math.PI / 2 + i * 2 * Math.PI / n }

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
  onToolsChanged: canvas.requestPaint()
  onCfgChanged: canvas.requestPaint()
  onPositionChanged: if (live) canvas.requestPaint()

  Connections {
    target: face.cfg
    function onChanged() { canvas.requestPaint() }
  }

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
      var lw = face.cfg.ringWidth

      function radial(a, r1, r2, w, style, alpha) {
        ctx.beginPath(); ctx.globalAlpha = alpha; ctx.lineWidth = w
        ctx.strokeStyle = style
        ctx.moveTo(cx + Math.cos(a) * r1, cy + Math.sin(a) * r1)
        ctx.lineTo(cx + Math.cos(a) * r2, cy + Math.sin(a) * r2)
        ctx.stroke(); ctx.globalAlpha = 1
      }
      function arc(r, a1, a2, w, style, alpha) {
        ctx.beginPath(); ctx.globalAlpha = alpha; ctx.lineWidth = w
        ctx.strokeStyle = style; ctx.lineCap = "butt"
        ctx.arc(cx, cy, r, a1, a2); ctx.stroke(); ctx.globalAlpha = 1
      }

      // --- ring 1: fine rotation scale --------------------------------------
      // The honest 0.1-degree readout. Dashes rather than a solid band, and the
      // sector belonging to the selection takes the accent.
      var bars = face.cfg.barCount
      for (var b = 0; b < bars; b++) {
        var a = -Math.PI / 2 + b * Math.PI * 2 / bars
        var d = Math.atan2(Math.sin(a - actA), Math.cos(a - actA))
        var inSector = Math.abs(d) <= seg / 2 * face.cfg.sectorFill
        var major = (b % face.cfg.majorEvery) === 0
        radial(a,
               face.rScaleIn + (inSector ? 0 : (major ? 4 * face.unit : 10 * face.unit)),
               face.rScaleOut,
               inSector ? face.cfg.barWidthActive
                        : (major ? face.cfg.barWidthMajor : face.cfg.barWidthMinor),
               inSector ? accent : fg,
               inSector ? 0.95 : (major ? 0.38 : 0.16))
      }

      // --- ring 2: the active tool's value, when it has one -------------------
      // Contextual, not decorative: nothing is drawn for a tool with no value,
      // so the ring's presence is itself information.
      var t = face.tools.length > face.index ? face.tools[face.index] : null
      if (t && t.value !== undefined) {
        var frac = Math.max(0, Math.min(1, t.value / 100))
        arc(face.rValue, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2, 2 * face.unit, fg, 0.10)
        if (frac > 0)
          arc(face.rValue, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * frac,
              3 * face.unit, accent, 0.85)
      }

      // --- ring 3: one tick per tool -----------------------------------------
      for (var s = 0; s < face.n; s++) {
        var on = (s === face.index)
        radial(face.angleOf(s), face.rSlot, face.rSlot + (on ? 14 : 8) * face.unit,
               on ? 2.5 * face.unit : lw, on ? accent : fg, on ? 0.9 : 0.30)
      }

      // --- leader: centre to the selected capsule -----------------------------
      radial(actA, face.rHub, face.rCapsule - face.capLenSel / 2,
             face.cfg.needleWidth, accent, 0.55)

      // Optional extras, both contained inside the face - never running past it.
      if (face.cfg.crosshair) {
        radial(0, 0, face.rHub, lw, fg, 0.12); radial(Math.PI, 0, face.rHub, lw, fg, 0.12)
        radial(-Math.PI / 2, 0, face.rHub, lw, fg, 0.12); radial(Math.PI / 2, 0, face.rHub, lw, fg, 0.12)
      }
      if (face.cfg.constructionLines) {
        for (var g = 0; g < face.n; g++)
          radial(face.angleOf(g) - seg / 2, face.rHub, face.rSlot, lw, fg, 0.10)
      }
    }
  }

  // --- capsules -------------------------------------------------------------
  Repeater {
    model: face.tools
    delegate: Item {
      id: cap
      required property int index
      required property var modelData
      readonly property bool active: index === face.index
      readonly property real aDeg: face.angleOf(index) * 180 / Math.PI
      // A stadium is symmetric end to end, so a capsule in the lower half is
      // turned through 180 degrees rather than left carrying upside-down text.
      readonly property bool flip: aDeg > 90 || aDeg < -90

      x: face.cx; y: face.cy
      width: 0; height: 0
      transformOrigin: Item.TopLeft
      rotation: flip ? aDeg + 180 : aDeg

      Rectangle {
        id: body
        readonly property real len: cap.active ? face.capLenSel : face.capLen
        readonly property real wide: cap.active ? face.capWideSel : face.capWide
        width: len
        height: wide
        // One continuous fillet, as a fraction of the largest radius the shape
        // allows: 1 gives a stadium (or a circle when square), 0 a hard box.
        radius: (Math.min(width, height) / 2) * face.cfg.capsuleFillet
        x: (cap.flip ? -face.rCapsule - len / 2 : face.rCapsule - len / 2)
        y: -wide / 2
        color: cap.active ? face.cfg.accentColor : "transparent"
        border.width: Math.max(1, face.cfg.ringWidth * 2)
        border.color: cap.active ? face.cfg.accentColor
                                 : Util.alpha(face.cfg.lineColor, 0.38)
        antialiasing: true

        Behavior on width  { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
        Behavior on height { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
        Behavior on color  { ColorAnimation { duration: 150 } }
        Behavior on border.color { ColorAnimation { duration: 150 } }

        Text {
          anchors.centerIn: parent
          // Rotated with its capsule, not set horizontally. The earlier
          // objection - that five labels must be read, not seen as texture -
          // was about *bare* labels on a circumference. The capsule supplies
          // the bounding shape and ground that made rotated text illegible
          // without it, so the objection is answered rather than overridden.
          text: (modelData.name || "").toUpperCase()
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.letterSpacing: 1.2
          font.bold: cap.active
          color: cap.active ? face.cfg.backgroundColor
                            : Util.alpha(face.cfg.lineColor, 0.72)
          Behavior on color { ColorAnimation { duration: 150 } }
        }
      }

      // Secondary line beside the selection, as on the reference plate: the
      // click action, which is the half of a tool you cannot infer. Offset
      // toward the centre rather than away from it, so it cannot be the thing
      // that breaches the rim.
      Text {
        visible: cap.active && face.cfg.showCallout && text !== ""
        text: {
          var h = cap.modelData.hint
          return (h && h !== "—") ? h : ""
        }
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        color: Util.alpha(face.cfg.lineColor, 0.60)
        x: body.x + body.width / 2 - width / 2
        y: body.y - height - Style.space(5)
      }
    }
  }

  // --- hub ------------------------------------------------------------------
  Column {
    x: face.cx - width / 2
    y: face.cy - height / 2
    spacing: Style.space(2)
    width: face.rHub * 1.9

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: face.tools.length > face.index ? (face.tools[face.index].name || "") : ""
      font.family: Style.font.family
      font.pixelSize: Style.font.body
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
