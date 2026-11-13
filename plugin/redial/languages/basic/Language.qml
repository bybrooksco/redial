import QtQuick

// re:dial basic: the quiet track (docs/superpowers/specs/2026-11-06-redial-basic-language-design.md).
// Every look is a thin track and an accent marker on it, the tools' own icons one step inside the
// track, and one shared card for the words; looks differ only in the track's shape. Flat theme
// tones (Tones.js), one face (Barlow Semi Condensed). See ../README.md for the look contract.
QtObject {
  id: language
  readonly property string name: "re:dial basic"

  // The looks this language ships. It ships no Classic: the soft mockups never drew one, and a
  // language offers only what it ships.
  readonly property var looks: ({ "capsule": "Capsule.qml", "gauge": "Gauge.qml", "pie": "Pie.qml",
                                  "sundial": "Sundial.qml", "tag": "Tag.qml", "wheel": "Wheel.qml",
                                  "deck": "Deck.qml", "carousel": "Carousel.qml", "toast": "Toast.qml" })
  readonly property string defaultLook: "capsule"
  // Picker labels that differ from the shared ones (LookResolve.LABELS): classic's tag is still a Repair tag.
  readonly property var labels: ({ tag: "List" })
  readonly property int lookCount: Object.keys(looks).length

  readonly property var easeOut: [0.23, 1, 0.32, 1, 1, 1]
  readonly property var easeInOut: [0.77, 0, 0.175, 1, 1, 1]
  readonly property var easeDrawer: [0.32, 0.72, 0, 1, 1, 1]
  readonly property real inkKey: 0.55

  // Bundled OFL faces (fonts/, each with its licence). A face that fails to load is "", and the
  // looks fall back to the host's font.
  // Static weights cut to the Latin range (fonttools instancer + pyftsubset); the full variable
  // fonts are at github.com/google/fonts. Static files keep the weight drawn certain.
  readonly property FontLoader _barlow: FontLoader { source: "fonts/barlow/BarlowSemiCondensed-Regular.ttf" }
  readonly property FontLoader _barlowSemi: FontLoader { source: "fonts/barlow/BarlowSemiCondensed-SemiBold.ttf" }
  readonly property FontLoader _barlowBold: FontLoader { source: "fonts/barlow/BarlowSemiCondensed-Bold.ttf" }
  readonly property string faceStandard: _barlow.status === FontLoader.Ready ? _barlow.name : ""
}
