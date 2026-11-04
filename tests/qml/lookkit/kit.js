.pragma library

// Shared fixtures for the per-look tests (tst_<language>_<look>.qml).
var eight = [
  { icon: "a", name: "Volume", hint: "mute", valueText: "42%" }, { icon: "b", name: "Workspaces" },
  { icon: "c", name: "Windows" }, { icon: "d", name: "Scroll" }, { icon: "e", name: "Zoom" },
  { icon: "f", name: "Tabs" }, { icon: "g", name: "Focus" }, { icon: "h", name: "Select" }
]

function twelve() {
  var t = []
  for (var i = 0; i < 12; i++) t.push({ icon: "x", name: "Tool " + (i + 1) })
  return t
}

// Every Text under item, depth first (Repeater delegates included: they are children of the parent).
function texts(item, out) {
  out = out || []
  if (!item) return out
  if (item.textFormat !== undefined && item.text !== undefined && item.font !== undefined) out.push(item)
  var kids = item.children || []
  for (var i = 0; i < kids.length; i++) texts(kids[i], out)
  return out
}

// The centre of item in ancestor's coordinates.
function centre(item, ancestor) {
  var p = item.mapToItem(ancestor, item.width / 2, item.height / 2)
  return [p.x, p.y]
}
