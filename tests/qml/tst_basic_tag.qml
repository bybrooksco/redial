import QtQuick
import QtTest
import "../../plugin/redial/languages/basic"
import "lookkit"
import "lookkit/kit.js" as Kit

// re:dial basic's Repair Tag look: a paper luggage tag on its string, set in Bricolage. The ring is
// a two-column checklist with an accent marker; a level punches real holes through the paper; can't
// act stamps it. Run: QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
Item {
  id: top
  width: 350; height: 316
  FakeCfg { id: fakeCfg }
  FakeCfg { id: movingCfg; motionBase: 200; motionFast: 140 }
  Language { id: lang }
  Component { id: lookComponent; Tag { cfg: fakeCfg; language: lang; width: plateSize.width; height: plateSize.height } }
  Component { id: movingComponent; Tag { cfg: movingCfg; language: lang; width: plateSize.width; height: plateSize.height } }

  TestCase {
    name: "BasicTag"
    when: windowShown
    function make(tools, comp) {
      var look = createTemporaryObject(comp || lookComponent, top)
      verify(look !== null, "the look loads with only QtQuick")
      look.tools = tools || Kit.eight
      return look
    }
    function at(item, look) { var p = item.mapToItem(look, 0, 0); return [Math.round(p.x), Math.round(p.y)] }

    function test_listed_by_the_language() { compare(lang.looks["tag"], "Tag.qml") }
    function test_plate_size() {
      var look = make()
      compare(look.plateSize.width, 350); compare(look.plateSize.height, 240)
      compare(look.wantsCallout, false); compare(look.kind, "face")
      look.noteKind = "turn"; look.note = { name: "Volume", value: 42 }
      compare(look.plateSize.width, 340); compare(look.plateSize.height, 172)
      look.noteKind = "hint"; look.note = { prompt: "Turn to pick", gesture: "turn", step: 1, steps: 3 }
      compare(look.plateSize.height, 124 + 10 + 172, "a hint tag hangs over the tool's tag")
    }
    function test_selection_follows_index() {
      var look = make()
      look.index = 3
      compare(at(look.selection, look), [54, 42 + 3 * 34])
      look.index = 5
      compare(at(look.selection, look), [54 + 136, 42 + 34])
    }
    function test_live_follows_position_directly() {
      var look = make()
      look.live = true; look.index = 2; look.position = 2.5
      compare(at(look.selection, look)[1], 42 + 2 * 34, "the marker is on the chosen row; the hand moves the index")
    }
    function test_turn_with_value_lights_scale() {
      var look = make()
      look.noteKind = "turn"; look.note = { name: "Volume", value: 42, valueText: "42%" }
      compare(look.litCount, 4, "4 of 10 holes punched")
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
      look.noteKind = "hint"; look.note = { prompt: "Turn to pick", gesture: "turn" }
      compare(look.stateDrawn, "hint")
      compare(look.plateSize.height, 104 + 10 + 172, "no steps: the short hint tag")
      look.noteKind = "cant"; look.note = { reason: "asleep", title: "Asleep", line: "Press to wake" }
      compare(look.stateDrawn, "cant")
      compare(look.stamp.text, "ASLEEP")
      compare(look.stamp.opacity, 1, "motion off: the stamp is down")
    }
    function test_stamp_lands_once() {
      var look = make(Kit.eight, movingComponent)
      look.noteKind = "cant"; look.note = { reason: "waiting" }
      compare(look.stamp.opacity, 0, "it waits 90 ms before landing")
      tryCompare(look.stamp, "opacity", 1, 1000)
      compare(look.stamp.scale, 1)
    }
    function test_swings_from_its_eyelet() {
      var look = make(Kit.eight, movingComponent)
      compare(look.swing.origin.x, 26); compare(look.swing.origin.y, 120)
      tryCompare(look.swing, "angle", 0, 1000)
      compare(look.scale, 1, "a tag swings, never scales")
    }
    function test_one_and_twelve_tools() {
      var one = make(Kit.eight.slice(0, 1))
      compare(at(one.selection, one), [54, 42])
      var many = make(Kit.twelve())
      many.index = 11
      var p = at(many.selection, many)
      verify(p[1] + many.selection.height <= 42 + 136, "the last row stays in the list: " + p[1])
      compare(p[0], 54 + 136, "second column")
    }
    function test_markup_name_is_plain() {
      var look = make([{ icon: "a", name: "<b>x" }, { icon: "b", name: "<i>y" }])
      var t = Kit.texts(look)
      verify(t.length > 0)
      for (var i = 0; i < t.length; i++) compare(t[i].textFormat, Text.PlainText, "Text " + i + " " + t[i].text)
    }
  }
}
