.pragma library

// The click actions grouped by where they help, for the settings window's action picker. The daemon
// publishes the actions (clicks.json, pen_clicks.json); this only orders them. Kept apart from
// ToolPicker so it is testable without the Omarchy shell.

var GROUPS = [
  { title: "The tool", names: ["", "tool", "none"] },  // "": no choice of yours (the default)
  { title: "Typing and dictation", names: ["dictation", "enter", "escape", "space", "tab", "backspace", "delete_word"] },
  { title: "Pointer", names: ["mouse_left", "left_click", "mouse_right", "right_click", "mouse_middle", "middle_click"] },
  { title: "Editing", names: ["copy", "paste", "cut", "select_all", "redo"] },
  { title: "Web and windows", names: ["tab_next", "tab_prev", "maximize", "fullscreen", "float", "screenshot"] },
  { title: "Sound and media", names: ["mute", "mic_mute", "play_pause", "next_track", "prev_track"] },
  { title: "Open", names: ["launcher", "menu", "terminal", "browser", "files", "assistant"] },
  { title: "The dial", names: ["reconnect_dial"] }
]

// [{ title, items: [action] }] in GROUPS order, empty groups dropped. Actions no group names (your
// own launchers, one added to the daemon later) go under "More", so every action is shown once.
function grouped(actions) {
  var out = [], used = {}
  for (var g of GROUPS) {
    var items = actions.filter(function (a) { return g.names.indexOf(a.name) >= 0 })
    items.forEach(function (a) { used[a.name] = true })
    if (items.length) out.push({ title: g.title, items: items })
  }
  var rest = actions.filter(function (a) { return !used[a.name] })
  if (rest.length) out.push({ title: "More", items: rest })
  return out
}
