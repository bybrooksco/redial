import QtQuick
import QtTest
import "../../plugin/redial/Languages.js" as Languages

// Where a design language loads from: built-ins from the plugin, yours only when the installer's
// index lists them, anything else re:dial classic.
TestCase {
  name: "Languages"
  readonly property string userDir: String(Qt.resolvedUrl("userlangs")).replace(/^file:\/\//, "")
  readonly property var index: ({ sample: { manifest: { name: "Sample", author: "Me" }, looks: 1 } })

  function test_built_ins_load_from_the_plugin() {
    compare(Languages.dir("classic", index, userDir), "languages/classic")
    compare(Languages.dir("basic", null, userDir), "languages/basic")
  }

  function test_an_indexed_language_loads_from_your_folder() {
    compare(Languages.dir("sample", index, userDir), "file://" + userDir + "/sample")
  }

  function test_anything_not_installed_falls_back_to_classic() {
    compare(Languages.dir("stray", index, userDir), "languages/classic")
    compare(Languages.dir("sample", null, userDir), "languages/classic")
    compare(Languages.dir("sample", {}, userDir), "languages/classic")
    compare(Languages.dir("toString", {}, userDir), "languages/classic")
  }

  function test_options_list_built_ins_then_yours() {
    var o = Languages.options(index)
    compare(o.map(function (x) { return x.key }), ["classic", "basic", "sample"])
    compare(o[2].label, "Sample")
    verify(o[0].builtin && !o[2].builtin)
    compare(Languages.options(null).length, 2)
  }

  Loader { id: lang }
  Loader { id: look }
  function test_an_indexed_language_and_its_look_load_from_an_absolute_path() {
    var d = Languages.dir("sample", index, userDir)
    lang.source = d + "/Language.qml"
    tryCompare(lang, "status", Loader.Ready)
    look.source = d + "/" + lang.item.looks.capsule
    tryCompare(look, "status", Loader.Ready)
    compare(look.item.stateDrawn, "ring")
  }
}
