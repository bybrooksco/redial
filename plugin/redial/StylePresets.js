.pragma library

// The Look page's Style controls: swatches and one-press presets over the Dial drawing keys.
// Kept apart from ToolPicker so it is testable without the Omarchy shell. Swatches are theme
// references, never hex, so the dial re-colours on a theme switch.

var SWATCHES = ["theme", "accent", "foreground", "background",
  "color0", "color1", "color2", "color3", "color4", "color5", "color6", "color7",
  "color8", "color9", "color10", "color11", "color12", "color13", "color14", "color15"]

var BACKING = [ { key: 0.7, label: "70%" }, { key: 0.85, label: "85%" },
                { key: 0.96, label: "96%" }, { key: 1, label: "Solid" } ]

var DENSITY = [ { key: 90, label: "Low" }, { key: 180, label: "Medium" }, { key: 360, label: "High" } ]

// Normal is the daemon's defaults (Settings.qml), so an untouched config reads as Normal.
var WEIGHT = [
  { key: "fine",   label: "Fine",   w: { barWidthMinor: 0.5, barWidthMajor: 1, barWidthActive: 1.5, needleWidth: 1, ringWidth: 0.5 } },
  { key: "normal", label: "Normal", w: { barWidthMinor: 1, barWidthMajor: 2, barWidthActive: 2.5, needleWidth: 2, ringWidth: 1 } },
  { key: "bold",   label: "Bold",   w: { barWidthMinor: 2, barWidthMajor: 3.5, barWidthActive: 4.5, needleWidth: 3.5, ringWidth: 1.5 } }
]

// dial.* switches, with the default each has when unset.
var ELEMENTS = [
  { key: "labels", label: "Tool names", fallback: true }, { key: "glyphs", label: "Tool icons", fallback: true },
  { key: "callout", label: "Callout", fallback: true }, { key: "constructionLines", label: "Construction lines", fallback: true },
  { key: "registrationMarks", label: "Registration marks", fallback: true }
]

// The weight preset all five widths match, or "" when they were set one by one.
// dial: the config's "dial" object (may be undefined).
function weightOf(dial) {
  var d = dial || {}
  for (var i = 0; i < WEIGHT.length; i++) {
    var same = true
    for (var k in WEIGHT[i].w) {
      var v = d[k] === undefined ? WEIGHT[1].w[k] : Number(d[k])
      if (v !== WEIGHT[i].w[k]) same = false
    }
    if (same) return WEIGHT[i].key
  }
  return ""
}

// The Style controls a language look can honour (languages/README.md, `controls`).
var CONTROLS = ["backing", "weight", "density", "labels", "glyphs", "callout", "constructionLines", "registrationMarks"]

// Whether the Look page shows a Style control for the chosen look: only what the look draws is
// shown, never greyed. language: the loaded Language.qml; look: the picker key
// (LookResolve.choice); plate: Settings' plate. A look its language does not list shows none.
function shown(what, language, look, plate) {
  if (what === "colors") return look !== "omarchy"
  var own = language && language.controls ? language.controls[look] : undefined
  if (!own || own.indexOf(what) < 0) return false
  // The host draws the Classic look's plate and its corner marks: no plate, nothing to back or mark.
  if (what === "backing") return look !== "classic" || plate !== "none"
  if (what === "registrationMarks") return plate === "rect"
  return true
}
