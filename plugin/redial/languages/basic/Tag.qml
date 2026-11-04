pragma ComponentBehavior: Bound

import QtQuick
import "Basic.js" as Basic

// re:dial basic: the Repair Tag look, set in Bricolage on the paper tones. A landscape luggage tag
// on its string, eyelet at the left; it swings from the eyelet as it opens and never scales. The
// ring is a two-column checklist with an accent marker; a level punches real holes through the
// paper (the desktop shows through); a hint is a small tag hung over the tool's tag; can't act
// stamps it once. Mockup: TAG in index.html.
LookBase {
  id: look

  readonly property real noteH: noteKind === "hint" ? (note.steps > 1 ? 124 : 104) : 0
  readonly property real mainY: noteH > 0 ? noteH + 10 : 0
  readonly property size plateSize: stateDrawn === "ring" ? Qt.size(350, 240) : Qt.size(340, mainY + 172)
  readonly property bool wantsCallout: false
  readonly property string kind: "face"

  readonly property var p: paperTone
  readonly property string tagFace: language && language.faceTag !== "" ? language.faceTag : face
  readonly property int litCount: litOf(10)
  readonly property Item selection: marker
  property alias stamp: stampText
  readonly property alias swing: swingRot
  readonly property int picked: chosen

  // Four rows by two columns; past eight tools the rows close up so all fit the list.
  readonly property int rows: Math.max(4, Math.ceil(n / 2))
  readonly property real rowPitch: u(34) * 3 / (rows - 1)
  readonly property real cellH: Math.min(u(30), rowPitch - u(2))
  function col(i) { return Math.floor(i / rows) }
  function row(i) { return i % rows }

  // The swing: from the eyelet, -3° to a .7° overshoot and home (260 ms).
  transform: Rotation { id: swingRot; origin.x: look.u(26); origin.y: look.u(look.mainY + (look.stateDrawn === "ring" ? 120 : 86)) }
  SequentialAnimation {
    id: swingIn
    NumberAnimation { target: swingRot; property: "angle"; from: -3; to: 0.7; duration: 187; easing.type: Easing.BezierSpline; easing.bezierCurve: look.easeDrawer }
    NumberAnimation { target: swingRot; property: "angle"; to: 0; duration: 73; easing.type: Easing.InOutQuad }
  }
  Component.onCompleted: if (cfg.motionBase > 0) swingIn.start()

  // A tag: chamfered paper with a reinforced eyelet; `punched` holes of `holes` are cut through.
  component Paper: Canvas {
    id: paper
    property int holes: 0
    property int punched: 0
    property real holeY: 132
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d"), k = look.unit, w = width, h = height, P = look.p
      ctx.reset()
      ctx.beginPath()
      ctx.moveTo(24 * k, 0); ctx.lineTo(w - 12 * k, 0); ctx.quadraticCurveTo(w, 0, w, 12 * k)
      ctx.lineTo(w, h - 12 * k); ctx.quadraticCurveTo(w, h, w - 12 * k, h)
      ctx.lineTo(24 * k, h); ctx.lineTo(0, h - 24 * k); ctx.lineTo(0, 24 * k); ctx.closePath()
      ctx.fillStyle = String(P.paper); ctx.fill()
      ctx.fillStyle = String(P.surface)
      ctx.beginPath(); ctx.arc(26 * k, h / 2, 13 * k, 0, Math.PI * 2); ctx.fill()
      for (var i = 0; i < paper.holes; i++) { ctx.beginPath(); ctx.arc((66 + i * 26) * k, paper.holeY * k, 8.5 * k, 0, Math.PI * 2); ctx.fill() }
      // The cuts: the eyelet, and the punched holes, straight through the paper.
      ctx.globalCompositeOperation = "destination-out"
      ctx.beginPath(); ctx.arc(26 * k, h / 2, 7 * k, 0, Math.PI * 2); ctx.fill()
      for (var j = 0; j < Math.min(paper.punched, paper.holes); j++) { ctx.beginPath(); ctx.arc((66 + j * 26) * k, paper.holeY * k, 8 * k, 0, Math.PI * 2); ctx.fill() }
      ctx.globalCompositeOperation = "source-over"
    }
    onPunchedChanged: requestPaint()
    onHolesChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    Connections { target: look; function onPChanged() { paper.requestPaint() } }
  }
  // The string, from the eyelet down and away to the left.
  component TagString: Canvas {
    id: str
    property real tagH: 172
    x: -look.u(60); width: look.u(90); height: look.u(tagH + 60)
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d"), k = look.unit, ox = 60 * k, h = tagH
      ctx.reset(); ctx.strokeStyle = String(look.p.string); ctx.lineWidth = 3 * k; ctx.lineCap = "round"
      ctx.beginPath(); ctx.moveTo(ox + 26 * k, h / 2 * k)
      ctx.bezierCurveTo(ox - 4 * k, (h / 2 + 4) * k, ox - 24 * k, (h / 2 + 22) * k, ox - 48 * k, (h + 56) * k); ctx.stroke()
    }
    Connections { target: look; function onPChanged() { str.requestPaint() } }
  }

  // ---- the ring: the checklist tag ----
  Item {
    visible: look.stateDrawn === "ring"
    anchors.fill: parent
    TagString { tagH: 240 }
    Paper { width: look.u(350); height: look.u(240) }
    Text {
      x: look.u(54); y: look.u(16)
      text: "re:dial"; textFormat: Text.PlainText
      font.family: look.tagFace; font.pixelSize: look.u(13); font.weight: Font.DemiBold
      color: look.p.soft
    }
    Text {
      x: look.u(330) - width; y: look.u(16)
      text: "Hold, then turn"; textFormat: Text.PlainText
      font.family: look.tagFace; font.pixelSize: look.u(13); font.weight: Font.DemiBold
      color: look.p.soft
    }
    Item {
      id: list
      x: look.u(54); y: look.u(42); width: look.u(272); height: look.u(136)
      Rectangle {
        id: marker
        x: look.col(look.picked) * look.u(136); y: look.row(look.picked) * look.rowPitch
        width: look.u(132); height: look.cellH
        topLeftRadius: look.u(4); topRightRadius: look.u(10); bottomRightRadius: look.u(6); bottomLeftRadius: look.u(3)
        color: look.p.accent
        Behavior on x { NumberAnimation { duration: look.cfg.motionFast; easing.type: Easing.BezierSpline; easing.bezierCurve: look.easeOut } }
        Behavior on y { NumberAnimation { duration: look.cfg.motionFast; easing.type: Easing.BezierSpline; easing.bezierCurve: look.easeOut } }
      }
      Repeater {
        model: look.stateDrawn === "ring" ? look.tools.length : 0
        delegate: Row {
          id: cell
          required property int index
          readonly property bool on: cell.index === look.picked
          x: look.col(cell.index) * look.u(136) + look.u(9)
          y: look.row(cell.index) * look.rowPitch
          height: look.cellH
          spacing: look.u(9)
          Text {
            width: look.u(20); anchors.verticalCenter: parent.verticalCenter
            visible: look.cfg.showGlyphs
            text: look.toolIcon(cell.index); textFormat: Text.PlainText
            font.family: look.fontFamily; font.pixelSize: Math.min(look.u(18), look.cellH * 0.62)
            color: cell.on ? look.p.onaccent : look.p.ink
          }
          Text {
            width: look.u(132 - 9 - 9 - 20 - 9); anchors.verticalCenter: parent.verticalCenter; elide: Text.ElideRight
            text: look.toolName(cell.index); textFormat: Text.PlainText
            font.family: look.tagFace; font.pixelSize: Math.min(look.u(18), look.cellH * 0.62); font.weight: Font.DemiBold
            color: cell.on ? look.p.onaccent : look.p.ink
          }
        }
      }
    }
    Row {
      x: look.u(54); y: look.u(192)
      spacing: look.u(6)
      Text {
        id: tagName
        width: Math.min(implicitWidth, look.u(150)); elide: Text.ElideRight
        text: look.toolName(look.picked); textFormat: Text.PlainText
        font.family: look.tagFace; font.pixelSize: look.u(16); font.weight: Font.Bold
        color: look.p.ink
      }
      Text {
        anchors.baseline: tagName.baseline
        width: Math.min(implicitWidth, look.u(270 - 6) - tagName.width); elide: Text.ElideRight
        text: look.pressText(look.picked); textFormat: Text.PlainText
        font.family: look.tagFace; font.pixelSize: look.u(16)
        color: look.p.soft
      }
    }
  }

  // ---- a hint: the small tag hung over the tool's tag ----
  Item {
    visible: look.stateDrawn === "hint"
    x: look.u(50); width: look.u(290); height: look.u(look.noteH)
    Canvas {
      id: hintString
      x: look.u(30); y: parent.height - look.u(4); width: look.u(20); height: look.u(40)
      renderStrategy: Canvas.Cooperative
      onPaint: {
        var ctx = getContext("2d"), k = look.unit
        ctx.reset(); ctx.strokeStyle = String(look.p.string); ctx.lineWidth = 3 * k; ctx.lineCap = "round"
        ctx.beginPath(); ctx.moveTo(2 * k, 0); ctx.bezierCurveTo(12 * k, 10 * k, 6 * k, 18 * k, 14 * k, 34 * k); ctx.stroke()
      }
    }
    Paper { anchors.fill: parent }
    Row {
      x: look.u(50); y: look.u(14); width: parent.width - look.u(66)
      spacing: look.u(12)
      Canvas {
        id: sign
        width: look.u(34); height: width
        renderStrategy: Canvas.Cooperative
        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          Basic.sign(ctx, look.noteKind, look.note, width, String(look.p.accent), String(look.p.alert))
        }
      }
      Column {
        width: parent.width - look.u(46)
        Text {
          width: parent.width
          wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
          text: String(look.note.prompt || ""); textFormat: Text.PlainText
          font.family: look.tagFace; font.pixelSize: look.u(19); font.weight: Font.ExtraBold
          lineHeight: 1.15
          color: look.p.ink
        }
        Text {
          width: parent.width; elide: Text.ElideRight
          visible: look.note.steps > 1
          text: "Step " + look.note.step + " of " + look.note.steps; textFormat: Text.PlainText
          font.family: look.tagFace; font.pixelSize: look.u(14)
          color: look.p.soft
        }
        Row {
          visible: look.note.steps > 1
          topPadding: look.u(8)
          spacing: look.u(6)
          Repeater {
            model: look.stateDrawn === "hint" && look.note.steps > 1 ? look.note.steps : 0
            delegate: Rectangle {
              required property int index
              readonly property bool done: index < (look.note.step || 1)
              width: look.u(10); height: width; radius: width / 2
              color: done ? look.p.ink : "transparent"
              border.width: done ? 0 : look.u(2); border.color: look.p.muted
            }
          }
        }
      }
    }
  }

  // ---- turn, hint and can't act: the tool's tag ----
  Item {
    visible: look.stateDrawn !== "ring"
    y: look.u(look.mainY); width: look.u(340); height: look.u(172)
    TagString { tagH: 172 }
    Paper {
      anchors.fill: parent
      holes: look.noteKind === "cant" ? 0 : 10
      punched: look.litCount
    }
    Item {
      anchors.fill: parent
      opacity: look.noteKind === "cant" ? 0.3 : 1
      Text {
        x: look.u(54); y: look.u(16)
        text: "re:dial"; textFormat: Text.PlainText
        font.family: look.tagFace; font.pixelSize: look.u(13); font.weight: Font.DemiBold
        color: look.p.soft
      }
      Row {
        x: look.u(54); y: look.u(36)
        width: look.u(340 - 54 - 22) - (look.levelShown ? value.width : 0)
        spacing: look.u(10)
        Text {
          anchors.verticalCenter: parent.verticalCenter
          visible: look.cfg.showGlyphs
          text: look.toolIcon(look.chosen); textFormat: Text.PlainText
          font.family: look.fontFamily; font.pixelSize: look.u(25)
          color: look.p.ink
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - look.u(40); elide: Text.ElideRight
          text: look.levelShown ? String(look.note.name || "") : look.toolName(look.chosen); textFormat: Text.PlainText
          font.family: look.tagFace; font.pixelSize: look.u(25); font.weight: Font.ExtraBold
          color: look.p.ink
        }
      }
      Text {
        id: value
        x: look.u(340 - 22) - width; y: look.u(30)
        visible: look.levelShown
        text: look.valueText; textFormat: Text.PlainText
        font.family: look.tagFace; font.pixelSize: look.u(44); font.weight: Font.ExtraBold
        color: look.p.ink
      }
    }
    Text {
      x: look.u(340 - 22) - width; y: look.u(172 - 12) - height
      visible: look.noteKind !== "cant"
      width: Math.min(implicitWidth, look.u(200)); elide: Text.ElideRight
      text: look.pressText(look.chosen); textFormat: Text.PlainText
      font.family: look.tagFace; font.pixelSize: look.u(14)
      color: look.p.soft
    }
    // Can't act: the stamp, and the reason under it.
    Rectangle {
      visible: look.noteKind === "cant"
      x: look.u(98); y: look.u(40)
      width: stampText.width + look.u(32); height: stampText.height + look.u(4)
      color: "transparent"; radius: look.u(8)
      border.width: look.u(4); border.color: look.p.alert
      rotation: stampText.turn
      scale: stampText.scale
      opacity: stampText.opacity
      Text {
        id: stampText
        property real turn: -6
        anchors.centerIn: parent
        readonly property string word: ({ asleep: "ASLEEP", waiting: "NO DIAL" })[look.note.reason] || "CAN'T ACT"
        text: word; textFormat: Text.PlainText
        font.family: look.tagFace; font.pixelSize: look.u(34); font.weight: Font.ExtraBold
        color: look.p.alert
      }
    }
    Column {
      visible: look.noteKind === "cant"
      x: look.u(54); width: look.u(340 - 54 - 22)
      y: look.u(172 - 14) - height
      Text {
        width: parent.width; elide: Text.ElideRight
        text: String(look.note.title || ""); textFormat: Text.PlainText
        font.family: look.tagFace; font.pixelSize: look.u(17); font.weight: Font.ExtraBold
        color: look.p.ink
      }
      Text {
        width: parent.width; elide: Text.ElideRight
        visible: text !== ""
        text: String(look.note.line || ""); textFormat: Text.PlainText
        font.family: look.tagFace; font.pixelSize: look.u(15)
        color: look.p.soft
      }
    }
  }

  SequentialAnimation {
    id: land
    PropertyAction { target: stampText; property: "opacity"; value: 0 }
    PropertyAction { target: stampText; property: "scale"; value: 1.18 }
    PropertyAction { target: stampText; property: "turn"; value: -11 }
    PauseAnimation { duration: 90 }
    ParallelAnimation {
      NumberAnimation { target: stampText; property: "opacity"; to: 1; duration: 170; easing.type: Easing.BezierSpline; easing.bezierCurve: look.easeOut }
      NumberAnimation { target: stampText; property: "scale"; to: 1; duration: 170; easing.type: Easing.BezierSpline; easing.bezierCurve: look.easeOut }
      NumberAnimation { target: stampText; property: "turn"; to: -6; duration: 170; easing.type: Easing.BezierSpline; easing.bezierCurve: look.easeOut }
    }
  }
  onNoteKindChanged: {
    if (noteKind === "cant" && cfg.motionBase > 0) land.restart()
    else { land.stop(); stampText.opacity = 1; stampText.scale = 1; stampText.turn = -6 }
    sign.requestPaint(); hintString.requestPaint()
  }
  onNoteChanged: sign.requestPaint()
}
