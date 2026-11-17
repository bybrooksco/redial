pragma ComponentBehavior: Bound

import QtQuick
import "Drafting.js" as Drafting

// re:dial classic: the Carousel layout, a slide rule. The tools sit along a ruled bar and a cursor
// rides to the chosen one; a level turns the rule into a 0-100 scale and the cursor reads it.
// A hint parks the cursor and clouds the annotation; can't act hatches the bar and drops the
// cursor. Mockup: DCAR in draft.js.
LookBase {
  id: face

  readonly property size plateSize: Qt.size(640, 168)
  readonly property bool wantsCallout: false
  readonly property string kind: "layout"

  readonly property int litCount: litOf(100)
  readonly property Item selection: cursor

  readonly property real x0: u(52)
  // 76 units between tools, closer when more than eight would run off the plate.
  readonly property real pitch: n > 1 ? Math.min(u(76), (width - 2 * x0) / (n - 1)) : u(76)
  // The rule is never shorter than eight tools' worth, so with one or two tools the level's figures,
  // the name row and the sheet number still have room.
  readonly property real ruleEnd: x0 + Math.max(pitch * (n - 1), u(76) * 7)
  readonly property real ruleTop: u(34)
  readonly property real ruleBot: u(98)
  readonly property real mid: (ruleTop + ruleBot) / 2

  // Where the cursor sits, in tool units. Live: the hand's position. Stepped: eased, except across
  // the wrap, where it lands at once rather than sliding back along the whole rule.
  readonly property real wrapped: ((position % n) + n) % n
  property real steppedP: 0
  Behavior on steppedP {
    id: stepEase
    NumberAnimation { duration: face.cfg.motionBase; easing.type: Easing.BezierSpline; easing.bezierCurve: face.easeInOut }
  }
  onIndexChanged: {
    stepEase.enabled = Math.abs(index - steppedP) <= 2
    steppedP = index
    stepEase.enabled = true
  }
  onLiveChanged: if (!live) { stepEase.enabled = false; steppedP = index; stepEase.enabled = true }
  readonly property real cursorX: levelShown ? x0 + level / 100 * (ruleEnd - x0)
                                 : noteKind === "hint" ? x0
                                 : x0 + Math.min(n - 1, live ? wrapped : steppedP) * pitch

  Canvas {
    id: back
    anchors.fill: parent
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d"), L = String(face.line), A = String(face.accent)
      ctx.reset(); ctx.__w = face.lineScale
      ctx.fillStyle = face.plateFill; ctx.fillRect(0, 0, width, height)
      var x0 = face.x0, end = face.ruleEnd, top = face.ruleTop, bot = face.ruleBot, bx = x0 - face.u(30), bw = end - x0 + face.u(60)
      if (face.cfg.constructionLines) {
        Drafting.regMarks(ctx, width, height, face.u(10), face.u(14), L)
        Drafting.line(ctx, 0, face.mid, width, face.mid, L, 0.1, 1)
        Drafting.node(ctx, width - face.u(10), face.mid, face.u(3), L, 0.35); Drafting.node(ctx, face.u(10), face.mid, face.u(3), L, 0.35)
      }
      if (face.noteKind === "cant") Drafting.hatch(ctx, function (c) { c.rect(bx, top, bw, bot - top) }, width, height, L, 0.22, face.u(7))
      ctx.strokeStyle = Drafting.ink(L, 0.45); ctx.lineWidth = (1) * face.lineScale; ctx.strokeRect(bx, top, bw, bot - top)
      var ticks = face.levelShown ? 100 : Math.max(1, (face.n - 1) * 8), every = face.levelShown ? 10 : 8
      for (var i = 0; i <= ticks; i++) {
        var x = x0 + i * (end - x0) / ticks, maj = i % every === 0
        if (face.n === 1 && !face.levelShown && i > 0) break
        Drafting.line(ctx, x, top, x, top + face.u(maj ? 14 : 6), L, maj ? 0.55 : 0.25, 1)
      }
      if (face.noteKind === "hint") Drafting.cloudRect(ctx, bx, bot + face.u(18), bw, face.u(40), face.u(16), A)
    }
  }

  // The level's 0-100 figures above the rule.
  Repeater {
    model: face.levelShown ? 11 : 0
    delegate: Text {
      required property int index
      x: face.x0 + index * (face.ruleEnd - face.x0) / 10 - width / 2
      y: face.ruleTop - face.u(8) - height
      text: String(index * 10)
      textFormat: Text.PlainText
      font.family: face.fontFamily; font.pixelSize: face.u(11); font.letterSpacing: face.u(1.1)
      color: face.ink(0.6)
    }
  }

  // The tools along the rule.
  Repeater {
    model: face.levelShown ? 0 : face.tools.length
    delegate: Text {
      id: glyph
      required property int index
      readonly property bool on: glyph.index === face.index && face.noteKind === ""
      x: face.x0 + glyph.index * face.pitch - width / 2
      y: face.mid + face.u(6) - height / 2
      visible: face.cfg.showGlyphs
      text: face.toolIcon(glyph.index)
      textFormat: Text.PlainText
      font.family: face.fontFamily; font.pixelSize: face.u(18)
      color: on ? face.accent : face.ink(0.5)
      opacity: face.noteKind === "cant" ? 0.35 : 1
      scale: on ? 1.35 : 1
      Behavior on scale { NumberAnimation { duration: face.cfg.motionBase * 0.75; easing.type: Easing.BezierSpline; easing.bezierCurve: face.easeOut } }
    }
  }

  // The cursor: a tinted window with a hairline and a node below the rule. Its x is its hairline.
  Item {
    id: cursor
    visible: face.noteKind !== "cant" && face.tools.length > 0
    x: face.cursorX
    y: face.ruleTop - face.u(12)
    Rectangle {
      x: -face.u(30); width: face.u(60); height: face.ruleBot - face.ruleTop + face.u(24)
      color: face.accentInk(0.07)
      border.width: 1; border.color: face.accentInk(0.7)
    }
    Rectangle { x: -0.5; width: 1; height: face.ruleBot - face.ruleTop + face.u(24); color: face.accent }
    Rectangle {
      x: -width / 2; y: face.ruleBot - face.ruleTop + face.u(24) - height / 2
      width: face.u(5); height: width; radius: width / 2; color: face.accent
    }
  }

  // The annotation row under the rule.
  Row {
    x: face.x0 - face.u(18)
    y: face.ruleBot + face.u(24) + (face.u(28) - height) / 2
    width: face.ruleEnd + face.u(18) - x
    spacing: face.u(14)
    Canvas {
      id: sign
      visible: face.noteKind === "hint" || face.noteKind === "cant"
      anchors.verticalCenter: parent.verticalCenter
      width: face.u(22); height: width
      renderStrategy: Canvas.Cooperative
      onPaint: {
        var ctx = getContext("2d")
        ctx.reset(); ctx.__w = face.lineScale
        Drafting.sign(ctx, face.noteKind, face.note, width, String(face.accent), String(face.alert))
      }
    }
    Text {
      id: nameText
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(implicitWidth, face.u(260)); elide: Text.ElideRight
      text: face.noteKind === "hint" ? String(face.note.prompt || "")
          : face.noteKind === "cant" ? String(face.note.title || "")
          : face.levelShown ? String(face.note.name || "")
          : face.toolName(face.index)
      textFormat: Text.PlainText
      font.family: face.fontFamily; font.bold: true
      font.pixelSize: face.noteKind === "hint" || face.noteKind === "cant" ? face.u(14) : face.u(16)
      color: face.noteKind === "cant" ? face.alert : face.stateDrawn === "ring" ? face.accent : face.line
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: face.levelShown
      text: face.valueText
      textFormat: Text.PlainText
      font.family: face.fontFamily; font.pixelSize: face.u(22)
      color: face.accent
    }
    Row {
      anchors.verticalCenter: parent.verticalCenter
      visible: face.noteKind === "" || face.noteKind === "turn"
      spacing: face.u(6)
      Text {
        anchors.baseline: hintText.baseline
        text: "CLICK"; textFormat: Text.PlainText
        font.family: face.fontFamily; font.pixelSize: face.u(11); font.letterSpacing: face.u(1.3)
        color: face.ink(face.inkKey)
      }
      Text {
        id: hintText
        text: face.toolHint(face.index) !== "" ? face.toolHint(face.index) : "nothing set"
        textFormat: Text.PlainText
        font.family: face.fontFamily; font.pixelSize: face.u(12)
        color: face.ink(face.toolHint(face.index) !== "" ? 1 : 0.55)
      }
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: text !== ""
      text: face.noteKind === "cant" ? String(face.note.line || "")
          : face.noteKind === "hint" && face.note.steps > 1 ? "Step " + face.note.step + " of " + face.note.steps : ""
      textFormat: Text.PlainText
      font.family: face.fontFamily; font.pixelSize: face.u(12)
      color: face.ink(0.7)
    }
  }
  Text {
    visible: face.stateDrawn === "ring"
    x: face.ruleEnd + face.u(18) - width
    y: face.ruleBot + face.u(24) + (face.u(28) - height) / 2
    text: "SHEET " + (Math.min(face.index, face.n - 1) + 1) + "/" + face.n
    textFormat: Text.PlainText
    font.family: face.fontFamily; font.pixelSize: face.u(11); font.letterSpacing: face.u(1.3)
    color: face.ink(0.7)
  }

  function repaint() { back.requestPaint(); sign.requestPaint() }
  onWidthChanged: repaint()
  onHeightChanged: repaint()
  onNoteKindChanged: repaint()
  onNoteChanged: repaint()
  onNChanged: repaint()
  onLineChanged: repaint()
  onAccentChanged: repaint()
  Connections { target: face.cfg; function onChanged() { face.repaint() } }
}
