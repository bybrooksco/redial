.pragma library

// re:dial basic's tones, all mixed from the colour scheme's four roles so every scheme works:
// the plate and its layers step from `ground` toward `line`. Colours in and out are "#rrggbb".

function rgb(hex) {
  var v = parseInt(String(hex).replace("#", "").slice(0, 6), 16)
  return [(v >> 16) & 255, (v >> 8) & 255, v & 255]
}
function hex(c) {
  return "#" + c.map(function (x) { var s = Math.round(Math.max(0, Math.min(255, x))).toString(16); return s.length < 2 ? "0" + s : s }).join("")
}
// a toward b by t (0..1).
function mix(a, b, t) {
  var x = rgb(a), y = rgb(b)
  return hex([x[0] + (y[0] - x[0]) * t, x[1] + (y[1] - x[1]) * t, x[2] + (y[2] - x[2]) * t])
}
// WCAG contrast ratio, the same formula as Contrast.qml (a library script cannot call that object).
function luminance(h) {
  var c = rgb(h).map(function (x) { x /= 255; return x <= 0.03928 ? x / 12.92 : Math.pow((x + 0.055) / 1.055, 2.4) })
  return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
}
function ratio(a, b) {
  var x = luminance(a), y = luminance(b)
  return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05)
}
// Whichever of the two reads better on `bg`.
function onColour(bg, a, b) { return ratio(a, bg) >= ratio(b, bg) ? a : b }

// The standard set: plate (ground), its rim, surfaces, cards, tracks, and text strengths.
function tones(roles) {
  var g = roles.ground, l = roles.line
  return { ground: g, rim: mix(g, l, 0.06), surface: mix(g, l, 0.10), card: mix(g, l, 0.13),
           track: mix(g, l, 0.10), muted: mix(g, l, 0.35), soft: mix(g, l, 0.70), ink: l,
           accent: roles.accent, onaccent: onColour(roles.accent, g, l), alert: roles.alert }
}

// The paper set (the repair tag, the wheel's card): the scheme turned over, line-coloured paper
// with ground-coloured ink, so a tag reads as a real tag on any scheme.
function paper(roles) {
  var g = roles.ground, l = roles.line
  return { paper: l, surface: mix(l, g, 0.10), ink: g, soft: mix(g, l, 0.20), muted: mix(g, l, 0.55),
           string: mix(g, l, 0.55), hole: mix(g, "#000000", 0.3), chrome: mix(l, g, 0.30),
           accent: roles.accent, onaccent: onColour(roles.accent, g, l), alert: roles.alert }
}
