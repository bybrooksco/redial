pragma ComponentBehavior: Bound

import QtQuick
import "Drafting.js" as Drafting

// re:dial classic: the Gauge look. A 270° graduated scale; the lit region follows the needle; a
// ruled readout box with a leader up to the hub. The needle springs between tools, lands at once
// when the choice wraps from the last tool to the first (it never sweeps back across the scale),
// and rests at zero, readout hatched, when the dial can't act. Mockup: DGAU in draft.js.
LookBase {
  id: face

  readonly property size plateSize: Qt.size(400, 376)
  readonly property bool wantsCallout: false
  readonly property string kind: "face"

  readonly property real cx: width / 2
  readonly property real cy: u(180)
  readonly property real a0: 135
  readonly property real span: 270
  function ang(i) { return a0 + i * span / Math.max(1, n - 1) }
  readonly property int litCount: litOf(135)

  // Where the needle is headed: the chosen tool (live: the hand's position), the level, or zero.
  readonly property real wrapped: ((position % n) + n) % n
  readonly property real target: levelShown ? a0 + level * 2.7
                                : noteKind !== "" ? a0
                                : Math.min(a0 + span, live ? ang(wrapped) : ang(index))
  // The hand drives the needle directly while live; otherwise a spring (k 600, d 28) carries it,
  // except with motion off or across more than 200° (the wrap), where it lands at once.
  readonly property bool springs: !live && cfg.motionBase > 0
  property real needleDeg: a0
  property real _v: 0
  onTargetChanged: settle()
  onSpringsChanged: settle()
  function settle() {
    if (!springs || Math.abs(target - needleDeg) > 200) { needleDeg = target; _v = 0 }
  }
  Component.onCompleted: { needleDeg = target }
  FrameAnimation {
    running: face.springs && (Math.abs(face.target - face.needleDeg) > 0.01 || Math.abs(face._v) > 0.01)
    onTriggered: {
      var steps = Math.max(1, Math.ceil(frameTime * 1000 / 4)), s = frameTime / steps
      var x = face.needleDeg, v = face._v
      for (var j = 0; j < steps; j++) { v += (600 * (face.target - x) - 28 * v) * s; x += v * s }
      if (Math.abs(face.target - x) < 0.01 && Math.abs(v) < 0.01) { x = face.target; v = 0 }
      face._v = v; face.needleDeg = x
    }
  }

  readonly property Item selection: needle

  // Plate, construction, arc, scale, readout box.
  readonly property real bx: cx - u(92)
  readonly property real by: cy + u(98)
  readonly property real bw: u(184)
  readonly property real bh: u(66)
  Canvas {
    id: back
    anchors.fill: parent
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d"), L = String(face.line), A = String(face.accent)
      ctx.reset()
      ctx.fillStyle = String(face.ground); ctx.fillRect(0, 0, width, height)
      var cx = face.cx, cy = face.cy
      if (face.cfg.constructionLines) {
        Drafting.regMarks(ctx, width, height, face.u(10), face.u(14), L)
        Drafting.line(ctx, 0, cy, width, cy, L, 0.13, 1); Drafting.line(ctx, cx, 0, cx, height, L, 0.13, 1)
        Drafting.node(ctx, width - face.u(10), cy, face.u(3), L, 0.35); Drafting.node(ctx, cx, face.u(10), face.u(2.5), L, 0.3)
      }
      ctx.beginPath(); ctx.strokeStyle = Drafting.ink(L, 0.3); ctx.lineWidth = 1
      ctx.arc(cx, cy, face.u(142), face.a0 * Math.PI / 180, (face.a0 + face.span) * Math.PI / 180); ctx.stroke()
      Drafting.ring(ctx, cx, cy, face.u(10), L, 0.5, 1)
      Drafting.scaleBars(ctx, cx, cy, face.a0, face.a0 + face.span, 135, face.u(112), face.u(119), face.u(126), 15, L)
      if (face.levelShown)
        Drafting.litBars(ctx, cx, cy, face.a0, face.a0 + face.span, 135, face.u(112), face.u(133), face.litCount, A, 1.5)
      // The readout box: a revision cloud on a hint, hatched when the dial can't act.
      if (face.noteKind === "hint") Drafting.cloudRect(ctx, face.bx, face.by, face.bw, face.bh, face.u(16), A)
      else {
        if (face.noteKind === "cant")
          Drafting.hatch(ctx, function (c) { c.rect(face.bx, face.by, face.bw, face.bh) }, width, height, L, 0.14, face.u(7))
        ctx.strokeStyle = Drafting.ink(L, 0.45); ctx.lineWidth = 1; ctx.strokeRect(face.bx, face.by, face.bw, face.bh)
      }
      Drafting.line(ctx, cx, face.by - face.u(12), cx, face.by, L, 0.3, 1)
      Drafting.node(ctx, cx, face.by - face.u(12), face.u(2), L, 0.5)
    }
  }

  // In the ring the lit region is the stretch of scale under the needle; it travels with it.
  Canvas {
    id: under
    anchors.fill: parent
    visible: face.stateDrawn === "ring"
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d"), A = String(face.accent)
      ctx.reset()
      var per = face.span / 135, half = face.span / Math.max(1, face.n - 1) / 2 * 0.86
      for (var b = 0; b < 135; b++) {
        var a = face.a0 + b * per
        if (Math.abs(a - face.needleDeg) > half) continue
        var p = Drafting.polar(face.cx, face.cy, face.u(112), a), q = Drafting.polar(face.cx, face.cy, face.u(133), a)
        Drafting.line(ctx, p[0], p[1], q[0], q[1], A, 0.95, 1.5)
      }
    }
  }

  // The tools' glyphs inside the scale; the chosen one grows in the accent.
  Repeater {
    model: face.levelShown ? 0 : face.tools.length
    delegate: Text {
      id: glyph
      required property int index
      readonly property bool on: glyph.index === face.index && face.noteKind === ""
      readonly property var at: Drafting.polar(face.cx, face.cy, face.u(92), face.ang(glyph.index))
      x: at[0] - width / 2; y: at[1] - height / 2
      visible: face.cfg.showGlyphs
      text: face.toolIcon(glyph.index)
      textFormat: Text.PlainText
      font.family: face.fontFamily; font.pixelSize: face.u(16)
      color: on ? face.accent : face.ink(0.45)
      opacity: face.noteKind === "cant" ? 0.35 : 1
      scale: on ? 1.4 : 1
      Behavior on scale { NumberAnimation { duration: face.cfg.motionBase * 0.75; easing.type: Easing.BezierSpline; easing.bezierCurve: face.easeOut } }
    }
  }

  // The level's 0 / 50 / 100 marks.
  Repeater {
    model: face.levelShown ? [0, 50, 100] : []
    delegate: Text {
      id: mark
      required property int modelData
      readonly property var at: Drafting.polar(face.cx, face.cy, face.u(150), face.a0 + mark.modelData * 2.7)
      x: mark.modelData === 50 ? at[0] - width / 2 : mark.modelData ? at[0] : at[0] - width
      y: at[1] - height / 2
      text: String(mark.modelData)
      textFormat: Text.PlainText
      font.family: face.fontFamily; font.pixelSize: face.u(11); font.letterSpacing: face.u(1.3)
      color: face.ink(0.6)
    }
  }

  // The needle: a line from the hub out to the scale, a node at its tip.
  Item {
    id: needle
    x: face.cx; y: face.cy
    rotation: face.needleDeg
    Rectangle { x: face.u(12); y: -height / 2; width: face.u(98); height: Math.max(1, face.u(1)); color: face.accent }
    Rectangle { x: face.u(110) - width / 2; y: -height / 2; width: face.u(6); height: width; radius: width / 2; color: face.accent }
  }

  // The readout.
  Column {
    x: face.bx; y: face.by + (face.bh - height) / 2
    width: face.bw
    spacing: face.u(2)
    Text {
      width: parent.width; horizontalAlignment: Text.AlignHCenter
      elide: Text.ElideRight
      text: face.noteKind === "hint" ? String(face.note.prompt || "")
          : face.noteKind === "cant" ? String(face.note.title || "")
          : face.levelShown ? face.valueText : face.toolName(face.index)
      textFormat: Text.PlainText
      font.family: face.fontFamily; font.bold: !face.levelShown
      font.pixelSize: face.levelShown ? face.u(26) : face.noteKind !== "" ? face.u(14) : face.u(15)
      color: face.noteKind === "cant" ? face.alert : face.noteKind === "hint" ? face.line : face.accent
    }
    Row {
      anchors.horizontalCenter: parent.horizontalCenter
      visible: face.stateDrawn === "ring"
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
      width: parent.width; horizontalAlignment: Text.AlignHCenter
      elide: Text.ElideRight
      visible: text !== ""
      readonly property string clickHint: face.toolHint(face.index)
      text: face.levelShown ? (String(face.note.name || "") + (clickHint !== "" ? " · click " + clickHint : "")).toUpperCase()
          : face.noteKind === "cant" ? String(face.note.line || "")
          : face.noteKind === "hint" && face.note.steps > 1 ? "Step " + face.note.step + " of " + face.note.steps
          : ""
      textFormat: Text.PlainText
      font.family: face.fontFamily
      font.pixelSize: face.u(11)
      font.letterSpacing: face.levelShown ? face.u(1.3) : 0
      color: face.ink(0.7)
    }
  }

  function repaint() { back.requestPaint(); under.requestPaint() }
  onWidthChanged: repaint()
  onHeightChanged: repaint()
  onNoteKindChanged: repaint()
  onNoteChanged: repaint()
  onLitCountChanged: back.requestPaint()
  onNeedleDegChanged: under.requestPaint()
  onNChanged: under.requestPaint()
  onLineChanged: repaint()
  onAccentChanged: repaint()
  Connections { target: face.cfg; function onChanged() { face.repaint() } }
}
