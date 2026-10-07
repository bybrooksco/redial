import QtQuick
import qs.Commons
import qs.Ui

// GAUGE face - tools laid out across a 180 degree dome, needle-style, like a
// car speedometer. Keeps the one thing that actually makes the dial feel
// good (a needle that tracks rotation continuously) while dropping every
// ring, hairline and callout column Classic carries. Meant as the middle
// ground between Classic's instrument density and Pie Wheel/Carousel/Toast's
// full minimalism.
//
// Not circular like Classic/Capsule/FacePie - the tools span a fixed 180
// degree arc (left to right, over the top) rather than the full circle, so
// its own angle math is deliberately separate from theirs rather than a
// wraparound special case bolted onto it. The needle itself still follows
// FaceClassic.qml's needle technique (a rotated Item + Behavior on rotation)
// since that part IS the same problem.
Item {
  id: face

  required property var cfg

  property var tools: []
  property int index: 0
  property real position: 0
  property bool live: false

  readonly property int n: Math.max(1, tools.length)
  readonly property real unit: Math.min(width, height) / 760

  // Pivot sits near the bottom of the square face area; the dome bows up
  // from there, exactly like a dashboard gauge's needle pivot.
  readonly property real cx: width / 2
  readonly property real cy: height - 90 * unit

  readonly property real rOuter: 300 * unit
  readonly property real rInner: 210 * unit
  readonly property real rIcon:  260 * unit
  readonly property real rNeedle: rOuter - 20 * unit
  readonly property real rHub: 40 * unit

  // 180 degrees, left to right over the top - not a full-circle angleOf like
  // the other faces, on purpose (see file header).
  function angleOf(i) { return Math.PI + i * Math.PI / Math.max(1, n - 1) }
  readonly property real liveDeg: 180 + position * (180 / Math.max(1, n - 1))
  readonly property real steppedDeg: 180 + index * (180 / Math.max(1, n - 1))
  readonly property real needleDeg: live ? liveDeg : steppedDeg

  onToolsChanged: canvas.requestPaint()
  onCfgChanged: canvas.requestPaint()

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

      var cx = face.cx, cy = face.cy

      // Dome backing band. A Canvas arc() takes explicit start/end angles and
      // a direction flag, not the ambiguous large-arc/sweep flags an SVG path
      // would need for the same shape - safe to draw directly rather than
      // sampling a polyline.
      //
      // Filled close to opaque with the theme's own background (same idea as
      // DialMenu's disc/rect plate -- a near-transparent band read as
      // "undefined" over real desktop content). Solid fill only, no rim
      // stroke -- an outlined edge around the whole backdrop competed with
      // the icons for attention instead of just sitting behind them; the
      // fill's own contrast against the desktop already reads as a defined
      // shape without one.
      ctx.beginPath()
      ctx.arc(cx, cy, face.rOuter, Math.PI, Math.PI * 2, false)
      ctx.arc(cx, cy, face.rInner, Math.PI * 2, Math.PI, true)
      ctx.closePath()
      var bg = face.cfg.backgroundColor
      ctx.fillStyle = Qt.rgba(bg.r, bg.g, bg.b, Math.max(0.85, face.cfg.plateOpacity))
      ctx.fill()
    }
  }

  // --- needle -----------------------------------------------------------------
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
      x: 0
      y: -face.cfg.needleWidth / 2
      width: face.rNeedle
      height: Math.max(2, face.cfg.needleWidth * 1.4)
      color: face.cfg.accentColor
    }
  }

  // --- icon glyphs, one per tool -----------------------------------------------
  Repeater {
    model: face.tools
    delegate: Item {
      required property int index
      required property var modelData
      readonly property bool active: index === face.index
      readonly property real a: face.angleOf(index)

      width: Style.space(50); height: width
      x: face.cx + Math.cos(a) * face.rIcon - width / 2
      y: face.cy + Math.sin(a) * face.rIcon - height / 2

      Rectangle {
        anchors.fill: parent
        radius: width / 2
        visible: parent.active
        color: face.cfg.accentColor
      }
      Text {
        anchors.centerIn: parent
        text: modelData.icon || ""
        font.family: Style.font.family
        // Deliberately a size (not two) smaller than the circle than it
        // first shipped with -- the glyph was nearly touching the accent
        // circle's edge with no breathing room.
        font.pixelSize: active ? Style.font.body : Style.font.caption
        color: active ? face.cfg.backgroundColor : Util.alpha(face.cfg.lineColor, 0.5)
        Behavior on font.pixelSize { NumberAnimation { duration: cfg.motionFast; easing.type: Easing.OutCubic } }
        Behavior on color { ColorAnimation { duration: cfg.motionFast } }
      }
    }
  }

  // --- pivot + readout, sitting just above the needle's base -------------------
  // Solid fill, no border -- same reasoning as the dome band above.
  Rectangle {
    x: face.cx - face.rHub
    y: face.cy - face.rHub
    width: face.rHub * 2; height: width
    radius: width / 2
    color: face.cfg.backgroundColor
  }
  Rectangle {
    x: face.cx - width / 2
    y: face.cy - height / 2
    width: Style.space(9); height: width
    radius: width / 2
    color: face.cfg.accentColor
  }
  Column {
    x: face.cx - width / 2
    y: face.cy - face.rHub - height - Style.space(10)
    spacing: Style.space(2)
    width: 220 * face.unit

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
  }
}
