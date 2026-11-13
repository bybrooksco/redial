import QtQuick
import QtTest
import "../../plugin/redial/languages/classic"
import "lookkit"
import "lookkit/kit.js" as Kit

// re:dial classic's Carousel layout: a slide rule; the cursor rides to the tool.
// Run: QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
Item {
  id: top
  width: 640; height: 168

  FakeCfg { id: fakeCfg }
  Language { id: lang }
  Component { id: lookComponent; Carousel { cfg: fakeCfg; language: lang; width: 640; height: 168 } }

  TestCase {
    name: "ClassicCarousel"
    when: windowShown

    function make(tools) {
      var look = createTemporaryObject(lookComponent, top)
      verify(look !== null, "the look loads with only QtQuick")
      look.tools = tools || Kit.eight
      return look
    }

    function test_listed_by_the_language() { compare(lang.looks["carousel"], "Carousel.qml") }

    function test_plate_size() {
      var look = make()
      compare(look.plateSize.width, 640); compare(look.plateSize.height, 168)
      compare(look.wantsCallout, false); compare(look.kind, "layout")
    }

    function test_selection_follows_index() {
      var look = make()
      compare(look.pitch, 76)
      look.index = 3
      compare(look.selection.x, 52 + 3 * 76)
    }

    function test_live_follows_position_directly() {
      var look = make()
      look.live = true
      look.position = 2.5
      compare(look.selection.x, 52 + 2.5 * 76)
    }

    function test_turn_with_value_lights_scale() {
      var look = make()
      look.noteKind = "turn"; look.note = { name: "Volume", value: 42, valueText: "42%" }
      compare(look.litCount, 42)
      compare(look.selection.x, 52 + 0.42 * 76 * 7, "the cursor reads 42% of the rule")
    }

    function test_turn_without_value_keeps_ring() {
      var look = make()
      look.noteKind = "turn"; look.note = { name: "Tabs" }
      compare(look.litCount, 0)
      compare(look.stateDrawn, "ring")
      verify(look.selection.visible)
    }

    function test_hint_and_cant_states() {
      var look = make()
      look.index = 4
      look.noteKind = "hint"; look.note = { prompt: "Turn to pick", gesture: "turn" }
      compare(look.stateDrawn, "hint")
      compare(look.selection.x, 52, "a hint parks the cursor at the start")
      look.noteKind = "cant"; look.note = { reason: "asleep", title: "Asleep", line: "Press to wake" }
      compare(look.stateDrawn, "cant")
      verify(!look.selection.visible, "can't act: no cursor")
    }

    function test_one_and_twelve_tools() {
      var one = make(Kit.eight.slice(0, 1))
      compare(one.selection.x, 52)
      compare(one.ruleEnd, 52 + 7 * 76, "one tool still gets a full rule for the figures, name and sheet")
      one.noteKind = "turn"; one.note = { name: "Volume", value: 42 }
      compare(one.selection.x, 52 + 0.42 * 7 * 76, "the level cursor reads 42% of the rule")
      var two = make(Kit.eight.slice(0, 2))
      two.noteKind = "turn"; two.note = { name: "Volume", value: 42 }
      compare(two.selection.x, 52 + 0.42 * 7 * 76)
      var many = make(Kit.twelve())
      verify(many.pitch < 76, "twelve tools fit the plate")
      many.index = 11
      verify(many.selection.x + 30 <= 640 - 22, "the last tool's cursor stays on the plate")
    }

    function test_markup_name_is_plain() {
      var look = make([{ icon: "a", name: "<b>x" }, { icon: "b", name: "<i>y" }])
      var t = Kit.texts(look)
      verify(t.length > 0)
      for (var i = 0; i < t.length; i++) compare(t[i].textFormat, Text.PlainText, "Text " + i + " " + t[i].text)
    }
  }
}
