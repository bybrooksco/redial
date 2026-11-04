import QtQuick
import QtTest
import "../../plugin/redial/languages/basic"
import "lookkit"
import "lookkit/kit.js" as Kit

// re:dial basic's Toast layout: one pill. Accent disc, name and click action, position dots; while
// turning the pill itself fills as the meter. Run: QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
Item {
  id: top
  width: 330; height: 60
  FakeCfg { id: fakeCfg }
  Language { id: lang }
  Component { id: lookComponent; Toast { cfg: fakeCfg; language: lang; width: 330; height: 60 } }

  TestCase {
    name: "BasicToast"
    when: windowShown
    function make(tools) {
      var look = createTemporaryObject(lookComponent, top)
      verify(look !== null, "the look loads with only QtQuick")
      look.tools = tools || Kit.eight
      return look
    }

    function test_listed_by_the_language() { compare(lang.looks["toast"], "Toast.qml") }
    function test_plate_size() {
      var look = make()
      compare(look.plateSize.width, 330); compare(look.plateSize.height, 60)
      compare(look.wantsCallout, false); compare(look.kind, "layout")
    }
    function test_selection_follows_index() {
      var look = make()
      look.index = 3
      compare(look.selection.text, "Scroll")
      compare(look.dots.count, 8)
      compare(look.dots.itemAt(3).on, true); compare(look.dots.itemAt(0).on, false)
    }
    function test_live_follows_position_directly() {
      var look = make()
      look.live = true; look.index = 2; look.position = 2.5
      compare(look.selection.text, "Windows", "the toast names the chosen tool; the hand moves the index")
    }
    function test_turn_with_value_lights_scale() {
      var look = make()
      look.noteKind = "turn"; look.note = { name: "Volume", value: 42, valueText: "42%" }
      compare(look.litCount, 42)
      compare(look.stateDrawn, "turn")
      compare(look.selection.text, "Volume")
      compare(look.dots.count, 0, "the value replaces the dots")
      compare(look.fill.visible, true); tryCompare(look.fill, "shown", 42)
    }
    function test_turn_without_value_keeps_ring() {
      var look = make()
      look.noteKind = "turn"; look.note = { name: "Tabs" }
      compare(look.litCount, 0); compare(look.stateDrawn, "ring")
      compare(look.fill.visible, false)
    }
    function test_hint_and_cant_states() {
      var look = make()
      look.noteKind = "hint"; look.note = { prompt: "Turn to pick", gesture: "turn", step: 2, steps: 3 }
      compare(look.stateDrawn, "hint"); compare(look.selection.text, "Turn to pick")
      look.noteKind = "cant"; look.note = { reason: "asleep", title: "Asleep", line: "Press to wake" }
      compare(look.stateDrawn, "cant"); compare(look.selection.text, "Asleep")
    }
    function test_one_and_twelve_tools() {
      var one = make(Kit.eight.slice(0, 1))
      compare(one.selection.text, "Volume")
      var many = make(Kit.twelve())
      many.index = 11
      compare(many.selection.text, "Tool 12")
      verify(many.dots.itemAt(11).x + many.dots.itemAt(11).width <= 330, "twelve dots stay inside the pill")
    }
    function test_markup_name_is_plain() {
      var look = make([{ icon: "a", name: "<b>x" }, { icon: "b", name: "<i>y" }])
      var t = Kit.texts(look)
      verify(t.length > 0)
      for (var i = 0; i < t.length; i++) compare(t[i].textFormat, Text.PlainText, "Text " + i + " " + t[i].text)
    }
  }
}
