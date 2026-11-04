import QtQuick

// re:dial basic: the soft design language (round two). Filled shapes on a rimmed plate instead of
// lines on vellum: capsules, wedges, discs and cards in tones mixed from the colour scheme
// (Tones.js), a large readable name in the middle, and bundled faces for the three newest looks.
// See ../README.md for the look contract.
QtObject {
  id: language
  readonly property string name: "re:dial basic"

  // The looks this language ships. It ships no Classic: the soft mockups never drew one, and a
  // language offers only what it ships.
  readonly property var looks: ({ "capsule": "Capsule.qml", "gauge": "Gauge.qml", "pie": "Pie.qml",
                                  "sundial": "Sundial.qml", "tag": "Tag.qml", "wheel": "Wheel.qml",
                                  "deck": "Deck.qml", "carousel": "Carousel.qml", "toast": "Toast.qml" })
  readonly property string defaultLook: "capsule"
  readonly property int lookCount: Object.keys(looks).length

  readonly property var easeOut: [0.23, 1, 0.32, 1, 1, 1]
  readonly property var easeInOut: [0.77, 0, 0.175, 1, 1, 1]
  readonly property var easeDrawer: [0.32, 0.72, 0, 1, 1, 1]
  readonly property real inkKey: 0.55

  // Bundled OFL faces (fonts/, each with its licence). A face that fails to load is "", and the
  // looks fall back to the host's font.
  readonly property FontLoader _fraunces: FontLoader { source: "fonts/fraunces/Fraunces.ttf" }
  readonly property FontLoader _bricolage: FontLoader { source: "fonts/bricolage/BricolageGrotesque.ttf" }
  readonly property FontLoader _barlow: FontLoader { source: "fonts/barlow/BarlowSemiCondensed-Regular.ttf" }
  readonly property FontLoader _barlowSemi: FontLoader { source: "fonts/barlow/BarlowSemiCondensed-SemiBold.ttf" }
  readonly property FontLoader _barlowBold: FontLoader { source: "fonts/barlow/BarlowSemiCondensed-Bold.ttf" }
  readonly property string faceSundial: _fraunces.status === FontLoader.Ready ? _fraunces.name : ""
  readonly property string faceTag: _bricolage.status === FontLoader.Ready ? _bricolage.name : ""
  readonly property string faceStandard: _barlow.status === FontLoader.Ready ? _barlow.name : ""
}
