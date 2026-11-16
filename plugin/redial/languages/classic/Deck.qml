pragma ComponentBehavior: Bound

import QtQuick
import "Drafting.js" as Drafting

// re:dial classic: the Deck layout, a fan of drawing sheets. Each tool is a sheet with a border,
// a title block and registration marks; the chosen tool's sheet is in front and the rest fan out
// behind it, their text fading with distance. A state shows one sheet in front of four blank ones.
// Mockup: DDECK in draft.js.
LookBase {
  id: face

  readonly property size plateSize: Qt.size(544, 262)
  readonly property bool wantsCallout: false
  readonly property string kind: "layout"

  readonly property int litCount: litOf(26)
  property alias cards: cardRepeater
  readonly property Item selection: stateDrawn === "ring" ? cardAt(Math.round(((p % n) + n) % n) % n) : frontSheet
  function cardAt(i) { return cardRepeater.count > i ? cardRepeater.itemAt(i) : null }

  // The fan's position in tool units. Live: the hand's position. Stepped: the short way round, eased.
  property real steppedP: 0
  Behavior on steppedP {
    id: stepEase
    NumberAnimation { duration: face.cfg.motionBase; easing.type: Easing.BezierSpline; easing.bezierCurve: face.easeInOut }
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

  readonly property real sheetX: u(186)
  readonly property real sheetY: u(20)
  readonly property real sheetW: u(172)
  readonly property real sheetH: u(224)

  // A sheet: ground, border, title block, registration marks. `ink` sets how strongly it is drawn.
  component Sheet: Item {
    id: sheet
    property real ink: 0.35
    property real d: 0
    property real dy: 0
    property real turn: 3.5
    property real shrink: 0.04
    property real spread: 30
    x: face.sheetX; y: face.sheetY
    width: face.sheetW; height: face.sheetH
    transform: [
      Scale { origin.x: sheet.width / 2; origin.y: sheet.height * 1.2; xScale: 1 - Math.min(Math.abs(sheet.d), 3) * sheet.shrink; yScale: xScale },
      Rotation { origin.x: sheet.width / 2; origin.y: sheet.height * 1.2; angle: sheet.d * sheet.turn },
      Translate { x: sheet.d * sheet.spread; y: sheet.dy }
    ]
    Rectangle { anchors.fill: parent; color: face.plateFill }
    Canvas {
      id: art
      anchors.fill: parent
      renderStrategy: Canvas.Cooperative
      onPaint: {
        var ctx = getContext("2d"), L = String(face.line), k = face.unit
        ctx.reset(); ctx.__w = face.lineScale
        ctx.strokeStyle = Drafting.ink(L, sheet.ink); ctx.lineWidth = (1) * face.lineScale
        ctx.strokeRect(7 * k, 7 * k, 158 * k, 210 * k)
        if (sheet.ink > 0.3) {
          ctx.strokeRect(7 * k, 185 * k, 158 * k, 32 * k)
          Drafting.line(ctx, 110 * k, 185 * k, 110 * k, 217 * k, L, sheet.ink, 1)
          Drafting.regMarks(ctx, width, height, 3 * k, 8 * k, L)
        }
      }
      Connections { target: face; function onLineChanged() { art.requestPaint() } function onUnitChanged() { art.requestPaint() } }
    }
  }

  // The ring: one sheet per tool.
  Repeater {
    id: cardRepeater
    model: face.stateDrawn === "ring" ? face.tools.length : 0
    delegate: Sheet {
      id: card
      required property int index
      readonly property int cardIndex: card.index
      readonly property real ad: Math.abs(d)
      d: { var x = card.index - face.p; return ((x % face.n) + face.n + face.n / 2) % face.n - face.n / 2 }
      dy: ad * face.u(12)
      turn: 6; shrink: 0.07; spread: face.u(92)
      opacity: ad > 2.6 ? 0 : 1
      z: 100 - Math.round(ad * 10)
      Item {
        id: body
        anchors.fill: parent
        opacity: Math.max(0, 1 - card.ad * 1.6)
        Column {
          x: face.u(7); y: face.u(7); width: face.u(158); height: face.u(178)
          topPadding: (height - implicitHeight) / 2
          spacing: face.u(4)
          Item {
            anchors.horizontalCenter: parent.horizontalCenter
            width: face.u(64); height: width
            Canvas {
              id: mark
              anchors.fill: parent
              renderStrategy: Canvas.Cooperative
              onPaint: {
                var ctx = getContext("2d"), L = String(face.line), c = width / 2
                ctx.reset(); ctx.__w = face.lineScale
                Drafting.ring(ctx, c, c, face.u(26), L, 0.4, 1)
                Drafting.line(ctx, 0, c, width, c, L, 0.25, 1); Drafting.line(ctx, c, 0, c, height, L, 0.25, 1)
              }
            }
            Text {
              anchors.centerIn: parent
              visible: face.cfg.showGlyphs
              text: face.toolIcon(card.index)
              textFormat: Text.PlainText
              font.family: face.fontFamily; font.pixelSize: face.u(22)
              color: card.ad < 0.5 ? face.accent : face.line
            }
          }
          Text {
            width: parent.width; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
            topPadding: face.u(4)
            text: face.toolName(card.index)
            textFormat: Text.PlainText
            font.family: face.fontFamily; font.pixelSize: face.u(16); font.bold: true
            color: face.line
          }
          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: face.u(5)
            Text {
              text: "CLICK"; textFormat: Text.PlainText
              font.family: face.fontFamily; font.pixelSize: face.u(11); font.letterSpacing: face.u(1.3)
              color: face.ink(face.inkKey)
            }
            Text {
              width: Math.min(implicitWidth, face.u(110)); elide: Text.ElideRight
              text: face.toolHint(card.index) !== "" ? face.toolHint(card.index) : "nothing set"
              textFormat: Text.PlainText
              font.family: face.fontFamily; font.pixelSize: face.u(11)
              color: face.ink(face.toolHint(card.index) !== "" ? 1 : 0.55)
            }
          }
        }
        Text {
          x: face.u(14); y: face.u(224 - 15) - height
          text: "RE:DIAL"; textFormat: Text.PlainText
          font.family: face.fontFamily; font.pixelSize: face.u(9.5); font.letterSpacing: face.u(1.1)
          color: face.ink(0.7)
        }
        Text {
          x: face.u(172 - 12) - width; y: face.u(224 - 15) - height
          text: (card.index + 1) + "/" + face.n; textFormat: Text.PlainText
          font.family: face.fontFamily; font.pixelSize: face.u(9.5); font.letterSpacing: face.u(1.1)
          color: face.ink(0.7)
        }
      }
    }
  }

  // A state: four blank sheets behind one that carries it.
  Repeater {
    model: face.stateDrawn === "ring" ? [] : [-2, -1, 1, 2]
    delegate: Sheet {
      required property int modelData
      d: modelData
      ink: 0.25
      spread: face.u(30)
      opacity: face.noteKind === "cant" ? 0.5 : 1
    }
  }
  Sheet {
    id: frontSheet
    visible: face.stateDrawn !== "ring"
    z: 200
    Canvas {
      id: stateArt
      anchors.fill: parent   // the whole sheet, so a cloud's scallops have room to bulge
      renderStrategy: Canvas.Cooperative
      onPaint: {
        var ctx = getContext("2d"), L = String(face.line), A = String(face.accent), m = face.u(7)
        var w = face.u(158), h = face.u(178)
        ctx.reset(); ctx.__w = face.lineScale
        if (face.noteKind === "cant") Drafting.hatch(ctx, function (c) { c.rect(m, m, w, h) }, width, height, L, 0.22, face.u(7))
        if (face.noteKind === "hint") Drafting.cloudRect(ctx, m + face.u(6), m + face.u(6), w - face.u(12), h - face.u(12), face.u(18), A)
        if (face.levelShown) {
          var x0 = m + (w - face.u(130)) / 2, y = m + h / 2 + face.u(30)
          for (var i = 0; i < 26; i++) {
            var x = x0 + face.u(2 + i * 5)
            if (i < face.litCount) Drafting.line(ctx, x, y + face.u(14), x, y + face.u(4), A, 0.95, 1.5)
            else Drafting.line(ctx, x, y + face.u(14), x, y + face.u(i % 5 ? 9 : 5), L, 0.35, 1)
          }
        }
      }
    }
    Column {
      x: face.u(7); y: face.u(7); width: face.u(158); height: face.u(178)
      topPadding: (height - implicitHeight) / 2 - (face.levelShown ? face.u(10) : 0)
      spacing: face.u(4)
      Canvas {
        id: sign
        anchors.horizontalCenter: parent.horizontalCenter
        visible: face.noteKind === "hint" || face.noteKind === "cant"
        width: face.u(30); height: width
        renderStrategy: Canvas.Cooperative
        onPaint: {
          var ctx = getContext("2d")
          ctx.reset(); ctx.__w = face.lineScale
          if (face.noteKind === "cant") { ctx.fillStyle = String(face.ground); ctx.beginPath(); ctx.arc(width / 2, height / 2, width / 2, 0, Math.PI * 2); ctx.fill() }
          Drafting.sign(ctx, face.noteKind, face.note, width, String(face.accent), String(face.alert))
        }
      }
      Text {
        width: parent.width; horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap; elide: Text.ElideRight; maximumLineCount: 3
        leftPadding: face.u(10); rightPadding: face.u(10)
        text: face.noteKind === "hint" ? String(face.note.prompt || "")
            : face.noteKind === "cant" ? String(face.note.title || "")
            : String(face.note.name || "").toUpperCase()
        textFormat: Text.PlainText
        font.family: face.fontFamily; font.bold: true
        font.pixelSize: face.levelShown ? face.u(11) : face.u(14)
        font.letterSpacing: face.levelShown ? face.u(1.3) : 0
        color: face.line
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: face.levelShown
        text: face.valueText
        textFormat: Text.PlainText
        font.family: face.fontFamily; font.pixelSize: face.u(44)
        color: face.accent
      }
      Item { visible: face.levelShown; width: 1; height: face.u(18) }
      Text {
        width: parent.width; horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap; elide: Text.ElideRight; maximumLineCount: 2
        leftPadding: face.u(10); rightPadding: face.u(10)
        visible: text !== ""
        readonly property string clickHint: face.toolHint(face.index)
        text: face.levelShown ? (clickHint !== "" ? "click " + clickHint : "")
            : face.noteKind === "cant" ? String(face.note.line || "")
            : face.note.steps > 1 ? "Step " + face.note.step + " of " + face.note.steps : ""
        textFormat: Text.PlainText
        font.family: face.fontFamily; font.pixelSize: face.u(11)
        color: face.ink(0.7)
      }
    }
  }

  function repaint() { stateArt.requestPaint(); sign.requestPaint() }
  onNoteKindChanged: repaint()
  onNoteChanged: repaint()
  onLitCountChanged: repaint()
  onAccentChanged: repaint()
  onLineChanged: repaint()
  Connections { target: face.cfg; function onChanged() { face.repaint() } }
}
