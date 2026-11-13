import QtQuick
import QtTest
import "../../plugin/redial/languages/basic" as Basic
import "../../plugin/redial/languages/basic/Tones.js" as Tones
import "lookkit"
import "lookkit/kit.js" as Kit

// re:dial basic's language file and its tones.
// Run: QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
TestCase {
  name: "BasicLanguage"
  Basic.Language { id: lang }
  FakeCfg { id: fakeCfg }
  Component { id: capsuleComponent; Basic.Capsule { cfg: fakeCfg; language: lang } }
  Component { id: iconComponent; Basic.Icon {} }
  readonly property var roles: ({ ground: "#222222", line: "#c2c2b0", accent: "#78824b", alert: "#bb7744" })

  function test_nine_looks_and_no_classic() {
    compare(lang.name, "re:dial basic")
    compare(lang.lookCount, 9)
    compare(lang.defaultLook, "capsule")
    verify(lang.looks["classic"] === undefined, "basic ships no Classic")
    compare(lang.easeDrawer.length, 6)
  }

  function test_bundled_faces_load() {
    tryVerify(function () { return lang.faceStandard !== "" }, 3000)
    compare(lang.faceStandard, "Barlow Semi Condensed")
    verify(lang.faceSundial === undefined && lang.faceTag === undefined, "one face only")
  }

  function test_tones_step_from_ground_toward_line() {
    var t = Tones.tones(roles)
    compare(t.ground, "#222222"); compare(t.ink, "#c2c2b0")
    compare(t.track, Tones.mix("#222222", "#c2c2b0", 0.10))
    verify(Tones.luminance(t.card) > Tones.luminance(t.track) && Tones.luminance(t.muted) > Tones.luminance(t.card))
  }

  function test_onaccent_is_the_more_readable_of_ground_and_line() {
    compare(Tones.tones({ ground: "#000000", line: "#ffffff", accent: "#ffcc00", alert: "#f00" }).onaccent, "#000000")
    compare(Tones.tones({ ground: "#000000", line: "#ffffff", accent: "#202080", alert: "#f00" }).onaccent, "#ffffff")
  }

  function test_ratio_matches_the_wcag_formula() {
    compare(Tones.ratio("#000000", "#ffffff").toFixed(2), "21.00")
    compare(Tones.ratio("#777777", "#777777"), 1)
  }

  function test_labels_rename_tag_only_here() { compare(lang.labels.tag, "List") }

  function test_icon_box_is_centred_on_its_point() {
    var look = createTemporaryObject(capsuleComponent, this)
    look.tools = Kit.eight
    var ic = createTemporaryObject(iconComponent, look, { host: look, i: 0, on: true, cx: 50, cy: 40 })
    verify(ic !== null, "Icon loads")
    compare(ic.x + ic.width / 2, 50); compare(ic.y + ic.height / 2, 40)
    compare(ic.px, look.iconOnPx)
  }

  function test_card_line() {
    var look = createTemporaryObject(capsuleComponent, this)
    look.tools = [{ name: "Volume", icon: "x", hint: "mute" }, { name: "Scroll", icon: "y" }]
    compare(look.cardLine(0), "1 / 2 · mute"); compare(look.cardLine(1), "2 / 2")
  }

  function test_track_metrics() {
    var look = createTemporaryObject(capsuleComponent, this)
    compare(look.trackW, 8); compare(look.iconGap, 20); compare(look.iconPx, 13); compare(look.iconOnPx, 16)
    compare(look.trackInk, 1); look.noteKind = "hint"; compare(look.trackInk, 0.5); compare(look.iconsShown, false)
  }
}
