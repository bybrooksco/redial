import QtQuick
import QtTest
import "../../plugin/redial/ThemeSlots.js" as ThemeSlots

// color0..color15 must come out of every theme, whether its colors.toml used numbers or names.
// Run: QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
TestCase {
  name: "ThemeSlots"

  // Shape of Omarchy's generated alacritty.toml (miasma, trimmed).
  readonly property string alacritty: '[colors.primary]\nbackground = "#222222"\nforeground = "#c2c2b0"\n\n'
      + '[colors.normal]\nblack = "#222222"\nred = "#685742"\nwhite = "#c2c2b0"\n\n'
      + '[colors.bright]\nblack = "#666666"\nmagenta = "#bb7744"\nwhite = "#c2c2b1"\n'

  function test_normal_colours_are_slots_0_to_7() {
    var s = ThemeSlots.parse(alacritty)
    compare(s.color0, "#222222"); compare(s.color1, "#685742"); compare(s.color7, "#c2c2b0")
  }
  function test_bright_colours_are_slots_8_to_15() {
    var s = ThemeSlots.parse(alacritty)
    compare(s.color8, "#666666"); compare(s.color13, "#bb7744"); compare(s.color15, "#c2c2b1")
  }
  function test_other_sections_are_ignored() {
    var s = ThemeSlots.parse(alacritty)
    compare(s.background, undefined)
    compare(Object.keys(s).length, 6)
  }
  function test_a_missing_file_gives_no_slots() {
    compare(Object.keys(ThemeSlots.parse(undefined)).length, 0)
    compare(Object.keys(ThemeSlots.parse("")).length, 0)
  }
}
