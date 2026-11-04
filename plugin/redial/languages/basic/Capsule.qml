pragma ComponentBehavior: Bound

import QtQuick

// re:dial basic: the Capsule look. Filled capsules round a rimmed disc; the chosen one slides 12
// outward and takes the accent; the centre disc names it in large type. Turning a level lights a
// ring of 20 segments round the value. Mockup: CAP in looks.js (2026-10-22).
LookBase {
  id: look

  readonly property size plateSize: Qt.size(336, 336)
  readonly property bool wantsCallout: false
  readonly property string kind: "face"

  readonly property real c: width / 2
  readonly property real step: 360 / n
  readonly property int litCount: litOf(20)
  readonly property int picked: live ? Math.round(((position % n) + n) % n) % n : chosen
  readonly property Item selection: caps.count > picked ? caps.itemAt(picked) : null

  // The disc: a rim, the plate inside it.
  Rectangle { anchors.fill: parent; radius: width / 2; color: look.tone.rim }
  Rectangle { anchors.fill: parent; anchors.margins: look.u(7); radius: width / 2; color: look.tone.ground }

  // The level: 20 segments, the first round(v/5) lit.
  Repeater {
    model: look.levelShown ? 20 : 0
    delegate: Rectangle {
      required property int index
      readonly property real a: -90 + index * 18
      x: look.c + Math.cos(a * Math.PI / 180) * look.u(136) - width / 2
      y: look.c + Math.sin(a * Math.PI / 180) * look.u(136) - height / 2
      width: look.u(10); height: look.u(26); radius: width / 2
      rotation: a + 90
      color: index < look.litCount ? look.tone.accent : look.tone.track
      Behavior on color { ColorAnimation { duration: look.cfg.motionFast } }
    }
  }

  // The capsules.
  Repeater {
    id: caps
    model: look.levelShown ? 0 : look.tools.length
    delegate: Item {
      id: cap
      required property int index
      readonly property int capIndex: cap.index
      readonly property bool on: cap.index === look.picked && look.noteKind === ""
      readonly property real a: -90 + cap.index * look.step
      property real out: on ? look.u(12) : 0
      Behavior on out { NumberAnimation { duration: look.cfg.motionBase * 0.75; easing.type: Easing.BezierSpline; easing.bezierCurve: look.easeInOut } }
      width: look.u(38); height: look.u(76)
      x: look.c + Math.cos(a * Math.PI / 180) * (look.u(114) + out) - width / 2
      y: look.c + Math.sin(a * Math.PI / 180) * (look.u(114) + out) - height / 2
      opacity: look.ringInk
      Rectangle {
        anchors.fill: parent; radius: width / 2
        rotation: cap.a + 90
        color: cap.on ? look.tone.accent : look.tone.surface
        Behavior on color { ColorAnimation { duration: look.cfg.motionFast } }
      }
      Text {
        anchors.centerIn: parent
        visible: look.cfg.showGlyphs
        text: look.toolIcon(cap.index); textFormat: Text.PlainText
        font.family: look.fontFamily; font.pixelSize: look.u(19)
        color: cap.on ? look.tone.onaccent : look.tone.soft
      }
    }
  }

  // The centre disc.
  Rectangle {
    readonly property real r: look.u(look.levelShown ? 100 : look.noteKind !== "" ? 92 : 72)
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
        font.family: look.face; font.pixelSize: look.u(58); font.weight: Font.Bold
        color: look.tone.ink
      }
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: look.u(6)
        Text {
          text: look.toolIcon(look.chosen); textFormat: Text.PlainText
          font.family: look.fontFamily; font.pixelSize: look.u(21); color: look.tone.accent
        }
        Text {
          text: String(look.note.name || ""); textFormat: Text.PlainText
          font.family: look.face; font.pixelSize: look.u(21); font.weight: Font.DemiBold
          color: look.tone.ink
        }
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: look.pressText(look.chosen); textFormat: Text.PlainText
        font.family: look.face; font.pixelSize: look.u(14)
        color: look.tone.soft
      }
    }
    Message {
      anchors.centerIn: parent
      width: parent.width - look.u(24)
      visible: look.noteKind === "hint" || look.noteKind === "cant"
      host: look
      big: 21; small: 14
    }
  }
}
