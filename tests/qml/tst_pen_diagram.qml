import QtQuick
import QtTest
import "../../plugin/redial" as Redial

// The Pen page's pen drawing loads, and each callout sits on the pen beside its label.
TestCase {
  name: "PenDiagram"
  when: windowShown
  width: 600; height: 320

  Redial.PenDiagram { id: d; width: 560; penHeight: 280; lineColor: "black"; textColor: "black"; softColor: "gray" }

  function test_the_pen_art_loads_and_shows_three_callouts() {
    tryCompare(d.children[0], "status", Image.Ready)  // the Image is the first child
    compare(d.callouts.length, 3)
    compare(d.callouts.map(function (c) { return c.title }), ["Tail button", "Barrel button", "Tip"])
  }

  function test_every_callout_point_is_inside_the_drawing() {
    for (var c of d.callouts) {
      verify(c.x >= 0 && c.x <= d.vbW, c.title)
      verify(c.y >= 0 && c.y <= d.vbH, c.title)
    }
    verify(d.labelX > d.vbW * d.scale, "labels sit to the right of the pen")
  }
}
