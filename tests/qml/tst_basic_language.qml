import QtQuick
import QtTest
import "../../plugin/redial/languages/basic" as Basic
import "../../plugin/redial/languages/basic/Tones.js" as Tones

// re:dial basic's language file and its tones.
// Run: QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
TestCase {
  name: "BasicLanguage"
  Basic.Language { id: lang }
  readonly property var roles: ({ ground: "#222222", line: "#c2c2b0", accent: "#78824b", alert: "#bb7744" })

  function test_nine_looks_and_no_classic() {
    compare(lang.name, "re:dial basic")
    compare(lang.lookCount, 9)
    compare(lang.defaultLook, "capsule")
    verify(lang.looks["classic"] === undefined, "basic ships no Classic")
    compare(lang.easeDrawer.length, 6)
  }

  function test_bundled_faces_load() {
    tryVerify(function () { return lang.faceSundial !== "" && lang.faceTag !== "" && lang.faceStandard !== "" }, 3000)
    compare(lang.faceStandard, "Barlow Semi Condensed")
    compare(lang.faceSundial, "Fraunces")
  }

  function test_tones_step_from_ground_toward_line() {
    var t = Tones.tones(roles)
    compare(t.ground, "#222222"); compare(t.ink, "#c2c2b0")
    compare(t.rim, Tones.mix("#222222", "#c2c2b0", 0.06))
    verify(Tones.luminance(t.surface) > Tones.luminance(t.rim) && Tones.luminance(t.card) > Tones.luminance(t.surface))
    verify(Tones.luminance(t.soft) > Tones.luminance(t.muted))
  }

  function test_onaccent_is_the_more_readable_of_ground_and_line() {
    compare(Tones.tones({ ground: "#000000", line: "#ffffff", accent: "#ffcc00", alert: "#f00" }).onaccent, "#000000")
    compare(Tones.tones({ ground: "#000000", line: "#ffffff", accent: "#202080", alert: "#f00" }).onaccent, "#ffffff")
  }

  function test_ratio_matches_the_wcag_formula() {
    compare(Tones.ratio("#000000", "#ffffff").toFixed(2), "21.00")
    compare(Tones.ratio("#777777", "#777777"), 1)
  }

  function test_paper_turns_the_scheme_over() {
    var p = Tones.paper(roles)
    compare(p.paper, "#c2c2b0"); compare(p.ink, "#222222")
    verify(Tones.luminance(p.hole) < Tones.luminance("#222222"), "a hole is darker than the ground")
  }
}
