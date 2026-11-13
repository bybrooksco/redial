import QtQuick
import "Basic.js" as Basic

// re:dial basic: the Pie look. The continuous quiet track, hairline spokes between tools, and a
// faint accent wedge from the choice back to the centre that turns with the marker.
RingFace {
  id: look
  segmented: false

  readonly property real inner: r - trackW / 2 - u(1)
  readonly property Item wedge: wedgeArt

  Canvas {
    id: spokes
    z: 0.5
    anchors.fill: parent
    visible: look.iconsShown
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      ctx.strokeStyle = String(look.tone.track); ctx.lineWidth = look.u(1.2)
      for (var i = 0; i < look.n && look.n > 1; i++) {
        var a = (-90 + (i + 0.5) * look.seg) * Math.PI / 180
        ctx.beginPath()
        ctx.moveTo(look.cx + Math.cos(a) * look.u(22), look.cy + Math.sin(a) * look.u(22))
        ctx.lineTo(look.cx + Math.cos(a) * look.inner, look.cy + Math.sin(a) * look.inner)
        ctx.stroke()
      }
    }
  }

  // The wedge, drawn at the top inside the marker so it turns with it.
  Canvas {
    id: wedgeArt
    parent: look.selection
    z: -1
    width: look.inner * 2; height: width
    x: -width / 2; y: -height / 2
    opacity: 0.14
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d"), c = width / 2, h = look.seg / 2 * Math.PI / 180
      ctx.reset()
      ctx.fillStyle = String(look.tone.accent)
      ctx.beginPath(); ctx.moveTo(c, c); ctx.arc(c, c, look.inner, -Math.PI / 2 - h, -Math.PI / 2 + h); ctx.closePath(); ctx.fill()
    }
  }

  onNChanged: { spokes.requestPaint(); wedgeArt.requestPaint() }
  onToneChanged: { spokes.requestPaint(); wedgeArt.requestPaint() }
  onWidthChanged: { spokes.requestPaint(); wedgeArt.requestPaint() }
}
