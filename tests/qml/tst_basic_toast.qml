import QtQuick
import QtTest
import "../../plugin/redial/languages/basic"
import "lookkit"
import "lookkit/kit.js" as Kit

// re:dial basic's Toast layout on the quiet track (spec 2026-11-06): the card alone, as a pill: an
// accent disc with the icon, the name and click action, and a tiny track showing the position.
// Run: QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
Item {
  id: top
  width: 300; height: 72
  FakeCfg { id: fakeCfg }
  Language { id: lang }
  Component { id: lookComponent; Toast { cfg: fakeCfg; language: lang; width: 300; height: 72 } }

  TestCase {
    name: "BasicToast"
    when: windowShown
    function make(tools) {
      var look = createTemporaryObject(lookComponent, top)
      verify(look !== null, "the look loads with only QtQuick")
      look.tools = tools !== undefined ? tools : Kit.eight
      return look
    }

    function test_listed_by_the_language() { compare(lang.looks["toast"], "Toast.qml") }
    function test_plate_size() {
      var look = make()
      compare(look.plateSize.width, 300); compare(look.plateSize.height, 72)
      compare(look.wantsCallout, false); compare(look.kind, "layout")
      look.noteKind = "turn"; look.note = { name: "Volume", value: 42 }
      compare(look.plateSize.height, 72, "the plate never changes with the state")
    }
    function test_selection_follows_index() {
      var look = make()
      look.index = 3
      tryCompare(look, "markerFrac", 3 / 8, 1000)
    }
    function test_live_follows_position_directly() {
      var look = make()
      look.live = true
      look.position = 2.5
      compare(look.markerFrac, 2.5 / 8)
    }
    function test_empty_tools_loads() { compare(make([]).stateDrawn, "ring") }
    function test_turn_fills() {
      var look = make()
      look.noteKind = "turn"; look.note = { name: "Volume", value: 42, valueText: "42%" }
      compare(look.litCount, 42)
      compare(look.card.line, "42%")
    }
    function test_hint_shows_the_sign_in_the_disc() {
      var look = make()
      compare(look.discSign.visible, false)
      look.noteKind = "hint"; look.note = { prompt: "Press", gesture: "press" }
      compare(look.discSign.visible, true)
    }
    function test_a_long_title_keeps_to_one_line() { compare(make().card.titleLines, 1) }
    function test_a_hint_takes_the_whole_pill() {
      var look = make()
      look.noteKind = "hint"; look.note = { prompt: "Turn to pick a tool", gesture: "turn" }
      compare(look.miniTrack.visible, false)
      verify(look.card.maxWidth > look.miniX - look.card.x, "the card may run past where the mini track was")
    }
    function test_the_pill_is_the_card() {
      var look = make()
      compare(look.card.framed, false)
      compare(look.card.title, "Volume")
      verify(look.card.x + look.card.width <= look.width)
    }
      function test_a_long_hint_uses_the_whole_pill() {
      var look = make()
      look.noteKind = "hint"; look.note = { prompt: "Too fast or slow? Menu > Setup > re:dial > Feel", gesture: "press" }
      verify(look.card.width > look.card.maxWidth - 1, look.card.width + " < " + look.card.maxWidth)
    }
  }
}
