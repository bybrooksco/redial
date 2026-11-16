import QtQuick
import QtTest
import "../../plugin/redial/StylePresets.js" as Presets
import "../../plugin/redial/languages/classic" as Classic
import "../../plugin/redial/languages/basic" as Basic

// The Look page's Style block (ToolPicker asks Presets.weightOf and Presets.shown).
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

  // Only what the chosen look draws is shown (never greyed): the language lists it per look.
  QtObject { id: lang; property var controls: ({ "classic": ["backing", "weight", "registrationMarks"], "gauge": ["backing", "density"] }) }
  Classic.Language { id: classicLang }
  Basic.Language { id: basicLang }

  function test_only_the_controls_a_look_lists_are_shown() {
    verify(Presets.shown("backing", lang, "gauge", "rect"))
    verify(Presets.shown("density", lang, "gauge", "rect"))
    verify(!Presets.shown("weight", lang, "gauge", "rect"))
    verify(!Presets.shown("backing", lang, "capsule", "rect"), "a look the map leaves out shows none")
    verify(!Presets.shown("backing", null, "gauge", "rect"), "no language loaded yet: none")
    verify(!Presets.shown("backing", { looks: {} }, "gauge", "rect"), "a language without controls: none")
  }

  function test_colours_hide_only_for_the_omarchy_osd() {
    verify(Presets.shown("colors", lang, "gauge", "rect"))
    verify(!Presets.shown("colors", lang, "omarchy", "rect"))
  }

  function test_the_host_drawn_classic_plate_needs_a_plate_to_back_or_mark() {
    verify(Presets.shown("backing", lang, "classic", "rect"))
    verify(!Presets.shown("backing", lang, "classic", "none"))
    verify(Presets.shown("registrationMarks", lang, "classic", "rect"))
    verify(!Presets.shown("registrationMarks", lang, "classic", "disc"))
  }

  function test_no_element_switch_does_nothing() {
    var keys = Presets.ELEMENTS.map(function (e) { return e.key })
    verify(keys.indexOf("crosshair") < 0, "nothing draws a crosshair")
    for (var k of keys) verify(Presets.CONTROLS.indexOf(k) >= 0, k)
  }

  function test_every_shipped_look_lists_known_controls_with_backing_and_weight() {
    for (var language of [classicLang, basicLang]) {
      for (var look in language.looks) {
        var own = language.controls[look]
        verify(own !== undefined, language.name + " " + look + " lists its controls")
        verify(own.indexOf("backing") >= 0 && own.indexOf("weight") >= 0, language.name + " " + look)
        for (var c of own) verify(Presets.CONTROLS.indexOf(c) >= 0, language.name + " " + look + ": " + c)
      }
    }
  }

  function test_density_shows_only_where_a_scale_is_drawn() {
    var scaled = Object.keys(classicLang.controls).filter(function (k) { return classicLang.controls[k].indexOf("density") >= 0 })
    compare(scaled.sort(), ["classic", "gauge", "wheel"])
  }

  function test_swatches_are_theme_references_never_hex() {
    compare(Presets.SWATCHES.length, 20)
    for (var s of Presets.SWATCHES) verify(s.indexOf("#") < 0, s)
  }
}
