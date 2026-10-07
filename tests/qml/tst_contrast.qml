import QtQuick
import QtTest
import "../../plugin/dial.radial"

// Every installed Omarchy theme's background, foreground and accent (copied from
// /usr/share/omarchy/themes/*/colors.toml): the helper must make each text style legible on all.
// Run: QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
TestCase {
  name: "Contrast"
  Contrast { id: c }

  readonly property var palettes: [
    {
      "n": "catppuccin-latte",
      "bg": "#eff1f5",
      "fg": "#4c4f69",
      "ac": "#1e66f5"
    },
    {
      "n": "catppuccin",
      "bg": "#1e1e2e",
      "fg": "#cdd6f4",
      "ac": "#89b4fa"
    },
    {
      "n": "ethereal",
      "bg": "#060B1E",
      "fg": "#ffcead",
      "ac": "#7d82d9"
    },
    {
      "n": "everforest",
      "bg": "#2d353b",
      "fg": "#d3c6aa",
      "ac": "#7fbbb3"
    },
    {
      "n": "flexoki-light",
      "bg": "#FFFCF0",
      "fg": "#100F0F",
      "ac": "#205EA6"
    },
    {
      "n": "gruvbox",
      "bg": "#282828",
      "fg": "#d4be98",
      "ac": "#7daea3"
    },
    {
      "n": "hackerman",
      "bg": "#0B0C16",
      "fg": "#ddf7ff",
      "ac": "#82FB9C"
    },
    {
      "n": "kanagawa",
      "bg": "#1f1f28",
      "fg": "#dcd7ba",
      "ac": "#dcd7ba"
    },
    {
      "n": "last-horizon",
      "bg": "#0c0b0c",
      "fg": "#FAFCFB",
      "ac": "#b59790"
    },
    {
      "n": "lumon",
      "bg": "#16242d",
      "fg": "#d6e2ee",
      "ac": "#8bc9eb"
    },
    {
      "n": "lupine",
      "bg": "#fafafa",
      "fg": "#212121",
      "ac": "#3264eb"
    },
    {
      "n": "matte-black",
      "bg": "#121212",
      "fg": "#bebebe",
      "ac": "#e68e0d"
    },
    {
      "n": "miasma",
      "bg": "#222222",
      "fg": "#c2c2b0",
      "ac": "#78824b"
    },
    {
      "n": "nord",
      "bg": "#2e3440",
      "fg": "#d8dee9",
      "ac": "#81a1c1"
    },
    {
      "n": "osaka-jade",
      "bg": "#111c18",
      "fg": "#C1C497",
      "ac": "#509475"
    },
    {
      "n": "retro-82",
      "bg": "#05182e",
      "fg": "#f6dcac",
      "ac": "#faa968"
    },
    {
      "n": "ristretto",
      "bg": "#2c2525",
      "fg": "#e6d9db",
      "ac": "#f38d70"
    },
    {
      "n": "rose-pine",
      "bg": "#faf4ed",
      "fg": "#575279",
      "ac": "#56949f"
    },
    {
      "n": "solitude",
      "bg": "#101315",
      "fg": "#cacccc",
      "ac": "#798186"
    },
    {
      "n": "tokyo-night",
      "bg": "#1a1b26",
      "fg": "#a9b1d6",
      "ac": "#7aa2f7"
    },
    {
      "n": "vantablack",
      "bg": "#000000",
      "fg": "#ffffff",
      "ac": "#8d8d8d"
    },
    {
      "n": "white",
      "bg": "#ffffff",
      "fg": "#000000",
      "ac": "#6e6e6e"
    }
  ]

  function col(hex) { return Qt.color(hex) }

  function test_known_ratios() {
    fuzzyCompare(c.ratio(col("#000000"), col("#ffffff")), 21, 0.01)
    fuzzyCompare(c.ratio(col("#777777"), col("#ffffff")), 4.48, 0.02)
    fuzzyCompare(c.ratio(col("#ffffff"), col("#ffffff")), 1, 0.001)
  }

  function test_soft_text_is_legible_on_every_theme_at_every_wished_opacity() {
    var wishes = [0.5, 0.55, 0.6, 0.7, 0.85]
    for (var i = 0; i < palettes.length; i++) {
      var p = palettes[i]
      for (var w = 0; w < wishes.length; w++) {
        var r = c.ratio(c.soft(col(p.fg), col(p.bg), wishes[w]), col(p.bg))
        verify(r >= 4.5 - 0.001, p.n + " @" + wishes[w] + " = " + r)
      }
    }
  }

  function test_soft_is_never_fainter_than_asked() {
    var p = palettes[0]
    var asked = c.mix(col(p.fg), col(p.bg), 0.6)
    var got = c.soft(col(p.fg), col(p.bg), 0.6)
    verify(c.ratio(got, col(p.bg)) >= c.ratio(asked, col(p.bg)) - 0.001)
  }

  function test_a_legible_theme_is_left_alone() {
    var fg = col("#ffffff"), bg = col("#000000")
    var got = c.soft(fg, bg, 0.85)
    fuzzyCompare(got.r, 0.85, 0.001)
  }

  function test_accent_text_is_legible_on_every_theme() {
    for (var i = 0; i < palettes.length; i++) {
      var p = palettes[i]
      var r = c.ratio(c.asText(col(p.ac), col(p.fg), col(p.bg)), col(p.bg))
      verify(r >= 4.5 - 0.001, p.n + " accent text = " + r)
    }
  }

  function test_a_legible_accent_is_unchanged() {
    var got = c.asText(col("#ffffff"), col("#ffffff"), col("#000000"))
    fuzzyCompare(got.r, 1, 0.001)
  }

  function test_text_on_an_accent_fill_is_legible_on_every_theme() {
    for (var i = 0; i < palettes.length; i++) {
      var p = palettes[i]
      var t = c.onFill(col(p.ac), col(p.bg), col(p.fg))
      var r = c.ratio(t, col(p.ac))
      verify(r >= 4.5 - 0.001, p.n + " on-accent = " + r)
    }
  }

  function test_on_fill_prefers_the_theme_background_when_it_works() {
    var t = c.onFill(col("#ffffff"), col("#101010"), col("#eeeeee"))
    fuzzyCompare(t.r, col("#101010").r, 0.001)
  }
}
