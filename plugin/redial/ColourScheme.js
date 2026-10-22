.pragma library

// Colour schemes fill the four roles every design language draws with:
//   ground  the plate behind everything
//   line    ink: hairlines, scale, labels, text
//   accent  the selection and the hand
//   alert   "the dial can't act"
// A language names only these roles, so every scheme works in every language (docs/DESIGN.md#design-layers).
//
// Schemes: "light" (ink on vellum, the default for everyone), "dark", and "theme", which matches the
// desktop's own theme (Omarchy's colors.toml today) and falls back to dark where there is none.

var LIGHT = { ground: "#f3f0e7", line: "#1c1e21", accent: "#c4452a", alert: "#9a3412" }
var DARK = { ground: "#121314", line: "#e8e5da", accent: "#de6145", alert: "#f0a35a" }

// key = "#rrggbb" lines from a colors.toml; comments and other values are ignored.
function parseToml(text) {
  var out = {}, lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var m = lines[i].match(/^\s*([A-Za-z0-9_]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})\b/)
    if (m) out[m[1]] = m[2]
  }
  return out
}

function _lin(c) { return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4) }
function luminance(hex) {
  var n = parseInt(String(hex).slice(1, 7), 16)
  return 0.2126 * _lin(((n >> 16) & 255) / 255) + 0.7152 * _lin(((n >> 8) & 255) / 255) + 0.0722 * _lin((n & 255) / 255)
}
function ratio(a, b) {
  var la = luminance(a), lb = luminance(b)
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)
}

function isHex(s) { return /^#[0-9A-Fa-f]{6}$/.test(String(s)) }

// The first candidate that reads against `ground` at 3:1 (large marks and hairlines), else `fallback`.
function firstReadable(candidates, ground, fallback) {
  for (var i = 0; i < candidates.length; i++)
    if (isHex(candidates[i]) && ratio(candidates[i], ground) >= 3) return candidates[i]
  return fallback
}

// theme: parsed colors.toml (background, foreground, accent); slots: color0..color15 (ThemeSlots.js).
// accentOverride: a resolved "#rrggbb" from the user's colors.accent, or "" to use the scheme's own.
function roles(scheme, theme, slots, accentOverride) {
  var r
  if (scheme === "theme" && theme && isHex(theme.background) && isHex(theme.foreground)) {
    var s = slots || {}
    r = { ground: theme.background, line: theme.foreground }
    r.accent = firstReadable([theme.accent, s.color4, s.color3, s.color6], r.ground, r.line)
    // a theme's red is often too dark to read on its own background; then the next warm slot, then ink
    r.alert = firstReadable([s.color1, s.color9, s.color5, s.color3], r.ground, r.line)
  } else {
    var b = scheme === "dark" || scheme === "theme" ? DARK : LIGHT
    r = { ground: b.ground, line: b.line, accent: b.accent, alert: b.alert }
  }
  if (isHex(accentOverride)) r.accent = accentOverride
  return r
}
