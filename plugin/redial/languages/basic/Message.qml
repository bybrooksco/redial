import QtQuick
import "Basic.js" as Basic

// A hint or can't-act message as every basic look carries it in its own frame: the sign, the
// prompt or title, its line, and step dots for a guided hint.
Column {
  id: msg
  required property LookBase host
  property real big: 21
  property real small: 14
  property real signSize: 36
  property color ink: host.tone.ink
  property color soft: host.tone.soft
  property string family: host.face
  readonly property var note: host.note
  readonly property bool hint: host.noteKind === "hint"
  spacing: host.u(3)
  Canvas {
    id: sign
    anchors.horizontalCenter: parent.horizontalCenter
    width: msg.host.u(msg.signSize); height: width
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      Basic.sign(ctx, msg.host.noteKind, msg.note, width, String(msg.host.tone.accent), String(msg.host.tone.alert))
    }
    Connections {
      target: msg.host
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
    font.family: msg.family; font.pixelSize: msg.host.u(msg.big); font.weight: Font.Bold
    lineHeight: 1.1
    color: msg.ink
  }
  Text {
    width: msg.width; horizontalAlignment: Text.AlignHCenter
    wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
    visible: text !== ""
    text: msg.hint ? "" : String(msg.note.line || "")
    textFormat: Text.PlainText
    font.family: msg.family; font.pixelSize: msg.host.u(msg.small)
    color: msg.soft
  }
  Row {
    anchors.horizontalCenter: parent.horizontalCenter
    visible: msg.hint && msg.note.steps > 1
    spacing: msg.host.u(6)
    topPadding: msg.host.u(5)
    Repeater {
      model: msg.hint && msg.note.steps > 1 ? msg.note.steps : 0
      delegate: Rectangle {
        required property int index
        width: msg.host.u(8); height: width; radius: width / 2
        color: index < (msg.note.step || 1) ? msg.host.tone.accent : msg.host.tone.track
      }
    }
  }
}
