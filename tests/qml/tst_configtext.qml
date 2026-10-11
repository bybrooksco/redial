import QtQuick
import QtTest
import "../../plugin/dial.radial/ConfigText.js" as ConfigText

// The settings window must never write over a config it could not read.
// Run: QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
TestCase {
  name: "ConfigText"

  function test_a_normal_config_is_read() {
    var r = ConfigText.parse('{"size": "medium", "launchers": [{"name": "x"}]}')
    compare(r.ok, true)
    compare(r.doc.size, "medium")
    compare(r.doc.launchers.length, 1)
  }
  function test_a_missing_or_empty_file_is_a_fresh_install_not_an_error() {
    compare(ConfigText.parse("").ok, true)
    compare(ConfigText.parse(undefined).ok, true)
    compare(ConfigText.parse("   \n").ok, true)
    compare(Object.keys(ConfigText.parse("").doc).length, 0)
  }
  function test_a_trailing_comma_is_a_problem_not_an_empty_config() {
    var r = ConfigText.parse('{"size": "medium", "launchers": [1,],}')
    compare(r.ok, false)
    compare(r.doc, null)
  }
  function test_truncated_text_is_a_problem() {
    compare(ConfigText.parse('{"size": "med').ok, false)
  }
  function test_valid_json_that_is_not_an_object_is_a_problem() {
    compare(ConfigText.parse("[1, 2]").ok, false)
    compare(ConfigText.parse("42").ok, false)
    compare(ConfigText.parse("null").ok, false)
    compare(ConfigText.parse('"text"').ok, false)
  }
}
