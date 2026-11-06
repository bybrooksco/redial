import QtQuick
import "Tones.js" as Tones
import "Basic.js" as Basic

// What every re:dial basic look shares: the look contract's properties (../README.md), unit
// scaling, the tones mixed from the colour roles, the language's face, and how a daemon state
// reads. A look is `LookBase { ... }` and sets plateSize, wantsCallout and kind itself.
Item {
  id: base

  required property var cfg
  property var language: null
  property real unit: 1
  property string fontFamily: "sans-serif"
  property var type: ({ caption: 10, subtitle: 13, title: 14, display: 24, displayLarge: 28 })
  property var tools: []
  property int index: 0
  property real position: 0
  property bool live: false
  property string noteKind: ""
  property var note: ({})
  property real landY: -1

  function u(px) { return px * unit }
  readonly property var tone: Tones.tones(cfg.roles)
  readonly property var paperTone: Tones.paper(cfg.roles)
  // The language's face, or the host's when the bundled one did not load.
  readonly property string face: language && language.faceStandard !== "" ? language.faceStandard : fontFamily
  readonly property var easeOut: language ? language.easeOut : [0.23, 1, 0.32, 1, 1, 1]
  readonly property var easeInOut: language ? language.easeInOut : [0.77, 0, 0.175, 1, 1, 1]
  readonly property var easeDrawer: language ? language.easeDrawer : [0.32, 0.72, 0, 1, 1, 1]

  readonly property int n: Math.max(1, tools.length)
  readonly property int chosen: Math.min(index, n - 1)
  function toolName(i) { return tools[i] ? String(tools[i].name || "") : "" }
  function toolIcon(i) { return tools[i] ? String(tools[i].icon || "") : "" }
  function pressText(i) { var h = tools[i] ? String(tools[i].hint || "") : ""; return "Press: " + (h !== "" ? h : "nothing set") }

  readonly property bool levelShown: noteKind === "turn" && note.value !== undefined
  readonly property real level: Math.max(0, Math.min(100, Number(note.value) || 0))
  readonly property string valueText: note.valueText !== undefined ? String(note.valueText) : String(Math.round(level)) + "%"
  readonly property string stateDrawn: noteKind === "hint" ? "hint" : noteKind === "cant" ? "cant"
                                     : levelShown ? "turn" : "ring"
  // How far the ring sets back behind a hint and can't act.
  readonly property real ringInk: noteKind === "cant" ? 0.28 : noteKind === "hint" ? 0.5 : 1
  function litOf(n) { return levelShown ? Basic.litCount(note.value, n) : 0 }

  // The quiet track (docs/superpowers/specs/2026-11-06-redial-basic-language-design.md).
  readonly property real trackW: u(8)
  readonly property real iconGap: u(20)      // an icon's centre sits this far inside the track's centre line
  readonly property real iconPx: u(13)
  readonly property real iconOnPx: u(16)
  readonly property real plateRadius: u(16)
  readonly property real trackInk: noteKind === "hint" || noteKind === "cant" ? 0.5 : 1
  readonly property bool iconsShown: stateDrawn === "ring"
  // The card's ring line: "3 / 10 · mute".
  function cardLine(i) {
    var h = tools[i] ? String(tools[i].hint || "") : ""
    return (i + 1) + " / " + tools.length + (h !== "" ? " · " + h : "")
  }
}
