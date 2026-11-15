import QtQuick
import QtTest
import "../../plugin/redial" as Redial

// The Pen page's pen drawing loads, each callout lists what its part does now, callouts never
// overlap, and a changed setting shows its new value.
TestCase {
  name: "PenDiagram"
  when: windowShown
  width: 700; height: 420

  property var parts: [
    { x: 31, y: 15, title: "Tail button", where: "away", lines: [ { key: "Click", value: "Nothing" }, { key: "Double", value: "Enter" }, { key: "Hold", value: "Play / pause" } ] },
    { x: 31, y: 15, title: "Eraser", where: "on screen", lines: [ { key: "Tap", value: "Escape" }, { key: "Hold", value: "Nothing" } ] },
    { x: 131, y: 410, title: "Barrel button", where: "hover", lines: [ { key: "Press", value: "Right click" } ] },
    { x: 207, y: 580, title: "Tip", where: "screen", lines: [ { key: "Touch", value: "Draws" } ] }
  ]

  Redial.PenDiagram {
    id: d; width: 660; penHeight: 280; fontSize: 12
    lineColor: "black"; textColor: "black"; softColor: "gray"; accentColor: "red"
  }

  function init() { d.parts = parts }

  function texts(item, out) {
    out = out || []
    if (item.text !== undefined && item.text !== "") out.push(item.text)
    for (var i = 0; i < item.children.length; i++) texts(item.children[i], out)
    return out
  }

  function test_the_pen_art_loads_and_lists_every_current_action() {
    tryCompare(d.children[0], "status", Image.Ready)  // the Image is the first child
    var shown = texts(d)
    for (var w of ["Tail button", "Eraser", "Barrel button", "Tip", "Play / pause", "Right click"])
      verify(shown.indexOf(w) >= 0, w)
  }

  function test_callouts_never_overlap_and_fit_inside() {
    for (var i = 1; i < parts.length; i++)
      verify(d.tops[i] >= d.tops[i - 1] + d.calloutHeight(parts[i - 1]), "callout " + i + " clears the one above")
    verify(d.implicitHeight >= d.contentBottom, "the diagram is tall enough for its last callout")
    for (var c of parts) verify(c.x >= 0 && c.x <= d.vbW && c.y >= 0 && c.y <= d.vbH, c.title)
    verify(d.labelX > d.vbW * d.penScale, "labels sit to the right of the pen")
  }

  function test_a_changed_setting_shows_its_new_value() {
    tryCompare(d.children[0], "status", Image.Ready)
    var p = JSON.parse(JSON.stringify(parts))
    p[2].lines[0].value = "Copy"
    d.parts = p
    tryVerify(function () { return texts(d).indexOf("Copy") >= 0 })
    verify(texts(d).indexOf("Right click") < 0)
  }
}
