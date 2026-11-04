import QtQuick
import QtTest
import "../../plugin/redial/languages/basic"
import "lookkit"
import "lookkit/kit.js" as Kit

// re:dial basic's Sundial look: tools are hours on a round dial; the sun follows the hand a breath
// behind and the gnomon's shadow falls away from it. Turning, a hint and can't act use the half
// plate. Run: QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
Item {
  id: top
  width: 336; height: 336
  FakeCfg { id: fakeCfg }
  FakeCfg { id: movingCfg; motionBase: 200; motionFast: 140 }
  Language { id: lang }
  Component { id: lookComponent; Sundial { cfg: fakeCfg; language: lang; width: 336; height: plateSize.height } }
  Component { id: movingComponent; Sundial { cfg: movingCfg; language: lang; width: 336; height: plateSize.height } }

  TestCase {
    name: "BasicSundial"
    when: windowShown
    function make(tools, comp) {
      var look = createTemporaryObject(comp || lookComponent, top)
      verify(look !== null, "the look loads with only QtQuick")
      look.tools = tools || Kit.eight
      return look
    }

    function test_listed_by_the_language() { compare(lang.looks["sundial"], "Sundial.qml") }
    function test_plate_size() {
      var look = make()
      compare(look.plateSize.width, 336); compare(look.plateSize.height, 336)
      compare(look.wantsCallout, false); compare(look.kind, "face")
      look.noteKind = "turn"; look.note = { name: "Volume", value: 42 }
      compare(look.plateSize.height, 226, "turning uses the half plate")
      look.noteKind = "hint"; look.note = { prompt: "Turn to pick", gesture: "turn" }
      compare(look.plateSize.height, 316, "a hint is a plaque over the half plate")
    }
    function test_selection_follows_index() {
      var look = make()
      look.index = 3
      tryCompare(look.selection, "deg", -90 + 3 * 45)
      var c = Kit.centre(look.selection, look), a = (-90 + 3 * 45) * Math.PI / 180
      verify(Math.abs(c[0] - (168 + Math.cos(a) * 116)) < 0.6 && Math.abs(c[1] - (168 + Math.sin(a) * 116)) < 0.6, "the sun sits on the 116 ring")
    }
    function test_live_follows_position_directly() {
      // The sun lags the hand by design (τ 60 ms): it moves toward 2.5 and arrives within 400 ms.
      var look = make(Kit.eight, movingComponent)
      look.live = true
      look.position = 2.5
      var target = -90 + 2.5 * 45
      verify(Math.abs(look.selection.deg - target) > 1, "not there at once")
      tryVerify(function () { return Math.abs(look.selection.deg - target) < 0.5 }, 400)
    }
    function test_turn_with_value_lights_scale() {
      var look = make()
      look.noteKind = "turn"; look.note = { name: "Volume", value: 42, valueText: "42%" }
      compare(look.litCount, 42)
      compare(look.stateDrawn, "turn")
      tryCompare(look.selection, "deg", 180 + 42 * 1.8)
    }
    function test_turn_without_value_keeps_ring() {
      var look = make()
      look.noteKind = "turn"; look.note = { name: "Tabs" }
      compare(look.litCount, 0); compare(look.stateDrawn, "ring")
      compare(look.plateSize.height, 336)
    }
    function test_hint_and_cant_states() {
      var look = make()
      look.noteKind = "hint"; look.note = { prompt: "Turn to pick", gesture: "turn", step: 1, steps: 3 }
      compare(look.stateDrawn, "hint")
      tryCompare(look.selection, "deg", 270, 1000, "the sun waits at noon")
      look.noteKind = "cant"; look.note = { reason: "asleep", title: "Asleep", line: "Press to wake" }
      compare(look.stateDrawn, "cant")
      compare(look.plateSize.height, 226)
      compare(look.moonX, 3, "motion off: the moon is already over the sun")
    }
    function test_moon_slides_in_once() {
      var look = make(Kit.eight, movingComponent)
      look.noteKind = "cant"; look.note = { reason: "asleep" }
      verify(look.moonX > 3)
      tryCompare(look, "moonX", 3, 1000)
    }
    function test_one_and_twelve_tools() {
      var one = make(Kit.eight.slice(0, 1))
      compare(one.selection.deg, -90)
      var many = make(Kit.twelve())
      many.index = 11
      tryCompare(many.selection, "deg", -90 - 30, 1000, "11 is one hour back from 0")
    }
    function test_markup_name_is_plain() {
      var look = make([{ icon: "a", name: "<b>x" }, { icon: "b", name: "<i>y" }])
      var t = Kit.texts(look)
      verify(t.length > 0)
      for (var i = 0; i < t.length; i++) compare(t[i].textFormat, Text.PlainText, "Text " + i + " " + t[i].text)
    }
  }
}
