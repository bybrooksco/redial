pragma ComponentBehavior: Bound

import QtQuick
import "Basic.js" as Basic

// re:dial basic: the Carousel layout. A row of tiles in a tray; one scalar (the hand's position)
// drives every tile's width, and the widths always sum to the same row, so the row never changes
// width. The name and click action sit under it. A state becomes a compact card: the level as a
// meter, or the message beside its sign. Mockup: CAR in looks.js.
LookBase {
  id: look

  readonly property size plateSize: stateDrawn === "ring" ? Qt.size(588, 150) : Qt.size(460, 122)
  readonly property bool wantsCallout: false
  readonly property string kind: "layout"

  readonly property int litCount: litOf(100)
  readonly property bool message: noteKind === "hint" || noteKind === "cant"
  property alias tiles: tileRepeater
  readonly property Item selection: stateDrawn === "ring" ? tileAt(Math.round(((p % n) + n) % n) % n) : cardTitle
  function tileAt(i) { return tileRepeater.count > i ? tileRepeater.itemAt(i) : null }

  // The row's position in tool units. Live: the hand's position. Stepped: the short way round, eased.
  property real steppedP: 0
  Behavior on steppedP {
    id: stepEase
    NumberAnimation { duration: look.cfg.motionBase * 0.75; easing.type: Easing.BezierSpline; easing.bezierCurve: look.easeOut }
  }
  readonly property real p: live ? position : steppedP
  property int _lastIndex: 0
  onIndexChanged: {
    var d = (index - _lastIndex) % n
    if (d > n / 2) d -= n
    if (d < -n / 2) d += n
    steppedP += d
    _lastIndex = index
  }
  onLiveChanged: if (!live) { stepEase.enabled = false; steppedP = position; stepEase.enabled = true }

  // A tile is base wide, plus grow shared between the tiles either side of p. Past eight tools
  // the base shrinks so the row still fits the tray.
  readonly property real grow: u(48)
  readonly property real gap: u(8)
  readonly property real base: Math.min(u(56), (width - u(36) - grow - (n - 1) * gap) / n)

  Rectangle { anchors.fill: parent; radius: look.u(36); color: look.tone.ground }

  // The ring: the row, and the label line.
  Row {
    visible: look.stateDrawn === "ring"
    anchors.horizontalCenter: parent.horizontalCenter
    y: look.u(14)
    spacing: look.gap
    Repeater {
      id: tileRepeater
      model: look.stateDrawn === "ring" ? look.tools.length : 0
      delegate: Rectangle {
        id: tile
        required property int index
        readonly property int tileIndex: tile.index
        readonly property real t: {
          var p = ((look.p % look.n) + look.n) % look.n, d = Math.abs(tile.index - p)
          return Math.max(0, 1 - Math.min(d, look.n - d))
        }
        width: look.base + look.grow * t; height: look.u(96); radius: look.u(18)
        color: t > 0.5 ? look.tone.accent : look.tone.surface
        Text {
          anchors.centerIn: parent
          visible: look.cfg.showGlyphs
          scale: 1 + 0.3 * tile.t
          text: look.toolIcon(tile.index); textFormat: Text.PlainText
          font.family: look.fontFamily; font.pixelSize: look.u(22)
          color: tile.t > 0.5 ? look.tone.onaccent : look.tone.soft
        }
      }
    }
  }
  Row {
    visible: look.stateDrawn === "ring"
    readonly property int shown: Math.round(((look.p % look.n) + look.n) % look.n) % look.n
    anchors.horizontalCenter: parent.horizontalCenter
    y: look.u(118)
    spacing: look.u(8)
    Text {
      id: label
      anchors.baseline: parent.children[1].baseline
      width: Math.min(implicitWidth, look.width - look.u(220)); elide: Text.ElideRight
      text: look.toolName(parent.shown); textFormat: Text.PlainText
      font.family: look.face; font.pixelSize: look.u(22); font.weight: Font.Bold
      color: look.tone.ink
    }
    Text {
      width: Math.min(implicitWidth, look.u(180)); elide: Text.ElideRight
      text: look.pressText(parent.shown); textFormat: Text.PlainText
      font.family: look.face; font.pixelSize: look.u(15)
      color: look.tone.soft
    }
  }

  // A state: the compact card.
  Row {
    visible: look.stateDrawn !== "ring"
    x: look.u(18); anchors.verticalCenter: parent.verticalCenter
    width: parent.width - look.u(36)
    spacing: look.u(16)
    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      width: look.u(look.message ? 72 : 96); height: width; radius: look.u(18)
      color: look.message ? look.tone.surface : look.tone.accent
      Text {
        anchors.centerIn: parent
        visible: !look.message && look.cfg.showGlyphs
        text: look.toolIcon(look.chosen); textFormat: Text.PlainText
        font.family: look.fontFamily; font.pixelSize: look.u(30)
        color: look.tone.onaccent
      }
      Canvas {
        id: sign
        anchors.centerIn: parent
        visible: look.message
        width: look.u(36); height: width
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
      width: parent.width - look.u(look.message ? 88 : 112)
      Item {
        width: parent.width; height: look.levelShown ? value.height : cardTitle.height
        Text {
          id: cardTitle
          width: parent.width - (look.levelShown ? value.width + look.u(8) : 0)
          y: look.levelShown ? value.baselineOffset - baselineOffset : 0
          wrapMode: look.message ? Text.Wrap : Text.NoWrap; maximumLineCount: 2; elide: Text.ElideRight
          text: look.noteKind === "hint" ? String(look.note.prompt || "")
              : look.noteKind === "cant" ? String(look.note.title || "")
              : String(look.note.name || "")
          textFormat: Text.PlainText
          font.family: look.face; font.pixelSize: look.u(look.message ? 22 : 24); font.weight: Font.Bold
          color: look.tone.ink
        }
        Text {
          id: value
          anchors.right: parent.right
          visible: look.levelShown
          text: look.valueText; textFormat: Text.PlainText
          font.family: look.face; font.pixelSize: look.u(44); font.weight: Font.Bold
          color: look.tone.ink
        }
      }
      Rectangle {
        visible: look.levelShown
        width: parent.width; height: look.u(8); radius: height / 2
        color: look.tone.track
        Rectangle {
          height: parent.height; radius: parent.radius
          width: parent.width * look.litCount / 100
          color: look.tone.accent
          Behavior on width { NumberAnimation { duration: look.cfg.motionFast } }
        }
      }
      Text {
        width: parent.width; elide: Text.ElideRight
        topPadding: look.u(look.message ? 3 : 6)
        visible: text !== ""
        text: look.noteKind === "hint" ? (look.note.steps > 1 ? "Step " + look.note.step + " of " + look.note.steps : "")
            : look.noteKind === "cant" ? String(look.note.line || "")
            : look.pressText(look.chosen)
        textFormat: Text.PlainText
        font.family: look.face; font.pixelSize: look.u(look.message ? 15 : 14)
        color: look.tone.soft
      }
    }
  }

  onNoteKindChanged: sign.requestPaint()
  onNoteChanged: sign.requestPaint()
  onToneChanged: sign.requestPaint()
}
