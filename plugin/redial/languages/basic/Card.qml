import QtQuick

// re:dial basic's one card: the only place a look's words appear, the same in every look and state.
// Ring: the tool and "3 / 10 · mute"; turning: the level's name and value; hint: the prompt, its
// line and step dots; can't act: the title and its line. Straight-track looks and layouts have no
// middle to put the state sign in, so they set showSign and it sits at the card's left.
Item {
  id: card
  required property Item host
  property bool showSign: false
  property int titleLines: 2
  property bool framed: true            // false: the look draws the card's frame itself (Toast's pill)
  readonly property Item background: bg
  property real maxWidth: host.u(200)
  property string ringLine: host.cardLine(host.chosen)

  readonly property string kind: host.stateDrawn
  readonly property var note: host.note || ({})
  readonly property string title: kind === "turn" ? String(note.name || host.toolName(host.chosen))
                                : kind === "hint" ? String(note.prompt || "")
                                : kind === "cant" ? String(note.title || "")
                                : host.toolName(host.chosen)
  readonly property string line: kind === "turn" ? host.valueText
                               : kind === "hint" || kind === "cant" ? String(note.line || "")
                               : ringLine
  readonly property int dotCount: kind === "hint" && Number(note.steps) > 1 ? Number(note.steps) : 0
  readonly property bool signShown: showSign && (kind === "hint" || kind === "cant")

  readonly property real pad: host.u(12)
  readonly property real signSize: host.u(28)
  // A hint or can't act is an instruction: it wraps rather than cut (a one-line card still elides).
  readonly property bool says: kind === "hint" || kind === "cant"
  property int stateLines: 4          // a fixed-height card (Deck) asks for fewer
  readonly property int lines: says && titleLines > 1 ? stateLines : titleLines
  // Measured apart from the laid-out text, whose implicitWidth is already elided to the card.
  TextMetrics { id: titleNat; font: titleText.font; text: card.title }
  TextMetrics { id: lineNat; font: lineText.font; text: card.line }
  readonly property real textNatural: Math.max(titleNat.advanceWidth, lineNat.advanceWidth,
                                               dotCount > 0 ? dots.implicitWidth : 0)
  readonly property real lead: signShown ? signSize + host.u(10) : 0
  implicitWidth: Math.min(maxWidth, Math.max(host.u(104), lead + textNatural + 2 * pad))
  implicitHeight: Math.max(host.u(58), Math.max(column.implicitHeight, signShown ? signSize : 0) + 2 * pad)
  width: implicitWidth; height: implicitHeight

  Rectangle {
    id: bg
    anchors.fill: parent
    visible: card.framed
    radius: card.host.u(12)
    color: card.host.tone.card
  }
  Sign {
    host: card.host
    visible: card.signShown
    size: card.signSize
    x: card.pad; anchors.verticalCenter: parent.verticalCenter
  }
  Column {
    id: column
    x: card.pad + card.lead
    anchors.verticalCenter: parent.verticalCenter
    width: card.width - x - card.pad
    spacing: card.host.u(3)
    Text {
      id: titleText
      width: parent.width; elide: Text.ElideRight
      wrapMode: Text.WordWrap; maximumLineCount: card.lines
      text: card.title; textFormat: Text.PlainText
      font.family: card.host.face; font.pixelSize: card.host.u(15); font.weight: Font.DemiBold
      color: card.host.tone.ink
    }
    Text {
      id: lineText
      width: parent.width; elide: Text.ElideRight
      wrapMode: Text.WordWrap; maximumLineCount: card.says && card.titleLines > 1 ? 3 : 1
      visible: text !== ""
      text: card.line; textFormat: Text.PlainText
      font.family: card.host.face; font.pixelSize: card.host.u(10.5)
      color: card.host.tone.muted
    }
    Row {
      id: dots
      visible: card.dotCount > 0
      spacing: card.host.u(5)
      topPadding: card.host.u(3)
      Repeater {
        model: card.dotCount
        delegate: Rectangle {
          required property int index
          width: card.host.u(6); height: width; radius: width / 2
          color: index < (Number(card.note.step) || 1) ? card.host.tone.accent : card.host.tone.track
        }
      }
    }
  }
}
