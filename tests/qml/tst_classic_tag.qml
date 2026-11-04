import QtQuick
import QtTest
import "../../plugin/redial/languages/classic"
import "lookkit"
import "lookkit/kit.js" as Kit

// re:dial classic's Repair tag look: the dial's tools as a checklist on a drawn tag; a level is
// punched holes; can't act stamps the tag.
// Run: QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
Item {
  id: top
  width: 640; height: 330

  FakeCfg { id: fakeCfg }
  FakeCfg { id: movingCfg; motionBase: 200; motionFast: 140 }
  Language { id: lang }
  Component { id: lookComponent; Tag { cfg: fakeCfg; language: lang; width: 640; height: 330 } }
  Component { id: movingComponent; Tag { cfg: movingCfg; language: lang; width: 640; height: 330 } }

  TestCase {
    name: "ClassicTag"
    when: windowShown

    function make(tools, comp) {
      var look = createTemporaryObject(comp || lookComponent, top)
      verify(look !== null, "the look loads with only QtQuick")
      look.tools = tools || Kit.eight
      return look
    }

    function test_listed_by_the_language() { compare(lang.looks["tag"], "Tag.qml") }

    function test_plate_size() {
      var look = make()
      compare(look.plateSize.width, 640); compare(look.plateSize.height, 330)
      compare(look.wantsCallout, true); compare(look.kind, "face")
      compare(look.calloutX, 456)
    }

    function test_selection_follows_index() {
      var look = make()
      look.index = 3
      compare(look.selection.x, 112); compare(look.selection.y, 84 + 3 * 34)
      look.index = 5
      compare(look.selection.x, 112 + 132); compare(look.selection.y, 84 + 34)
    }

    function test_live_follows_position_directly() {
      var look = make()
      look.live = true
      look.index = 2
      look.position = 2.5
      compare(look.selection.y, 84 + 2 * 34, "the marker is on the chosen row; the hand moves the index")
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
      compare(look.litCount, 0)
      compare(look.stateDrawn, "ring")
      verify(look.selection.visible)
    }

    function test_hint_and_cant_states() {
      var look = make()
      look.noteKind = "hint"; look.note = { prompt: "Turn to pick", gesture: "turn" }
      compare(look.stateDrawn, "hint")
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

    function test_one_and_twelve_tools() {
      var one = make(Kit.eight.slice(0, 1))
      compare(one.selection.y, 84)
      var many = make(Kit.twelve())
      many.index = 11
      verify(many.selection.y + many.selection.height <= 62 + 196, "the last row stays on the tag")
      verify(many.selection.x > 112, "second column")
    }

    function test_markup_name_is_plain() {
      var look = make([{ icon: "a", name: "<b>x" }, { icon: "b", name: "<i>y" }])
      var t = Kit.texts(look)
      verify(t.length > 0)
      for (var i = 0; i < t.length; i++) compare(t[i].textFormat, Text.PlainText, "Text " + i + " " + t[i].text)
    }
  }
}
