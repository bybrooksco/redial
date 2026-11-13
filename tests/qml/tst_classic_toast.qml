import QtQuick
import QtTest
import "../../plugin/redial/languages/classic"
import "lookkit"
import "lookkit/kit.js" as Kit

// re:dial classic's Toast layout: a drawing's title block. Glyph cell, name and click action,
// and "Sheet n/N" (or the level) in the right cell.
// Run: QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
Item {
  id: top
  width: 400; height: 60

  FakeCfg { id: fakeCfg }
  Language { id: lang }
  Component { id: lookComponent; Toast { cfg: fakeCfg; language: lang; width: 400; height: 60 } }

  TestCase {
    name: "ClassicToast"
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
      compare(look.plateSize.width, 400); compare(look.plateSize.height, 60)
      compare(look.wantsCallout, false); compare(look.kind, "layout")
    }

    function test_selection_follows_index() {
      var look = make()
      look.index = 3
      compare(look.selection.text, "Scroll")
      compare(look.sheetText, "SHEET 4/8")
    }

    function test_live_follows_position_directly() {
      var look = make()
      look.live = true
      look.index = 2
      look.position = 2.5
      compare(look.selection.text, "Windows", "the toast names the chosen tool; the hand moves the index")
    }

    function test_turn_with_value_lights_scale() {
      var look = make()
      look.noteKind = "turn"; look.note = { name: "Volume", value: 42, valueText: "42%" }
      compare(look.litCount, 10)
      compare(look.stateDrawn, "turn")
      compare(look.selection.text, "Volume")
      compare(look.sheetText, "42%")
    }

    function test_turn_without_value_keeps_ring() {
      var look = make()
      look.noteKind = "turn"; look.note = { name: "Tabs" }
      compare(look.litCount, 0)
      compare(look.stateDrawn, "ring")
    }

    function test_hint_and_cant_states() {
      var look = make()
      look.noteKind = "hint"; look.note = { prompt: "Turn to pick", gesture: "turn", step: 2, steps: 3 }
      compare(look.stateDrawn, "hint")
      compare(look.selection.text, "Turn to pick")
      compare(look.sheetText, "NOTE 2")
      look.noteKind = "cant"; look.note = { reason: "asleep", title: "Asleep", line: "Press to wake" }
      compare(look.stateDrawn, "cant")
      compare(look.selection.text, "Asleep")
      compare(look.sheetText, "ASLEEP")
    }

    function test_one_and_twelve_tools() {
      var one = make(Kit.eight.slice(0, 1))
      compare(one.sheetText, "SHEET 1/1")
      var many = make(Kit.twelve())
      many.index = 11
      compare(many.sheetText, "SHEET 12/12")
    }

    function test_markup_name_is_plain() {
      var look = make([{ icon: "a", name: "<b>x" }, { icon: "b", name: "<i>y" }])
      var t = Kit.texts(look)
      verify(t.length > 0)
      for (var i = 0; i < t.length; i++) compare(t[i].textFormat, Text.PlainText, "Text " + i + " " + t[i].text)
    }
  }
}
