import QtQuick
import "Basic.js" as Basic

// A hint or can't-act message as every basic look carries it in its own frame: the sign, the
// prompt or title, its line, and step dots for a guided hint.
Column {
  id: msg
  required property Item look
  property real big: 21
  property real small: 14
  property real signSize: 36
  property color ink: look.tone.ink
  property color soft: look.tone.soft
  property string family: look.face
  readonly property var note: look.note
  readonly property bool hint: look.noteKind === "hint"
  spacing: look.u(3)
  Canvas {
    id: sign
    anchors.horizontalCenter: parent.horizontalCenter
    width: msg.look.u(msg.signSize); height: width
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      Basic.sign(ctx, msg.look.noteKind, msg.note, width, String(msg.look.tone.accent), String(msg.look.tone.alert))
    }
    Connections {
      target: msg.look
      function onNoteKindChanged() { sign.requestPaint() }
      function onNoteChanged() { sign.requestPaint() }
      function onToneChanged() { sign.requestPaint() }
    }
  }
  Text {
    width: msg.width; horizontalAlignment: Text.AlignHCenter
    wrapMode: Text.Wrap; maximumLineCount: 3; elide: Text.ElideRight
    text: msg.hint ? String(msg.note.prompt || "") : String(msg.note.title || "")
    textFormat: Text.PlainText
    font.family: msg.family; font.pixelSize: msg.look.u(msg.big); font.weight: Font.Bold
    lineHeight: 1.1
    color: msg.ink
  }
  Text {
    width: msg.width; horizontalAlignment: Text.AlignHCenter
    wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
    visible: text !== ""
    text: msg.hint ? "" : String(msg.note.line || "")
    textFormat: Text.PlainText
    font.family: msg.family; font.pixelSize: msg.look.u(msg.small)
    color: msg.soft
  }
  Row {
    anchors.horizontalCenter: parent.horizontalCenter
    visible: msg.hint && msg.note.steps > 1
    spacing: msg.look.u(6)
    topPadding: msg.look.u(5)
    Repeater {
      model: msg.hint && msg.note.steps > 1 ? msg.note.steps : 0
      delegate: Rectangle {
        required property int index
        width: msg.look.u(8); height: width; radius: width / 2
        color: index < (msg.note.step || 1) ? msg.look.tone.accent : msg.look.tone.track
      }
    }
  }
}
