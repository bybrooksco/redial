import QtQuick
import QtTest
import "../../plugin/redial/ActionGroups.js" as Groups

// The click picker's groups (ToolPicker's ActionPicker asks Groups.grouped).
TestCase {
  name: "ActionGroups"

  function test_every_action_shows_once_and_unknown_ones_go_under_more() {
    var acts = [{ name: "copy" }, { name: "launch_krita" }, { name: "dictation" }, { name: "mouse_left" }]
    var g = Groups.grouped(acts)
    compare(g.map(function (x) { return x.title }), ["Typing and dictation", "Pointer", "Editing", "More"])
    compare(g[3].items[0].name, "launch_krita")
    var n = 0; g.forEach(function (x) { n += x.items.length })
    compare(n, acts.length)
  }

  function test_no_action_is_in_two_groups() {
    var seen = {}
    for (var gr of Groups.GROUPS) for (var nm of gr.names) { verify(!seen[nm], nm); seen[nm] = true }
  }
}
