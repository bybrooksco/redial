import QtQuick
import QtTest
import "../../plugin/redial/languages/basic"
import "lookkit"
import "lookkit/kit.js" as Kit

// re:dial basic's Capsule look on the quiet track (spec 2026-11-06): a full-ring track, an accent marker,
// icons one gap inside the track, the shared card at the right.
// Run: QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
Item {
  id: top
  width: 340; height: 248
  FakeCfg { id: fakeCfg }
  Language { id: lang }
  Component { id: lookComponent; Capsule { cfg: fakeCfg; language: lang; width: 340; height: 248 } }

  TestCase {
    name: "BasicCapsule"
    when: windowShown
    function make(tools) {
      var look = createTemporaryObject(lookComponent, top)
      verify(look !== null, "the look loads with only QtQuick")
      look.tools = tools !== undefined ? tools : Kit.eight
      return look
    }
    function near(a, b, msg) { verify(Math.abs(a - b) < 0.6, msg + ": " + a + " vs " + b) }

    function test_listed_by_the_language() { compare(lang.looks["capsule"], "Capsule.qml") }
    function test_plate_size() {
      var look = make()
      compare(look.plateSize.width, 340); compare(look.plateSize.height, 248)
      compare(look.wantsCallout, false); compare(look.kind, "face")
    }
    function test_selection_follows_index() {
      var look = make()
      look.index = 3
      tryCompare(look.selection, "rotation", 3 * 45, 1000)
    }
    function test_live_follows_position_directly() {
      var look = make()
      look.live = true
      look.position = 2.5
      compare(look.selection.rotation, 2.5 * 45)
    }
    function test_wraps_the_short_way() {
      var look = make()
      look.index = 7
      tryCompare(look.selection, "rotation", -45, 1000)   // 0 -> 7 is one step back
      look.index = 0
      tryCompare(look.selection, "rotation", 0, 1000)     // 7 -> 0 is one step forward
    }
    function test_reduced_motion_lands_at_once() {
      var look = make()
      fakeCfg.motionBase = 0
      look.index = 2
      compare(look.selection.rotation, 90)
    }
    function test_icons_sit_one_gap_inside_the_track_on_their_angle() {
      var look = make()
      for (var i = 0; i < 8; i++) {
        var c = Kit.centre(look.icons.itemAt(i), look)
        var dx = c[0] - 112, dy = c[1] - 124
        near(Math.sqrt(dx * dx + dy * dy), 90 - 20, "icon " + i + " radius")
        var a = Math.atan2(dy, dx) * 180 / Math.PI, want = -90 + i * 45
        var d = ((a - want) % 360 + 540) % 360 - 180
        verify(Math.abs(d) < 0.5, "icon " + i + " angle " + a + " vs " + want)
      }
    }
    function test_chosen_icon_takes_the_accent() {
      var look = make()
      look.index = 2
      verify(look.icons.itemAt(2).on); verify(!look.icons.itemAt(1).on)
    }
    function test_twelve_tools_do_not_crowd() {
      var look = make(Kit.twelve())
      var a = Kit.centre(look.icons.itemAt(0), look), b = Kit.centre(look.icons.itemAt(1), look)
      verify(Math.hypot(a[0] - b[0], a[1] - b[1]) >= look.iconOnPx, "neighbours overlap")
    }
    function test_one_tool() {
      var look = make(Kit.eight.slice(0, 1))
      compare(look.selection.rotation, 0)
    }
    function test_empty_tools_loads() {
      var look = make([])
      compare(look.stateDrawn, "ring")
    }
    function test_turn_fills_the_track() {
      var look = make()
      look.noteKind = "turn"; look.note = { name: "Volume", value: 42, valueText: "42%" }
      compare(look.litCount, 42); compare(look.stateDrawn, "turn")
      verify(!look.selection.visible, "the marker hides while a level shows")
    }
    function test_hint_and_cant_mute_the_track() {
      var look = make()
      look.noteKind = "hint"; look.note = { prompt: "Press", gesture: "press" }
      compare(look.trackInk, 0.5); compare(look.stateDrawn, "hint")
      look.noteKind = "cant"; look.note = { reason: "asleep", title: "Asleep" }
      compare(look.stateDrawn, "cant")
    }
    function test_card_names_the_choice() {
      var look = make()
      look.index = 4
      compare(look.card.title, Kit.eight[4].name)
      verify(look.card.x >= 210, "the card sits right of the ring")
    }
    function test_markup_name_is_plain() {
      var look = make([{ icon: "a", name: "<b>x" }, { icon: "b", name: "<i>y" }])
      var t = Kit.texts(look)
      for (var i = 0; i < t.length; i++) compare(t[i].textFormat, Text.PlainText)
    }
    function test_card_stays_on_the_plate() {
      var look = make()
      look.noteKind = "hint"; look.note = { prompt: "Turn the dial to pick a tool from the ring", gesture: "turn" }
      verify(look.card.x + look.card.width <= look.width, "card right edge " + (look.card.x + look.card.width))
    }
    function test_track_is_segmented() { compare(make().segmented, true) }
      function test_tool_count_change_lands_on_the_choice() {
      var look = make()
      look.index = 2
      tryCompare(look.selection, "rotation", 90, 1000)
      look.tools = Kit.eight.slice(0, 5)
      compare(look.selection.rotation, 2 * 72, "re-based to the new spacing at once")
      look.index = 3
      tryCompare(look.selection, "rotation", 3 * 72, 1000)
    }
    function test_tool_count_shrinking_under_the_choice_clamps() {
      var look = make()
      look.index = 7
      tryCompare(look.selection, "rotation", -45, 1000)
      look.tools = Kit.eight.slice(0, 3)
      compare(look.chosen, 2)
      verify(Math.abs((((look.selection.rotation % 360) + 360) % 360) - 240) < 0.6, "marker on tool 2: " + look.selection.rotation)
    }
    function test_long_hint_wraps_instead_of_cutting() {
      var look = make()
      look.noteKind = "hint"
      look.note = { prompt: "Too fast or slow? Menu > Setup > re:dial > Feel", line: "This app turns scrolling into prompt history", gesture: "press" }
      var t = Kit.texts(look.card)
      for (var i = 0; i < t.length; i++) if (t[i].visible) compare(t[i].truncated, false, "'" + t[i].text + "' is cut")
      verify(look.card.y >= 0 && look.card.y + look.card.height <= look.height, "the card stays on the plate")
    }
  }
}
