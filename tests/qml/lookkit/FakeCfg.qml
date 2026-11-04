import QtQuick

// A stand-in for Settings.qml: only what a look reads. Motion is zero so values settle at once.
QtObject {
  signal changed()
  property var roles: ({ ground: "#f3f0e7", line: "#1c1e21", accent: "#c4452a", alert: "#9a3412" })
  property int motionBase: 0
  property int motionFast: 0
  property int motionFade: 120
  property real ringWidth: 1
  property int barCount: 180
  property int majorEvery: 15
  property real sectorFill: 0.86
  property real barWidthMinor: 1
  property real barWidthMajor: 2
  property real barWidthActive: 2.5
  property real needleWidth: 2
  property bool constructionLines: true
  property string plate: "rect"
  property bool showLabels: true
  property bool showGlyphs: true
  property bool showCallout: true
}
