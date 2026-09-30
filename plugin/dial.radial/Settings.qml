import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Configuration for the Surface Dial overlay.
//
// Every value has a default in code, so the overlay behaves correctly with no
// config file at all - that is the shipped behaviour, and a missing, empty or
// malformed file degrades to exactly it rather than to a broken panel.
//
// The file is watched, so edits apply live without restarting the shell.
//
//   ~/.config/dial-radial/config.json
//
// The path is deliberately tool-owned rather than under ~/.config/omarchy:
// it survives Omarchy updates, and it is the same file the daemon reads, so
// one document configures the whole tool.
Item {
  id: cfg

  readonly property string dir:
    (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/dial-radial"
  readonly property string path: dir + "/config.json"

  // Parsed user document. Empty object until a valid file loads.
  property var doc: ({})
  // True once the file has been read at least once, whatever it contained.
  property bool everLoaded: false
  signal changed()

  // ---------------------------------------------------------------- defaults
  readonly property var defaults: ({
    "layout": "dial",
    "_face": "classic | capsule - which instrument face the dial layout draws",
    "face": "classic",
    "anchor": "bottom",
    "_size": "large | medium | small - overall size of the on-screen dial menu; large is the original full size",
    "size": "large",
    "_plate": "none | disc | rect - backing behind the dial face",
    "plate": "disc",
    "_plateOpacity": "0..1 - backing strength; hairlines need contrast over busy content",
    "plateOpacity": 0.96,
    "watchdogMs": 15000,
    "colors": {
      "accent": "theme",
      "line": "theme",
      "background": "theme"
    },
    "dial": {
      "barCount": 180,
      "majorEvery": 15,
      "sectorFill": 0.86,
      "barWidthMinor": 1,
      "barWidthMajor": 2,
      "barWidthActive": 2.5,
      "needleWidth": 2,
      "ringWidth": 1,
      "_capsuleFillet": "0..1 corner fillet on the tool capsules, as a fraction of the largest radius the shape allows: 1 = stadium (circle when square), 0 = hard box",
      "capsuleFillet": 1.0,
      "_capsuleSpan": "0..1 - capsule width as a fraction of the arc each tool owns. Higher closes the gaps between pills. Note the capsule keeps a fixed radial length, so pushing this far past ~0.35 squares it off and, at capsuleFillet 1, turns it into a circle.",
      "capsuleSpan": 0.14,
      "constructionLines": false,
      "crosshair": false,
      "registrationMarks": true,
      "labels": true,
      "glyphs": true,
      "callout": true
    },
    "deck": {
      "cardWidth": 150,
      "cardHeight": 170,
      "gap": 14
    }
  })

  // ------------------------------------------------------------- accessors
  // Look a dotted key up in the user document, falling back to the default
  // tree. Type is checked against the default, so a string where a number
  // belongs is ignored rather than propagated into a binding.
  function get(key) {
    var parts = key.split(".")
    var d = defaults, u = doc
    for (var i = 0; i < parts.length; i++) {
      d = (d === undefined || d === null) ? undefined : d[parts[i]]
      u = (u === undefined || u === null) ? undefined : u[parts[i]]
    }
    if (u === undefined || u === null) return d
    if (typeof u !== typeof d) return d
    return u
  }

  function num(key, min, max) {
    var v = Number(get(key))
    if (!isFinite(v)) return Number(getDefault(key))
    if (min !== undefined) v = Math.max(min, v)
    if (max !== undefined) v = Math.min(max, v)
    return v
  }

  function getDefault(key) {
    var parts = key.split("."), d = defaults
    for (var i = 0; i < parts.length; i++) d = d[parts[i]]
    return d
  }

  // The single point where a colour name becomes a colour.
  //
  // Keeping every colour lookup funnelled through here is what makes the theme
  // coupling one function instead of a habit spread across two files - if this
  // ever has to run somewhere without Omarchy's palette, this is the only thing
  // that needs a fallback.
  //
  // Accepts: "theme" (the role's natural theme colour), a palette role name
  // (accent/foreground/background/urgent/muted), or any literal Qt colour
  // string such as "#78824b".
  function resolveColor(spec, role) {
    var s = String(spec === undefined || spec === null ? "theme" : spec).trim()
    var natural = role === "accent" ? Color.accent
                : role === "background" ? Color.background
                : Color.foreground
    if (s === "" || s === "theme" || s === "auto") return natural
    if (s === "accent") return Color.accent
    if (s === "foreground") return Color.foreground
    if (s === "background") return Color.background
    if (s === "urgent") return Color.urgent
    if (s === "muted") return Color.muted !== undefined ? Color.muted : Color.foreground
    if (/^#([0-9a-fA-F]{3,8})$/.test(s)) return s
    return natural
  }

  // --------------------------------------------------------- resolved values
  readonly property color accentColor: resolveColor(get("colors.accent"), "accent")
  readonly property color lineColor: resolveColor(get("colors.line"), "foreground")
  readonly property color backgroundColor: resolveColor(get("colors.background"), "background")

  readonly property string layout: {
    var v = String(get("layout"))
    return (v === "deck" || v === "dial") ? v : "dial"
  }
  readonly property string anchor: String(get("anchor"))
  // Overall scale of the dial overlay. "large" is the original full-size look and
  // the default, so a config with no "size" key renders exactly as before.
  readonly property string size: {
    var v = String(get("size"))
    return (v === "large" || v === "medium" || v === "small") ? v : "large"
  }
  readonly property real sizeScale: size === "small" ? 0.55 : (size === "medium" ? 0.75 : 1.0)
  readonly property real plateOpacity: num("plateOpacity", 0.0, 1.0)
  readonly property string face: {
    var v = String(get("face"))
    return (v === "classic" || v === "capsule") ? v : "classic"
  }

  // The backing follows the face unless the config names one explicitly: the
  // classic instrument was drawn for its rectangular window, the capsule face
  // for a disc. Setting "plate" always wins.
  readonly property string plate: {
    var v = doc && doc.plate !== undefined ? String(doc.plate) : ""
    if (v === "none" || v === "disc" || v === "rect") return v
    return face === "classic" ? "rect" : "disc"
  }
  readonly property int watchdogMs: num("watchdogMs", 2000, 120000)

  readonly property int barCount: num("dial.barCount", 24, 720)
  readonly property int majorEvery: num("dial.majorEvery", 2, 90)
  readonly property real sectorFill: num("dial.sectorFill", 0.1, 1.0)
  readonly property real barWidthMinor: num("dial.barWidthMinor", 0.5, 12)
  readonly property real barWidthMajor: num("dial.barWidthMajor", 0.5, 12)
  readonly property real barWidthActive: num("dial.barWidthActive", 0.5, 16)
  readonly property real needleWidth: num("dial.needleWidth", 0.5, 12)
  readonly property real ringWidth: num("dial.ringWidth", 0.5, 8)
  readonly property real capsuleFillet: num("dial.capsuleFillet", 0.0, 1.0)
  readonly property real capsuleSpan: num("dial.capsuleSpan", 0.05, 1.0)
  readonly property bool constructionLines: get("dial.constructionLines") === true
  readonly property bool crosshair: get("dial.crosshair") === true
  readonly property bool registrationMarks: get("dial.registrationMarks") === true
  readonly property bool showLabels: get("dial.labels") === true
  readonly property bool showGlyphs: get("dial.glyphs") === true
  readonly property bool showCallout: get("dial.callout") === true

  readonly property int cardWidth: num("deck.cardWidth", 80, 400)
  readonly property int cardHeight: num("deck.cardHeight", 80, 400)
  readonly property int cardGap: num("deck.gap", 0, 80)

  // ------------------------------------------------------------------- load
  function load(raw) {
    var text = String(raw || "").trim()
    if (text === "") { doc = ({}); changed(); return }
    try {
      var parsed = JSON.parse(text)
      doc = (parsed && typeof parsed === "object" && !Array.isArray(parsed)) ? parsed : ({})
    } catch (e) {
      // A syntax error must not take the overlay down with it.
      console.warn("[dial.radial] config is not valid JSON, using defaults:", e)
      doc = ({})
    }
    changed()
  }

  FileView {
    id: file
    path: cfg.path
    watchChanges: true
    printErrors: false
    onLoaded: { cfg.everLoaded = true; cfg.load(text()) }
    onLoadFailed: cfg.load("")
    // text() is stale inside the change signal, so both paths are routed
    // through reload() -> onLoaded to always parse fresh content.
    onFileChanged: reload()
  }

  // watchChanges follows a file that exists; it does not fire when one is
  // created later, and on a fresh install the config will not exist at all.
  // This polls until the first successful read, then stops and leaves the
  // watcher to handle edits. Verified: without it, a newly written config
  // only took effect on the next shell restart.
  Timer {
    running: !cfg.everLoaded
    interval: 2000
    repeat: true
    onTriggered: file.reload()
  }
}
