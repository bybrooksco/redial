import QtQuick
import QtTest
import "../../plugin/redial/languages/classic"

// The Classic look of re:dial classic, driven the way DialMenu drives it.
// Run: QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
Item {
  id: top
  width: 880; height: 580

  // A stand-in for Settings.qml: only what a look reads. Motion is zero so values settle at once.
  QtObject {
    id: fakeCfg
    signal changed()
    property var roles: ({ ground: "#f3f0e7", line: "#1c1e21", accent: "#c4452a", alert: "#9a3412" })
    property int motionBase: 0
    property int motionFast: 0
    property int motionFade: 120
    property real ringWidth: 1
    property int barCount: 180
    property int majorEvery: 15
    property real sectorFill: 0.86
    property real barWidthMinor: 1
    property real barWidthMajor: 2
    property real barWidthActive: 2.5
    property real needleWidth: 2
    property bool constructionLines: true
    property string plate: "rect"
    property bool showLabels: true
    property bool showGlyphs: true
    property bool showCallout: true
  }

  Language { id: lang }

  readonly property var eight: [
    { icon: "a", name: "Volume", hint: "mute", valueText: "42%" }, { icon: "b", name: "Workspaces" },
    { icon: "c", name: "Windows" }, { icon: "d", name: "Scroll" }, { icon: "e", name: "Zoom" },
    { icon: "f", name: "Tabs" }, { icon: "g", name: "Focus" }, { icon: "h", name: "Select" }
  ]

  Component { id: lookComponent; Classic { cfg: fakeCfg; language: lang; width: 880; height: 580 } }

  TestCase {
    name: "ClassicLook"
    when: windowShown

    function make(tools) {
      var look = createTemporaryObject(lookComponent, top)
      verify(look !== null, "the look loads with only QtQuick")
      look.tools = tools
      return look
    }

    function test_the_language_lists_its_classic_look() {
      compare(lang.name, "re:dial classic")
      compare(lang.looks["classic"], "Classic.qml")
      compare(lang.easeOut.length, 6)
    }

    function test_live_the_hand_follows_the_position_directly() {
      var look = make(top.eight)
      look.live = true
      look.position = 2.5
      compare(look.needleDeg, -90 + 2.5 * 45)
      look.position = 7.9
      compare(look.needleDeg, -90 + 7.9 * 45)
    }

    function test_stepped_goes_the_short_way_round() {
      var look = make(top.eight)
      look.live = false
      look.index = 7
      compare(look.steppedDeg, -90 - 45, "0 -> 7 is one sector back, not seven forward")
      look.index = 0
      compare(look.steppedDeg, -90, "7 -> 0 is one sector forward")
    }

    function test_leaving_live_picks_the_hand_up_where_it_was() {
      var look = make(top.eight)
      look.live = true
      look.position = 3.2
      look.live = false
      compare(look.steppedDeg, look.liveDeg)
      compare(look.needleDeg, -90 + 3.2 * 45)
    }

    function test_the_leader_follows_the_chosen_tool_even_while_live() {
      var look = make(top.eight)
      look.live = true
      look.index = 2
      compare(look.leaderDeg, -90 + 2 * 45)
      verify(look.leaderY > look.cy - 1, "Windows sits at 3 o'clock, so the callout centres near the middle")
    }

    function test_the_chosen_label_is_hidden_and_its_glyph_grows() {
      var look = make(top.eight)
      look.index = 4
      wait(0)
      var labels = [], glyphs = []
      for (var i = 0; i < look.children.length; i++) {
        var c = look.children[i]
        if (c.room !== undefined) labels.push(c)
        else if (c.a !== undefined && c.active !== undefined) glyphs.push(c)
      }
      compare(labels.length, 8)
      compare(glyphs.length, 8)
      for (var j = 0; j < 8; j++) {
        compare(labels[j].opacity, labels[j].index === 4 ? 0 : 1, "label " + j)
        var g = glyphs[j].children[0]
        compare(g.scale > 1, glyphs[j].index === 4, "glyph " + j)
      }
    }

    function test_no_tools_still_draws() {
      var look = make([])
      compare(look.n, 1)
      look.index = 0
      look.position = 0.4
      verify(isFinite(look.needleDeg))
    }
  }
}
