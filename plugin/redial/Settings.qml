import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "ThemeSlots.js" as ThemeSlots
import "ColourScheme.js" as Scheme

// Configuration for the re:dial overlay.
//
// Every value has a default in code, so the overlay behaves correctly with no
// config file at all - that is the shipped behaviour, and a missing, empty or
// malformed file degrades to exactly it rather than to a broken panel.
//
// The file is watched, so edits apply live without restarting the shell.
//
//   ~/.config/redial/config.json
//
// The path is deliberately tool-owned rather than under ~/.config/omarchy:
// it survives Omarchy updates, and it is the same file the daemon reads, so
// one document configures the whole tool.
Item {
  id: cfg

  readonly property string dir:
    (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/redial"
  readonly property string path: dir + "/config.json"

  // Parsed user document. Empty object until a valid file loads.
  property var doc: ({})
  // True once the file has been read at least once, whatever it contained.
  property bool everLoaded: false
  signal changed()

  // ---------------------------------------------------------------- defaults
  readonly property var defaults: ({
    "_language": "classic - the design language that draws the overlay (how things are drawn and how they move). re:dial classic is the standard; others live in plugin/redial/languages/<name>/ and fall back to classic when absent",
    "language": "classic",
    "_color_scheme": "light | dark | theme - fills the language's four colour roles (ground, line, accent, alert). light is ink on vellum and the default; theme matches the desktop's own theme (Omarchy), dark where there is none. colors.accent, when set, still overrides the accent",
    "color_scheme": "light",
    "_reference_lines": "true | false - the drawing's background reference lines (construction lines, crosshair, registration marks). Rings and the scale stay: they carry information",
    "reference_lines": true,
    "_layout": "dial | deck | carousel | toast | omarchy - the overlay's overall shape. dial is the circular instrument (see face, below, for which one); deck and carousel are both horizontal card rows (deck: dense, original; carousel: fewer visual details, center-emphasis sizing); toast is a single small pill plus a dot strip, the smallest footprint of the four.",
    "layout": "dial",
    "_face": "classic | capsule | pie | gauge - which instrument face the dial layout draws",
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
      "constructionLines": true,
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
  // (accent/foreground/background/urgent/muted), a theme slot "color0".."color15"
  // (that slot of whatever theme is active, so it re-colours on a theme switch),
  // or any literal Qt colour string such as "#78824b".
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
    if (/^color([0-9]|1[0-5])$/.test(s)) return themeSlots[s] || natural
    if (/^#([0-9a-fA-F]{3,8})$/.test(s)) return s
    return natural
  }

  // --------------------------------------------------------- resolved values
  // Every look and the settings window draw with the colour scheme's roles (Light, Dark, Match
  // desktop), so one choice recolours all of re:dial. colors.* still wins when it names a colour.
  function overridden(key) {
    var s = String(get(key)).trim()
    return s !== "" && s !== "theme" && s !== "auto"
  }
  readonly property color accentColor: roles.accent
  readonly property color lineColor: roles.line
  readonly property color backgroundColor: roles.ground

  // Text colours for the settings card, which is always drawn opaque on backgroundColor. Each is
  // the theme's own colour, adjusted only as far as needed to reach 4.5:1 (see Contrast.qml), so
  // every theme stays legible without a hand-tuned palette.
  Contrast { id: contrast }
  function soft(alpha) { return contrast.soft(lineColor, backgroundColor, alpha) }
  readonly property color accentText: contrast.asText(accentColor, lineColor, backgroundColor)
  readonly property color onAccent: contrast.onFill(accentColor, backgroundColor, lineColor)
  // An opaque surface a little lighter (or darker) than the card, for tooltips.
  function tint(t) { return contrast.mix(lineColor, backgroundColor, t) }

  // Design layers (docs/DESIGN.md#design-layers). A language folder name is the only thing a
  // community language needs; an unknown one falls back to classic where it is loaded.
  readonly property string language: {
    var v = String(get("language"))
    return /^[a-z0-9][a-z0-9-]{0,39}$/.test(v) ? v : "classic"
  }
  readonly property string colorScheme: {
    var v = String(get("color_scheme"))
    return (v === "light" || v === "dark" || v === "theme") ? v : "light"
  }
  readonly property bool referenceLines: get("reference_lines") !== false
  // The user's own colours (colors.*), as "#rrggbb", or "" where the scheme's own role stays.
  function overrideHex(key, role) {
    if (!overridden(key)) return ""
    var c = String(Qt.lighter(resolveColor(get(key), role), 1.0))  // a colour value as "#rrggbb"
    return c.length === 9 ? "#" + c.slice(3) : c                    // "#aarrggbb": drop the alpha
  }
  // The four colour roles every language draws with, as "#rrggbb" strings.
  readonly property var roles: Scheme.roles(colorScheme, omarchyTheme, themeSlots, {
    accent: overrideHex("colors.accent", "accent"),
    line: overrideHex("colors.line", "foreground"),
    ground: overrideHex("colors.background", "background")
  })

  readonly property string layout: {
    var v = String(get("layout"))
    return (v === "deck" || v === "dial" || v === "carousel" || v === "toast" || v === "omarchy") ? v : "dial"
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
    return (v === "classic" || v === "capsule" || v === "pie" || v === "gauge") ? v : "classic"
  }

  // The backing follows the face unless the config names one explicitly: the
  // classic instrument was drawn for its rectangular window, capsule and pie
  // for a disc, gauge draws its own dome band so a disc/rect behind it would
  // just show through the gap below the arc. Setting "plate" always wins.
  readonly property string plate: {
    var v = doc && doc.plate !== undefined ? String(doc.plate) : ""
    if (v === "none" || v === "disc" || v === "rect") return v
    if (face === "classic") return "rect"
    if (face === "gauge") return "none"
    return "disc"
  }
  // Motion: three speeds used by every animation, all zero when reduce_motion is on (config key
  // or Feel page), so nothing slides or scales. Reduced motion means gentler, not none: the
  // overlay's own fade in and out keeps motionFade/motionExit, which move nothing.
  readonly property bool reduceMotion: !!(doc && doc.reduce_motion === true)
  readonly property int motionFast: reduceMotion ? 0 : 120   // small text and colour shifts
  readonly property int motionBase: reduceMotion ? 0 : 160   // moves, scale, highlight travel
  readonly property int motionSlow: reduceMotion ? 0 : 260   // whole-dial rotations
  readonly property int motionFade: 120                      // opening fade, kept under reduce_motion
  readonly property int motionExit: 100                      // closing is always quicker than opening
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
  // reference_lines is the one switch for all three; the dial.* keys still tune each when it is on
  readonly property bool constructionLines: referenceLines && get("dial.constructionLines") === true
  readonly property bool crosshair: referenceLines && get("dial.crosshair") === true
  readonly property bool registrationMarks: referenceLines && get("dial.registrationMarks") === true
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
      console.warn("[redial] config is not valid JSON, using defaults:", e)
      doc = ({})
    }
    changed()
  }

  // The active theme's 16 terminal colours, for "color0".."color15" (see ThemeSlots.js).
  // Omarchy only reads its palette at startup and pushes later switches over IPC, so
  // re-read whenever that palette changes.
  property var themeSlots: ({})
  FileView {
    id: themeColors
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/alacritty.toml"
    printErrors: false
    onLoaded: cfg.themeSlots = ThemeSlots.parse(text())
    onLoadFailed: cfg.themeSlots = ({})
  }
  // The theme's own background, foreground and accent for color_scheme "theme". Read from the file,
  // not from the shell's Color singleton, so the colour layer needs nothing from Omarchy's shell.
  property var omarchyTheme: ({})
  FileView {
    id: themeToml
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
    printErrors: false
    onLoaded: cfg.omarchyTheme = Scheme.parseToml(text())
    onLoadFailed: cfg.omarchyTheme = ({})
  }
  Connections {
    target: Color
    function onBackgroundChanged() { themeColors.reload(); themeToml.reload() }
    function onForegroundChanged() { themeColors.reload(); themeToml.reload() }
    function onAccentChanged() { themeColors.reload(); themeToml.reload() }
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
