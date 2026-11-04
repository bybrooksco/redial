import QtQuick
import "Drafting.js" as Drafting

// What every re:dial classic look shares: the look contract's properties (languages/README.md),
// unit scaling, the colour roles, and how a daemon state reads. A look is `LookBase { ... }` and
// sets plateSize, wantsCallout and kind itself.
Item {
  id: base

  required property var cfg
  property var language: null
  property real unit: 1
  property string fontFamily: "monospace"
  property var type: ({ caption: 10, subtitle: 13, title: 14, display: 24, displayLarge: 28 })
  property var tools: []
  property int index: 0
  property real position: 0
  property bool live: false
  property string noteKind: ""
  property var note: ({})
  property real landY: -1

  function u(px) { return px * unit }
  readonly property color line: cfg.roles.line
  readonly property color accent: cfg.roles.accent
  readonly property color alert: cfg.roles.alert
  readonly property color ground: cfg.roles.ground
  function ink(a) { return Qt.rgba(line.r, line.g, line.b, a) }
  function accentInk(a) { return Qt.rgba(accent.r, accent.g, accent.b, a) }
  readonly property var easeOut: language ? language.easeOut : [0.23, 1, 0.32, 1, 1, 1]
  readonly property var easeInOut: language ? language.easeInOut : [0.77, 0, 0.175, 1, 1, 1]
  readonly property real inkKey: language ? language.inkKey : 0.55

  readonly property int n: Math.max(1, tools.length)
  function toolName(i) { return tools[i] ? String(tools[i].name || "") : "" }
  function toolHint(i) { return tools[i] ? String(tools[i].hint || "") : "" }
  function toolIcon(i) { return tools[i] ? String(tools[i].icon || "") : "" }

  // A turn with a level owns the scale; a turn without one leaves the ring as it is.
  readonly property bool levelShown: noteKind === "turn" && note.value !== undefined
  readonly property real level: Math.max(0, Math.min(100, Number(note.value) || 0))
  readonly property string valueText: note.valueText !== undefined ? String(note.valueText) : String(Math.round(level)) + "%"
  readonly property string stateDrawn: noteKind === "hint" ? "hint" : noteKind === "cant" ? "cant"
                                     : levelShown ? "turn" : "ring"
  // How strongly the ring reads behind a hint (set back) or can't act (further back).
  readonly property real ringInk: noteKind === "cant" ? 0.35 : noteKind === "hint" ? 0.55 : 1
  function litOf(n) { return levelShown ? Drafting.litCount(note.value, n) : 0 }
}
