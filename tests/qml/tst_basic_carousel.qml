import QtQuick
import QtTest
import "../../plugin/redial/languages/basic"
import "lookkit"
import "lookkit/kit.js" as Kit

// re:dial basic's Carousel layout: a constant-width row of tiles in a tray (one scalar drives every
// tile, so the row never changes width); a state becomes a compact card.
// Run: QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
Item {
  id: top
  width: 588; height: 150
  FakeCfg { id: fakeCfg }
  Language { id: lang }
  Component { id: lookComponent; Carousel { cfg: fakeCfg; language: lang; width: 588; height: 150 } }

  TestCase {
    name: "BasicCarousel"
    when: windowShown
    function make(tools) {
      var look = createTemporaryObject(lookComponent, top)
      verify(look !== null, "the look loads with only QtQuick")
      look.tools = tools || Kit.eight
      return look
    }
    function rowWidth(look) {
      var w = 0
      for (var i = 0; i < look.tiles.count; i++) w += look.tiles.itemAt(i).width
      return w
    }

    function test_listed_by_the_language() { compare(lang.looks["carousel"], "Carousel.qml") }
    function test_plate_size() {
      var look = make()
      compare(look.plateSize.width, 588); compare(look.plateSize.height, 150)
      compare(look.wantsCallout, false); compare(look.kind, "layout")
      look.noteKind = "cant"; look.note = { title: "Asleep" }
      compare(look.plateSize.width, 460, "a state is the compact card")
    }
    function test_selection_follows_index() {
      var look = make()
      look.index = 3
      tryCompare(look, "p", 3)
      compare(look.selection.tileIndex, 3)
      compare(look.selection.width, 104, "the chosen tile is 56 + 48 wide")
      compare(look.tiles.itemAt(0).width, 56)
    }
    function test_wrap_is_one_tile_on() {
      var look = make()
      look.index = 7
      tryCompare(look, "p", -1)
      compare(look.selection.tileIndex, 7)
    }
    function test_live_follows_position_directly() {
      var look = make()
      look.live = true
      look.position = 2.5
      compare(look.p, 2.5)
      compare(look.tiles.itemAt(2).width, 80); compare(look.tiles.itemAt(3).width, 80)
      var w = rowWidth(look)
      look.position = 2.9
      compare(rowWidth(look), w, "the row never changes width")
    }
    function test_turn_with_value_lights_scale() {
      var look = make()
      look.noteKind = "turn"; look.note = { name: "Volume", value: 42, valueText: "42%" }
      compare(look.litCount, 42)
      compare(look.stateDrawn, "turn")
      compare(look.tiles.count, 0)
      compare(look.selection.text, "Volume")
    }
    function test_turn_without_value_keeps_ring() {
      var look = make()
      look.noteKind = "turn"; look.note = { name: "Tabs" }
      compare(look.litCount, 0); compare(look.stateDrawn, "ring")
      compare(look.tiles.count, 8)
    }
    function test_hint_and_cant_states() {
      var look = make()
      look.noteKind = "hint"; look.note = { prompt: "Turn to pick", gesture: "turn", step: 1, steps: 3 }
      compare(look.stateDrawn, "hint"); compare(look.selection.text, "Turn to pick")
      look.noteKind = "cant"; look.note = { reason: "asleep", title: "Asleep", line: "Press to wake" }
      compare(look.stateDrawn, "cant"); compare(look.selection.text, "Asleep")
    }
    function test_one_and_twelve_tools() {
      var one = make(Kit.eight.slice(0, 1))
      compare(one.selection.tileIndex, 0)
      var many = make(Kit.twelve())
      verify(rowWidth(many) + 11 * 8 <= 588 - 36, "twelve tiles fit the tray: " + rowWidth(many))
      many.index = 11
      tryCompare(many, "p", -1)
      compare(many.selection.tileIndex, 11)
    }
    function test_markup_name_is_plain() {
      var look = make([{ icon: "a", name: "<b>x" }, { icon: "b", name: "<i>y" }])
      var t = Kit.texts(look)
      verify(t.length > 0)
      for (var i = 0; i < t.length; i++) compare(t[i].textFormat, Text.PlainText, "Text " + i + " " + t[i].text)
    }
  }
}
