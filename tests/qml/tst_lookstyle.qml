import QtQuick
import QtTest
import "../../plugin/redial/languages/classic" as Classic
import "../../plugin/redial/languages/basic" as Basic
import "../../plugin/redial/languages/classic/Drafting.js" as Drafting
import "lookkit"

// The look-wide style (backing, line weight, scale density) reaches every look, not only Classic.
// Run: QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
Item {
  id: top
  width: 400; height: 400

  FakeCfg { id: fakeCfg }
  Classic.Language { id: classicLang }
  Basic.Language { id: basicLang }
  Component { id: gauge; Classic.Gauge { cfg: fakeCfg; language: classicLang; width: 400; height: 376 } }
  Component { id: wheel; Classic.Wheel { cfg: fakeCfg; language: classicLang; width: 400; height: 400 } }
  Component { id: basicCapsule; Basic.Capsule { cfg: fakeCfg; language: basicLang; width: 400; height: 400 } }
  QtObject {
    id: bareCfg
    signal changed()
    property var roles: fakeCfg.roles
  }
  Component { id: bare; Classic.Gauge { cfg: bareCfg; language: classicLang } }

  TestCase {
    name: "LookStyle"
    when: windowShown
    function init() { fakeCfg.plateOpacity = 1; fakeCfg.lineScale = 1; fakeCfg.density = 1 }

    function test_backing_sets_how_solid_the_plate_is() {
      var look = createTemporaryObject(gauge, top)
      compare(look.plateFill.a, 1)
      fakeCfg.plateOpacity = 0.7
      fuzzyCompare(look.plateFill.a, 0.7, 0.01)
      var b = createTemporaryObject(basicCapsule, top)
      fuzzyCompare(b.backed(b.tone.ground).a, 0.7, 0.01)
    }

    function test_line_weight_scales_the_basic_track() {
      var b = createTemporaryObject(basicCapsule, top)
      compare(b.trackW, 8)
      fakeCfg.lineScale = 0.5; compare(b.trackW, 6)
      fakeCfg.lineScale = 1.75; compare(b.trackW, 11)
    }

    function test_line_weight_reaches_the_drafting_helpers_through_the_context() {
      compare(Drafting.weightOf({}), 1, "a context nobody set draws at Normal")
      compare(Drafting.weightOf({ __w: 1.75 }), 1.75)
    }

    function test_density_sets_how_many_marks_a_scale_has() {
      var g = createTemporaryObject(gauge, top), w = createTemporaryObject(wheel, top)
      compare(g.marks, 135); compare(w.marks, 100)
      fakeCfg.density = 0.5; compare(g.marks, 72); compare(w.marks, 50)
      fakeCfg.density = 2; compare(g.marks, 270); compare(w.marks, 200)
      compare(g.marks / g.majorStep, 9, "the majors stay where they were")
    }

    function test_a_host_without_the_style_draws_solid_normal_medium() {
      var look = createTemporaryObject(bare, top)
      compare(look.backing, 1); compare(look.lineScale, 1); compare(look.density, 1)
      compare(look.marks, 135)
    }
  }
}
