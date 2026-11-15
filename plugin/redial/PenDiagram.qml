pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects

// The pen's buttons, drawn on the Pen page. Each callout lists what that button does right now
// (passed in as `parts`), and a line lights up in the accent when its setting changes.
// art/surface-pen.svg: white centre-line strokes traced from US D825,566 S FIG. 1, tinted here.
Item {
  id: diagram

  property color lineColor: "white"
  property color textColor: "white"
  property color softColor: "gray"
  property color accentColor: "orange"
  property string fontFamily: ""
  property real fontSize: 12
  property real penHeight: 240
  property int motion: 160  // 0 under reduced motion: lines change without sliding

  // [{ x, y (SVG units), title, where, lines: [{ key, value }] }], top of the pen first.
  property var parts: []

  // SVG viewBox 220.08 x 583.92.
  readonly property real vbW: 220.08
  readonly property real vbH: 583.92
  readonly property real penScale: penHeight / vbH
  readonly property real labelX: vbW * penScale + fontSize * 4
  readonly property real lineH: fontSize * 1.5
  readonly property real gap: fontSize * 1.2

  // Callout tops, pushed down so none overlaps the one above it.
  readonly property var tops: {
    var out = [], next = 0
    var ps = parts || []
    for (var i = 0; i < ps.length; i++) {
      var want = ps[i].y * penScale - fontSize * 0.75
      var top = Math.max(want, next)
      out.push(top)
      next = top + calloutHeight(ps[i]) + gap
    }
    return out
  }
  function calloutHeight(p) { return lineH * (1 + p.lines.length) }
  readonly property real contentBottom: parts && parts.length
    ? tops[parts.length - 1] + calloutHeight(parts[parts.length - 1]) : 0

  implicitHeight: Math.max(penHeight, contentBottom) + fontSize
  implicitWidth: labelX + fontSize * 24

  Image {
    id: pen
    source: Qt.resolvedUrl("art/surface-pen.svg")
    width: diagram.vbW * diagram.penScale
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
    model: pen.status === Image.Ready ? diagram.parts : []
    delegate: Item {
      id: callout
      required property var modelData
      required property int index
      readonly property real px: modelData.x * diagram.penScale
      readonly property real py: modelData.y * diagram.penScale
      readonly property real ty: (diagram.tops[index] || 0) + diagram.lineH / 2
      readonly property real kneeX: diagram.labelX - diagram.fontSize * 2

      // Leader: out from the part, down (or up) to its callout, then across to the words.
      Rectangle { x: callout.px; y: callout.py; width: callout.kneeX - callout.px; height: 1; color: diagram.softColor }
      Rectangle {
        x: callout.kneeX
        y: Math.min(callout.py, callout.ty)
        width: 1
        height: Math.abs(callout.ty - callout.py) + 1
        color: diagram.softColor
      }
      Rectangle {
        x: callout.kneeX; y: callout.ty
        width: diagram.labelX - callout.kneeX - diagram.fontSize * 0.5; height: 1
        color: diagram.softColor
      }
      Rectangle {
        x: callout.px - 2.5; y: callout.py - 2
        width: 5; height: 5; radius: 2.5
        color: diagram.textColor
      }

      Column {
        x: diagram.labelX
        y: diagram.tops[callout.index] || 0
        width: diagram.width - diagram.labelX
        Row {
          height: diagram.lineH
          spacing: diagram.fontSize * 0.75
          Text {
            text: callout.modelData.title
            textFormat: Text.PlainText
            font.family: diagram.fontFamily
            font.pixelSize: diagram.fontSize
            font.bold: true
            color: diagram.textColor
          }
          Text {
            text: callout.modelData.where || ""
            textFormat: Text.PlainText
            font.family: diagram.fontFamily
            font.pixelSize: diagram.fontSize
            color: diagram.softColor
          }
        }
        Repeater {
          model: callout.modelData.lines
          delegate: Row {
            id: line
            required property var modelData
            height: diagram.lineH
            spacing: diagram.fontSize
            Text {
              width: diagram.fontSize * 6
              text: line.modelData.key
              textFormat: Text.PlainText
              font.family: diagram.fontFamily
              font.pixelSize: diagram.fontSize
              color: diagram.softColor
            }
            ValueText { value: line.modelData.value }
          }
        }
      }
    }
  }

  // A setting's current action. When it changes it slides in from the right in the accent
  // and settles back to the text colour, so the eye finds what just changed on the pen.
  component ValueText: Text {
    id: vt
    property string value: ""
    property bool ready: false
    text: value
    textFormat: Text.PlainText
    font.family: diagram.fontFamily
    font.pixelSize: diagram.fontSize
    color: diagram.textColor
    Component.onCompleted: ready = true
    onValueChanged: if (ready) flash.restart()
    transform: Translate { id: shift }
    SequentialAnimation {
      id: flash
      PropertyAction { target: vt; property: "color"; value: diagram.accentColor }
      PropertyAction { target: shift; property: "x"; value: diagram.motion > 0 ? diagram.fontSize * 0.6 : 0 }
      NumberAnimation { target: shift; property: "x"; to: 0; duration: diagram.motion; easing.type: Easing.OutCubic }
      PauseAnimation { duration: 700 }
      ColorAnimation { target: vt; property: "color"; to: diagram.textColor; duration: 400 }
    }
  }
}
