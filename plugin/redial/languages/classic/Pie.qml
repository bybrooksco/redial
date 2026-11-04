pragma ComponentBehavior: Bound

import QtQuick
import "Drafting.js" as Drafting

// re:dial classic: the Pie look. Sectors are drawn, not filled; the chosen sector is
// section-hatched in the accent and turns forward to the next choice (the short way round, so the
// last tool to the first is one sector on). Turning a level hatches the value with a dimension arc
// round the outside. Mockup: DPIE in draft.js.
LookBase {
  id: face

  readonly property size plateSize: Qt.size(400, 400)
  readonly property bool wantsCallout: false
  readonly property string kind: "face"

  readonly property real cx: width / 2
  readonly property real cy: height / 2
  readonly property real step: 360 / n
  readonly property int litCount: litOf(100)
  readonly property Item selection: wedge

  // The wedge's turn. Live: the detent the hand is on, at once. Stepped: cumulative, eased.
  property real steppedDeg: 0
  Behavior on steppedDeg {
    id: stepEase
    NumberAnimation { duration: face.cfg.motionBase; easing.type: Easing.BezierSpline; easing.bezierCurve: face.easeInOut }
  }
  property int _lastIndex: 0
  onIndexChanged: {
    var d = (index - _lastIndex) % n
    if (d > n / 2) d -= n
    if (d < -n / 2) d += n
    steppedDeg += d * step
    _lastIndex = index
  }
  onLiveChanged: if (!live) { stepEase.enabled = false; steppedDeg = Math.round(position) * step; stepEase.enabled = true }

  Canvas {
    id: back
    anchors.fill: parent
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d"), L = String(face.line), A = String(face.accent)
      ctx.reset()
      ctx.fillStyle = String(face.ground); ctx.fillRect(0, 0, width, height)
      var cx = face.cx, cy = face.cy, r0 = face.u(58), r1 = face.u(160)
      if (face.cfg.constructionLines) {
        Drafting.regMarks(ctx, width, height, face.u(10), face.u(14), L)
        Drafting.construction(ctx, width, height, cx, cy, r0, r1, face.u(18), L)
      }
      Drafting.ring(ctx, cx, cy, r0, L, 0.35, 1)
      Drafting.ring(ctx, cx, cy, r1, L, 0.35, 1)
      Drafting.ring(ctx, cx, cy, face.u(168), L, 0.14, 1)
      for (var s = 0; s < face.tools.length; s++) {
        var a = -90 + s * face.step - face.step / 2, p = Drafting.polar(cx, cy, r0, a), q = Drafting.polar(cx, cy, r1, a)
        Drafting.line(ctx, p[0], p[1], q[0], q[1], L, 0.3, 1)
      }
      if (face.levelShown) {
        var end = -90 + Math.max(1, face.level) * 3.6
        Drafting.hatch(ctx, function (c) { Drafting.sectorPath(c, cx, cy, r0, r1, -90, end) }, width, height, A, 0.5, face.u(6))
        Drafting.sectorPath(ctx, cx, cy, r0, r1, -90, end)
        ctx.strokeStyle = Drafting.ink(A, 1); ctx.lineWidth = 1.2; ctx.stroke()
        Drafting.dimArc(ctx, cx, cy, face.u(180), -88, end - 2, A, face.u(7))
      }
      if (face.noteKind === "cant")
        Drafting.hatch(ctx, function (c) { Drafting.sectorPath(c, cx, cy, r0, r1, -90, 269.99) }, width, height, L, 0.22, face.u(7))
      if (face.noteKind === "hint") Drafting.cloudCircle(ctx, cx, cy, face.u(52), 12, A)
    }
  }

  // The chosen sector, hatched in the accent, turned with the choice.
  Item {
    id: wedge
    anchors.fill: parent
    visible: face.stateDrawn === "ring" && face.tools.length > 0
    rotation: face.live ? Math.round(face.position) * face.step : face.steppedDeg
    Canvas {
      id: wedgeArt
      anchors.fill: parent
      renderStrategy: Canvas.Cooperative
      onPaint: {
        var ctx = getContext("2d"), A = String(face.accent), cx = face.cx, cy = face.cy
        var a0 = -90 - face.step / 2, a1 = -90 + face.step / 2, r0 = face.u(58), r1 = face.u(168)
        ctx.reset()
        Drafting.hatch(ctx, function (c) { Drafting.sectorPath(c, cx, cy, r0, r1, a0, a1) }, width, height, A, 0.5, face.u(6))
        Drafting.sectorPath(ctx, cx, cy, r0, r1, a0, a1)
        ctx.strokeStyle = Drafting.ink(A, 1); ctx.lineWidth = 1.4; ctx.stroke()
      }
    }
  }

  // The level's dimension text, outside the arc at its middle.
  Text {
    visible: face.levelShown
    readonly property var at: Drafting.polar(face.cx, face.cy, face.u(192), -90 + Math.max(1, face.level) * 1.8)
    x: at[0] - width / 2; y: at[1] - height / 2
    text: Math.round(Math.max(1, face.level)) + "%"
    textFormat: Text.PlainText
    font.family: face.fontFamily; font.pixelSize: face.u(11); font.letterSpacing: face.u(1.3)
    color: face.accent
  }

  // Glyphs; the chosen one grows in the accent on a ground disc that cuts the hatching.
  Repeater {
    model: face.levelShown ? 0 : face.tools.length
    delegate: Item {
      id: glyph
      required property int index
      readonly property bool on: glyph.index === face.index && face.noteKind === ""
      readonly property var at: Drafting.polar(face.cx, face.cy, face.u(110), -90 + glyph.index * face.step)
      x: at[0]; y: at[1]
      opacity: face.noteKind === "cant" ? 0.35 : 1
      Rectangle {
        visible: glyph.on
        x: -width / 2; y: -height / 2; width: face.u(34); height: width; radius: width / 2
        color: face.ground
      }
      Text {
        anchors.centerIn: parent
        visible: face.cfg.showGlyphs
        text: face.toolIcon(glyph.index)
        textFormat: Text.PlainText
        font.family: face.fontFamily; font.pixelSize: face.u(17)
        color: glyph.on ? face.accent : face.ink(0.5)
        scale: glyph.on ? 1.3 : 1
        Behavior on scale { NumberAnimation { duration: face.cfg.motionBase * 0.75; easing.type: Easing.BezierSpline; easing.bezierCurve: face.easeOut } }
      }
    }
  }

  // The hub: the chosen tool, the level, or the state's sign and message.
  Column {
    anchors.centerIn: parent
    width: face.u(100)
    spacing: face.u(3)
    Canvas {
      id: sign
      anchors.horizontalCenter: parent.horizontalCenter
      visible: face.noteKind === "hint" || face.noteKind === "cant"
      width: face.u(22); height: width
      renderStrategy: Canvas.Cooperative
      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        Drafting.sign(ctx, face.noteKind, face.note, width, String(face.accent), String(face.alert))
      }
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      visible: face.levelShown
      text: face.valueText
      textFormat: Text.PlainText
      font.family: face.fontFamily; font.pixelSize: face.u(24)
      color: face.accent
    }
    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.Wrap; elide: Text.ElideRight; maximumLineCount: 3
      text: face.noteKind === "hint" ? String(face.note.prompt || "")
          : face.noteKind === "cant" ? String(face.note.title || "")
          : face.levelShown ? String(face.note.name || "").toUpperCase()
          : face.toolName(face.index)
      textFormat: Text.PlainText
      font.family: face.fontFamily; font.bold: true
      font.pixelSize: face.stateDrawn === "ring" ? face.u(14) : face.u(11)
      font.letterSpacing: face.levelShown ? face.u(1.3) : 0
      color: face.line
    }
    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      elide: Text.ElideRight
      visible: face.stateDrawn === "ring"
      text: face.toolHint(face.index) !== "" ? face.toolHint(face.index) : "nothing set"
      textFormat: Text.PlainText
      font.family: face.fontFamily; font.pixelSize: face.u(11)
      color: face.ink(face.toolHint(face.index) !== "" ? 1 : 0.55)
    }
  }

  function repaint() { back.requestPaint(); wedgeArt.requestPaint(); sign.requestPaint() }
  onWidthChanged: repaint()
  onHeightChanged: repaint()
  onNoteKindChanged: repaint()
  onNoteChanged: repaint()
  onNChanged: repaint()
  onLineChanged: repaint()
  onAccentChanged: repaint()
  Connections { target: face.cfg; function onChanged() { face.repaint() } }
}
