import QtQuick
import QtTest
import "../../plugin/redial/languages/classic"
import "lookkit"
import "lookkit/kit.js" as Kit

// re:dial classic's Finger wheel look: a rotary dial in plan. The wheel is the hand (no easing);
// the finger stop does not turn; an angle dimension reads how far it has been dialled.
// Run: QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
Item {
  id: top
  width: 640; height: 440

  FakeCfg { id: fakeCfg }
  FakeCfg { id: movingCfg; motionBase: 200; motionFast: 140 }
  Language { id: lang }
  Component { id: lookComponent; Wheel { cfg: fakeCfg; language: lang; width: 640; height: 440 } }
  Component { id: movingComponent; Wheel { cfg: movingCfg; language: lang; width: 640; height: 440 } }

  TestCase {
    name: "ClassicWheel"
    when: windowShown

    function make(tools, comp) {
      var look = createTemporaryObject(comp || lookComponent, top)
      verify(look !== null, "the look loads with only QtQuick")
      look.tools = tools || Kit.eight
      return look
    }

    function test_listed_by_the_language() { compare(lang.looks["wheel"], "Wheel.qml") }

    function test_plate_size() {
      var look = make()
      compare(look.plateSize.width, 640); compare(look.plateSize.height, 440)
      compare(look.wantsCallout, true); compare(look.kind, "face")
      compare(look.calloutX, 468)
    }

    function test_selection_follows_index() {
      var look = make()
      look.index = 3
      compare(look.selection.rotation, -3 * 45)
      compare(look.turned, 135)
    }

    function test_live_follows_position_directly() {
      var look = make(Kit.eight, movingComponent)
      look.live = true
      look.position = 2.5
      compare(look.selection.rotation, -2.5 * 45, "the wheel is the hand")
    }

    function test_release_spins_to_the_chosen_hole() {
      var look = make(Kit.eight, movingComponent)
      look.live = true
      look.index = 3
      look.position = 2.6
      look.live = false
      verify(Math.abs(look.selection.rotation - (-3 * 45)) > 1, "it eases, not snaps")
      tryCompare(look.selection, "rotation", -3 * 45, 1000)
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
      look.index = 2
      look.noteKind = "hint"; look.note = { prompt: "Turn to pick", gesture: "turn" }
      compare(look.stateDrawn, "hint")
      look.noteKind = "cant"; look.note = { reason: "asleep", title: "Asleep" }
      compare(look.stateDrawn, "cant")
      compare(look.selection.rotation, 0, "can't act: the wheel rests")
    }

    function test_one_and_twelve_tools() {
      var one = make(Kit.eight.slice(0, 1))
      compare(one.selection.rotation, 0)
      var many = make(Kit.twelve())
      many.index = 11
      compare(many.selection.rotation, 30, "11 of 12 is one hole back, the short way")
    }

    function test_markup_name_is_plain() {
      var look = make([{ icon: "a", name: "<b>x" }, { icon: "b", name: "<i>y" }])
      var t = Kit.texts(look)
      verify(t.length > 0)
      for (var i = 0; i < t.length; i++) compare(t[i].textFormat, Text.PlainText, "Text " + i + " " + t[i].text)
    }
  }
}
