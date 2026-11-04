import QtQuick
import QtTest
import "../../plugin/redial/LookResolve.js" as LookResolve
import "../../plugin/redial/languages/classic" as Classic

// Which file draws a look. A language offers only the looks it ships; nothing is borrowed from
// another language. A broken look draws the language's default, and a broken default draws
// re:dial classic's Classic as a crash guard, so the overlay is never blank.
// Run: QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
TestCase {
  name: "LookResolve"

  readonly property var basic: ({
    defaultLook: "capsule",
    looks: { capsule: "Capsule.qml", gauge: "Gauge.qml", pie: "Pie.qml", sundial: "Sundial.qml",
             tag: "Tag.qml", wheel: "Wheel.qml", deck: "Deck.qml", carousel: "Carousel.qml",
             toast: "Toast.qml" }
  })
  readonly property string guard: "languages/classic/Classic.qml"

  Classic.Language { id: classicLanguage }

  function test_own_look_wins() {
    compare(LookResolve.resolve("languages/basic", basic, "pie", false), "languages/basic/Pie.qml")
  }

  function test_look_the_language_lacks_draws_its_default() {
    compare(LookResolve.resolve("languages/basic", basic, "classic", false), "languages/basic/Capsule.qml")
  }

  function test_failed_look_draws_the_default() {
    compare(LookResolve.resolve("languages/basic", basic, "pie", true), "languages/basic/Capsule.qml")
  }

  function test_failed_default_is_the_crash_guard() {
    compare(LookResolve.resolve("languages/basic", basic, "capsule", true), guard)
  }

  function test_null_language_is_the_crash_guard() {
    compare(LookResolve.resolve("languages/basic", null, "pie", false), guard)
  }

  function test_offered_is_the_languages_own_looks_plus_omarchy() {
    var o = LookResolve.offered(basic)
    compare(o.length, 10)
    compare(o[o.length - 1], "omarchy")
    verify(o.indexOf("classic") === -1, "basic does not ship Classic")
  }

  function test_lookName() {
    compare(LookResolve.lookName("dial", "pie"), "pie")
    compare(LookResolve.lookName("deck", "pie"), "deck")
    compare(LookResolve.lookName("carousel", "pie"), "carousel")
    compare(LookResolve.lookName("toast", "pie"), "toast")
    compare(LookResolve.lookName("omarchy", "pie"), "")
  }

  // Transitional until every language ships deck, carousel and toast (see the plan's ledger):
  // a layout the language lacks is drawn by the host's own block, not by a substitute face.
  function test_layout_the_language_lacks_has_no_language_look() {
    var classicNow = { defaultLook: "classic", looks: { classic: "Classic.qml" } }
    compare(LookResolve.resolve("languages/classic", classicNow, "deck", false), "")
  }

  function test_lookCount_matches_looks() {
    compare(classicLanguage.lookCount, Object.keys(classicLanguage.looks).length)
    verify(classicLanguage.looks[classicLanguage.defaultLook] !== undefined, "the default is a look it ships")
  }

  function test_new_faces_are_valid_and_unknown_is_classic() {
    compare(LookResolve.validFace("sundial"), "sundial")
    compare(LookResolve.validFace("tag"), "tag")
    compare(LookResolve.validFace("wheel"), "wheel")
    compare(LookResolve.validFace("capsule"), "capsule")
    compare(LookResolve.validFace("teapot"), "classic")
    compare(LookResolve.validFace(undefined), "classic")
  }

  function test_option_writes_layout_and_face_together() {
    var o = LookResolve.option("wheel")
    compare(o.label, "Finger wheel"); compare(o.layout, "dial"); compare(o.face, "wheel")
    var d = LookResolve.option("deck")
    compare(d.layout, "deck"); compare(d.face, "")
    compare(LookResolve.option("omarchy").layout, "omarchy")
  }

  function test_choice_names_the_look_the_config_draws() {
    compare(LookResolve.choice("dial", "tag"), "tag")
    compare(LookResolve.choice("carousel", "tag"), "carousel")
    compare(LookResolve.choice("omarchy", "tag"), "omarchy")
    compare(LookResolve.choice("dial", "teapot"), "classic")
  }
}
