import QtQuick
import QtQuick.Effects

// The pen's buttons, drawn on the Pen page so each setting below has a place on the pen.
// art/surface-pen.svg: white centre-line strokes traced from US D825,566 S FIG. 1, tinted here.
Item {
  id: diagram

  property color lineColor: "white"
  property color textColor: "white"
  property color softColor: "gray"
  property string fontFamily: ""
  property real fontSize: 12
  property real penHeight: 240

  // Callout anchors, in the SVG's own units (viewBox 220.08 x 583.92).
  readonly property real vbW: 220.08
  readonly property real vbH: 583.92
  readonly property var callouts: [
    { x: 31, y: 15, title: "Tail button", body: "Click it away from the screen. Touch the screen with it to erase." },
    { x: 131, y: 410, title: "Barrel button", body: "Press it while the pen hovers over the screen." },
    { x: 207, y: 580, title: "Tip", body: "Draws; hover and contact come from here." }
  ]

  readonly property real scale: penHeight / vbH
  readonly property real labelX: vbW * scale + fontSize * 2

  implicitHeight: penHeight
  implicitWidth: labelX + fontSize * 24

  Image {
    id: pen
    source: Qt.resolvedUrl("art/surface-pen.svg")
    width: diagram.vbW * diagram.scale
    height: diagram.penHeight
    sourceSize: Qt.size(width * 2, height * 2)
    fillMode: Image.PreserveAspectFit
    smooth: true
    visible: false
  }
  MultiEffect {
    source: pen
    anchors.fill: pen
    colorization: 1
    colorizationColor: diagram.lineColor
    visible: pen.status === Image.Ready
  }

  Repeater {
    model: pen.status === Image.Ready ? diagram.callouts : []
    delegate: Item {
      id: callout
      required property var modelData
      readonly property real px: modelData.x * diagram.scale
      readonly property real py: modelData.y * diagram.scale

      Rectangle {  // leader line from the part to its label
        x: callout.px
        y: callout.py
        width: diagram.labelX - callout.px - diagram.fontSize * 0.5
        height: 1
        color: diagram.softColor
      }
      Rectangle {
        x: callout.px - 2.5
        y: callout.py - 2
        width: 5
        height: 5
        radius: 2.5
        color: diagram.textColor
      }
      Column {
        x: diagram.labelX
        y: Math.max(0, Math.min(callout.py - diagram.fontSize * 0.7, diagram.penHeight - height))
        width: diagram.width - diagram.labelX
        Text {
          text: callout.modelData.title
          font.family: diagram.fontFamily
          font.pixelSize: diagram.fontSize
          font.bold: true
          color: diagram.textColor
        }
        Text {
          width: parent.width
          text: callout.modelData.body
          wrapMode: Text.WordWrap
          font.family: diagram.fontFamily
          font.pixelSize: diagram.fontSize
          color: diagram.softColor
        }
      }
    }
  }
}
