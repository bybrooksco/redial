import QtQuick
import QtTest
import "../../plugin/redial/languages/basic"
import "lookkit"
import "lookkit/kit.js" as Kit

// re:dial basic's Gauge look on the quiet track (spec 2026-11-06): an arc track from 135° over 270°,
// icons one gap inside it on each tool's angle, the shared card under it.
// Run: QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
Item {
  id: top
  width: 320; height: 250
  FakeCfg { id: fakeCfg }
  Language { id: lang }
  Component { id: lookComponent; Gauge { cfg: fakeCfg; language: lang; width: 320; height: 250 } }

  TestCase {
    name: "BasicGauge"
    when: windowShown
    function make(tools) {
      var look = createTemporaryObject(lookComponent, top)
      verify(look !== null, "the look loads with only QtQuick")
      look.tools = tools !== undefined ? tools : Kit.eight
      return look
    }
    function near(a, b, msg) { verify(Math.abs(a - b) < 0.6, msg + ": " + a + " vs " + b) }
    function angleOf(i, n) { return n > 1 ? 135 + i * 270 / (n - 1) : 135 + 270 / 2 }

    function test_listed_by_the_language() { compare(lang.looks["gauge"], "Gauge.qml") }
    function test_plate_size() {
      var look = make()
      compare(look.plateSize.width, 320); compare(look.plateSize.height, 250)
      compare(look.wantsCallout, false); compare(look.kind, "face")
    }
    function test_plate_never_changes_with_state() {
      var look = make()
      var states = [["", {}], ["turn", { name: "Volume", value: 42 }], ["hint", { prompt: "Press", gesture: "press" }], ["cant", { reason: "asleep", title: "Asleep" }]]
      for (var k = 0; k < states.length; k++) {
        look.noteKind = states[k][0]; look.note = states[k][1]
        compare(look.plateSize.width, 320); compare(look.plateSize.height, 250)
      }
    }
    function test_selection_follows_index() {
      var look = make()
      look.index = 3
      tryCompare(look.selection, "rotation", angleOf(3, 8), 1000)
    }
    function test_live_follows_position_directly() {
      var look = make()
      look.live = true
      look.position = 2.5
      compare(look.selection.rotation, 135 + 2.5 * 270 / 7)
    }
    function test_one_tool_sits_in_the_middle() {
      var look = make(Kit.eight.slice(0, 1))
      compare(look.selection.rotation, angleOf(0, 1))
    }
    function test_icons_on_their_angles() {
      var look = make()
      for (var i = 0; i < 8; i++) {
        var c = Kit.centre(look.icons.itemAt(i), look), dx = c[0] - 160, dy = c[1] - 100
        near(Math.sqrt(dx * dx + dy * dy), 74 - 20, "icon " + i + " radius")
        var a = Math.atan2(dy, dx) * 180 / Math.PI, want = angleOf(i, 8)
        verify(Math.abs(((a - want) % 360 + 540) % 360 - 180) < 0.5, "icon " + i + " angle " + a + " vs " + want)
      }
    }
    function test_empty_tools_loads() { compare(make([]).stateDrawn, "ring") }
    function test_turn_fills() {
      var look = make()
      look.noteKind = "turn"; look.note = { name: "Volume", value: 42, valueText: "42%" }
      compare(look.litCount, 42); compare(look.stateDrawn, "turn")
      verify(!look.selection.visible)
    }
    function test_hint_mutes_the_track() {
      var look = make()
      look.noteKind = "hint"; look.note = { prompt: "Press", gesture: "press" }
      compare(look.trackInk, 0.5)
    }
    function test_card_sits_under_the_arc_on_the_plate() {
      var look = make()
      verify(look.card.y > 100 - 10, "under the arc"); verify(look.card.y + look.card.height <= look.height)
      near(look.card.x + look.card.width / 2, 160, "centred")
    }
    function test_markup_name_is_plain() {
      var look = make([{ icon: "a", name: "<b>x" }, { icon: "b", name: "<i>y" }])
      var t = Kit.texts(look)
      for (var i = 0; i < t.length; i++) compare(t[i].textFormat, Text.PlainText)
    }
  }
}
