pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// The design language library on the Look page: a card per installed language with its preview
// pictures, author, licence, version and how many looks it ships; Use, Remove (yours only), and
// Install from folder. Installing and removing go through `redial-language` (bin/), which checks a
// language before it is installed. Previews are pictures the language ships, never its code.
Column {
  id: lib

  required property var cfg
  property var options: []           // Languages.options(): { key, label, builtin, manifest, looks }
  property string current: "classic"
  signal picked(string key)

  readonly property string tool: Quickshell.env("HOME") + "/.local/bin/redial-language"
  // install: "" | "warn" (the warning is up) | "busy" | "report"; report: the tool's JSON answer.
  property string installState: ""
  property var report: ({})
  property string lastFolder: ""
  property string confirmRemove: ""

  width: parent ? parent.width : 0
  spacing: Style.space(8)

  Text {
    text: "Design language"
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    font.bold: true
    font.capitalization: Font.AllUppercase
    font.letterSpacing: Style.space(1.2)
    color: lib.cfg.soft(0.6)
  }
  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    text: "How the overlay is drawn and moves. Hover a card to see its looks."
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    color: lib.cfg.soft(0.5)
  }

  Flow {
    width: parent.width
    spacing: Style.space(8)
    Repeater {
      model: lib.options
      delegate: Rectangle {
        id: card
        required property var modelData
        readonly property bool active: lib.current === modelData.key
        readonly property string dir: modelData.builtin
          ? String(Qt.resolvedUrl("languages/" + modelData.key)).replace(/^file:\/\//, "")
          : lib.cfg.userLanguagesDir + "/" + modelData.key
        property var manifest: modelData.manifest || ({})
        readonly property var previews: (manifest.previews || []).filter(function (p) { return typeof p === "string" })
        property int shown: 0

        width: Style.space(232)
        height: body.implicitHeight + Style.space(16)
        radius: Style.space(4)
        color: Util.alpha(lib.cfg.lineColor, hover.hovered ? 0.06 : 0.03)
        border.width: active ? Math.max(2, Style.space(2)) : Math.max(1, Style.space(1))
        border.color: active ? lib.cfg.accentColor : Util.alpha(lib.cfg.lineColor, 0.25)

        // Built-ins carry their manifest in the plugin; yours come from the installer's index.
        FileView {
          path: card.modelData.builtin ? card.dir + "/manifest.json" : ""
          printErrors: false
          onLoaded: { try { card.manifest = JSON.parse(text()) } catch (e) { card.manifest = ({}) } }
        }
        HoverHandler { id: hover }
        Timer {
          running: hover.hovered && card.previews.length > 1 && lib.cfg.motionBase > 0
          interval: 1400
          repeat: true
          onTriggered: card.shown = (card.shown + 1) % card.previews.length
          onRunningChanged: if (!running) card.shown = 0
        }

        Column {
          id: body
          x: Style.space(8); y: Style.space(8)
          width: parent.width - Style.space(16)
          spacing: Style.space(4)

          // The pictures were rendered on the light ground, so they sit on it in any scheme.
          Rectangle {
            width: parent.width
            height: width * 0.62
            radius: Style.space(2)
            color: "#f3f0e7"
            clip: true
            Image {
              anchors.fill: parent
              anchors.margins: Style.space(4)
              fillMode: Image.PreserveAspectFit
              smooth: true
              asynchronous: true
              source: card.previews.length ? "file://" + card.dir + "/" + card.previews[card.shown] : ""
            }
            Text {
              anchors.centerIn: parent
              visible: !card.previews.length
              text: "No preview"
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              color: "#6b6b66"
            }
          }
          Text {
            width: parent.width
            elide: Text.ElideRight
            text: card.manifest.name || card.modelData.label
            textFormat: Text.PlainText
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
            color: lib.cfg.lineColor
          }
          Text {
            width: parent.width
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: [card.manifest.author, card.manifest.licence, card.manifest.version ? "v" + card.manifest.version : ""]
                    .filter(function (s) { return !!s }).join(" · ")
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: lib.cfg.soft(0.6)
          }
          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            maximumLineCount: 2
            elide: Text.ElideRight
            textFormat: Text.PlainText
            visible: text !== ""
            text: card.manifest.description || ""
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: lib.cfg.soft(0.5)
          }
          Row {
            spacing: Style.space(4)
            LibButton {
              text: card.active ? "In use" : "Use"
              primary: card.active
              label: "Use " + (card.manifest.name || card.modelData.label)
              onActivated: if (!card.active) lib.picked(card.modelData.key)
            }
            LibButton {
              visible: !card.modelData.builtin
              text: lib.confirmRemove === card.modelData.key ? "Remove it" : "Remove"
              alert: lib.confirmRemove === card.modelData.key
              label: "Remove " + (card.manifest.name || card.modelData.label)
              onActivated: {
                if (lib.confirmRemove !== card.modelData.key) { lib.confirmRemove = card.modelData.key; return }
                lib.confirmRemove = ""
                if (card.active) lib.picked("classic")   // never leave the overlay on a removed language
                removeProc.command = [lib.tool, "remove", "--json", card.modelData.key]
                removeProc.running = true
              }
            }
            Text {
              visible: lib.confirmRemove === card.modelData.key
              anchors.verticalCenter: parent.verticalCenter
              text: "Press again to remove"
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              color: lib.cfg.soft(0.6)
            }
          }
          Text {
            text: card.modelData.builtin ? "Built in" : (card.modelData.looks + (card.modelData.looks === 1 ? " look" : " looks"))
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: lib.cfg.soft(0.45)
          }
        }
      }
    }
  }

  // ---- Install from a folder: warning, folder picker, the checker's report.
  LibButton {
    visible: lib.installState === "" || lib.installState === "report"
    text: "Install from folder…"
    label: "Install a design language from a folder"
    onActivated: { lib.installState = "warn"; lib.report = ({}) }
  }
  Rectangle {
    visible: lib.installState === "warn" || lib.installState === "busy"
    width: parent.width
    height: warnCol.implicitHeight + Style.space(16)
    radius: Style.space(4)
    color: Util.alpha(lib.cfg.accentColor, 0.12)
    Column {
      id: warnCol
      x: Style.space(8); y: Style.space(8)
      width: parent.width - Style.space(16)
      spacing: Style.space(6)
      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        text: "A design language runs code on your desktop. re:dial checks it for the risky things it knows; only languages in the reviewed gallery have been read by a person."
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        color: lib.cfg.lineColor
      }
      Row {
        spacing: Style.space(4)
        LibButton {
          text: lib.installState === "busy" ? "Checking…" : "Choose folder"
          primary: true
          label: "Choose the language's folder"
          onActivated: if (lib.installState === "warn") lib.runInstall("", false)
        }
        LibButton {
          text: "Cancel"
          label: "Cancel installing"
          onActivated: lib.installState = ""
        }
      }
    }
  }
  Column {
    visible: lib.installState === "report"
    width: parent.width
    spacing: Style.space(4)
    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: lib.report.ok ? "Installed " + lib.report.name + ". Pick it above to use it."
          : lib.report.cancelled ? "No folder chosen."
          : (lib.report.name ? lib.report.name + " wasn't installed:" : "It wasn't installed:")
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      color: lib.report.ok || lib.report.cancelled ? lib.cfg.lineColor : lib.cfg.roles.alert
    }
    Repeater {
      model: lib.report.problems || []
      delegate: Text {
        required property var modelData
        width: lib.width
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        text: "• " + modelData.file + (modelData.line ? ", line " + modelData.line : "") + ": " + modelData.reason
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        color: lib.cfg.soft(0.75)
      }
    }
    LibButton {
      visible: !!(lib.report.problems && lib.report.problems.length === 1
                  && /already installed/.test(lib.report.problems[0].reason))
      text: "Replace it"
      label: "Replace the installed copy with this folder"
      onActivated: lib.runInstall(lib.lastFolder, true)
    }
  }

  function runInstall(folder, replace) {
    installState = "busy"
    // Prints the folder on the first line, then the tool's JSON report; exit 3 = no folder chosen.
    installProc.command = ["bash", "-c",
      'd="$1"; [ -n "$d" ] || d=$(zenity --file-selection --directory --title="Choose a design language folder") || exit 3; ' +
      'printf "%s\\n" "$d"; exec "$2" install --json $3 "$d"', "_", folder, tool, replace ? "--replace" : ""]
    installProc.running = true
  }
  Process {
    id: installProc
    stdout: StdioCollector { id: installOut }
    onExited: (code) => {
      var lines = installOut.text.split("\n")
      lib.lastFolder = lines[0] || ""
      try { lib.report = JSON.parse(lines.slice(1).join("\n")) }
      catch (e) { lib.report = code === 3 ? { cancelled: true } : { ok: false, problems: [ { file: "redial-language", line: 0, reason: "didn't run (is it installed?)" } ] } }
      lib.installState = "report"
      lib.cfg.reloadLanguages()
    }
  }
  Process {
    id: removeProc
    onExited: lib.cfg.reloadLanguages()
  }

  // A small text button in the library's style.
  component LibButton: Pressable {
    id: btn
    property string text: ""
    property bool primary: false
    property bool alert: false
    ringColor: lib.cfg.accentColor
    ringWidth: Math.max(2, Style.space(2))
    width: Math.max(Style.space(56), btnText.implicitWidth + Style.space(20))
    height: Style.space(28)
    radius: Style.space(2)
    color: primary ? lib.cfg.accentColor : alert ? Util.alpha(lib.cfg.roles.alert, 0.15) : Util.alpha(lib.cfg.lineColor, btn.hovered ? 0.08 : 0)
    border.width: Math.max(1, Style.space(1))
    border.color: primary ? lib.cfg.accentColor : alert ? lib.cfg.roles.alert : Util.alpha(lib.cfg.lineColor, 0.55)
    Text {
      id: btnText
      anchors.centerIn: parent
      text: btn.text
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      color: btn.primary ? lib.cfg.onAccent : lib.cfg.lineColor
    }
  }
}
