import QtQuick
import QtTest
import "../../plugin/redial/languages/classic"
import "lookkit"
import "lookkit/kit.js" as Kit

// re:dial classic's Capsule look: drawn capsules round a hub, the chosen one slides outward.
// Run: QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
Item {
  id: top
  width: 400; height: 400

  FakeCfg { id: fakeCfg }
  Language { id: lang }
  Component { id: lookComponent; Capsule { cfg: fakeCfg; language: lang; width: 400; height: 400 } }

  TestCase {
    name: "ClassicCapsule"
    when: windowShown

    function make(tools) {
      var look = createTemporaryObject(lookComponent, top)
      verify(look !== null, "the look loads with only QtQuick")
      look.tools = tools || Kit.eight
      return look
    }
    function near(a, b, msg) { verify(Math.abs(a - b) < 0.6, msg + ": " + a + " vs " + b) }

    function test_listed_by_the_language() {
      compare(lang.looks["capsule"], "Capsule.qml")
    }

    function test_plate_size() {
      var look = make()
      compare(look.plateSize.width, 400); compare(look.plateSize.height, 400)
      compare(look.wantsCallout, false)
      compare(look.kind, "face")
    }

    function test_selection_follows_index() {
      var look = make()
      look.index = 3
      wait(0)
      var c = Kit.centre(look.selection, look), a = (-90 + 3 * 45) * Math.PI / 180
      near(c[0], 200 + Math.cos(a) * 124, "x: 12 outward of the 112 ring")
      near(c[1], 200 + Math.sin(a) * 124, "y")
    }

    function test_live_follows_position_directly() {
      var look = make()
      look.live = true
      look.position = 2.4
      compare(look.leaderDeg, -90 + 2 * 45, "the callout sits on the detent the hand is at")
      look.position = 2.6
      compare(look.leaderDeg, -90 + 3 * 45)
    }

    function test_turn_with_value_lights_scale() {
      var look = make()
      look.noteKind = "turn"; look.note = { name: "Volume", value: 42, valueText: "42%" }
      compare(look.litCount, 10)
      compare(look.stateDrawn, "turn")
    }

    function test_turn_without_value_keeps_ring() {
      var look = make()
      look.noteKind = "turn"; look.note = { name: "Tabs" }
      compare(look.litCount, 0)
      compare(look.stateDrawn, "ring")
      verify(look.selection.visible, "the capsules stay")
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
      verify(one.selection !== null)
      var many = make(Kit.twelve())
      many.index = 11
      wait(0)
      var c = Kit.centre(many.selection, many), a = (-90 + 11 * 30) * Math.PI / 180
      near(c[0], 200 + Math.cos(a) * 124, "twelve tools: x")
    }

    function test_rim_label_clears_the_chosen_capsule_at_three_oclock() {
      var look = make()
      look.index = 2
      wait(0)
      // The capsule's footprint as drawn: 32x68 turned to lie along its radius.
      var r = look.rimLabel, c = Kit.centre(look.selection, look), t = (look.selection.deg + 90) * Math.PI / 180
      var hx = Math.abs(Math.cos(t)) * 16 + Math.abs(Math.sin(t)) * 34, hy = Math.abs(Math.sin(t)) * 16 + Math.abs(Math.cos(t)) * 34
      var overlap = r.x < c[0] + hx && r.x + r.width > c[0] - hx && r.y < c[1] + hy && r.y + r.height > c[1] - hy
      verify(!overlap, "label " + r.x + "," + r.y + " " + r.width + "x" + r.height + " over capsule at " + c)
    }

    function test_markup_name_is_plain() {
      var look = make([{ icon: "a", name: "<b>x" }, { icon: "b", name: "<i>y" }])
      var t = Kit.texts(look)
      verify(t.length > 0)
      for (var i = 0; i < t.length; i++) compare(t[i].textFormat, Text.PlainText, "Text " + i + " " + t[i].text)
    }
  }
}
