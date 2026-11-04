pragma ComponentBehavior: Bound

import QtQuick
import "Basic.js" as Basic

// re:dial basic: the Pie look. A donut of filled sectors with gaps between them; one accent wedge
// turns forward to the choice (the short way round). Turning a level fills the donut round from
// the top, inside the sectors. Mockup: PIE in looks.js.
LookBase {
  id: look

  readonly property size plateSize: Qt.size(336, 336)
  readonly property bool wantsCallout: false
  readonly property string kind: "face"

  readonly property real c: width / 2
  readonly property real step: 360 / n
  readonly property real gap: 2.2
  readonly property int litCount: litOf(100)
  readonly property Item selection: wedge

  property real steppedDeg: 0
  Behavior on steppedDeg {
    id: stepEase
    NumberAnimation { duration: look.cfg.motionBase * 0.75; easing.type: Easing.BezierSpline; easing.bezierCurve: look.easeInOut }
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
  readonly property int picked: live ? Math.round(((position % n) + n) % n) % n : chosen

  Rectangle { anchors.fill: parent; radius: width / 2; color: look.tone.ground }

  // The sectors, and the level filling them.
  Canvas {
    id: donut
    anchors.fill: parent
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d"), c = look.c, t = look.tone, s = look.step, g = look.gap
      ctx.reset()
      ctx.globalAlpha = look.levelShown ? 1 : look.ringInk
      function sectors() {
        ctx.beginPath()
        for (var i = 0; i < look.tools.length; i++) {
          var a0 = (-90 - s / 2 + i * s + g) * Math.PI / 180, a1 = (-90 + s / 2 + i * s - g) * Math.PI / 180
          ctx.moveTo(c + Math.cos(a0) * look.u(158), c + Math.sin(a0) * look.u(158))
          ctx.arc(c, c, look.u(158), a0, a1, false); ctx.arc(c, c, look.u(82), a1, a0, true); ctx.closePath()
        }
      }
      sectors(); ctx.fillStyle = String(t.surface); ctx.fill()
      if (look.levelShown && look.level > 0) {
        ctx.save(); sectors(); ctx.clip()
        var start = -90 - s / 2
        Basic.sectorPath(ctx, c, c, look.u(82), look.u(158), start, start + look.level * 3.6)
        ctx.fillStyle = String(t.accent); ctx.fill(); ctx.restore()
      }
    }
  }

  // The chosen wedge, turned with the choice.
  Item {
    id: wedge
    anchors.fill: parent
    visible: look.stateDrawn === "ring" && look.tools.length > 0
    rotation: look.live ? Math.round(look.position) * look.step : look.steppedDeg
    Canvas {
      id: wedgeArt
      anchors.fill: parent
      renderStrategy: Canvas.Cooperative
      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        Basic.sectorPath(ctx, look.c, look.c, look.u(80), look.u(166), -90 - look.step / 2 + look.gap, -90 + look.step / 2 - look.gap)
        ctx.fillStyle = String(look.tone.accent); ctx.fill()
      }
    }
  }

  Repeater {
    model: look.levelShown ? 0 : look.tools.length
    delegate: Text {
      id: g
      required property int index
      readonly property var at: Basic.polar(look.c, look.c, look.u(121), -90 + g.index * look.step)
      x: at[0] - width / 2; y: at[1] - height / 2
      visible: look.cfg.showGlyphs
      text: look.toolIcon(g.index); textFormat: Text.PlainText
      font.family: look.fontFamily; font.pixelSize: look.u(20)
      color: g.index === look.picked && look.noteKind === "" ? look.tone.onaccent : look.tone.soft
      opacity: look.ringInk
    }
  }

  // The centre disc.
  Rectangle {
    readonly property real r: look.u(look.stateDrawn === "ring" || look.levelShown ? 76 : 80)
    x: look.c - r; y: look.c - r; width: r * 2; height: width; radius: r
    color: look.tone.surface
    Column {
      anchors.centerIn: parent
      width: parent.width - look.u(24)
      visible: look.stateDrawn === "ring"
      Text {
        width: parent.width; horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
        text: look.toolName(look.picked); textFormat: Text.PlainText
        font.family: look.face; font.pixelSize: look.u(26); font.weight: Font.Bold
        lineHeight: 1.05
        color: look.tone.ink
      }
      Text {
        width: parent.width; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
        topPadding: look.u(4)
        text: look.pressText(look.picked); textFormat: Text.PlainText
        font.family: look.face; font.pixelSize: look.u(15)
        color: look.tone.soft
      }
    }
    Column {
      anchors.centerIn: parent
      visible: look.levelShown
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: look.valueText; textFormat: Text.PlainText
        font.family: look.face; font.pixelSize: look.u(50); font.weight: Font.Bold
        color: look.tone.ink
      }
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: look.u(6)
        Text {
          text: look.toolIcon(look.chosen); textFormat: Text.PlainText
          font.family: look.fontFamily; font.pixelSize: look.u(18); color: look.tone.accent
        }
        Text {
          text: String(look.note.name || ""); textFormat: Text.PlainText
          font.family: look.face; font.pixelSize: look.u(18); font.weight: Font.DemiBold
          color: look.tone.ink
        }
      }
    }
    Message {
      anchors.centerIn: parent
      width: parent.width - look.u(24)
      visible: look.noteKind === "hint" || look.noteKind === "cant"
      look: look
      big: 19; small: 13
    }
  }

  function repaint() { donut.requestPaint(); wedgeArt.requestPaint() }
  onWidthChanged: repaint()
  onToneChanged: repaint()
  onNoteKindChanged: repaint()
  onNoteChanged: repaint()
  onNChanged: repaint()
}
