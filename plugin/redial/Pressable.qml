import QtQuick

// A button the keyboard and assistive technology can use. Every clickable thing in the settings
// window is one of these, so they all behave the same way:
//
//   * Tab / Shift+Tab move to it; Enter, Return or Space press it
//   * a ring is drawn around it while it has keyboard focus
//   * it tells screen readers its role (button, or radio button when `checkable`), its name and
//     whether it is chosen
//   * the pointer becomes a hand over it
//
// It draws no look of its own beyond the focus ring: the caller sets color, radius and children,
// exactly as with a Rectangle. It imports nothing from the shell so it can be tested on its own
// (tests/qml/tst_pressable.qml).
Rectangle {
  id: root

  property string label: ""         // what a screen reader announces
  property bool checkable: false    // true: one of a set of choices (radio), false: plain button
  property bool checked: false
  property color ringColor: "white"
  property real ringWidth: 2
  property real minimumSize: 32     // never smaller than this in either direction, in pixels
  readonly property bool hovered: pointer.containsMouse
  signal activated()
  signal alternate()                // right-click, or Shift+Enter / Shift+Space: "the other way"

  implicitWidth: minimumSize
  implicitHeight: minimumSize
  activeFocusOnTab: true

  Accessible.role: checkable ? Accessible.RadioButton : Accessible.Button
  Accessible.name: label
  Accessible.focusable: true
  Accessible.checkable: checkable
  Accessible.checked: checkable && checked
  Accessible.onPressAction: root.activated()

  Keys.onPressed: event => {
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
      event.accepted = true
      if (event.modifiers & Qt.ShiftModifier) root.alternate()
      else root.activated()
    }
  }

  MouseArea {
    id: pointer
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    cursorShape: Qt.PointingHandCursor
    onClicked: mouse => {
      if (mouse.button === Qt.RightButton) root.alternate()
      else root.activated()
    }
  }

  // The keyboard focus ring, outside the control so it never changes its size.
  Rectangle {
    objectName: "focusRing"
    anchors.fill: parent
    anchors.margins: -root.ringWidth * 1.5
    radius: root.radius + root.ringWidth * 1.5
    color: "transparent"
    border.width: root.ringWidth
    border.color: root.ringColor
    visible: root.activeFocus
  }
}
