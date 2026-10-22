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

    function test_left_side_leaders_go_round_the_scale_not_across_it() {
      var look = make(top.eight)
      for (var i = 0; i < 8; i++) {
        var r = look.leaderRoute(-90 + i * 45)
        verify(Math.cos(r.a) > -0.06, "tool " + i + " leaves the dial on the right")
        if (!r.left) continue
        var off = ((r.a * 180 / Math.PI + 90) % 45 + 45) % 45
        fuzzyCompare(off, 22.5, 1e-6, "tool " + i + " leaves between two labels, not through one")
        compare(Math.sin(r.a) < 0, r.up, "tool " + i + " stays on its side of level")
      }
      verify(look.leaderRoute(-90 + 7 * 45).left && look.leaderRoute(-90 + 7 * 45).up, "Select goes over the top")
      verify(look.leaderRoute(-90 + 5 * 45).left && !look.leaderRoute(-90 + 5 * 45).up, "Tabs goes under")
      verify(look.leaderRoute(-90 + 6 * 45).up, "Focus, level with the hub, goes over the top")
      verify(!look.leaderRoute(-90 + 2 * 45).left, "Windows on the right goes straight out")
    }

    function test_a_clamped_callout_is_met_round_the_scale_not_across_it() {
      var look = make(top.eight)
      var bottom = -90 + 4 * 45   // Zoom, straight down
      var land = look.cy + 150     // the host held the callout higher than the leader's natural run
      var r = look.leaderRoute(bottom, land)
      fuzzyCompare(look.cy + Math.sin(r.a) * (look.rRule + look.u(36)), land, 1e-6, "the level run meets the callout")
      verify(Math.cos(r.a) > 0, "it leaves on the right")
      verify(!r.cw, "from the bottom up the right side is anticlockwise")
      var free = look.leaderRoute(bottom, look.cy + look.rRule + look.u(36))
      compare(free.a, bottom * Math.PI / 180, "an unclamped callout changes nothing")
    }

    function test_a_level_takes_the_scale_and_the_hand() {
      var look = make(top.eight)
      look.index = 3
      look.note = { name: "Volume", value: 50, valueText: "50%" }
      look.noteKind = "turn"
      verify(look.levelShown)
      compare(look.levelDeg, 90, "50% is half way round from the top")
      tryCompare(look, "needleDeg", 90)
      compare(look.ringInk, 0, "the tool ring steps aside")
      tryCompare(look, "leaderY", look.cy + look.rRule + look.u(36))
      look.note = { name: "Volume", value: 140, valueText: "140%" }
      compare(look.levelDeg, 270, "a level over 100 pins at full scale")
    }

    function test_a_turn_without_a_level_keeps_the_ring() {
      var look = make(top.eight)
      look.noteKind = "turn"
      look.note = { name: "Zoom" }
      verify(!look.levelShown)
      compare(look.ringInk, 1)
    }

    function test_hints_and_cant_act_set_the_ring_back() {
      var look = make(top.eight)
      look.noteKind = "hint"
      look.note = { prompt: "Now press it", gesture: "press" }
      compare(look.ringInk, 0.55)
      look.noteKind = "cant"
      look.note = { reason: "asleep", title: "Dial went to sleep", line: "Press it once to wake it" }
      compare(look.ringInk, 0.35)
      look.noteKind = ""
      compare(look.ringInk, 1)
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
