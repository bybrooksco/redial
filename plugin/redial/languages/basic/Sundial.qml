pragma ComponentBehavior: Bound

import QtQuick
import "Basic.js" as Basic
import "Tones.js" as Tones

// re:dial basic: the Sundial look, set in Fraunces. The tools are hours round a dial; the sun
// follows the hand a breath behind (solar inertia) and the gnomon's shadow falls away from it.
// Turning, a hint and can't act use the half plate: the sun climbs the arc as the level, a hint
// is a plaque above it, and can't act is an eclipse (the moon slides over the sun once).
// Mockup: SUN in index.html.
LookBase {
  id: look

  readonly property bool half: stateDrawn !== "ring"
  readonly property real plaqueH: stateDrawn === "hint" ? 90 : 0
  readonly property size plateSize: half ? Qt.size(336, 226 + plaqueH) : Qt.size(336, 336)
  readonly property bool wantsCallout: false
  readonly property string kind: "face"

  readonly property string sunFace: language && language.faceSundial !== "" ? language.faceSundial : face
  readonly property color shade: Tones.mix(String(tone.ground), "#000000", 0.45)
  readonly property real c: u(168)
  readonly property real hy: u(plaqueH + 172)   // the half plate's centre
  readonly property real step: 360 / n
  readonly property int litCount: litOf(100)
  readonly property Item selection: sun

  property int _lastIndex: 0
  property real _hours: 0   // cumulative index, so the sun goes the short way
  onIndexChanged: {
    var d = (index - _lastIndex) % n
    if (d > n / 2) d -= n
    if (d < -n / 2) d += n
    _hours += d
    _lastIndex = index
  }
  onLiveChanged: if (!live) _hours = Math.round(position)
  readonly property int picked: live ? Math.round(((position % n) + n) % n) % n : chosen

  // Where the sun is headed: the hand round the dial, the level up the arc, noon for a hint.
  readonly property real sunTarget: levelShown ? 180 + level * 1.8
                                  : half ? 270   // a hint parks the sun at noon, clear of the plinth
                                  : -90 + (live ? position : _hours) * step
  readonly property real tau: levelShown ? 45 : 60
  onSunTargetChanged: if (cfg.motionBase <= 0) sun.deg = sunTarget
  onHalfChanged: { sun.deg = sunTarget; repaint() }   // a new plate: the sun starts where it belongs
  FrameAnimation {
    running: look.cfg.motionBase > 0 && Math.abs(look.sunTarget - look.sunDeg) > 0.01
    onTriggered: {
      var d = look.sunTarget - sun.deg
      sun.deg = Math.abs(d) < 0.05 ? look.sunTarget : sun.deg + d * (1 - Math.exp(-frameTime * 1000 / look.tau))
    }
  }
  readonly property real sunDeg: sun.deg

  // The eclipse: the moon slides over the sun once, 420 ms ease-in-out.
  property real moonX: 43
  NumberAnimation { id: moonIn; target: look; property: "moonX"; from: 43; to: 3; duration: 420; easing.type: Easing.BezierSpline; easing.bezierCurve: look.easeInOut }
  onNoteKindChanged: {
    if (noteKind !== "cant") { moonIn.stop(); moonX = 43 }
    else if (cfg.motionBase > 0) moonIn.restart()
    else moonX = 3
    repaint()
  }

  // ---- the round plate (ring) ----
  Canvas {
    id: dial
    anchors.fill: parent
    visible: !look.half
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d"), c = look.c, t = look.tone
      ctx.reset()
      ctx.fillStyle = String(t.rim); ctx.beginPath(); ctx.arc(c, c, look.u(168), 0, Math.PI * 2); ctx.fill()
      ctx.fillStyle = String(t.ground); ctx.beginPath(); ctx.arc(c, c, look.u(150), 0, Math.PI * 2); ctx.fill()
      ctx.strokeStyle = String(t.muted); ctx.lineWidth = look.u(2.5); ctx.lineCap = "round"
      for (var i = 0; i < look.tools.length; i++) {
        var a = -90 + i * look.step + look.step / 2, p = Basic.polar(c, c, look.u(137), a), q = Basic.polar(c, c, look.u(144), a)
        ctx.beginPath(); ctx.moveTo(p[0], p[1]); ctx.lineTo(q[0], q[1]); ctx.stroke()
      }
    }
  }
  // The gnomon's shadow, falling away from the sun.
  Item {
    visible: !look.half
    x: look.c; y: look.c
    rotation: sun.deg + 270
    Canvas {
      id: shadowArt
      x: -look.u(7); y: -look.u(98); width: look.u(14); height: look.u(98)
      renderStrategy: Canvas.Cooperative
      onPaint: {
        var ctx = getContext("2d")
        ctx.reset(); ctx.fillStyle = String(look.shade)
        ctx.beginPath(); ctx.moveTo(0, height); ctx.lineTo(width / 2, 0); ctx.lineTo(width, height); ctx.closePath(); ctx.fill()
      }
    }
  }
  Rectangle {
    visible: !look.half
    x: look.c - width / 2; y: look.c - height / 2; width: look.u(152); height: width; radius: width / 2
    color: look.tone.surface
    Column {
      anchors.centerIn: parent
      width: parent.width - look.u(16)
      Text {
        width: parent.width; horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
        text: look.toolName(look.picked); textFormat: Text.PlainText
        font.family: look.sunFace; font.pixelSize: look.u(26); font.weight: Font.DemiBold
        lineHeight: 1.1
        color: look.tone.ink
      }
      Text {
        width: parent.width; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
        topPadding: look.u(4)
        text: look.pressText(look.picked); textFormat: Text.PlainText
        font.family: look.sunFace; font.pixelSize: look.u(15)
        color: look.tone.soft
      }
    }
  }
  Text {
    // "re:dial" engraved at the top of the rim.
    anchors.horizontalCenter: parent.horizontalCenter
    y: (look.half ? look.hy : look.c) - look.u(159) - height / 2
    text: "re:dial"; textFormat: Text.PlainText
    font.family: look.sunFace; font.pixelSize: look.u(12); font.letterSpacing: look.u(0.5)
    color: look.tone.muted
    z: 2
  }

  // ---- the half plate (turn, hint, can't act) ----
  Canvas {
    id: halfArt
    y: look.u(look.plaqueH); width: parent.width; height: look.u(226)
    visible: look.half
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d"), c = look.c, cy = look.u(172), t = look.tone, U = look.unit
      ctx.reset()
      ctx.fillStyle = String(t.rim)
      ctx.beginPath(); ctx.moveTo(0, cy); ctx.arc(c, cy, look.u(168), Math.PI, 0, false)
      ctx.lineTo(width, look.u(206)); ctx.arcTo(width, height, width - look.u(20), height, look.u(20))
      ctx.lineTo(look.u(20), height); ctx.arcTo(0, height, 0, look.u(206), look.u(20)); ctx.closePath(); ctx.fill()
      ctx.fillStyle = String(t.ground)
      ctx.beginPath(); ctx.moveTo(look.u(18), cy); ctx.arc(c, cy, look.u(150), Math.PI, 0, false); ctx.closePath(); ctx.fill()
      ctx.strokeStyle = String(t.muted); ctx.lineCap = "round"
      for (var i = 0; i < 11; i++) {
        var a = 180 + i * 18, major = i % 5 === 0
        var p = Basic.polar(c, cy, look.u(major ? 128 : 132), a), q = Basic.polar(c, cy, look.u(140), a)
        ctx.lineWidth = look.u(major ? 3 : 2); ctx.beginPath(); ctx.moveTo(p[0], p[1]); ctx.lineTo(q[0], q[1]); ctx.stroke()
      }
      if (look.noteKind === "cant") {
        ctx.fillStyle = String(t.alert); ctx.beginPath(); ctx.arc(c, look.u(58), look.u(17), 0, Math.PI * 2); ctx.fill()
        return
      }
      ctx.lineWidth = look.u(6); ctx.strokeStyle = String(t.track)
      ctx.beginPath(); ctx.arc(c, cy, look.u(120), Math.PI, 0, false); ctx.stroke()
      var v = Math.max(0, Math.min(100, (sun.deg - 180) / 1.8))
      if (look.levelShown && v > 0.2) Basic.arc(ctx, c, cy, look.u(120), 180, sun.deg, String(t.accent), look.u(6))
      var s = Basic.polar(c, cy, look.u(46), sun.deg + 180)
      ctx.strokeStyle = String(look.shade); ctx.lineWidth = look.u(7); ctx.lineCap = "round"
      ctx.beginPath(); ctx.moveTo(c, cy); ctx.lineTo(s[0], Math.min(s[1], cy - look.u(4))); ctx.stroke()
      ctx.fillStyle = String(t.muted)
      ctx.beginPath(); ctx.moveTo(c - look.u(8), cy); ctx.lineTo(c, cy - look.u(30)); ctx.lineTo(c + look.u(8), cy); ctx.closePath(); ctx.fill()
    }
  }
  // The moon, over the alert sun.
  Rectangle {
    visible: look.noteKind === "cant"
    x: look.c + look.u(look.moonX) - width / 2; y: look.u(54) - height / 2
    width: look.u(34); height: width; radius: width / 2
    color: look.tone.rim
  }

  // The sun: round the dial on the ring, up the arc on the half plate.
  Item {
    id: sun
    property real deg: -90
    Component.onCompleted: deg = look.sunTarget
    onDegChanged: if (look.half) halfArt.requestPaint()
    visible: look.noteKind !== "cant"
    readonly property var at: look.half ? Basic.polar(look.c, look.hy, look.u(120), deg) : Basic.polar(look.c, look.c, look.u(116), deg)
    x: at[0] - width / 2; y: at[1] - height / 2
    width: look.u(look.half ? 24 : 46); height: width
    Canvas {
      id: corona
      anchors.centerIn: parent
      width: look.u(look.half ? 44 : 70); height: width
      renderStrategy: Canvas.Cooperative
      onPaint: {
        var ctx = getContext("2d"), c = width / 2, k = look.half ? 10 : 12
        var r0 = look.u(look.half ? 17 : 29), r1 = look.u(look.half ? 21 : 33)
        ctx.reset(); ctx.strokeStyle = String(look.tone.accent); ctx.globalAlpha = 0.7
        ctx.lineWidth = look.u(2.5); ctx.lineCap = "round"
        for (var i = 0; i < k; i++) {
          var p = Basic.polar(c, c, r0, i * 360 / k), q = Basic.polar(c, c, r1, i * 360 / k)
          ctx.beginPath(); ctx.moveTo(p[0], p[1]); ctx.lineTo(q[0], q[1]); ctx.stroke()
        }
      }
    }
    Rectangle { anchors.fill: parent; radius: width / 2; color: look.tone.accent }
  }

  // The tool glyphs, over the sun; the one under it takes the ground colour.
  Repeater {
    model: look.half ? 0 : look.tools.length
    delegate: Text {
      id: g
      required property int index
      readonly property var at: Basic.polar(look.c, look.c, look.u(116), -90 + g.index * look.step)
      x: at[0] - width / 2; y: at[1] - height / 2
      visible: look.cfg.showGlyphs
      text: look.toolIcon(g.index); textFormat: Text.PlainText
      font.family: look.fontFamily; font.pixelSize: look.u(20)
      color: g.index === look.picked ? look.tone.ground : look.tone.soft
    }
  }

  // The half plate's centre and plinth.
  Text {
    visible: look.half
    y: look.u(look.plaqueH + (look.levelShown ? 80 : look.noteKind === "cant" ? 96 : 92))
    width: parent.width; horizontalAlignment: Text.AlignHCenter
    leftPadding: look.u(60); rightPadding: look.u(60); elide: Text.ElideRight
    text: look.levelShown ? look.valueText : look.noteKind === "cant" ? String(look.note.title || "") : look.toolName(look.chosen)
    textFormat: Text.PlainText
    font.family: look.sunFace; font.pixelSize: look.u(look.levelShown ? 52 : 25); font.weight: Font.DemiBold
    color: look.tone.ink
  }
  Item {
    visible: look.half
    x: look.u(22); y: look.hy + look.u(6); width: parent.width - look.u(44); height: look.u(48)
    Row {
      visible: look.noteKind !== "cant"
      anchors.verticalCenter: parent.verticalCenter
      spacing: look.u(8)
      Text {
        visible: look.cfg.showGlyphs
        text: look.toolIcon(look.chosen); textFormat: Text.PlainText
        font.family: look.fontFamily; font.pixelSize: look.u(19); color: look.tone.accent
      }
      Text {
        width: Math.min(implicitWidth, look.u(150)); elide: Text.ElideRight
        text: look.levelShown ? String(look.note.name || "") : look.toolName(look.chosen); textFormat: Text.PlainText
        font.family: look.sunFace; font.pixelSize: look.u(19)
        color: look.tone.ink
      }
    }
    Text {
      anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
      visible: look.noteKind !== "cant"
      width: Math.min(implicitWidth, look.u(130)); elide: Text.ElideRight
      text: look.pressText(look.chosen); textFormat: Text.PlainText
      font.family: look.sunFace; font.pixelSize: look.u(15)
      color: look.tone.soft
    }
    Text {
      anchors.centerIn: parent
      visible: look.noteKind === "cant"
      width: parent.width; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
      text: String(look.note.line || ""); textFormat: Text.PlainText
      font.family: look.sunFace; font.pixelSize: look.u(16)
      color: look.tone.soft
    }
  }

  // A hint: the plaque above the half plate.
  Rectangle {
    visible: look.stateDrawn === "hint"
    width: parent.width; height: look.u(82); radius: look.u(20)
    color: look.tone.ground
    Row {
      x: look.u(18); anchors.verticalCenter: parent.verticalCenter
      width: parent.width - look.u(36)
      spacing: look.u(14)
      Canvas {
        id: sign
        anchors.verticalCenter: parent.verticalCenter
        width: look.u(36); height: width
        renderStrategy: Canvas.Cooperative
        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          Basic.sign(ctx, look.noteKind, look.note, width, String(look.tone.accent), String(look.tone.alert))
        }
      }
      Column {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - look.u(50) - dots.width - look.u(14)
        Text {
          width: parent.width
          wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
          text: String(look.note.prompt || ""); textFormat: Text.PlainText
          font.family: look.sunFace; font.pixelSize: look.u(22); font.weight: Font.DemiBold
          lineHeight: 1.15
          color: look.tone.ink
        }
        Text {
          width: parent.width; elide: Text.ElideRight
          visible: look.note.steps > 1
          text: "Step " + look.note.step + " of " + look.note.steps; textFormat: Text.PlainText
          font.family: look.sunFace; font.pixelSize: look.u(16)
          color: look.tone.soft
        }
      }
      Row {
        id: dots
        anchors.verticalCenter: parent.verticalCenter
        spacing: look.u(6)
        Repeater {
          model: look.stateDrawn === "hint" && look.note.steps > 1 ? look.note.steps : 0
          delegate: Rectangle {
            required property int index
            width: look.u(8); height: width; radius: width / 2
            color: index < (look.note.step || 1) ? look.tone.accent : look.tone.track
          }
        }
      }
    }
  }

  function repaint() { dial.requestPaint(); shadowArt.requestPaint(); halfArt.requestPaint(); corona.requestPaint(); sign.requestPaint() }
  onWidthChanged: repaint()
  onToneChanged: repaint()
  onNoteChanged: repaint()
  onNChanged: repaint()
}
