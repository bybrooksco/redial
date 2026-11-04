pragma ComponentBehavior: Bound

import QtQuick

// re:dial basic: the Deck layout, a fanned hand of cards about 540 wide. The front card is the
// chosen tool; the hand slides as the dial turns and only the front card speaks. A state shows one
// card in front of four backs (face down and faint when the dial can't act). Mockup: DECK in looks.js.
LookBase {
  id: look

  readonly property size plateSize: Qt.size(540, 250)
  readonly property bool wantsCallout: false
  readonly property string kind: "layout"

  readonly property int litCount: litOf(100)
  property alias cards: cardRepeater
  readonly property Item selection: stateDrawn === "ring" ? cardAt(Math.round(((p % n) + n) % n) % n) : frontCard
  function cardAt(i) { return cardRepeater.count > i ? cardRepeater.itemAt(i) : null }

  // The hand's position in tool units. Live: the hand's position. Stepped: the short way round, eased.
  property real steppedP: 0
  Behavior on steppedP {
    id: stepEase
    NumberAnimation { duration: look.cfg.motionBase; easing.type: Easing.BezierSpline; easing.bezierCurve: look.easeInOut }
  }
  readonly property real p: live ? position : steppedP
  property int _lastIndex: 0
  onIndexChanged: {
    var d = (index - _lastIndex) % n
    if (d > n / 2) d -= n
    if (d < -n / 2) d += n
    steppedP += d
    _lastIndex = index
  }
  onLiveChanged: if (!live) { stepEase.enabled = false; steppedP = position; stepEase.enabled = true }

  // A card, placed in the fan by its distance d from the front (transform-origin 50% 120%).
  component Card: Rectangle {
    id: card
    property real d: 0
    property real spread: look.u(92)
    property real lift: look.u(12)
    property real turn: 6
    property real shrink: 0.07
    readonly property real ad: Math.abs(d)
    x: look.u(186); y: look.u(22); width: look.u(168); height: look.u(212); radius: look.u(16)
    color: look.tone.card
    // The mockup parts the cards with a drop shadow; an edge in the rim tone does that without effects.
    border.width: look.u(1); border.color: look.tone.rim
    transform: [
      Scale { origin.x: card.width / 2; origin.y: card.height * 1.2; xScale: 1 - Math.min(card.ad, 3) * card.shrink; yScale: xScale },
      Rotation { origin.x: card.width / 2; origin.y: card.height * 1.2; angle: card.d * card.turn },
      Translate { x: card.d * card.spread; y: card.ad * card.lift }
    ]
  }

  // The ring: one card per tool.
  Repeater {
    id: cardRepeater
    model: look.stateDrawn === "ring" ? look.tools.length : 0
    delegate: Card {
      id: card
      required property int index
      readonly property int cardIndex: card.index
      readonly property bool front: card.ad < 0.5
      d: { var x = card.index - look.p; return ((x % look.n) + look.n + look.n / 2) % look.n - look.n / 2 }
      opacity: ad > 2.6 ? 0 : 1
      z: 100 - Math.round(ad * 10)
      Column {
        anchors.centerIn: parent
        width: parent.width - look.u(28)
        Rectangle {
          anchors.horizontalCenter: parent.horizontalCenter
          width: look.u(56); height: width; radius: width / 2
          color: card.front ? look.tone.accent : look.tone.surface
          Text {
            anchors.centerIn: parent
            visible: look.cfg.showGlyphs
            text: look.toolIcon(card.index); textFormat: Text.PlainText
            font.family: look.fontFamily; font.pixelSize: look.u(26)
            color: card.front ? look.tone.onaccent : look.tone.soft
          }
        }
        // Only the front card speaks.
        Column {
          width: parent.width
          opacity: Math.max(0, 1 - card.ad * 1.6)
          Text {
            width: parent.width; horizontalAlignment: Text.AlignHCenter
            topPadding: look.u(12)
            wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
            text: look.toolName(card.index); textFormat: Text.PlainText
            font.family: look.face; font.pixelSize: look.u(22); font.weight: Font.Bold
            lineHeight: 1.05
            color: look.tone.ink
          }
          Text {
            width: parent.width; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
            topPadding: look.u(4)
            text: look.pressText(card.index); textFormat: Text.PlainText
            font.family: look.face; font.pixelSize: look.u(14)
            color: look.tone.soft
          }
        }
      }
    }
  }

  // A state: four backs behind one card that carries it.
  Repeater {
    model: look.stateDrawn === "ring" ? [] : [-2, -1, 1, 2]
    delegate: Card {
      required property int modelData
      d: modelData
      spread: look.u(34); lift: 0; turn: 4; shrink: 0.05
      color: look.tone.surface
      opacity: look.noteKind === "cant" ? 0.35 : 0.9
    }
  }
  Card {
    id: frontCard
    visible: look.stateDrawn !== "ring"
    z: 200
    Column {
      anchors.centerIn: parent
      width: parent.width - look.u(28)
      visible: look.levelShown
      Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        width: look.u(52); height: width; radius: width / 2
        color: look.tone.accent
        Text {
          anchors.centerIn: parent
          visible: look.cfg.showGlyphs
          text: look.toolIcon(look.chosen); textFormat: Text.PlainText
          font.family: look.fontFamily; font.pixelSize: look.u(24)
          color: look.tone.onaccent
        }
      }
      Text {
        width: parent.width; horizontalAlignment: Text.AlignHCenter
        topPadding: look.u(8)
        text: look.valueText; textFormat: Text.PlainText
        font.family: look.face; font.pixelSize: look.u(look.valueText.length > 4 ? 40 : 56); font.weight: Font.Bold
        color: look.tone.ink
      }
      Text {
        width: parent.width; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
        text: String(look.note.name || ""); textFormat: Text.PlainText
        font.family: look.face; font.pixelSize: look.u(20); font.weight: Font.DemiBold
        color: look.tone.ink
      }
      Text {
        width: parent.width; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
        topPadding: look.u(6)
        text: look.pressText(look.chosen); textFormat: Text.PlainText
        font.family: look.face; font.pixelSize: look.u(14)
        color: look.tone.soft
      }
    }
    Message {
      anchors.centerIn: parent
      width: parent.width - look.u(28)
      visible: look.noteKind === "hint" || look.noteKind === "cant"
      look: look
      big: 20; small: 14
    }
  }
}
