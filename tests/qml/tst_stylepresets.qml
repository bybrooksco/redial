import QtQuick
import QtTest
import "../../plugin/redial/StylePresets.js" as Presets

// The Look page's Style block (ToolPicker asks Presets.weightOf and Presets.drawn).
TestCase {
  name: "StylePresets"

  function test_an_untouched_config_reads_as_normal_weight() {
    compare(Presets.weightOf(undefined), "normal")
    compare(Presets.weightOf({ barCount: 90 }), "normal")
  }

  function test_each_preset_is_recognised_and_a_hand_set_width_matches_none() {
    for (var p of Presets.WEIGHT) compare(Presets.weightOf(p.w), p.key)
    var bold = Object.assign({}, Presets.WEIGHT[2].w, { needleWidth: 9 })
    compare(Presets.weightOf(bold), "")
  }

  function test_controls_the_look_does_not_draw_are_greyed() {
    verify(Presets.drawn("labels", "dial", "classic", "rect"))
    verify(!Presets.drawn("labels", "dial", "capsule", "disc"))
    verify(Presets.drawn("crosshair", "dial", "capsule", "disc"))
    verify(!Presets.drawn("registrationMarks", "dial", "capsule", "disc"))
    verify(!Presets.drawn("weight", "dial", "pie", "disc"))
    verify(!Presets.drawn("colors", "omarchy", "classic", "rect"))
    verify(!Presets.drawn("density", "toast", "classic", "rect"))
    verify(Presets.drawn("backing", "dial", "gauge", "none"))
    verify(!Presets.drawn("backing", "dial", "classic", "none"))
  }

  function test_new_faces_use_the_classic_controls() {
    var faces = ["sundial", "tag", "wheel"]
    for (var i = 0; i < faces.length; i++) {
      verify(Presets.drawn("callout", "dial", faces[i], "rect"), faces[i] + " callout")
      verify(Presets.drawn("density", "dial", faces[i], "rect"), faces[i] + " density")
      verify(Presets.drawn("weight", "dial", faces[i], "rect"), faces[i] + " weight")
      verify(Presets.drawn("constructionLines", "dial", faces[i], "rect"), faces[i] + " construction")
    }
  }

  function test_swatches_are_theme_references_never_hex() {
    compare(Presets.SWATCHES.length, 20)
    for (var s of Presets.SWATCHES) verify(s.indexOf("#") < 0, s)
  }
}
