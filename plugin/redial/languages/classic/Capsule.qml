pragma ComponentBehavior: Bound

import QtQuick
import "Drafting.js" as Drafting

// re:dial classic: the Capsule look. Drawn capsules round a hub; the chosen one slides outward and
// takes the accent; its name and click action ride a rim callout with a short leader. Turning a
// tool with a level lights a ring of 24 capsules. It draws its own plate, so it draws its own
// marks and its own rim label (no host callout). Mockup: DCAP in draft.js (2026-10-22).
LookBase {
  id: face

  // Contract additions (languages/README.md): a 400×400 plate in units, no host callout.
  readonly property size plateSize: Qt.size(400, 400)
  readonly property bool wantsCallout: false
  readonly property string kind: "face"

  readonly property real step: 360 / n
  readonly property real cx: width / 2
  readonly property real cy: height / 2

  readonly property int litCount: litOf(24)
  readonly property Item rimLabel: rim
  readonly property Item selection: capsules.count > 0 ? capsules.itemAt(Math.min(index, capsules.count - 1)) : null

  // The rim callout's angle. Live: the detent the hand is on, at once. Stepped: the short way
  // round, eased, so the last tool to the first moves one capsule forward.
  property real steppedDeg: -90
  Behavior on steppedDeg {
    id: stepEase
    NumberAnimation { duration: face.cfg.motionBase; easing.type: Easing.BezierSpline; easing.bezierCurve: face.easeInOut }
  }
  readonly property real leaderDeg: live ? -90 + Math.round(position) * step : steppedDeg
  property int _lastIndex: 0
  onIndexChanged: {
    var d = (index - _lastIndex) % n
    if (d > n / 2) d -= n
    if (d < -n / 2) d += n
    steppedDeg += d * step
    _lastIndex = index
  }
  onLiveChanged: if (!live) { stepEase.enabled = false; steppedDeg = -90 + Math.round(position) * step; stepEase.enabled = true }

  // The plate, construction, rings, and each state's drafting mark.
  Canvas {
    id: back
    anchors.fill: parent
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d"), L = String(face.line), A = String(face.accent)
      ctx.reset(); ctx.__w = face.lineScale
      ctx.fillStyle = face.plateFill; ctx.fillRect(0, 0, width, height)
      var cx = face.cx, cy = face.cy
      if (face.cfg.constructionLines) {
        Drafting.regMarks(ctx, width, height, face.u(10), face.u(14), L)
        Drafting.construction(ctx, width, height, cx, cy, face.u(70), face.u(160), face.u(18), L)
      }
      Drafting.ring(ctx, cx, cy, face.u(46), L, 0.22, 1)
      Drafting.ring(ctx, cx, cy, face.u(70), L, 0.10, 1)
      Drafting.ring(ctx, cx, cy, face.u(160), L, 0.30, 1)
      if (face.levelShown) {
        for (var i = 0; i < 24; i++) {
          var a = -90 + i * 15, p = Drafting.polar(cx, cy, face.u(112), a)
          ctx.save(); ctx.translate(p[0], p[1]); ctx.rotate((a + 90) * Math.PI / 180)
          Drafting.capsulePath(ctx, face.u(12), face.u(30), face.u(6))
          if (i < face.litCount) { ctx.fillStyle = Drafting.ink(A, 0.9); ctx.fill() }
          else { ctx.strokeStyle = Drafting.ink(L, 0.35); ctx.lineWidth = (1) * face.lineScale; ctx.stroke() }
          ctx.restore()
        }
      }
      if (face.noteKind === "cant")
        Drafting.hatch(ctx, function (c) { c.arc(cx, cy, face.u(160), 0, Math.PI * 2) }, width, height, L, 0.22, face.u(7))
      if (face.noteKind === "hint") Drafting.cloudCircle(ctx, cx, cy, face.u(62), 14, A)
    }
  }

  // The capsules: one per tool, the chosen one 12 units outward in the accent.
  Repeater {
    id: capsules
    model: face.levelShown ? 0 : face.tools.length
    delegate: Item {
      id: cap
      required property int index
      readonly property bool on: cap.index === face.index
      readonly property real deg: -90 + cap.index * face.step
      property real out: on && face.noteKind === "" ? face.u(12) : 0
      Behavior on out { NumberAnimation { duration: face.cfg.motionFast; easing.type: Easing.BezierSpline; easing.bezierCurve: face.easeOut } }
      width: face.u(32); height: face.u(68)
      x: face.cx + Math.cos(deg * Math.PI / 180) * (face.u(112) + out) - width / 2
      y: face.cy + Math.sin(deg * Math.PI / 180) * (face.u(112) + out) - height / 2
      opacity: face.ringInk
      Rectangle {
        anchors.fill: parent
        radius: width / 2
        rotation: cap.deg + 90
        color: cap.on ? Qt.rgba(face.accent.r, face.accent.g, face.accent.b, 0.16) : "transparent"
        border.width: 1
        border.color: cap.on ? Qt.rgba(face.accent.r, face.accent.g, face.accent.b, 0.9) : face.ink(0.4)
      }
      Text {
        anchors.centerIn: parent
        visible: face.cfg.showGlyphs
        text: face.tools[cap.index] ? (face.tools[cap.index].icon || "") : ""
        textFormat: Text.PlainText
        font.family: face.fontFamily
        font.pixelSize: face.u(17)
        color: cap.on ? face.accent : face.ink(0.55)
      }
    }
  }

  // The rim callout's leader: out from the rule, a short radial run, then a level tail.
  readonly property var leadFrom: Drafting.polar(cx, cy, u(160), leaderDeg)
  readonly property var leadTo: Drafting.polar(cx, cy, u(176), leaderDeg)
  readonly property bool leadRight: Math.cos(leaderDeg * Math.PI / 180) >= 0
  Canvas {
    id: lead
    anchors.fill: parent
    visible: face.stateDrawn === "ring" && face.tools.length > 0
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset(); ctx.__w = face.lineScale
      var p = face.leadFrom, q = face.leadTo
      ctx.strokeStyle = Drafting.ink(String(face.accent), 0.65); ctx.lineWidth = (1) * face.lineScale
      ctx.beginPath(); ctx.moveTo(p[0], p[1]); ctx.lineTo(q[0], q[1]); ctx.lineTo(q[0] + (face.leadRight ? 1 : -1) * face.u(14), q[1]); ctx.stroke()
    }
  }
  Column {
    id: rim
    visible: lead.visible
    readonly property real m: face.u(14)
    readonly property real wantX: face.leadRight ? face.leadTo[0] + face.u(18) : face.leadTo[0] - face.u(18) - width
    x: Math.max(m, Math.min(face.width - width - m, wantX))
    // Clamped against the plate edge (tools near 3 and 9 o'clock), the label would sit on the chosen
    // capsule, so it moves clear above the leader, or below it in the lower half.
    readonly property bool pushed: Math.abs(x - wantX) > 0.5
    readonly property real wantY: !pushed ? face.leadTo[1] - height / 2
                                  : face.leadTo[1] > face.cy + 0.5 ? face.leadTo[1] + face.u(22) : face.leadTo[1] - height - face.u(22)
    y: Math.max(m, Math.min(face.height - height - m, wantY))
    Text {
      text: face.tools[face.index] ? (face.tools[face.index].name || "") : ""
      textFormat: Text.PlainText
      font.family: face.fontFamily; font.pixelSize: face.u(14); font.bold: true
      color: face.accent
    }
    Row {
      spacing: face.u(6)
      Text {
        text: "CLICK"; textFormat: Text.PlainText
        font.family: face.fontFamily; font.pixelSize: face.u(11); font.letterSpacing: face.u(1.3)
        color: face.ink(face.language ? face.language.inkKey : 0.55)
      }
      Text {
        readonly property string hint: face.tools[face.index] ? (face.tools[face.index].hint || "") : ""
        text: hint !== "" ? hint : "nothing set"
        textFormat: Text.PlainText
        font.family: face.fontFamily; font.pixelSize: face.u(12)
        color: face.ink(hint !== "" ? 1 : 0.55)
      }
    }
  }

  // The hub: the chosen tool, the level, or the state's sign and message.
  Column {
    anchors.centerIn: parent
    width: face.u(108)
    spacing: face.u(4)
    Canvas {
      id: sign
      anchors.horizontalCenter: parent.horizontalCenter
      visible: face.noteKind === "hint" || face.noteKind === "cant"
      width: face.u(24); height: width
      renderStrategy: Canvas.Cooperative
      onPaint: {
        var ctx = getContext("2d")
        ctx.reset(); ctx.__w = face.lineScale
        Drafting.sign(ctx, face.noteKind, face.note, width, String(face.accent), String(face.alert))
      }
    }
    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.Wrap
      elide: Text.ElideRight; maximumLineCount: 3
      text: face.noteKind === "hint" ? (face.note.prompt || "")
          : face.noteKind === "cant" ? (face.note.title || "")
          : face.levelShown ? String(face.note.name || "").toUpperCase()
          : face.tools[face.index] ? (face.tools[face.index].name || "") : ""
      textFormat: Text.PlainText
      font.family: face.fontFamily; font.bold: true
      font.pixelSize: face.noteKind === "hint" || face.noteKind === "cant" || face.levelShown ? face.u(12) : face.u(15)
      font.letterSpacing: face.levelShown ? face.u(1.3) : 0
      color: face.line
    }
    Text {
      objectName: "valueText"
      anchors.horizontalCenter: parent.horizontalCenter
      visible: face.levelShown
      text: face.valueText
      textFormat: Text.PlainText
      font.family: face.fontFamily; font.pixelSize: face.u(28)
      color: face.accent
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      visible: face.stateDrawn === "ring"
      text: "HOLD · TURN"
      textFormat: Text.PlainText
      font.family: face.fontFamily; font.pixelSize: face.u(10); font.letterSpacing: face.u(1.2)
      color: face.ink(face.language ? face.language.inkKey : 0.55)
    }
  }

  function repaint() { back.requestPaint(); lead.requestPaint(); sign.requestPaint() }
  onWidthChanged: repaint()
  onHeightChanged: repaint()
  onNoteKindChanged: repaint()
  onNoteChanged: repaint()
  onLitCountChanged: back.requestPaint()
  onLeaderDegChanged: lead.requestPaint()
  onLineChanged: repaint()
  onAccentChanged: repaint()
  Connections { target: face.cfg; function onChanged() { face.repaint() } }
}
