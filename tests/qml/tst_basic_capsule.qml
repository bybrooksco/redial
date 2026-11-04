import QtQuick
import QtTest
import "../../plugin/redial/languages/basic"
import "lookkit"
import "lookkit/kit.js" as Kit

// re:dial basic's Capsule look: filled capsules on a rimmed disc; the chosen one slides outward in
// the accent. Run: QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
Item {
  id: top
  width: 336; height: 336
  FakeCfg { id: fakeCfg }
  Language { id: lang }
  Component { id: lookComponent; Capsule { cfg: fakeCfg; language: lang; width: 336; height: 336 } }

  TestCase {
    name: "BasicCapsule"
    when: windowShown
    function make(tools) {
      var look = createTemporaryObject(lookComponent, top)
      verify(look !== null, "the look loads with only QtQuick")
      look.tools = tools || Kit.eight
      return look
    }
    function near(a, b, msg) { verify(Math.abs(a - b) < 0.6, msg + ": " + a + " vs " + b) }

    function test_listed_by_the_language() { compare(lang.looks["capsule"], "Capsule.qml") }
    function test_plate_size() {
      var look = make()
      compare(look.plateSize.width, 336); compare(look.plateSize.height, 336)
      compare(look.wantsCallout, false); compare(look.kind, "face")
    }
    function test_selection_follows_index() {
      var look = make()
      look.index = 3
      var c = Kit.centre(look.selection, look), a = (-90 + 3 * 45) * Math.PI / 180
      near(c[0], 168 + Math.cos(a) * 126, "x: 12 outward of the 114 ring"); near(c[1], 168 + Math.sin(a) * 126, "y")
    }
    function test_live_follows_position_directly() {
      var look = make()
      look.live = true
      look.position = 2.4
      compare(look.selection.capIndex, 2)
      look.position = 2.6
      compare(look.selection.capIndex, 3)
    }
    function test_turn_with_value_lights_scale() {
      var look = make()
      look.noteKind = "turn"; look.note = { name: "Volume", value: 42, valueText: "42%" }
      compare(look.litCount, 8, "8 of 20 segments")
      compare(look.stateDrawn, "turn")
    }
    function test_turn_without_value_keeps_ring() {
      var look = make()
      look.noteKind = "turn"; look.note = { name: "Tabs" }
      compare(look.litCount, 0); compare(look.stateDrawn, "ring")
      verify(look.selection.visible)
    }
    function test_hint_and_cant_states() {
      var look = make()
      look.noteKind = "hint"; look.note = { prompt: "Turn to pick", gesture: "turn", step: 1, steps: 3 }
      compare(look.stateDrawn, "hint")
      look.noteKind = "cant"; look.note = { reason: "asleep", title: "Asleep", line: "Press to wake" }
      compare(look.stateDrawn, "cant")
    }
    function test_one_and_twelve_tools() {
      var one = make(Kit.eight.slice(0, 1))
      verify(one.selection !== null)
      var many = make(Kit.twelve())
      many.index = 11
      var c = Kit.centre(many.selection, many), a = (-90 + 11 * 30) * Math.PI / 180
      near(c[0], 168 + Math.cos(a) * 126, "twelve tools")
    }
    function test_markup_name_is_plain() {
      var look = make([{ icon: "a", name: "<b>x" }, { icon: "b", name: "<i>y" }])
      var t = Kit.texts(look)
      verify(t.length > 0)
      for (var i = 0; i < t.length; i++) compare(t[i].textFormat, Text.PlainText, "Text " + i + " " + t[i].text)
    }
  }
}
