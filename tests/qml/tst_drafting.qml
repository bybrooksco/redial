import QtQuick
import QtTest
import "../../plugin/redial/languages/classic/Drafting.js" as Drafting

// The shared drawing helpers of re:dial classic (hatching, revision clouds, dimension arcs, scales).
// Run: QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
TestCase {
  name: "Drafting"

  function fuzzy(a, b) { return Math.abs(a - b) < 1e-9 }

  function test_polar_quarter_turns() {
    var p = Drafting.polar(0, 0, 10, 0);   verify(fuzzy(p[0], 10) && fuzzy(p[1], 0))
    p = Drafting.polar(0, 0, 10, 90);      verify(fuzzy(p[0], 0) && fuzzy(p[1], 10), "y grows down the screen")
    p = Drafting.polar(5, 5, 10, 180);     verify(fuzzy(p[0], -5) && fuzzy(p[1], 5))
  }

  function test_cloud_bump_count() {
    compare(Drafting.cloudRectArcs(100, 40, 20), 2 * 5 + 2 * 2, "bump is the scallop diameter")
    compare(Drafting.cloudRectArcs(10, 10, 10), 2 * 2 + 2 * 1, "at least two bumps across, one down")
  }

  function test_ink_alpha_string() {
    compare(Drafting.ink("#1c1e21", 0.5), "rgba(28,30,33,0.5)")
    compare(Drafting.ink("#ffffff", 1), "rgba(255,255,255,1)")
  }

  function test_lit_count_rounds() {
    compare(Drafting.litCount(42, 24), 10)
    compare(Drafting.litCount(42, 135), 57)
    compare(Drafting.litCount(0, 24), 0)
    compare(Drafting.litCount(100, 24), 24)
    compare(Drafting.litCount(150, 24), 24, "clamped")
  }
}
