.pragma library

// Where each design language lives (see languages/README.md, "Your languages").
//
// Built-in languages ship inside the plugin. Yours are installed by `redial-language install` into
// ${XDG_DATA_HOME:-~/.local/share}/redial/languages/<name>/ and listed in index.json there; only
// languages that index lists load, so a folder copied in by hand is ignored. Anything else falls
// back to re:dial classic.

var BUILTIN = ["classic", "basic"]

function isBuiltin(name) { return BUILTIN.indexOf(name) >= 0 }

// The folder a language loads from: a plugin-relative path for a built-in, a file URL for one of
// yours, classic for anything not installed.
function dir(name, index, userDir) {
  if (isBuiltin(name)) return "languages/" + name
  if (index && Object.prototype.hasOwnProperty.call(index, name) && userDir) return "file://" + userDir + "/" + name
  return "languages/classic"
}

// Every installed language, built-ins first: { key, label, builtin, manifest, looks }.
function options(index) {
  var out = BUILTIN.map(function (n) { return { key: n, label: "re:dial " + n, builtin: true, manifest: null, looks: 0 } })
  var names = Object.keys(index || {}).filter(function (n) { return !isBuiltin(n) }).sort()
  for (var i = 0; i < names.length; i++) {
    var e = index[names[i]] || {}
    var m = e.manifest || {}
    out.push({ key: names[i], label: String(m.name || names[i]), builtin: false, manifest: m, looks: Number(e.looks) || 0 })
  }
  return out
}
