import QtQuick
import QtTest
import "../../plugin/redial/languages/basic"
import "lookkit"
import "lookkit/kit.js" as Kit

// re:dial basic's Carousel layout on the quiet track (spec 2026-11-06): a straight track, icons
// above it scrolling so the chosen tool is centred over a fixed accent marker, the card below.
// Run: QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
Item {
  id: top
  width: 340; height: 230
  FakeCfg { id: fakeCfg }
  Language { id: lang }
  Component { id: lookComponent; Carousel { cfg: fakeCfg; language: lang; width: 340; height: 230 } }

  TestCase {
    name: "BasicCarousel"
    when: windowShown
    function make(tools) {
      var look = createTemporaryObject(lookComponent, top)
      verify(look !== null, "the look loads with only QtQuick")
      look.tools = tools !== undefined ? tools : Kit.eight
      return look
    }
    function centreSlot(look) {
      for (var k = 0; k < look.slots.count; k++) if (look.slots.itemAt(k).slot === 0) return look.slots.itemAt(k)
      return null
    }

    function test_listed_by_the_language() { compare(lang.looks["carousel"], "Carousel.qml") }
    function test_plate_size() {
      var look = make()
      compare(look.plateSize.width, 340); compare(look.plateSize.height, 230)
      compare(look.wantsCallout, false); compare(look.kind, "layout")
      look.noteKind = "cant"; look.note = { reason: "asleep", title: "Asleep" }
      compare(look.plateSize.width, 340, "the plate never changes with the state")
    }
    function test_chosen_icon_is_centred() {
      var look = make()
      look.index = 3
      tryCompare(look, "listPos", 3, 1000)
      compare(centreSlot(look).tool, 3)
      verify(Math.abs(Kit.centre(centreSlot(look), look)[0] - 170) < 0.6)
      verify(Math.abs(Kit.centre(look.selection, look)[0] - 170) < 0.6, "the marker is under it")
    }
    function test_each_tool_shows_once() {
      var look = make()
      var seen = {}
      for (var k = 0; k < look.slots.count; k++) {
        var it = look.slots.itemAt(k)
        if (!it.visible) continue
        verify(seen[it.tool] === undefined, "tool " + it.tool + " shows twice")
        seen[it.tool] = true
      }
    }
    function test_live_follows_position_directly() {
      var look = make()
      look.live = true
      look.position = 2.5
      compare(look.listPos, 2.5)
    }
    function test_wraps_the_short_way() {
      var look = make()
      look.index = 7
      tryCompare(look, "listPos", -1, 1000)
      look.index = 0
      tryCompare(look, "listPos", 0, 1000)
    }
    function test_empty_tools_loads() { compare(make([]).stateDrawn, "ring") }
    function test_turn_fills() {
      var look = make()
      look.noteKind = "turn"; look.note = { name: "Volume", value: 42, valueText: "42%" }
      compare(look.litCount, 42)
      verify(!centreSlot(look).visible, "icons hide while a level fills the track")
    }
    function test_hint_puts_the_sign_in_the_card() {
      var look = make()
      look.noteKind = "hint"; look.note = { prompt: "Press", gesture: "press" }
      compare(look.card.signShown, true)
    }
    function test_card_sits_below_the_track() {
      var look = make()
      verify(look.card.y > 100); verify(look.card.y + look.card.height <= look.height)
    }
      function test_tool_count_change_keeps_the_choice_centred() {
      var look = make()
      look.live = true; look.position = 9; look.index = 1; look.live = false   // a full turn and one
      look.tools = Kit.eight.slice(0, 5)
      compare(centreSlot(look).tool, 1)
    }
  }
}
