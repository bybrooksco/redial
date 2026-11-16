pragma ComponentBehavior: Bound

import QtQuick
import "Drafting.js" as Drafting

// re:dial classic: the Repair tag look. The dial's tools as a checklist on a drawn tag (dimensioned
// like a part, an eyelet, a dashed string down to the dial); an outlined marker sits on the chosen
// row and the host's callout carries its notes. A level is punched holes; can't act stamps the
// tag once. Mockup: DTAG in classic3.js.
LookBase {
  id: face

  readonly property size plateSize: Qt.size(640, 330)
  readonly property bool wantsCallout: true
  readonly property string kind: "face"
  readonly property real calloutX: 40 + 360 + 56

  readonly property int litCount: litOf(10)
  readonly property Item selection: marker
  property alias stamp: stampText

  // The tag, in units (mockup values).
  readonly property real tx: u(40)
  readonly property real ty: u(62)
  readonly property real tw: u(360)
  readonly property real th: u(196)
  readonly property real ex: tx + u(30)
  readonly property real ey: ty + th / 2
  readonly property real fx: tx + u(78)
  readonly property real fw: tw - u(96)
  // Four rows by two columns; past eight tools the rows close up so all fit the tag.
  readonly property int rows: Math.max(4, Math.ceil(n / 2))
  readonly property real rowPitch: u(34) * 3 / (rows - 1)
  function col(i) { return Math.floor(i / rows) }
  function row(i) { return i % rows }
  readonly property bool fields: levelShown || noteKind === "cant"

  // Holes: the level's tenths, punched (filled, as a drawing shows a cut).
  function holeX(i) { return fx + u(10) + i * (fw - u(20)) / 9 }
  readonly property real holeY: ty + u(154)

  // The leader out to the callout: from the marker (ring), the last punched hole (level), or the
  // tag's corner (can't act).
  readonly property int chosen: Math.min(index, n - 1)
  readonly property var leadFrom: noteKind === "cant" ? [tx + tw, ty + u(30)]
                                : levelShown ? [holeX(Math.max(0, litCount - 1)), holeY - u(8)]
                                : [marker.x + marker.width, marker.y + u(15)]
  readonly property var leadKnee: noteKind === "cant" ? [leadFrom[0] + u(16), leadFrom[1]]
                                : levelShown ? [leadFrom[0] + u(16), holeY - u(30)]
                                : [leadFrom[0] + u(14), leadFrom[1]]
  readonly property real leaderY: leadKnee[1]
  readonly property real leaderEndY: landY >= 0 ? landY : leaderY
  readonly property real leaderEndX: tx + tw + u(44)

  Canvas {
    id: back
    anchors.fill: parent
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d"), L = String(face.line), A = String(face.accent), k = face.unit
      var tx = face.tx, ty = face.ty, tw = face.tw, th = face.th, ex = face.ex, ey = face.ey, i
      ctx.reset(); ctx.__w = face.lineScale
      ctx.fillStyle = face.plateFill; ctx.fillRect(0, 0, width, height)
      if (face.cfg.constructionLines) {
        Drafting.regMarks(ctx, width, height, face.u(10), face.u(14), L)
        Drafting.line(ctx, 0, ey, width, ey, L, 0.1, 1); Drafting.node(ctx, width - face.u(10), ey, face.u(3), L, 0.35)
      }
      // The dimension across the top, the way a part is drawn.
      Drafting.line(ctx, tx, ty - face.u(30), tx, ty - face.u(6), L, 0.35, 1)
      Drafting.line(ctx, tx + tw, ty - face.u(30), tx + tw, ty - face.u(6), L, 0.35, 1)
      var dy = ty - face.u(22), h = face.u(5)
      Drafting.line(ctx, tx + face.u(4), dy, tx + tw - face.u(4), dy, L, 0.5, 1)
      ctx.strokeStyle = Drafting.ink(L, 0.6); ctx.lineWidth = (1.2) * face.lineScale; ctx.beginPath()
      ctx.moveTo(tx + face.u(4) + h, dy - h * 0.8); ctx.lineTo(tx + face.u(4), dy); ctx.lineTo(tx + face.u(4) + h, dy + h * 0.8)
      ctx.moveTo(tx + tw - face.u(4) - h, dy - h * 0.8); ctx.lineTo(tx + tw - face.u(4), dy); ctx.lineTo(tx + tw - face.u(4) - h, dy + h * 0.8); ctx.stroke()
      // The tag: chamfered on the eyelet end, hatched when the dial can't act.
      var c = face.u(26)
      function outline(g) { g.moveTo(tx + c, ty); g.lineTo(tx + tw, ty); g.lineTo(tx + tw, ty + th); g.lineTo(tx + c, ty + th); g.lineTo(tx, ty + th - c); g.lineTo(tx, ty + c); g.closePath() }
      if (face.noteKind === "cant") Drafting.hatch(ctx, outline, width, height, L, 0.12, face.u(7))
      ctx.beginPath(); outline(ctx); ctx.strokeStyle = Drafting.ink(L, 0.6); ctx.lineWidth = (1.2) * face.lineScale; ctx.stroke()
      // The eyelet, its string, and the stub line between eyelet and fields.
      Drafting.ring(ctx, ex, ey, face.u(16), L, 0.35, 1); Drafting.ring(ctx, ex, ey, face.u(8), L, 0.7, 1)
      Drafting.line(ctx, ex - face.u(22), ey, ex + face.u(22), ey, L, 0.3, 1); Drafting.line(ctx, ex, ey - face.u(22), ex, ey + face.u(22), L, 0.3, 1)
      ctx.strokeStyle = Drafting.ink(L, 0.5); ctx.lineWidth = (1) * face.lineScale; ctx.setLineDash([6 * k, 4 * k]); ctx.beginPath()
      ctx.moveTo(ex, ey); ctx.bezierCurveTo(ex - face.u(40), ey + face.u(30), ex - face.u(10), height - face.u(40), ex - face.u(46), height); ctx.stroke(); ctx.setLineDash([])
      Drafting.line(ctx, tx + face.u(62), ty, tx + face.u(62), ty + th, L, 0.3, 1)
      if (face.fields) {
        Drafting.line(ctx, face.fx, ty + face.u(76), face.fx + face.fw, ty + face.u(76), L, 0.3, 1)
        Drafting.line(ctx, face.fx, ty + face.u(124), face.fx + face.fw, ty + face.u(124), L, 0.3, 1)
        for (i = 0; i < 10; i++) {
          ctx.beginPath(); ctx.arc(face.holeX(i), face.holeY, face.u(7), 0, Math.PI * 2)
          if (i < face.litCount) { ctx.fillStyle = Drafting.ink(A, 0.9); ctx.fill() }
          ctx.strokeStyle = Drafting.ink(L, 0.5); ctx.lineWidth = (1) * face.lineScale; ctx.stroke()
        }
      } else {
        for (i = 0; i < face.tools.length; i++) {
          var bx = face.fx + face.col(i) * (face.fw / 2), by = ty + face.u(44) + face.row(i) * face.rowPitch
          ctx.strokeStyle = Drafting.ink(L, 0.5 * face.ringInk); ctx.lineWidth = (1) * face.lineScale
          ctx.strokeRect(bx, by - face.u(11), face.u(12), face.u(12))
          if (i === face.chosen && face.noteKind === "") {
            ctx.strokeStyle = Drafting.ink(A, 1); ctx.lineWidth = (1.6) * face.lineScale; ctx.beginPath()
            ctx.moveTo(bx + face.u(2), by - face.u(5)); ctx.lineTo(bx + face.u(5), by - face.u(1)); ctx.lineTo(bx + face.u(12), by - face.u(10)); ctx.stroke()
          }
        }
      }
      var tb = Drafting.titleBlock(ctx, width, height, face.unit, L)
      titleLeft.x = tb[0]; titleRight.x = tb[1]; titleLeft.y = titleRight.y = tb[2] - titleLeft.baselineOffset
    }
  }

  Text {
    x: face.tx + face.tw / 2 - width / 2; y: face.ty - face.u(27) - height + face.u(3)
    text: "RE:DIAL REPAIR TAG"; textFormat: Text.PlainText
    font.family: face.fontFamily; font.pixelSize: face.u(11); font.letterSpacing: face.u(1.3)
    color: face.ink(0.6)
  }

  // The checklist.
  Text {
    visible: !face.fields
    x: face.fx; y: face.ty + face.u(6)
    text: "TOOLS ON THIS DIAL"; textFormat: Text.PlainText
    font.family: face.fontFamily; font.pixelSize: face.u(11); font.letterSpacing: face.u(1.3)
    color: face.ink(face.inkKey)
  }
  Repeater {
    model: face.fields ? 0 : face.tools.length
    delegate: Row {
      id: item
      required property int index
      readonly property bool on: item.index === face.chosen && face.noteKind === ""
      x: face.fx + face.col(item.index) * (face.fw / 2) + face.u(20)
      y: face.ty + face.u(44) + face.row(item.index) * face.rowPitch - face.u(5) - height / 2
      spacing: face.u(7)
      opacity: face.ringInk
      Text {
        visible: face.cfg.showGlyphs
        text: face.toolIcon(item.index); textFormat: Text.PlainText
        font.family: face.fontFamily; font.pixelSize: face.u(13)
        color: item.on ? face.accent : face.line
      }
      Text {
        width: Math.min(implicitWidth, face.fw / 2 - face.u(48)); elide: Text.ElideRight
        text: face.toolName(item.index); textFormat: Text.PlainText
        font.family: face.fontFamily; font.pixelSize: face.u(13); font.bold: item.on
        color: item.on ? face.accent : face.line
      }
    }
  }
  Rectangle {
    id: marker
    visible: !face.fields && face.tools.length > 0
    x: face.fx - face.u(6) + face.col(face.chosen) * (face.fw / 2)
    y: face.ty + face.u(44) - face.u(22) + face.row(face.chosen) * face.rowPitch
    width: face.fw / 2 - face.u(4); height: face.u(30)
    color: "transparent"
    border.width: 1.2; border.color: face.accent
    opacity: face.noteKind === "" ? 1 : face.ringInk
    Behavior on x { NumberAnimation { duration: face.cfg.motionBase; easing.type: Easing.BezierSpline; easing.bezierCurve: face.easeInOut } }
    Behavior on y { NumberAnimation { duration: face.cfg.motionBase; easing.type: Easing.BezierSpline; easing.bezierCurve: face.easeInOut } }
  }

  // The level fields: the tool, its level, the holes.
  Column {
    visible: face.fields
    x: face.fx; y: face.ty + face.u(14); width: face.fw
    Text {
      text: "TOOL"; textFormat: Text.PlainText
      font.family: face.fontFamily; font.pixelSize: face.u(11); font.letterSpacing: face.u(1.3)
      color: face.ink(face.inkKey)
    }
    Row {
      spacing: face.u(8)
      Text {
        text: face.toolIcon(face.chosen); textFormat: Text.PlainText
        font.family: face.fontFamily; font.pixelSize: face.u(18); color: face.accent
      }
      Text {
        width: Math.min(implicitWidth, face.fw - face.u(30)); elide: Text.ElideRight
        text: face.levelShown ? String(face.note.name || face.toolName(face.chosen)) : face.toolName(face.chosen)
        textFormat: Text.PlainText
        font.family: face.fontFamily; font.pixelSize: face.u(18); font.bold: true; color: face.line
      }
    }
  }
  Item {
    visible: face.levelShown
    x: face.fx; y: face.ty + face.u(84); width: face.fw; height: valueTextItem.height
    Text {
      anchors.baseline: valueTextItem.baseline
      text: "LEVEL"; textFormat: Text.PlainText
      font.family: face.fontFamily; font.pixelSize: face.u(11); font.letterSpacing: face.u(1.3)
      color: face.ink(face.inkKey)
    }
    Text {
      id: valueTextItem
      anchors.right: parent.right
      text: face.valueText; textFormat: Text.PlainText
      font.family: face.fontFamily; font.pixelSize: face.u(28); color: face.accent
    }
  }

  // The stamp: lands once when the dial can't act (170 ms after a 90 ms pause).
  Rectangle {
    visible: face.noteKind === "cant"
    x: face.fx + face.u(40); y: face.ty + face.u(66)
    width: stampText.width + face.u(28); height: stampText.height + face.u(4)
    color: face.ground
    border.width: Math.max(1, face.u(2)); border.color: face.alert
    rotation: stampText.turn
    scale: stampText.scale
    opacity: stampText.opacity
    Text {
      id: stampText
      property real turn: -6
      anchors.centerIn: parent
      readonly property string word: ({ asleep: "ASLEEP", waiting: "NO DIAL" })[face.note.reason] || "CAN'T ACT"
      text: word; textFormat: Text.PlainText
      font.family: face.fontFamily; font.pixelSize: face.u(24); font.bold: true; font.letterSpacing: face.u(2.9)
      color: face.alert
    }
  }
  SequentialAnimation {
    id: land
    PropertyAction { target: stampText; properties: "opacity"; value: 0 }
    PropertyAction { target: stampText; property: "scale"; value: 1.18 }
    PropertyAction { target: stampText; property: "turn"; value: -11 }
    PauseAnimation { duration: 90 }
    ParallelAnimation {
      NumberAnimation { target: stampText; property: "opacity"; to: 1; duration: 170; easing.type: Easing.BezierSpline; easing.bezierCurve: face.easeOut }
      NumberAnimation { target: stampText; property: "scale"; to: 1; duration: 170; easing.type: Easing.BezierSpline; easing.bezierCurve: face.easeOut }
      NumberAnimation { target: stampText; property: "turn"; to: -6; duration: 170; easing.type: Easing.BezierSpline; easing.bezierCurve: face.easeOut }
    }
  }
  onNoteKindChanged: {
    if (noteKind === "cant" && cfg.motionBase > 0) land.restart()
    else { land.stop(); stampText.opacity = 1; stampText.scale = 1; stampText.turn = -6 }
    repaint()
  }

  // The leader out to the host's callout.
  Canvas {
    id: lead
    anchors.fill: parent
    visible: face.cfg.showCallout && (face.tools.length > 0 || face.noteKind !== "")
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d"), A = String(face.accent)
      ctx.reset(); ctx.__w = face.lineScale
      var p = face.leadFrom, kn = face.leadKnee, ey = face.leaderEndY, ex = face.leaderEndX
      var bent = Math.abs(ey - kn[1]) > 0.5, kx = bent ? Math.max(p[0], kn[0]) + face.u(18) : kn[0], ky = bent ? ey : kn[1]
      ctx.strokeStyle = Drafting.ink(A, 0.65); ctx.lineWidth = (1) * face.lineScale
      ctx.beginPath(); ctx.moveTo(p[0], p[1]); ctx.lineTo(kx, ky); ctx.lineTo(ex, ey); ctx.stroke()
      Drafting.node(ctx, p[0], p[1], face.u(3), A, 1)
      Drafting.node(ctx, ex, ey, face.u(2.2), A, 0.85)
    }
  }

  Text {
    id: titleLeft
    text: "RE:DIAL"; textFormat: Text.PlainText
    font.family: face.fontFamily; font.pixelSize: face.u(11); font.letterSpacing: face.u(1.3)
    color: face.ink(0.7)
  }
  Text {
    id: titleRight
    width: face.u(118); elide: Text.ElideRight
    text: face.noteKind === "cant" ? "STATUS: " + stampText.word
        : face.levelShown ? "TAG 1/1"
        : face.noteKind === "hint" ? "NOTE " + (face.note.step || 1)
        : "ITEM " + (face.chosen + 1) + "/" + face.n
    textFormat: Text.PlainText
    font.family: face.fontFamily; font.pixelSize: face.u(11); font.letterSpacing: face.u(1.3)
    color: face.ink(0.7)
  }

  function repaint() { back.requestPaint(); lead.requestPaint() }
  onWidthChanged: repaint()
  onHeightChanged: repaint()
  onNoteChanged: repaint()
  onIndexChanged: back.requestPaint()
  onNChanged: repaint()
  onLineChanged: repaint()
  onAccentChanged: repaint()
  onLeaderEndYChanged: lead.requestPaint()
  onLeadFromChanged: lead.requestPaint()
  Connections { target: face.cfg; function onChanged() { face.repaint() } }
}
