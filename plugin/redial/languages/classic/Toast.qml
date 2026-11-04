pragma ComponentBehavior: Bound

import QtQuick
import "Drafting.js" as Drafting

// re:dial classic: the Toast layout, a drawing's title block. Three cells: the tool's glyph, its
// name and click action, and the sheet number (or the level, or the note's stamp). A hint clouds
// the glyph cell; can't act hatches it. Mockup: DTOAST in draft.js.
LookBase {
  id: face

  readonly property size plateSize: Qt.size(400, 60)
  readonly property bool wantsCallout: false
  readonly property string kind: "layout"

  readonly property int litCount: litOf(24)
  readonly property Item selection: nameText
  readonly property string sheetText: noteKind === "hint" ? "NOTE " + (note.step || 1)
                                    : noteKind === "cant" ? String(note.reason || "can't act").toUpperCase()
                                    : levelShown ? valueText
                                    : "SHEET " + (Math.min(index, n - 1) + 1) + "/" + n

  readonly property real cell: u(60)
  readonly property real sheetX: width - u(96)

  Canvas {
    id: back
    anchors.fill: parent
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d"), L = String(face.line), A = String(face.accent)
      ctx.reset()
      ctx.fillStyle = String(face.ground); ctx.fillRect(0, 0, width, height)
      if (face.cfg.constructionLines) Drafting.regMarks(ctx, width, height, face.u(4), face.u(8), L)
      if (face.noteKind === "cant")
        Drafting.hatch(ctx, function (c) { c.rect(0, 0, face.cell, height) }, width, height, L, 0.22, face.u(7))
      Drafting.line(ctx, face.cell, 0, face.cell, height, L, 0.4, 1)
      Drafting.line(ctx, face.sheetX, 0, face.sheetX, height, L, 0.4, 1)
      if (face.levelShown) {
        for (var i = 0; i < 24; i++) {
          var x = face.u(66 + i * 9)
          if (i < face.litCount) Drafting.line(ctx, x, face.u(50), x, face.u(42), A, 0.95, 1.5)
          else Drafting.line(ctx, x, face.u(50), x, face.u(i % 6 ? 46 : 43), L, 0.3, 1)
        }
      }
      if (face.noteKind === "hint") Drafting.cloudRect(ctx, face.u(4), face.u(6), face.u(52), height - face.u(12), face.u(12), A)
    }
  }

  // The glyph cell: the tool's icon, or the state's sign.
  Text {
    x: (face.cell - width) / 2; y: (face.height - height) / 2
    visible: face.noteKind === "" || face.noteKind === "turn"
    text: face.toolIcon(face.index)
    textFormat: Text.PlainText
    font.family: face.fontFamily; font.pixelSize: face.u(22)
    color: face.accent
  }
  Canvas {
    id: sign
    visible: face.noteKind === "hint" || face.noteKind === "cant"
    width: face.u(26); height: width
    x: (face.cell - width) / 2; y: (face.height - height) / 2
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      if (face.noteKind === "cant") {   // the sign stands on ground, clear of the hatching
        ctx.fillStyle = String(face.ground); ctx.beginPath(); ctx.arc(width / 2, height / 2, width / 2, 0, Math.PI * 2); ctx.fill()
      }
      Drafting.sign(ctx, face.noteKind, face.note, width, String(face.accent), String(face.alert))
    }
  }

  // The name cell.
  Column {
    x: face.u(74); width: face.sheetX - face.u(10) - x
    y: face.levelShown ? face.u(8) : face.u(12)
    spacing: face.u(1)
    Text {
      id: nameText
      width: parent.width; elide: Text.ElideRight
      text: face.noteKind === "hint" ? String(face.note.prompt || "")
          : face.noteKind === "cant" ? String(face.note.title || "")
          : face.levelShown ? String(face.note.name || face.toolName(face.index))
          : face.toolName(face.index)
      textFormat: Text.PlainText
      font.family: face.fontFamily; font.bold: true
      font.pixelSize: face.noteKind === "hint" || face.noteKind === "cant" ? face.u(14) : face.u(15)
      color: face.noteKind === "cant" ? face.alert : face.line
    }
    Row {
      visible: face.noteKind === "" || face.noteKind === "turn" && !face.levelShown
      spacing: face.u(6)
      Text {
        text: "CLICK"; textFormat: Text.PlainText
        font.family: face.fontFamily; font.pixelSize: face.u(11); font.letterSpacing: face.u(1.3)
        color: face.ink(face.inkKey)
      }
      Text {
        text: face.toolHint(face.index) !== "" ? face.toolHint(face.index) : "nothing set"
        textFormat: Text.PlainText
        font.family: face.fontFamily; font.pixelSize: face.u(12)
        color: face.ink(face.toolHint(face.index) !== "" ? 1 : 0.55)
      }
    }
    Text {
      width: parent.width; elide: Text.ElideRight
      visible: face.noteKind === "hint" || face.noteKind === "cant"
      text: face.noteKind === "cant" ? String(face.note.line || "")
          : face.note.steps > 1 ? "Step " + face.note.step + " of " + face.note.steps : ""
      textFormat: Text.PlainText
      font.family: face.fontFamily; font.pixelSize: face.u(12)
      color: face.ink(0.7)
    }
  }

  // The sheet cell.
  Text {
    x: face.sheetX + (face.u(96) - width) / 2; y: (face.height - height) / 2
    width: Math.min(implicitWidth, face.u(90)); elide: Text.ElideRight
    text: face.sheetText
    textFormat: Text.PlainText
    font.family: face.fontFamily
    font.pixelSize: face.levelShown ? face.u(20) : face.u(11)
    font.letterSpacing: face.levelShown ? 0 : face.u(1.3)
    color: face.levelShown ? face.accent : face.ink(0.7)
  }

  function repaint() { back.requestPaint(); sign.requestPaint() }
  onWidthChanged: repaint()
  onHeightChanged: repaint()
  onNoteKindChanged: repaint()
  onNoteChanged: repaint()
  onLineChanged: repaint()
  onAccentChanged: repaint()
  Connections { target: face.cfg; function onChanged() { face.repaint() } }
}
