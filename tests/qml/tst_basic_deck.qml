import QtQuick
import QtTest
import "../../plugin/redial/languages/basic"
import "lookkit"
import "lookkit/kit.js" as Kit

// re:dial basic's Deck layout on the quiet track (spec 2026-11-06): a still fan of cards; the front
// card is the info card (icon, name, line) with a short accent bar as the marker.
// Run: QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
Item {
  id: top
  width: 320; height: 230
  FakeCfg { id: fakeCfg }
  Language { id: lang }
  Component { id: lookComponent; Deck { cfg: fakeCfg; language: lang; width: 320; height: 230 } }

  TestCase {
    name: "BasicDeck"
    when: windowShown
    function make(tools) {
      var look = createTemporaryObject(lookComponent, top)
      verify(look !== null, "the look loads with only QtQuick")
      look.tools = tools !== undefined ? tools : Kit.eight
      return look
    }

    function test_listed_by_the_language() { compare(lang.looks["deck"], "Deck.qml") }
    function test_plate_size() {
      var look = make()
      compare(look.plateSize.width, 320); compare(look.plateSize.height, 230)
      compare(look.wantsCallout, false); compare(look.kind, "layout")
    }
    function test_front_card_names_the_choice() {
      var look = make()
      look.index = 4
      compare(look.card.title, Kit.eight[4].name)
      compare(look.selection.rotation, 0, "the front card faces you")
    }
    function test_back_cards_do_not_move() {
      var look = make()
      var before = []
      for (var k = 0; k < look.backs.count; k++) before.push(look.backs.itemAt(k).rotation)
      look.index = 5
      for (k = 0; k < look.backs.count; k++) compare(look.backs.itemAt(k).rotation, before[k])
      compare(look.backs.count, 4)
    }
    function test_empty_tools_loads() { compare(make([]).stateDrawn, "ring") }
    function test_turn_meter() {
      var look = make()
      look.noteKind = "turn"; look.note = { name: "Volume", value: 42, valueText: "42%" }
      compare(look.litCount, 42)
      verify(Math.abs(look.meterBar.width - look.meterSpan * 0.42) < 0.6, "the bar reads the level")
    }
    function test_cant_dims_the_backs() {
      var look = make()
      var o = look.backs.itemAt(0).opacity
      look.noteKind = "cant"; look.note = { reason: "asleep", title: "Asleep" }
      verify(look.backs.itemAt(0).opacity < o)
      compare(look.frontSign.visible, true, "the sign takes the icon's place on the front card")
    }
    function test_markup_name_is_plain() {
      var look = make([{ icon: "a", name: "<b>x" }, { icon: "b", name: "<i>y" }])
      var t = Kit.texts(look)
      for (var i = 0; i < t.length; i++) compare(t[i].textFormat, Text.PlainText)
    }
  }
}
