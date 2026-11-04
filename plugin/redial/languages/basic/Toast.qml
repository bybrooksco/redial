pragma ComponentBehavior: Bound

import QtQuick
import "Basic.js" as Basic
import "Tones.js" as Tones

// re:dial basic: the Toast layout, the quietest look. One pill: an accent disc with the tool's
// glyph, the name and its click action, fixed-size position dots. Turning a level fills the pill
// itself as the meter. A hint or can't act puts the sign in the disc. Mockup: TOAST in looks.js.
LookBase {
  id: look

  readonly property size plateSize: Qt.size(330, 60)
  readonly property bool wantsCallout: false
  readonly property string kind: "layout"

  readonly property int litCount: litOf(100)
  readonly property bool message: noteKind === "hint" || noteKind === "cant"
  readonly property Item selection: nameText
  property alias dots: dotRow.dots
  property alias fill: fillBar

  Rectangle { anchors.fill: parent; radius: height / 2; color: look.tone.ground }
  // The meter: the pill itself filling, clipped to its rounded ends.
  Canvas {
    id: fillBar
    anchors.fill: parent
    visible: look.levelShown
    renderStrategy: Canvas.Cooperative
    property real shown: look.level
    Behavior on shown { NumberAnimation { duration: look.cfg.motionFast } }
    onShownChanged: requestPaint()
    onPaint: {
      var ctx = getContext("2d"), r = height / 2
      ctx.reset()
      ctx.beginPath(); ctx.roundedRect(0, 0, width, height, r, r); ctx.clip()
      ctx.fillStyle = Tones.mix(String(look.tone.ground), String(look.tone.accent), 0.22)
      ctx.fillRect(0, 0, width * shown / 100, height)
    }
  }

  Row {
    x: look.u(8); anchors.verticalCenter: parent.verticalCenter
    width: parent.width - look.u(28)
    spacing: look.u(12)

    Rectangle {
      width: look.u(44); height: width; radius: width / 2
      color: look.message ? look.tone.surface : look.tone.accent
      Text {
        anchors.centerIn: parent
        visible: !look.message && look.cfg.showGlyphs
        text: look.toolIcon(look.levelShown ? 0 : look.chosen); textFormat: Text.PlainText
        font.family: look.fontFamily; font.pixelSize: look.u(20)
        color: look.tone.onaccent
      }
      Canvas {
        id: sign
        anchors.centerIn: parent
        visible: look.message
        width: look.u(28); height: width
        renderStrategy: Canvas.Cooperative
        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          Basic.sign(ctx, look.noteKind, look.note, width, String(look.tone.accent), String(look.tone.alert))
        }
      }
    }

    Column {
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width - look.u(56) - right.width - look.u(12)
      Text {
        id: nameText
        width: parent.width; elide: Text.ElideRight
        text: look.noteKind === "hint" ? String(look.note.prompt || "")
            : look.noteKind === "cant" ? String(look.note.title || "")
            : look.levelShown ? String(look.note.name || "") : look.toolName(look.chosen)
        textFormat: Text.PlainText
        font.family: look.face; font.pixelSize: look.u(look.message ? 19 : 20); font.weight: Font.Bold
        color: look.tone.ink
      }
      Text {
        width: parent.width; elide: Text.ElideRight
        visible: text !== ""
        text: look.noteKind === "hint" ? (look.note.steps > 1 ? "Step " + look.note.step + " of " + look.note.steps : "")
            : look.noteKind === "cant" ? String(look.note.line || "")
            : look.pressText(look.chosen)
        textFormat: Text.PlainText
        font.family: look.face; font.pixelSize: look.u(look.message ? 13 : 14)
        color: look.tone.soft
      }
    }

    Item {
      id: right
      anchors.verticalCenter: parent.verticalCenter
      width: look.levelShown ? valueText.width : look.message ? 0 : dotRow.width
      height: look.u(30)
      // The value, a trailing % set smaller as in the mockup.
      Row {
        id: valueText
        readonly property bool pct: look.valueText.slice(-1) === "%"
        anchors.verticalCenter: parent.verticalCenter
        visible: look.levelShown
        Text {
          anchors.baseline: parent.children[1].baseline
          text: valueText.pct ? look.valueText.slice(0, -1) : look.valueText; textFormat: Text.PlainText
          font.family: look.face; font.pixelSize: look.u(28); font.weight: Font.Bold
          color: look.tone.ink
        }
        Text {
          visible: valueText.pct
          text: "%"; textFormat: Text.PlainText
          font.family: look.face; font.pixelSize: look.u(17); font.weight: Font.Bold
          color: look.tone.ink
        }
      }
      Row {
        id: dotRow
        property alias dots: dotRepeater
        anchors.verticalCenter: parent.verticalCenter
        visible: look.stateDrawn === "ring"
        spacing: look.u(6)
        Repeater {
          id: dotRepeater
          model: look.stateDrawn === "ring" ? look.tools.length : 0
          delegate: Rectangle {
            required property int index
            readonly property bool on: index === look.chosen
            width: look.u(8); height: width; radius: width / 2
            scale: on ? 1.35 : 1
            color: on ? look.tone.accent : look.tone.track
          }
        }
      }
    }
  }

  onNoteKindChanged: sign.requestPaint()
  onNoteChanged: sign.requestPaint()
  onToneChanged: { sign.requestPaint(); fillBar.requestPaint() }
}
