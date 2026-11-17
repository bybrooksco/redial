import QtQuick

// re:dial classic: the standard design language, a drafting plate.
//
// Information lives around the dial and is carried by lines: hairline rings, construction lines to
// the plate edge with nodes at their ends, a graduated scale whose lit region is the selection, a
// needle that is the hand, and an elbowed leader out to label/value notes. Colours come only from
// the four roles (cfg.roles), so every colour scheme works. See README.md beside this file.
QtObject {
  readonly property string name: "re:dial classic"

  // The looks this language ships, by face or layout name. It offers only these: a look it does not
  // list is not borrowed from another language.
  readonly property var looks: ({ "classic": "Classic.qml", "capsule": "Capsule.qml", "gauge": "Gauge.qml", "pie": "Pie.qml", "toast": "Toast.qml", "deck": "Deck.qml", "carousel": "Carousel.qml", "sundial": "Sundial.qml", "tag": "Tag.qml", "wheel": "Wheel.qml" })
  // Drawn when the config names a look this language does not ship (see LookResolve.js).
  readonly property string defaultLook: "classic"
  // How many looks the language ships: the tag a language library lists. Derived, so it cannot drift.
  readonly property int lookCount: Object.keys(looks).length
  // The Look page's Style controls each look draws (README.md); the page shows only these.
  readonly property var controls: ({
    "classic": ["backing", "weight", "density", "labels", "glyphs", "callout", "constructionLines", "registrationMarks"],
    "capsule": ["backing", "weight", "glyphs", "constructionLines"],
    "gauge": ["backing", "weight", "density", "glyphs", "constructionLines"],
    "pie": ["backing", "weight", "glyphs", "constructionLines"],
    "toast": ["backing", "weight", "constructionLines"],
    "deck": ["backing", "weight", "glyphs"],
    "carousel": ["backing", "weight", "glyphs", "constructionLines"],
    "sundial": ["backing", "weight", "labels", "glyphs", "callout", "constructionLines"],
    "tag": ["backing", "weight", "glyphs", "callout", "constructionLines"],
    "wheel": ["backing", "weight", "density", "glyphs", "callout", "constructionLines"]
  })

  // Motion character: crisp and mechanical. Strong ease-out for things arriving, ease-in-out for
  // things moving on screen (Emil Kowalski's curves); closing is always quicker than opening.
  readonly property var easeOut: [0.23, 1, 0.32, 1, 1, 1]
  readonly property var easeInOut: [0.77, 0, 0.175, 1, 1, 1]

  // Ink strengths, so every look in the language reads the same.
  readonly property real inkLabel: 0.58     // tool names on the circumference
  readonly property real inkKey: 0.55       // CLICK / ROTATE keys in the callout
  readonly property real inkValue: 0.78     // their values
}
