import QtQuick
import QtTest
import "../../plugin/redial"

// Run headless: QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
// The keys here go to a window inside the test process only, never to the desktop.
TestCase {
  id: tc
  name: "Pressable"
  width: 300
  height: 200
  visible: true
  when: windowShown

  Component {
    id: row
    Column {
      property alias a: a
      property alias b: b
      property int pressed: 0
      property int other: 0
      Pressable { id: a; width: 80; height: 40; label: "First"; onActivated: parent.pressed += 1; onAlternate: parent.other += 1 }
      Pressable { id: b; width: 80; height: 40; label: "Second"; checkable: true; checked: true }
    }
  }

  function make() {
    var o = createTemporaryObject(row, tc)
    verify(o)
    return o
  }

  function ring(p) {
    for (var i = 0; i < p.children.length; i++)
      if (p.children[i].objectName === "focusRing") return p.children[i]
    return null
  }

  function test_enter_return_and_space_all_press() {
    var o = make()
    o.a.forceActiveFocus()
    keyClick(Qt.Key_Return)
    keyClick(Qt.Key_Enter)
    keyClick(Qt.Key_Space)
    compare(o.pressed, 3)
  }

  function test_other_keys_do_not_press() {
    var o = make()
    o.a.forceActiveFocus()
    keyClick(Qt.Key_A)
    keyClick(Qt.Key_Escape)
    compare(o.pressed, 0)
  }

  function test_a_click_presses() {
    var o = make()
    mouseClick(o.a)
    compare(o.pressed, 1)
  }

  function test_tab_moves_between_buttons_and_back() {
    var o = make()
    o.a.forceActiveFocus()
    verify(o.a.activeFocus)
    keyClick(Qt.Key_Tab)
    verify(o.b.activeFocus)
    keyClick(Qt.Key_Backtab)
    verify(o.a.activeFocus)
  }

  function test_focus_ring_shows_only_while_focused() {
    var o = make()
    verify(!ring(o.a).visible)
    o.a.forceActiveFocus()
    verify(ring(o.a).visible)
    verify(!ring(o.b).visible)
  }

  function test_accessible_role_name_and_state() {
    var o = make()
    compare(o.a.Accessible.role, Accessible.Button)
    compare(o.a.Accessible.name, "First")
    compare(o.b.Accessible.role, Accessible.RadioButton)
    verify(o.b.Accessible.checked)
    verify(!o.a.Accessible.checked)
  }

  function test_never_smaller_than_the_minimum_target() {
    var p = createTemporaryObject(Qt.createComponent(Qt.resolvedUrl("../../plugin/redial/Pressable.qml")), tc)
    verify(p.implicitWidth >= 32)
    verify(p.implicitHeight >= 32)
  }

  function test_shift_enter_and_right_click_are_the_alternate() {
    var o = make()
    o.a.forceActiveFocus()
    keyClick(Qt.Key_Return, Qt.ShiftModifier)
    keyClick(Qt.Key_Space, Qt.ShiftModifier)
    mouseClick(o.a, 10, 10, Qt.RightButton)
    compare(o.other, 3)
    compare(o.pressed, 0)
  }

  function test_a_disabled_button_ignores_keys_and_clicks() {
    var o = make()
    o.a.enabled = false
    o.a.forceActiveFocus()
    keyClick(Qt.Key_Return)
    mouseClick(o.a)
    compare(o.pressed, 0)
  }
}
