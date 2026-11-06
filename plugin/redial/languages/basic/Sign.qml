import QtQuick
import "Basic.js" as Basic

// The state sign: a hint's gesture in the accent, can't act in the alert (Basic.sign).
Canvas {
  id: sign
  required property Item host
  property real size: host.u(36)
  width: size; height: size
  renderStrategy: Canvas.Cooperative
  onPaint: {
    var ctx = getContext("2d")
    ctx.reset()
    Basic.sign(ctx, host.noteKind, host.note, width, String(host.tone.accent), String(host.tone.alert))
  }
  Connections {
    target: sign.host
    function onNoteKindChanged() { sign.requestPaint() }
    function onNoteChanged() { sign.requestPaint() }
  }
  onWidthChanged: requestPaint()
}
