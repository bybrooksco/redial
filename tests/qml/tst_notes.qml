import QtQuick
import QtTest
import "../../plugin/redial/Notes.js" as Notes

// When a daemon state may take the overlay (DialMenu.showNote asks Notes.accept).
TestCase {
  name: "Notes"

  function idle() { return { kind: "", ringOpen: false, ageMs: 0 } }

  function test_each_state_shows_on_an_idle_overlay() {
    compare(Notes.accept("turn", idle()), true)
    compare(Notes.accept("hint", idle()), true)
    compare(Notes.accept("cant", idle()), true)
  }
  function test_an_unknown_kind_is_ignored() {
    compare(Notes.accept("pos", idle()), false)
    compare(Notes.accept("", idle()), false)
  }
  function test_the_open_ring_already_shows_the_tool_turning() {
    var s = idle(); s.ringOpen = true
    compare(Notes.accept("turn", s), false)
    compare(Notes.accept("hint", s), true, "a tour hint still shows over the ring")
  }
  function test_a_level_waits_until_a_hint_has_been_readable() {
    var s = idle(); s.kind = "hint"; s.ageMs = 400
    compare(Notes.accept("turn", s), false)
    s.ageMs = 1200
    compare(Notes.accept("turn", s), true)
    s.kind = "cant"; s.ageMs = 400
    compare(Notes.accept("turn", s), false)
  }
  function test_a_level_replaces_a_level() {
    var s = idle(); s.kind = "turn"; s.ageMs = 50
    compare(Notes.accept("turn", s), true)
  }
  function test_each_state_has_its_time() {
    verify(Notes.MS.hint > Notes.MS.turn)
    verify(Notes.MS.cant > 0)
  }
}
