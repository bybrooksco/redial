.pragma library

// The active theme's 16 terminal colours as { color0: "#rrggbb", ... color15 }, read from
// Omarchy's generated alacritty.toml. Themes write colors.toml either as color0..15 or as
// named keys (red, bright_blue, ...), but Omarchy renders every theme into the same
// [colors.normal] / [colors.bright] sections there: normal is 0-7, bright is 8-15.
function parse(text) {
  var names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
  var slots = {}, section = "", lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var h = lines[i].match(/^\s*\[([^\]]+)\]/)
    if (h) { section = h[1].trim(); continue }
    var base = section === "colors.normal" ? 0 : section === "colors.bright" ? 8 : -1
    var m = lines[i].match(/^\s*([a-z]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
    if (base >= 0 && m && names.indexOf(m[1]) >= 0) slots["color" + (base + names.indexOf(m[1]))] = m[2]
  }
  return slots
}
