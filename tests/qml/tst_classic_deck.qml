import QtQuick
import QtTest
import "../../plugin/redial/languages/classic"
import "lookkit"
import "lookkit/kit.js" as Kit

// re:dial classic's Deck layout: a fan of drawing sheets; the chosen tool's sheet is in front.
// Run: QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
Item {
  id: top
  width: 544; height: 262

  FakeCfg { id: fakeCfg }
  Language { id: lang }
  Component { id: lookComponent; Deck { cfg: fakeCfg; language: lang; width: 544; height: 262 } }

  TestCase {
    name: "ClassicDeck"
    when: windowShown

    function make(tools) {
      var look = createTemporaryObject(lookComponent, top)
      verify(look !== null, "the look loads with only QtQuick")
      look.tools = tools || Kit.eight
      return look
    }
    function frontmost(look) {
      var best = null
      for (var i = 0; i < look.cards.count; i++) {
        var c = look.cards.itemAt(i)
        if (best === null || c.z > best.z) best = c
      }
      return best
    }

    function test_listed_by_the_language() { compare(lang.looks["deck"], "Deck.qml") }

    function test_plate_size() {
      var look = make()
      compare(look.plateSize.width, 544); compare(look.plateSize.height, 262)
      compare(look.wantsCallout, false); compare(look.kind, "layout")
    }

    function test_selection_follows_index() {
      var look = make()
      look.index = 3
      compare(look.selection.cardIndex, 3)
      verify(frontmost(look) === look.selection, "the chosen sheet is in front")
    }

    function test_wrap_is_one_sheet_on() {
      var look = make()
      look.index = 7
      compare(look.p, -1, "0 -> 7 is one sheet back")
      look.index = 0
      compare(look.p, 0)
    }

    function test_live_follows_position_directly() {
      var look = make()
      look.live = true
      look.position = 2.5
      compare(look.p, 2.5)
      look.position = 2.6
      compare(look.selection.cardIndex, 3, "the sheet nearest the hand is in front")
    }

    function test_turn_with_value_lights_scale() {
      var look = make()
      look.noteKind = "turn"; look.note = { name: "Volume", value: 42, valueText: "42%" }
      compare(look.litCount, 11, "i < 42 * .26, as the mockup lights them")
      compare(look.stateDrawn, "turn")
    }

    function test_turn_without_value_keeps_ring() {
      var look = make()
      look.noteKind = "turn"; look.note = { name: "Tabs" }
      compare(look.litCount, 0)
      compare(look.stateDrawn, "ring")
      verify(look.cards.count === 8 && look.selection.visible)
    }

    function test_hint_and_cant_states() {
      var look = make()
      look.noteKind = "hint"; look.note = { prompt: "Turn to pick", gesture: "turn" }
      compare(look.stateDrawn, "hint")
      look.noteKind = "cant"; look.note = { reason: "asleep", title: "Asleep", line: "Press to wake" }
      compare(look.stateDrawn, "cant")
    }

    function test_one_and_twelve_tools() {
      var one = make(Kit.eight.slice(0, 1))
      compare(one.selection.cardIndex, 0)
      var many = make(Kit.twelve())
      many.index = 11
      compare(many.selection.cardIndex, 11)
      verify(frontmost(many) === many.selection)
    }

    function test_markup_name_is_plain() {
      var look = make([{ icon: "a", name: "<b>x" }, { icon: "b", name: "<i>y" }])
      var t = Kit.texts(look)
      verify(t.length > 0)
      for (var i = 0; i < t.length; i++) compare(t[i].textFormat, Text.PlainText, "Text " + i + " " + t[i].text)
    }
  }
}
