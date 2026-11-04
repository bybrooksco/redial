.pragma library

// Which file draws a look (see languages/README.md).
//
// A language offers only the looks it ships: nothing is borrowed from another language. A look the
// config names but the language lacks draws the language's defaultLook; a look that failed to load
// draws the default too, and a failed default draws re:dial classic's Classic, a crash guard so the
// overlay is never blank.

var LAYOUTS = ["deck", "carousel", "toast"]
var GUARD = "languages/classic/Classic.qml"

// The look a layout draws: the face in the dial layout, the layout itself for deck, carousel and
// toast, and none for the omarchy layout (Omarchy's own OSD box, not a language look).
function lookName(layout, face) {
  if (layout === "dial") return face
  return LAYOUTS.indexOf(layout) >= 0 ? layout : ""
}

// The file for `name`, or "" when the host draws it itself.
// shortcut: a layout the language lacks returns "" so DialMenu's own deck/carousel/toast block
// draws it; remove once those blocks are deleted (plan Task 11).
function resolve(dir, language, name, failed) {
  if (!language || !language.looks) return GUARD
  var looks = language.looks
  if (!failed && looks[name]) return dir + "/" + looks[name]
  if (!failed && LAYOUTS.indexOf(name) >= 0) return ""
  if (failed && name === language.defaultLook) return GUARD
  var fallback = looks[language.defaultLook]
  return fallback ? dir + "/" + fallback : GUARD
}

// The looks the Settings picker offers: the language's own, in its order, then the omarchy layout,
// which every language keeps because it is the desktop's OSD.
function offered(language) {
  var keys = language && language.looks ? Object.keys(language.looks) : []
  return keys.concat(["omarchy"])
}

// Every look name a language may ship, with the label the Settings picker shows. Faces are drawn in
// the dial layout; the others are layouts of their own. The omarchy layout is the desktop's OSD.
var LABELS = { classic: "Classic", capsule: "Capsule", pie: "Pie Wheel", gauge: "Gauge",
               sundial: "Sundial", tag: "Repair tag", wheel: "Finger wheel",
               deck: "Deck", carousel: "Carousel", toast: "Minimal Toast", omarchy: "Omarchy" }
var FACES = ["classic", "capsule", "pie", "gauge", "sundial", "tag", "wheel"]

function validFace(v) {
  return FACES.indexOf(String(v)) >= 0 ? String(v) : "classic"
}

// A picker option: the config's layout and face written together, so neither is left stale.
function option(key) {
  var face = FACES.indexOf(key) >= 0
  return { key: key, label: LABELS[key] || key, layout: face ? "dial" : key, face: face ? key : "" }
}

// The picker key for what the config draws now.
function choice(layout, face) {
  if (layout === "omarchy" || LAYOUTS.indexOf(layout) >= 0) return layout
  return validFace(face)
}
