import QtQuick
import QtTest
import "../../plugin/redial/languages/classic"
import "lookkit"
import "lookkit/kit.js" as Kit

// re:dial classic's Sundial look: tools are hours round a gnomon; the sun follows the hand a breath
// behind and the dashed shadow points away from it. Turning and can't act use a half plate.
// Run: QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
Item {
  id: top
  width: 640; height: 440

  FakeCfg { id: fakeCfg }
  FakeCfg { id: movingCfg; motionBase: 200; motionFast: 140 }
  Language { id: lang }
  Component { id: lookComponent; Sundial { cfg: fakeCfg; language: lang; width: 640; height: plateSize.height } }
  Component { id: movingComponent; Sundial { cfg: movingCfg; language: lang; width: 640; height: plateSize.height } }

  TestCase {
    name: "ClassicSundial"
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
      compare(look.plateSize.width, 640); compare(look.plateSize.height, 440)
      compare(look.wantsCallout, true); compare(look.kind, "face")
      verify(look.calloutX > 440 && look.calloutX < 500)
      look.noteKind = "turn"; look.note = { name: "Volume", value: 42 }
      compare(look.plateSize.height, 330, "turning uses the half plate")
    }

    function test_selection_follows_index() {
      var look = make()
      look.index = 3
      tryCompare(look.selection, "deg", -90 + 3 * 45)
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

    function test_leader_meets_a_clamped_callout() {
      var look = make()
      look.index = 0
      var natural = look.leaderY
      look.landY = natural + 40
      compare(look.leaderEndY, natural + 40, "the leader bends to where the host put the callout")
      look.landY = -1
      compare(look.leaderEndY, natural)
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
      compare(look.litCount, 0)
      compare(look.stateDrawn, "ring")
      compare(look.plateSize.height, 440)
    }

    function test_hint_and_cant_states() {
      var look = make()
      look.noteKind = "hint"; look.note = { prompt: "Turn to pick", gesture: "turn" }
      compare(look.stateDrawn, "hint")
      compare(look.plateSize.height, 440, "a hint is about the ring, so the ring stays")
      look.noteKind = "cant"; look.note = { reason: "asleep", title: "Asleep", line: "Press to wake" }
      compare(look.stateDrawn, "cant")
      compare(look.plateSize.height, 330)
      compare(look.moonX, 2, "motion off: the moon is already over the sun")
    }

    function test_moon_slides_in_once() {
      var look = make(Kit.eight, movingComponent)
      look.noteKind = "cant"; look.note = { reason: "asleep" }
      verify(look.moonX > 2)
      tryCompare(look, "moonX", 2, 1000)
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
