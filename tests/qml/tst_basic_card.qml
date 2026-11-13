import QtQuick
import QtTest
import "../../plugin/redial/languages/basic"
import "lookkit"
import "lookkit/kit.js" as Kit

// re:dial basic's shared card: the only place a look's words appear, the same in every look.
// Run: QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
Item {
  id: top
  width: 340; height: 248
  FakeCfg { id: fakeCfg }
  Language { id: lang }
  Component { id: hostComponent; Capsule { cfg: fakeCfg; language: lang; width: 340; height: 248 } }
  Component { id: cardComponent; Card {} }

  TestCase {
    name: "BasicCard"
    when: windowShown
    property var host
    property var card
    function init() {
      host = createTemporaryObject(hostComponent, top)
      host.tools = Kit.eight
      card = createTemporaryObject(cardComponent, host, { host: host })
      verify(card !== null, "the card loads")
    }

    function test_ring_text() {
      host.index = 2
      compare(card.title, Kit.eight[2].name)
      compare(card.line, host.cardLine(2))
    }
    function test_ring_line_can_be_overridden() {
      card.ringLine = "mute"
      compare(card.line, "mute")
    }
    function test_turn_text() {
      host.noteKind = "turn"; host.note = { name: "Volume", value: 42, valueText: "42%" }
      compare(card.title, "Volume"); compare(card.line, "42%")
    }
    function test_hint_text_and_dots() {
      host.noteKind = "hint"; host.note = { prompt: "Turn the dial", line: "to set volume", gesture: "turn", step: 2, steps: 5 }
      compare(card.title, "Turn the dial"); compare(card.line, "to set volume"); compare(card.dotCount, 5)
    }
    function test_no_dots_outside_a_guided_hint() {
      compare(card.dotCount, 0)
      host.noteKind = "hint"; host.note = { prompt: "Press to mute", gesture: "press", steps: 0 }
      compare(card.dotCount, 0)
    }
    function test_cant_text() {
      host.noteKind = "cant"; host.note = { reason: "asleep", title: "Asleep", line: "turn to wake" }
      compare(card.title, "Asleep"); compare(card.line, "turn to wake")
    }
    function test_long_name_elides_at_max_width() {
      host.tools = [{ name: "An extremely long launcher name that goes on and on", icon: "x" }]
      verify(card.width <= card.maxWidth + 0.5, card.width + " > " + card.maxWidth)
    }
    function test_min_width() {
      host.tools = [{ name: "A", icon: "x" }]
      compare(card.width, host.u(104))
    }
    function test_sign_only_when_asked_and_in_a_state() {
      compare(card.signShown, false)
      host.noteKind = "cant"; host.note = { reason: "asleep", title: "Asleep" }
      compare(card.signShown, false, "a ring face draws the sign in its middle")
      card.showSign = true
      compare(card.signShown, true)
    }
    function test_unframed_card_draws_no_background() {
      compare(card.framed, true); compare(card.background.visible, true)
      card.framed = false
      compare(card.background.visible, false)
    }
    function test_names_are_plain_text() {
      host.tools = [{ name: "<b>x", icon: "x" }]
      var t = Kit.texts(card)
      for (var i = 0; i < t.length; i++) compare(t[i].textFormat, Text.PlainText)
    }
  }
}
