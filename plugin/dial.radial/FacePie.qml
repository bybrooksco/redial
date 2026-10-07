import QtQuick
import qs.Commons
import qs.Ui

// PIE WHEEL face - tools as full-bleed pie wedges, game-menu style.
//
// Built for someone who has never seen this plugin before: no rings, no
// degree scale, no construction lines - the wedge you're pointing at IS the
// selection, the way a game's weapon/item wheel already works. Icon only on
// idle wedges; the hub carries the one piece of text that matters (the
// selected tool's name, value and click hint), same pattern Classic/Capsule
// already use for their hub.
//
// Shares its angle math and live/stepped needle interpolation with
// FaceCapsule.qml on purpose - that code is already correct, and inventing
// a second version of it would just be a second place for the same bug.
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
  readonly property real unit: Math.min(width, height) / 760   // same design grid as Capsule

  readonly property real rOuter: 300 * unit
  readonly property real rInner: 104 * unit
  readonly property real rIcon:  (rOuter + rInner) / 2
  readonly property real rHub:    96 * unit
  // How far this face's own drawing actually reaches -- DialMenu's disc
  // backing sizes itself to this (plus its own small margin) instead of
  // always filling the whole square.
  readonly property real contentRadius: rOuter
  // Small angular gap between wedges so they read as separate slices rather
  // than one ring with tick marks - a fixed radian value, not a fraction of
  // the wedge, so it stays a clean hairline regardless of tool count.
  readonly property real wedgeGap: 0.035

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
      var idleFill = Util.alpha(face.cfg.lineColor, 0.07)
      var cx = face.cx, cy = face.cy
      var half = Math.PI / face.n - face.wedgeGap / 2

      for (var i = 0; i < face.n; i++) {
        var a = face.angleOf(i)
        var a0 = a - half, a1 = a + half
        var on = (i === face.index)
        ctx.beginPath()
        ctx.arc(cx, cy, face.rOuter, a0, a1, false)
        ctx.arc(cx, cy, face.rInner, a1, a0, true)
        ctx.closePath()
        ctx.fillStyle = on ? accent : idleFill
        ctx.fill()
      }
    }
  }

  // --- icon glyphs, one per wedge -------------------------------------------
  Repeater {
    model: face.tools
    delegate: Item {
      required property int index
      required property var modelData
      readonly property bool active: index === face.index
      readonly property real a: face.angleOf(index)

      width: Style.space(52); height: width
      x: face.cx + Math.cos(a) * face.rIcon - width / 2
      y: face.cy + Math.sin(a) * face.rIcon - height / 2

      Text {
        anchors.centerIn: parent
        text: modelData.icon || ""
        font.family: Style.font.family
        font.pixelSize: active ? Style.font.displayLarge : Style.font.title
        color: active ? face.cfg.backgroundColor : Util.alpha(face.cfg.lineColor, 0.55)
        Behavior on font.pixelSize { NumberAnimation { duration: cfg.motionFast; easing.type: Easing.OutCubic } }
        Behavior on color { ColorAnimation { duration: cfg.motionFast } }
      }
    }
  }

  // --- hub -------------------------------------------------------------------
  // Solid fill, no border -- matches Gauge's pivot (same backdrop-vs-icon
  // reasoning: the fill's own contrast is definition enough, a stroke was
  // just competing with the icons around it for attention).
  Rectangle {
    x: face.cx - width / 2
    y: face.cy - height / 2
    width: face.rHub * 2
    height: width
    radius: width / 2
    color: face.cfg.backgroundColor
  }
  Column {
    x: face.cx - width / 2
    y: face.cy - height / 2
    spacing: Style.space(2)
    width: face.rHub * 1.7

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: face.tools.length > face.index ? (face.tools[face.index].name || "") : ""
      font.family: Style.font.family
      font.pixelSize: Style.font.subtitle
      font.bold: true
      color: face.cfg.lineColor
      elide: Text.ElideRight
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
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
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      visible: text !== ""
      text: {
        var t = face.tools.length > face.index ? face.tools[face.index] : null
        var h = t ? t.hint : ""
        return (h && h !== "—") ? ("click: " + h) : ""
      }
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      color: Util.alpha(face.cfg.lineColor, 0.55)
      elide: Text.ElideRight
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
    }
  }
}
