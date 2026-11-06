import QtQuick
import QtTest
import "../../plugin/redial/languages/basic"
import "lookkit"
import "lookkit/kit.js" as Kit

// re:dial basic's List look (key "tag", was the Repair tag) on the quiet track (spec 2026-11-06):
// a vertical track at the left, rows of icon + name that scroll so the chosen tool is the middle
// row, a fixed accent marker at that row, and the shared card at the right.
// Run: QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
Item {
  id: top
  width: 340; height: 248
  FakeCfg { id: fakeCfg }
  Language { id: lang }
  Component { id: lookComponent; Tag { cfg: fakeCfg; language: lang; width: 340; height: 248 } }

  TestCase {
    name: "BasicTag"
    when: windowShown
    function make(tools) {
      var look = createTemporaryObject(lookComponent, top)
      verify(look !== null, "the look loads with only QtQuick")
      look.tools = tools !== undefined ? tools : Kit.eight
      return look
    }
    function middleRow(look) {
      for (var k = 0; k < look.rows.count; k++) if (look.rows.itemAt(k).slot === 0) return look.rows.itemAt(k)
      return null
    }

    function test_listed_by_the_language() { compare(lang.looks["tag"], "Tag.qml"); compare(lang.labels.tag, "List") }
    function test_plate_size() {
      var look = make()
      compare(look.plateSize.width, 340); compare(look.plateSize.height, 248)
      compare(look.wantsCallout, false); compare(look.kind, "face")
    }
    function test_chosen_row_is_the_middle_row() {
      var look = make()
      look.index = 3
      tryCompare(look, "listPos", 3, 1000)
      compare(middleRow(look).tool, 3)
      compare(middleRow(look).name, Kit.eight[3].name)
      verify(Math.abs(Kit.centre(middleRow(look), look)[1] - 124) < 0.6, "the middle row sits at the marker")
    }
    function test_marker_is_fixed_at_the_middle() {
      var look = make()
      var y0 = Kit.centre(look.selection, look)[1]
      look.index = 5
      compare(Kit.centre(look.selection, look)[1], y0)
      verify(Math.abs(y0 - 124) < 0.6)
    }
    function test_live_scrolls_directly() {
      var look = make()
      look.live = true
      look.position = 2.5
      compare(look.listPos, 2.5)
    }
    function test_wraps_the_short_way() {
      var look = make()
      look.index = 7
      tryCompare(look, "listPos", -1, 1000)
      compare(middleRow(look).tool, 7, "one row back wraps to the last tool")
      look.index = 0
      tryCompare(look, "listPos", 0, 1000)
    }
    function test_empty_tools_loads() { compare(make([]).stateDrawn, "ring") }
    function test_turn_fills() {
      var look = make()
      look.noteKind = "turn"; look.note = { name: "Volume", value: 42, valueText: "42%" }
      compare(look.litCount, 42); compare(look.stateDrawn, "turn")
      verify(!middleRow(look).visible, "rows hide while a level fills the track")
    }
    function test_hint_puts_the_sign_in_the_card() {
      var look = make()
      look.noteKind = "hint"; look.note = { prompt: "Press", gesture: "press" }
      compare(look.card.signShown, true); compare(look.trackInk, 0.5)
    }
    function test_card_takes_the_row_space_when_rows_hide() {
      var look = make()
      look.noteKind = "hint"; look.note = { prompt: "Turn to pick a tool", gesture: "turn", steps: 3, step: 1 }
      verify(look.card.x < look.u(100), "card moved left: " + look.card.x)
      verify(look.card.x + look.card.width <= look.width)
    }
    function test_card_line_is_the_click_action() {
      var look = make()
      compare(look.card.title, "Volume"); compare(look.card.line, "mute")
    }
    function test_markup_name_is_plain() {
      var look = make([{ icon: "a", name: "<b>x" }, { icon: "b", name: "<i>y" }])
      var t = Kit.texts(look)
      for (var i = 0; i < t.length; i++) compare(t[i].textFormat, Text.PlainText)
    }
  }
}
