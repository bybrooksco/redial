pragma ComponentBehavior: Bound

import QtQuick
import "Basic.js" as Basic

// re:dial basic: the Gauge look. A 270° instrument on a rimmed disc; the tapered needle is the
// selection and springs between tools (it lands at once across the wrap, and rests at zero when
// the dial can't act); a rounded card under the hub carries the name or the level, whose arc fills
// round the rim. Mockup: GAU in looks.js.
LookBase {
  id: look

  readonly property size plateSize: Qt.size(320, 320)
  readonly property bool wantsCallout: false
  readonly property string kind: "face"

  readonly property real c: width / 2
  readonly property real a0: 135
  readonly property real span: 270
  function ang(i) { return a0 + i * span / Math.max(1, n - 1) }
  readonly property int litCount: litOf(100)
  readonly property Item selection: needle

  readonly property real wrapped: ((position % n) + n) % n
  readonly property real target: levelShown ? a0 + level * 2.7
                                : noteKind === "hint" || noteKind === "cant" ? a0
                                : Math.min(a0 + span, live ? ang(wrapped) : ang(index))
  readonly property bool springs: !live && cfg.motionBase > 0
  property real needleDeg: a0
  property real _v: 0
  onTargetChanged: settle()
  onSpringsChanged: settle()
  function settle() { if (!springs || Math.abs(target - needleDeg) > 200) { needleDeg = target; _v = 0 } }
  Component.onCompleted: needleDeg = target
  FrameAnimation {
    running: look.springs && (Math.abs(look.target - look.needleDeg) > 0.01 || Math.abs(look._v) > 0.01)
    onTriggered: {
      var steps = Math.max(1, Math.ceil(frameTime * 1000 / 4)), s = frameTime / steps
      var x = look.needleDeg, v = look._v
      for (var j = 0; j < steps; j++) { v += (600 * (look.target - x) - 28 * v) * s; x += v * s }
      if (Math.abs(look.target - x) < 0.01 && Math.abs(v) < 0.01) { x = look.target; v = 0 }
      look._v = v; look.needleDeg = x
    }
  }

  Rectangle { anchors.fill: parent; radius: width / 2; color: look.tone.rim }
  Rectangle { anchors.fill: parent; anchors.margins: look.u(7); radius: width / 2; color: look.tone.ground }

  Canvas {
    id: dial
    anchors.fill: parent
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d"), c = look.c, t = look.tone
      ctx.reset()
      ctx.lineCap = "round"; ctx.strokeStyle = String(t.muted)
      for (var i = 0; i <= 40; i++) {
        var a = look.a0 + i * look.span / 40, major = i % 10 === 0
        var p = Basic.polar(c, c, look.u(major ? 128 : 134), a), q = Basic.polar(c, c, look.u(142), a)
        ctx.lineWidth = look.u(major ? 3 : 1.6); ctx.beginPath(); ctx.moveTo(p[0], p[1]); ctx.lineTo(q[0], q[1]); ctx.stroke()
      }
      ctx.lineCap = "butt"
      ctx.beginPath(); ctx.strokeStyle = String(t.track); ctx.lineWidth = look.u(3)
      ctx.arc(c, c, look.u(150), look.a0 * Math.PI / 180, (look.a0 + look.span) * Math.PI / 180); ctx.stroke()
      if (look.levelShown && look.level > 0)
        Basic.arc(ctx, c, c, look.u(150), look.a0, look.a0 + look.level * 2.7, String(t.accent), look.u(5))
    }
  }

  // Tool glyphs (ring), or the level's 0 / 50 / 100.
  Repeater {
    model: look.levelShown ? 0 : look.tools.length
    delegate: Text {
      id: g
      required property int index
      readonly property var at: Basic.polar(look.c, look.c, look.u(108), look.ang(g.index))
      x: at[0] - width / 2; y: at[1] - height / 2
      visible: look.cfg.showGlyphs
      text: look.toolIcon(g.index); textFormat: Text.PlainText
      font.family: look.fontFamily; font.pixelSize: look.u(18)
      color: g.index === look.chosen && look.noteKind === "" ? look.tone.accent : look.tone.soft
      opacity: look.ringInk
    }
  }
  Repeater {
    model: look.levelShown ? [0, 50, 100] : []
    delegate: Text {
      id: m
      required property int modelData
      readonly property var at: Basic.polar(look.c, look.c, look.u(112), look.a0 + m.modelData * 2.7)
      x: at[0] - width / 2; y: at[1] - height / 2
      text: String(m.modelData); textFormat: Text.PlainText
      font.family: look.face; font.pixelSize: look.u(15)
      color: look.tone.soft
    }
  }

  // The needle, tapered, and the hub.
  Item {
    id: needle
    x: look.c; y: look.c
    rotation: look.needleDeg
    Canvas {
      id: needleArt
      x: -look.u(4); y: -look.u(4); width: look.u(112); height: look.u(8)
      renderStrategy: Canvas.Cooperative
      onPaint: {
        var ctx = getContext("2d")
        ctx.reset(); ctx.fillStyle = String(look.tone.accent)
        ctx.beginPath(); ctx.moveTo(0, 0); ctx.lineTo(width, height * 0.4); ctx.lineTo(width, height * 0.6); ctx.lineTo(0, height); ctx.closePath(); ctx.fill()
      }
    }
  }
  Rectangle {
    x: look.c - width / 2; y: look.c - height / 2; width: look.u(30); height: width; radius: width / 2
    color: look.tone.card
    border.width: look.u(4); border.color: look.tone.accent
  }

  // The sign above the hub on a hint or can't act.
  Canvas {
    id: sign
    visible: look.noteKind === "hint" || look.noteKind === "cant"
    x: look.c - look.u(18); y: look.c - look.u(76); width: look.u(36); height: width
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      Basic.sign(ctx, look.noteKind, look.note, width, String(look.tone.accent), String(look.tone.alert))
    }
  }

  // The readout card.
  Rectangle {
    x: look.c - look.u(90); y: look.c + look.u(56); width: look.u(180); height: look.u(74); radius: look.u(14)
    color: look.tone.surface
    Column {
      anchors.centerIn: parent
      width: parent.width - look.u(20)
      visible: look.stateDrawn === "ring"
      Text {
        width: parent.width; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
        text: look.toolName(look.chosen); textFormat: Text.PlainText
        font.family: look.face; font.pixelSize: look.u(22); font.weight: Font.Bold
        color: look.tone.ink
      }
      Text {
        width: parent.width; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
        text: look.pressText(look.chosen); textFormat: Text.PlainText
        font.family: look.face; font.pixelSize: look.u(14)
        color: look.tone.soft
      }
    }
    Column {
      anchors.centerIn: parent
      width: parent.width - look.u(20)
      visible: look.levelShown
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: look.valueText; textFormat: Text.PlainText
        font.family: look.face; font.pixelSize: look.u(34); font.weight: Font.Bold
        color: look.tone.ink
      }
      Text {
        width: parent.width; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
        text: String(look.note.name || "") + " · " + look.pressText(look.chosen); textFormat: Text.PlainText
        font.family: look.face; font.pixelSize: look.u(14)
        color: look.tone.soft
      }
    }
    Column {
      anchors.centerIn: parent
      width: parent.width - look.u(20)
      visible: look.noteKind === "hint" || look.noteKind === "cant"
      Text {
        width: parent.width; horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
        text: look.noteKind === "hint" ? String(look.note.prompt || "") : String(look.note.title || "")
        textFormat: Text.PlainText
        font.family: look.face; font.pixelSize: look.u(19); font.weight: Font.Bold
        color: look.tone.ink
      }
      Text {
        width: parent.width; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
        visible: text !== ""
        text: look.noteKind === "cant" ? String(look.note.line || "")
            : look.note.steps > 1 ? "Step " + look.note.step + " of " + look.note.steps : ""
        textFormat: Text.PlainText
        font.family: look.face; font.pixelSize: look.u(13)
        color: look.tone.soft
      }
    }
  }

  function repaint() { dial.requestPaint(); needleArt.requestPaint(); sign.requestPaint() }
  onWidthChanged: repaint()
  onToneChanged: repaint()
  onNoteKindChanged: repaint()
  onNoteChanged: repaint()
  onLitCountChanged: dial.requestPaint()
}
