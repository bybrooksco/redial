import QtQuick
import QtQuick.Window
import "lookkit"
import "lookkit/kit.js" as Kit

// Renders one language look in each state to PNGs for comparing against the mockups.
// Run: QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qml tests/qml/render_looks.qml -- <language> <look> [dark] [out]
// Writes /tmp/redial-render/<language>-<look>-{ring,turn,hint,cant}.png, or <out>/<look>-<state>.png.
// <language> is a built-in's name or a language folder's absolute path (redial-language preview).
Window {
  id: win
  visible: true
  color: "#808080"
  readonly property var args: Qt.application.arguments.slice(Qt.application.arguments.indexOf("--") + 1)
  readonly property string lang: args[0] || "classic"
  readonly property string lookKey: args[1] || "classic"
  readonly property string dir: lang.indexOf("/") >= 0 ? "file://" + lang : "../../plugin/redial/languages/" + lang
  readonly property string out: args[3] ? args[3] + "/" + lookKey + "-" : "/tmp/redial-render/" + lang + "-" + lookKey + "-"
  readonly property var states: [
    { name: "ring", kind: "", note: {} },
    { name: "turn", kind: "turn", note: { name: "Volume", value: 42, valueText: "42%" } },
    { name: "hint", kind: "hint", note: { prompt: "Turn to pick a tool", gesture: "turn", step: 1, steps: 3 } },
    { name: "cant", kind: "cant", note: { reason: "asleep", title: "Dial asleep", line: "Press to wake" } }
  ]
  property int at: 0

  FakeCfg {
    id: cfg
    motionBase: 0; motionFast: 0
    roles: win.args[2] === "dark" ? { ground: "#151614", line: "#ecebe4", accent: "#de6145", alert: "#f0a35a" }
                                  : { ground: "#f3f0e7", line: "#1c1e21", accent: "#c4452a", alert: "#9a3412" }
  }
  Loader {
    id: language
    source: win.dir + "/Language.qml"
    onLoaded: look.setSource(win.dir + "/" + item.looks[win.lookKey], { cfg: cfg })
  }
  Loader {
    id: look
    onStatusChanged: if (status === Loader.Error) { console.log("look failed to load"); Qt.quit() }
    onLoaded: {
      item.language = language.item
      item.tools = Kit.eight
      item.index = 2
      var s = item.plateSize !== undefined ? item.plateSize : Qt.size(880, 580)
      item.width = s.width; item.height = s.height
      win.width = s.width; win.height = s.height
      shot.start()
    }
  }
  Timer {
    id: shot
    interval: 150
    onTriggered: {
      var st = win.states[win.at]
      look.item.noteKind = st.kind; look.item.note = st.note
      settle.start()
    }
  }
  Timer {
    id: settle
    interval: 500
    onTriggered: look.item.grabToImage(function (r) {
      r.saveToFile(win.out + win.states[win.at].name + ".png")
      console.log("wrote", win.out + win.states[win.at].name + ".png")
      win.at++
      if (win.at < win.states.length) shot.start(); else Qt.quit()
    })
  }
}
