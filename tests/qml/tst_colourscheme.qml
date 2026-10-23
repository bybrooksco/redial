import QtQuick
import QtTest
import "../../plugin/redial/ColourScheme.js" as Scheme

// The colour-scheme layer: Light by default, Dark, and Match theme with readable fallbacks.
TestCase {
  name: "ColourScheme"

  // the Studio's miasma theme, as Omarchy writes it
  readonly property var miasma: ({ background: "#222222", foreground: "#c2c2b0", accent: "#78824b" })
  readonly property var miasmaSlots: ({ color1: "#685742", color9: "#685742", color3: "#b36d43", color4: "#78824b", color5: "#bb7744", color6: "#c9a554" })

  function test_light_is_the_default() {
    var r = Scheme.roles("light", null, null, {})
    compare(r.ground, Scheme.LIGHT.ground)
    compare(r.line, Scheme.LIGHT.line)
    compare(Scheme.roles("anything else", null, null, "").ground, Scheme.LIGHT.ground)
  }

  function test_dark() {
    compare(Scheme.roles("dark", miasma, miasmaSlots, "").ground, Scheme.DARK.ground)
  }

  function test_theme_takes_the_desktop_colours() {
    var r = Scheme.roles("theme", miasma, miasmaSlots, "")
    compare(r.ground, "#222222")
    compare(r.line, "#c2c2b0")
    compare(r.accent, "#78824b")
  }

  function test_theme_alert_skips_a_red_too_dark_to_read() {
    // miasma's red #685742 is about 2.3:1 on #222222; the next warm slot reads
    compare(Scheme.roles("theme", miasma, miasmaSlots, "").alert, "#bb7744")
  }

  function test_theme_without_a_theme_falls_back_to_dark() {
    compare(Scheme.roles("theme", null, null, "").ground, Scheme.DARK.ground)
    compare(Scheme.roles("theme", { background: "nope" }, {}, "").ground, Scheme.DARK.ground)
  }

  function test_your_colours_override_every_role_the_looks_draw_with() {
    var r = Scheme.roles("theme", miasma, miasmaSlots, { accent: "#112233", line: "#445566", ground: "#778899" })
    compare([r.accent, r.line, r.ground], ["#112233", "#445566", "#778899"])
    compare(Scheme.roles("light", null, null, { line: "", ground: "nope" }).ground, Scheme.LIGHT.ground)
  }

  function test_unreadable_accent_falls_back_to_a_slot_then_ink() {
    var flat = { background: "#000000", foreground: "#ffffff", accent: "#050505" }
    compare(Scheme.roles("theme", flat, { color4: "#888888" }, "").accent, "#888888")
    compare(Scheme.roles("theme", flat, {}, "").accent, "#ffffff")
  }

  function test_the_users_accent_override_wins_in_every_scheme() {
    compare(Scheme.roles("light", null, null, { accent: "#de6145" }).accent, "#de6145")
    compare(Scheme.roles("theme", miasma, miasmaSlots, { accent: "#de6145" }).accent, "#de6145")
    compare(Scheme.roles("light", null, null, { accent: "theme" }).accent, Scheme.LIGHT.accent)
  }

  function test_parse_toml_reads_hex_keys_and_ignores_the_rest() {
    var t = Scheme.parseToml('# c\naccent = "#78824b"   # x\nmode = "dark"\ncolor1  = "#5F8787"  # base08\nbad = "#12"\n')
    compare(t.accent, "#78824b")
    compare(t.color1, "#5F8787")
    compare(t.mode, undefined)
    compare(t.bad, undefined)
  }

  function test_ratio_matches_wcag() {
    fuzzyCompare(Scheme.ratio("#000000", "#ffffff"), 21, 0.01)
    fuzzyCompare(Scheme.ratio("#777777", "#ffffff"), 4.48, 0.02)
  }
}
