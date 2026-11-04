pragma ComponentBehavior: Bound

import QtQuick
import "Basic.js" as Basic

// re:dial basic: the Finger wheel look, a rotary phone dial. The wheel is the hand: it follows the
// dial directly, so the brass ring at the finger stop always frames the armed tool; let go and it
// spins back onto the chosen hole. The centre is a paper card. Turning is a smaller ring meter.
// Mockup: WHL in index.html.
LookBase {
  id: look

  readonly property bool meterShown: stateDrawn === "turn"
  readonly property size plateSize: meterShown ? Qt.size(264, 264) : Qt.size(336, 336)
  readonly property bool wantsCallout: false
  readonly property string kind: "face"

  readonly property var p: paperTone
  readonly property real c: width / 2
  readonly property real stop: 40   // the finger stop, at about 4 o'clock
  readonly property real step: 360 / n
  readonly property int litCount: litOf(100)
  readonly property Item selection: wheel
  property alias meter: meterArt

  // The chosen hole, counted the short way round so the wheel never spins the long way.
  property real _holes: 0
  property int _lastIndex: 0
  onIndexChanged: {
    var d = (index - _lastIndex) % n
    if (d > n / 2) d -= n
    if (d < -n / 2) d += n
    _holes += d
    _lastIndex = index
  }
  // Letting go: the wheel spins back from the hand's angle onto the chosen hole (the nearest one).
  property real _releaseFrom: 0
  property real releaseT: 1
  NumberAnimation { id: release; target: look; property: "releaseT"; from: 0; to: 1; duration: 260; easing.type: Easing.BezierSpline; easing.bezierCurve: look.easeDrawer }
  onLiveChanged: {
    if (live) { release.stop(); releaseT = 1; return }
    var from = -position * step, rest = -_holes * step
    _holes += Math.round((from - rest) / 360) * -360 / step
    _releaseFrom = from
    if (cfg.motionBase > 0) release.restart(); else releaseT = 1
  }
  readonly property real restDeg: noteKind === "cant" || noteKind === "hint" ? 0 : -_holes * step
  readonly property real wheelDeg: live ? -position * step
                                 : releaseT < 1 ? _releaseFrom + (restDeg - _releaseFrom) * releaseT
                                 : restDeg
  readonly property real turned: ((-wheelDeg % 360) + 360) % 360
  readonly property int picked: live ? Math.round(((position % n) + n) % n) % n : chosen

  // ---- the dial (ring, hint, can't act) ----
  Rectangle { visible: !look.meterShown; anchors.fill: parent; radius: width / 2; color: look.tone.rim }
  Rectangle { visible: !look.meterShown; anchors.fill: parent; anchors.margins: look.u(8); radius: width / 2; color: look.tone.ground }
  Item {
    id: wheel
    visible: !look.meterShown
    anchors.fill: parent
    rotation: look.wheelDeg
    opacity: look.noteKind === "cant" ? 0.3 : 1
    Rectangle { anchors.fill: parent; anchors.margins: look.u(18); radius: width / 2; color: look.tone.surface }
    Repeater {
      model: look.tools.length
      delegate: Rectangle {
        required property int index
        readonly property var at: Basic.polar(look.c, look.c, look.u(114), look.stop + index * look.step)
        x: at[0] - width / 2; y: at[1] - height / 2; width: look.u(50); height: width; radius: width / 2
        color: look.p.hole
      }
    }
  }
  // The glyphs ride the holes but stay upright.
  Repeater {
    model: look.meterShown ? 0 : look.tools.length
    delegate: Text {
      id: g
      required property int index
      readonly property var at: Basic.polar(look.c, look.c, look.u(114), look.stop + g.index * look.step + look.wheelDeg)
      x: at[0] - width / 2; y: at[1] - height / 2
      visible: look.cfg.showGlyphs
      opacity: look.noteKind === "cant" ? 0.3 : 1
      text: look.toolIcon(g.index); textFormat: Text.PlainText
      font.family: look.fontFamily; font.pixelSize: look.u(20)
      color: look.tone.ink
    }
  }
  // The brass ring at the stop, and the finger stop.
  Canvas {
    id: stopArt
    visible: !look.meterShown
    anchors.fill: parent
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d"), c = look.c, a = String(look.tone.accent), f = Basic.polar(c, c, look.u(114), look.stop)
      ctx.reset()
      ctx.globalAlpha = look.noteKind === "cant" ? 0.3 : 1
      ctx.strokeStyle = a; ctx.lineWidth = look.u(4)
      ctx.beginPath(); ctx.arc(f[0], f[1], look.u(28), 0, Math.PI * 2); ctx.stroke()
      ctx.globalAlpha = 1
      var s = Basic.polar(c, c, look.u(150), look.stop + 26)
      ctx.save(); ctx.translate(s[0], s[1]); ctx.rotate((look.stop + 26 + 90) * Math.PI / 180)
      ctx.fillStyle = a; ctx.beginPath(); ctx.roundedRect(-look.u(8), -look.u(24), look.u(16), look.u(44), look.u(8), look.u(8)); ctx.fill()
      ctx.fillStyle = "#ffffff"; ctx.globalAlpha = 0.35
      ctx.beginPath(); ctx.roundedRect(-look.u(3), -look.u(18), look.u(4), look.u(30), look.u(2), look.u(2)); ctx.fill()
      ctx.restore()
    }
  }
  // The centre card: chrome rim, paper face.
  Rectangle {
    visible: !look.meterShown
    readonly property real r: look.u(look.noteKind === "" || look.noteKind === "turn" ? 78 : 96)
    x: look.c - r - look.u(5); y: look.c - r - look.u(5); width: (r + look.u(5)) * 2; height: width; radius: width / 2
    color: look.p.chrome
    Rectangle {
      anchors.fill: parent; anchors.margins: look.u(5); radius: width / 2
      color: look.p.paper
      Column {
        anchors.centerIn: parent
        width: parent.width - look.u(28)
        visible: look.stateDrawn === "ring"
        Text {
          width: parent.width; horizontalAlignment: Text.AlignHCenter
          text: "re:dial"; textFormat: Text.PlainText
          font.family: look.face; font.pixelSize: look.u(12); font.weight: Font.DemiBold; font.letterSpacing: look.u(0.4)
          color: look.p.soft
        }
        Text {
          width: parent.width; horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
          text: look.toolName(look.picked); textFormat: Text.PlainText
          font.family: look.face; font.pixelSize: look.u(28); font.weight: Font.Bold
          lineHeight: 1.05
          color: look.p.ink
        }
        Text {
          width: parent.width; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
          topPadding: look.u(4)
          text: look.pressText(look.picked); textFormat: Text.PlainText
          font.family: look.face; font.pixelSize: look.u(15)
          color: look.p.soft
        }
      }
      Message {
        anchors.centerIn: parent
        width: parent.width - look.u(28)
        visible: look.noteKind === "hint" || look.noteKind === "cant"
        host: look
        big: 22; small: 15; signSize: 38
        ink: look.p.ink; soft: look.p.soft
      }
    }
  }

  // ---- turning: the ring meter ----
  Rectangle { visible: look.meterShown; anchors.fill: parent; radius: width / 2; color: look.tone.ground }
  Canvas {
    id: meterArt
    visible: look.meterShown
    anchors.fill: parent
    renderStrategy: Canvas.Cooperative
    property real shown: look.level
    Behavior on shown { enabled: look.cfg.motionFast > 0; NumberAnimation { duration: look.cfg.motionFast; easing.type: Easing.BezierSpline; easing.bezierCurve: look.easeOut } }
    onShownChanged: requestPaint()
    onPaint: {
      var ctx = getContext("2d"), c = look.c, t = look.tone
      ctx.reset()
      ctx.fillStyle = String(t.ink)
      for (var i = 0; i < 20; i++) {
        var q = Basic.polar(c, c, look.u(125), -90 + i * 18)
        ctx.globalAlpha = 0.45; ctx.beginPath(); ctx.arc(q[0], q[1], look.u(i % 5 ? 1.6 : 2.6), 0, Math.PI * 2); ctx.fill()
      }
      ctx.globalAlpha = 1
      ctx.strokeStyle = String(t.surface); ctx.lineWidth = look.u(14)
      ctx.beginPath(); ctx.arc(c, c, look.u(110), 0, Math.PI * 2); ctx.stroke()
      if (shown > 0.2) Basic.arc(ctx, c, c, look.u(110), -90, -90 + shown * 3.6, String(t.accent), look.u(14))
    }
  }
  Rectangle {
    visible: look.meterShown
    x: look.c - look.u(102); y: look.c - look.u(102); width: look.u(204); height: width; radius: width / 2
    color: look.p.chrome
    Rectangle {
      anchors.fill: parent; anchors.margins: look.u(5); radius: width / 2
      color: look.p.paper
      Column {
        anchors.centerIn: parent
        width: parent.width - look.u(28)
        Text {
          width: parent.width; horizontalAlignment: Text.AlignHCenter
          text: "re:dial"; textFormat: Text.PlainText
          font.family: look.face; font.pixelSize: look.u(12); font.weight: Font.DemiBold
          color: look.p.soft
        }
        Text {
          width: parent.width; horizontalAlignment: Text.AlignHCenter
          text: look.valueText; textFormat: Text.PlainText
          font.family: look.face; font.pixelSize: look.u(look.valueText.length > 4 ? 44 : 60); font.weight: Font.Bold
          color: look.p.ink
        }
        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: look.u(8)
          Text {
            visible: look.cfg.showGlyphs
            text: look.toolIcon(look.chosen); textFormat: Text.PlainText
            font.family: look.fontFamily; font.pixelSize: look.u(21); color: look.p.ink
          }
          Text {
            width: Math.min(implicitWidth, look.u(130)); elide: Text.ElideRight
            text: String(look.note.name || ""); textFormat: Text.PlainText
            font.family: look.face; font.pixelSize: look.u(21); font.weight: Font.DemiBold
            color: look.p.ink
          }
        }
        Text {
          width: parent.width; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
          text: look.pressText(look.chosen); textFormat: Text.PlainText
          font.family: look.face; font.pixelSize: look.u(14)
          color: look.p.soft
        }
      }
    }
  }

  function repaint() { stopArt.requestPaint(); meterArt.requestPaint() }
  onWidthChanged: repaint()
  onToneChanged: repaint()
  onNoteKindChanged: repaint()
}
