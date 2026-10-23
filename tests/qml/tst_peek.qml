import QtQuick
import QtTest
import "../../plugin/redial/Peek.js" as Peek

// The Live peek from the settings window (DialMenu's settingsWindow and onLiveRequested).
TestCase {
  name: "Peek"

  function test_live_shows_a_peek_then_hides_it() {
    compare(Peek.toggle({ opened: false, liveDriven: false }), "open")
    compare(Peek.toggle({ opened: true, liveDriven: false }), "close")
  }
  function test_live_never_hides_the_ring_the_dial_is_turning() {
    compare(Peek.toggle({ opened: true, liveDriven: true }), "open")
    compare(Peek.closesWithSettings({ opened: true, liveDriven: true }), false)
  }
  function test_closing_settings_takes_the_peek_with_it() {
    compare(Peek.closesWithSettings({ opened: true, liveDriven: false }), true)
    compare(Peek.closesWithSettings({ opened: false, liveDriven: false }), false)
  }
}
