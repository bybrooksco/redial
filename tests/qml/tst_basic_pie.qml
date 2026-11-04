import QtQuick
import QtTest
import "../../plugin/redial/languages/basic"
import "lookkit"
import "lookkit/kit.js" as Kit

// re:dial basic's Pie look. Run: QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
Item {
  id: top
  width: 336; height: 336
  FakeCfg { id: fakeCfg }
  FakeCfg { id: movingCfg; motionBase: 200; motionFast: 140 }
  Language { id: lang }
  Component { id: lookComponent; Pie { cfg: fakeCfg; language: lang; width: plateSize.width; height: plateSize.height } }
  Component { id: movingComponent; Pie { cfg: movingCfg; language: lang; width: plateSize.width; height: plateSize.height } }

  TestCase {
    name: "BasicPie"
    when: windowShown
    function make(tools, comp) {
      var look = createTemporaryObject(comp || lookComponent, top)
      verify(look !== null, "the look loads with only QtQuick")
      look.tools = tools || Kit.eight
      return look
    }
    function test_listed_by_the_language() { compare(lang.looks["pie"], "Pie.qml") }
    function test_hint_and_cant_states() {
      var look = make()
      look.noteKind = "hint"; look.note = { prompt: "Turn to pick", gesture: "turn", step: 1, steps: 3 }
      compare(look.stateDrawn, "hint")
      look.noteKind = "cant"; look.note = { reason: "asleep", title: "Asleep", line: "Press to wake" }
      compare(look.stateDrawn, "cant")
    }
    function test_turn_without_value_keeps_ring() {
      var look = make()
      look.noteKind = "turn"; look.note = { name: "Tabs" }
      compare(look.litCount, 0); compare(look.stateDrawn, "ring")
      verify(look.selection.visible)
    }
    function test_markup_name_is_plain() {
      var look = make([{ icon: "a", name: "<b>x" }, { icon: "b", name: "<i>y" }])
      var t = Kit.texts(look)
      verify(t.length > 0)
      for (var i = 0; i < t.length; i++) compare(t[i].textFormat, Text.PlainText, "Text " + i + " " + t[i].text)
    }
    function test_plate_size() {
      var look = make()
      compare(look.plateSize.width, 336); compare(look.plateSize.height, 336)
      compare(look.wantsCallout, false); compare(look.kind, "face")
    }
    function test_selection_follows_index() {
      var look = make()
      look.index = 3
      compare(look.selection.rotation, 135)
    }
    function test_wedge_goes_forward_across_the_wrap() {
      var look = make()
      look.index = 7
      compare(look.selection.rotation, -45)
      look.index = 0
      compare(look.selection.rotation, 0)
    }
    function test_live_follows_position_directly() {
      var look = make()
      look.live = true
      look.position = 2.6
      compare(look.selection.rotation, 135)
    }
    function test_turn_with_value_lights_scale() {
      var look = make()
      look.noteKind = "turn"; look.note = { name: "Volume", value: 42, valueText: "42%" }
      compare(look.litCount, 42, "the fill reaches 42")
      compare(look.stateDrawn, "turn")
    }
    function test_one_and_twelve_tools() {
      var one = make(Kit.eight.slice(0, 1))
      compare(one.selection.rotation, 0)
      var many = make(Kit.twelve())
      many.index = 2
      compare(many.selection.rotation, 60)
    }
  }
}
