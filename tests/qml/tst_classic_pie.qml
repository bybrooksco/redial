import QtQuick
import QtTest
import "../../plugin/redial/languages/classic"
import "lookkit"
import "lookkit/kit.js" as Kit

// re:dial classic's Pie look: drawn sectors; the chosen one is section-hatched and turns forward.
// Run: QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
Item {
  id: top
  width: 400; height: 400

  FakeCfg { id: fakeCfg }
  Language { id: lang }
  Component { id: lookComponent; Pie { cfg: fakeCfg; language: lang; width: 400; height: 400 } }

  TestCase {
    name: "ClassicPie"
    when: windowShown

    function make(tools) {
      var look = createTemporaryObject(lookComponent, top)
      verify(look !== null, "the look loads with only QtQuick")
      look.tools = tools || Kit.eight
      return look
    }

    function test_listed_by_the_language() { compare(lang.looks["pie"], "Pie.qml") }

    function test_plate_size() {
      var look = make()
      compare(look.plateSize.width, 400); compare(look.plateSize.height, 400)
      compare(look.wantsCallout, false); compare(look.kind, "face")
    }

    function test_selection_follows_index() {
      var look = make()
      look.index = 3
      compare(look.selection.rotation, 3 * 45)
    }

    function test_wedge_goes_forward_across_the_wrap() {
      var look = make()
      look.index = 7
      compare(look.selection.rotation, -45, "0 -> 7 is one sector back")
      look.index = 0
      compare(look.selection.rotation, 0, "7 -> 0 is one sector forward, not seven back")
      look.index = 7; look.index = 6; look.index = 7; look.index = 0; look.index = 1
      compare(look.selection.rotation, 45)
    }

    function test_live_follows_position_directly() {
      var look = make()
      look.live = true
      look.position = 2.4
      compare(look.selection.rotation, 2 * 45)
      look.position = 2.6
      compare(look.selection.rotation, 3 * 45)
    }

    function test_turn_with_value_lights_scale() {
      var look = make()
      look.noteKind = "turn"; look.note = { name: "Volume", value: 42, valueText: "42%" }
      compare(look.litCount, 42)
      compare(look.stateDrawn, "turn")
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
      look.noteKind = "hint"; look.note = { prompt: "Turn to pick", gesture: "turn" }
      compare(look.stateDrawn, "hint")
      look.noteKind = "cant"; look.note = { reason: "asleep", title: "Asleep" }
      compare(look.stateDrawn, "cant")
    }

    function test_one_and_twelve_tools() {
      var one = make(Kit.eight.slice(0, 1))
      compare(one.selection.rotation, 0)
      var many = make(Kit.twelve())
      many.index = 2
      compare(many.selection.rotation, 60)
    }

    function test_markup_name_is_plain() {
      var look = make([{ icon: "a", name: "<b>x" }, { icon: "b", name: "<i>y" }])
      var t = Kit.texts(look)
      verify(t.length > 0)
      for (var i = 0; i < t.length; i++) compare(t[i].textFormat, Text.PlainText, "Text " + i + " " + t[i].text)
    }
  }
}
