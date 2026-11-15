import QtQuick
import QtQuick.Controls
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "ConfigText.js" as ConfigText
import "ActionGroups.js" as ActionGroups
import "StylePresets.js" as StylePresets
import "LookResolve.js" as LookResolve

// Pick and reorder which of the daemon's tools are active, and where the overlay sits.
//
// A settings screen: real mouse input, no rotation socket; it only reads and writes files in
// ~/.config/redial/:
//   tools.json   - written by the daemon at startup: [{name, icon}] for every tool it can
//                  build, so a tool added to TOOL_LIBRARY just shows up here.
//   status.json  - written by the daemon every few seconds ({state, battery, updated, ...});
//                  shown as the status line under the title.
//   config.json  - the shared config. Keys this panel doesn't own are read whole and
//                  written back untouched.
//
// Every change, the tool ring included, is written at once; the daemon reloads the ring while the
// dial is idle, so no restart. (The ring used to wait for a Save, and closing the window lost it.)
Item {
  id: root
  required property var cfg

  // Window lifecycle is owned by the embedder (DialMenu.qml); this signal is all it needs.
  signal closeRequested()
  // Peek at the live overlay beside this window; pressing Live again (or closing) hides it.
  signal liveRequested()
  property var manifest: []     // [{name, icon}], in TOOL_LIBRARY order
  property var configDoc: ({})  // full parsed config.json, kept intact
  property var selected: []     // ordered active_tools names
  // True while config.json exists but cannot be read (caught mid-edit, say). configDoc then keeps
  // the last good copy and every write is refused, so one click cannot replace a hand-written
  // config with an almost empty one.
  property bool configBroken: false

  // Change config.json: copy the last good config, let `mutate` edit the copy, write it, keep it.
  // Every setting goes through here. Returns false (writing nothing) while the file is unreadable.
  function writeConfig(mutate) {
    if (configBroken) return false
    var out = ({})
    for (var k in configDoc) out[k] = configDoc[k]
    mutate(out)
    configFile.setText(JSON.stringify(out, null, 2))
    configDoc = out
    return true
  }
  property string ringFocus: ""  // ring tool that keeps keyboard focus across a keyboard move

  // DialMenu gives this keyboard focus each time the window opens; Escape closes it, and Tab
  // walks every control in reading order.
  focus: true
  // A wide window puts the ring beside the Look controls and the setting groups two across.
  readonly property bool wide: width >= Style.space(760)
  Keys.onEscapePressed: root.closeRequested()
  property bool everLoadedManifest: false
  property bool everLoadedConfig: false

  readonly property string dir:
    (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/redial"
  readonly property string manifestPath: dir + "/tools.json"
  readonly property string configPath: dir + "/config.json"

  // Named anchorGrid, not "anchors" -- every Item already has a built-in
  // "anchors" group property (anchors.fill, anchors.centerIn, ...), and a
  // custom property of the same name would shadow it.
  readonly property var anchorGrid: [
    ["top-left", "top", "top-right"],
    ["left", "center", "right"],
    ["bottom-left", "bottom", "bottom-right"],
  ]
  // configDoc.anchor falls back to Settings.qml's own default ("bottom")
  // when unset, exactly like cfg.anchor does -- kept in sync with it rather
  // than read from cfg directly so a click highlights immediately, before
  // the file-watcher round-trip updates cfg.
  property string anchor: (configDoc && configDoc.anchor) ? String(configDoc.anchor) : "bottom"

  // Overall size of the on-screen dial menu (Settings.qml maps these to a scale).
  // Bound to configDoc like `anchor`, so a click highlights before the file-watcher
  // round-trip updates cfg.
  readonly property var sizeOptions: [
    { key: "large",  label: "Large" },
    { key: "medium", label: "Medium" },
    { key: "small",  label: "Small" }
  ]
  property string sizeChoice: {
    var v = (configDoc && configDoc.size) ? String(configDoc.size) : "large"
    return (v === "medium" || v === "small") ? v : "large"
  }
  function setSize(s) {
    writeConfig(function (o) { o.size = s })
  }

  // Which page of the window is showing: "look" (position, size, appearance, tools) or "feel"
  // (sensitivity, timings, clicks), "all" or "help" -- the Dial's pages -- or "pen", the Surface Pen,
  // which has its own tab above the Dial's pages. Feel and Pen apply immediately.
  // Installed design languages: one folder each under languages/ (see languages/README.md).
  FolderListModel {
    id: languageFolders
    folder: Qt.resolvedUrl("languages")
    showFiles: false
    showDirs: true
  }
  readonly property var languageOptions: {
    var out = []
    for (var i = 0; i < languageFolders.count; i++) {
      var n = String(languageFolders.get(i, "fileName"))
      // re:dial's own languages carry the re:dial name ("basic" is a working name)
      out.push({ key: n, label: (n === "classic" || n === "basic") ? "re:dial " + n : n.charAt(0).toUpperCase() + n.slice(1) })
    }
    return out.length ? out : [ { key: "classic", label: "re:dial classic" } ]
  }
  // ---- Every setting: rows from schema.json (one per key re:dial reads), so nothing is file-only.
  property var schemaGroups: []
  property string allFilter: ""
  FileView {
    path: String(Qt.resolvedUrl("schema.json")).replace(/^file:\/\//, "")
    printErrors: false
    onLoaded: {
      try { root.schemaGroups = JSON.parse(text()).groups || [] } catch (e) { root.schemaGroups = [] }
    }
  }
  function rowMatches(item) {
    var f = allFilter.trim().toLowerCase()
    if (f === "") return true
    return (item.label + " " + item.key + " " + (item.help || "")).toLowerCase().indexOf(f) >= 0
  }
  // A dotted key ("pen.barrel.action") in the saved config, or undefined when it is not set.
  function getPath(key) {
    var parts = key.split("."), v = configDoc
    for (var i = 0; i < parts.length; i++) {
      if (v === null || typeof v !== "object") return undefined
      v = v[parts[i]]
    }
    return v
  }
  function effective(item) {
    var v = getPath(item.key)
    return v === undefined ? item["default"] : v
  }
  // Set (or, with `remove`, delete) a dotted key, copying each object on the way so the last good
  // config is never edited in place. Empty objects left behind by a reset are removed too.
  function setPath(key, value, remove) {
    writeConfig(function (o) {
      var parts = key.split("."), objs = [o]
      for (var i = 0; i < parts.length - 1; i++) {
        var cur = objs[i][parts[i]], copy = ({})
        if (cur && typeof cur === "object" && !Array.isArray(cur)) for (var k in cur) copy[k] = cur[k]
        objs[i][parts[i]] = copy
        objs.push(copy)
      }
      var leaf = parts[parts.length - 1]
      if (remove) delete objs[objs.length - 1][leaf]
      else objs[objs.length - 1][leaf] = value
      for (var j = parts.length - 2; j >= 0 && remove; j--)
        if (Object.keys(objs[j + 1]).length === 0) delete objs[j][parts[j]]
    })
  }
  function shown(v) {
    if (v === undefined || v === "") return "unset"
    if (typeof v === "boolean") return v ? "on" : "off"
    if (typeof v === "object") return JSON.stringify(v)
    return String(v)
  }
  function clickChoices(item) {
    if (item.group === "barrel") return penBarrelActions
    return clickOptions(item.group, item.key.split(".").pop())
  }
  function clickChoice(item) {
    var opts = clickChoices(item), cur = String(effective(item))
    for (var i = 0; i < opts.length; i++) if (opts[i].name === cur) return opts[i]
    return { name: cur, label: cur, description: "" }
  }
  function nudge(item, dir) {
    var v = Number(effective(item)) + dir * item.step
    v = Math.max(item.min, Math.min(item.max, v))
    var dp = String(item.step).indexOf(".") >= 0 ? String(item.step).split(".")[1].length : 0
    setPath(item.key, Number(v.toFixed(dp)))
  }
  readonly property var colourSpec: /^(theme|auto|accent|foreground|background|urgent|muted|color([0-9]|1[0-5])|#[0-9a-fA-F]{6})$/
  Process {
    id: editorProc
    command: ["bash", "-c", "command -v omarchy-launch-editor >/dev/null && exec omarchy-launch-editor \"$1\" || exec xdg-open \"$1\"", "_", root.configPath]
  }
  function openConfigFile() { editorProc.running = true; root.closeRequested() }

  property string page: "look"
  // The Dial page to return to from the Pen tab.
  property string dialPage: "look"
  onPageChanged: if (page !== "pen") dialPage = page
  readonly property var devices: [ { key: "dial", label: "Dial" }, { key: "pen", label: "Pen" } ]
  readonly property var pages: [ { key: "look", label: "Look" }, { key: "feel", label: "Feel" },
                                 { key: "all", label: "Every setting" }, { key: "help", label: "Help" } ]
  function pageNumber() {
    for (var i = 0; i < pages.length; i++) if (pages[i].key === page) return i + 1
    return 1
  }

  // A saved setting, or `fallback` if it is missing or the wrong type.
  function cfgValue(key, fallback) {
    var v = configDoc ? configDoc[key] : undefined
    var ok = typeof v === typeof fallback && (typeof v !== "number" || isFinite(v))
    return ok ? v : fallback
  }
  // Write one key back to config.json, keeping every other key as it is.
  function setConfigKey(key, value) {
    writeConfig(function (o) { o[key] = value })
  }

  readonly property var helpTopics: [
    { title: "Turn", body: "Turning the dial does what the armed tool does. Volume is armed when nothing else is." },
    { title: "Click", body: "One click does the armed tool's click (mute, for Volume). A double click and a triple click do the actions chosen on the Feel page." },
    { title: "Hold", body: "Hold the button until the menu appears. Turn to pick a tool and let go to choose it. With Tap menu on the Feel page, let go as soon as it opens, then turn and click to choose; leave it alone and it closes by itself." },
    { title: "Coming back", body: "A tool you picked drops back to Volume after a few seconds without turning, so nothing stays armed by accident. Change how long on the Feel page." },
    { title: "Too jumpy or too slow", body: "Sensitivity changes how far you turn for each step. Ignore small turns filters out a bump or a tremor. Hold and double-click speed can both be relaxed." },
    { title: "Setup: browse the web", body: "Put Scroll, Tabs, Focus and Zoom on the ring (Look page). Scroll reads, Tabs switches tabs, Focus walks the links with each step and its click opens one, Zoom enlarges. Scroll stays armed while you read." },
    { title: "Setup: point and click", body: "Pointer moves the mouse and has its own clicks: click to left-click, double-click to flip between left-right and up-down, triple-click to right-click. Change any of them under Clicks for one tool on the Feel page." },
    { title: "Setup: dictate", body: "Double click Dictation on/off starts and stops dictation; Triple click Enter sends what you said. Both are the defaults for every tool. With Pointer armed those clicks are Pointer's own, so dictate from the pen's tail button or give Pointer a Dictation click of its own." },
    { title: "Setup: run the computer", body: "Windows and Workspaces on the ring move between apps; a click Maximizes or goes back. Set a Double click to Omarchy menu (Open) to reach apps and settings, and add the Settings tool so the dial can change itself." },
    { title: "Keyboard", body: "Tab moves between controls, Enter or Space presses one, Shift+Enter goes back through a list of choices, Escape closes this window." },
    { title: "About", body: "re:dial " + (status.version || "(unknown version)") + ", beta. Please mention this number when you report a problem." },
    { title: "Something wrong?", body: "The line under the title says whether the dial is connected. If it says the service is not running, press Restart dial service. If that does not help, run redial-setup in a terminal; it checks everything and says what to fix." }
  ]

  // One labelled row of choice chips. `current` is the stored value; if it matches none of the
  // chips (a value written by hand) a note says so. The daemon clamps every value to a safe range.
  component ChoiceRow: Column {
    id: choiceRow
    property var cfg
    property string title: ""
    property string help: ""
    property string unit: ""
    property var options: []
    property var current
    signal picked(var key)
    readonly property bool custom: {
      for (var i = 0; i < options.length; i++)
        if (options[i].key === current) return false
      return true
    }
    width: parent ? parent.width : 0
    spacing: Style.space(6)

    Text {
      text: choiceRow.title
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      font.capitalization: Font.AllUppercase
      font.letterSpacing: Style.space(1.2)
      color: choiceRow.cfg.soft(0.6)
    }

    Flow {
      width: parent.width
      spacing: Style.space(4)
      Repeater {
        model: choiceRow.options
        delegate: Pressable {
          id: chip
          required property var modelData
          readonly property bool active: choiceRow.current === modelData.key
          label: choiceRow.title + ": " + modelData.label
          checkable: true
          checked: active
          ringColor: choiceRow.cfg.accentColor
          ringWidth: Math.max(2, Style.space(2))
          onActivated: choiceRow.picked(modelData.key)
          width: Math.max(Style.space(64), chipText.implicitWidth + Style.space(20))
          height: Style.space(32)
          radius: Style.space(2)
          color: active ? choiceRow.cfg.accentColor : "transparent"
          border.width: Math.max(1, Style.space(1))
          border.color: active ? choiceRow.cfg.accentColor : Util.alpha(choiceRow.cfg.lineColor, 0.55)

          Text {
            id: chipText
            anchors.centerIn: parent
            text: chip.modelData.label
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: chip.active ? choiceRow.cfg.onAccent : choiceRow.cfg.lineColor
          }
        }
      }
    }

    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      visible: text !== ""
      text: choiceRow.help + (choiceRow.custom
            ? " Custom value in config.json: " + choiceRow.current + choiceRow.unit + "." : "")
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      color: choiceRow.cfg.soft(0.5)
    }
  }

  // A number on a scale: drag, or arrow keys when focused. Saves on release, not every step.
  component SliderRow: Column {
    id: sliderRow
    property var cfg
    property string title: ""
    property string help: ""
    property real from: 0
    property real to: 1
    property real stepSize: 1
    property real current: 0
    property var format: function (v) { return String(v) }
    signal picked(real value)
    onCurrentChanged: slider.value = current  // dragging breaks the binding; follow outside edits
    width: parent ? parent.width : 0
    spacing: Style.space(6)

    Text {
      text: sliderRow.title + "   " + sliderRow.format(slider.value)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      font.capitalization: Font.AllUppercase
      font.letterSpacing: Style.space(1.2)
      color: sliderRow.cfg.soft(0.6)
    }

    Slider {
      id: slider
      width: parent.width
      height: Style.space(32)
      from: sliderRow.from
      to: sliderRow.to
      stepSize: sliderRow.stepSize
      snapMode: Slider.SnapAlways
      value: sliderRow.current
      Accessible.name: sliderRow.title
      function commit() { if (value !== sliderRow.current) sliderRow.picked(value) }
      onPressedChanged: if (!pressed) commit()
      onMoved: if (!pressed) commit()  // keyboard steps
      background: Rectangle {
        x: slider.leftPadding
        y: slider.topPadding + slider.availableHeight / 2 - height / 2
        width: slider.availableWidth
        height: Math.max(1, Style.space(1))
        color: Util.alpha(sliderRow.cfg.lineColor, 0.55)
        Rectangle {
          width: slider.visualPosition * parent.width
          height: Math.max(2, Style.space(2))
          anchors.verticalCenter: parent.verticalCenter
          color: sliderRow.cfg.accentColor
        }
      }
      handle: Rectangle {
        x: slider.leftPadding + slider.visualPosition * (slider.availableWidth - width)
        y: slider.topPadding + slider.availableHeight / 2 - height / 2
        implicitWidth: Style.space(18)
        implicitHeight: Style.space(18)
        radius: width / 2
        color: slider.pressed ? sliderRow.cfg.accentColor : "transparent"
        border.width: slider.activeFocus ? Math.max(2, Style.space(2)) : Math.max(1, Style.space(1))
        border.color: slider.activeFocus || slider.pressed ? sliderRow.cfg.accentColor : sliderRow.cfg.lineColor
      }
    }

    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      visible: text !== ""
      text: sliderRow.help
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      color: sliderRow.cfg.soft(0.5)
    }
  }

  // One colour role as a grid of swatches: Auto (the colour scheme's own), the theme's roles and
  // its 16 slots. A hex written by hand matches no swatch, and the note says so.
  component SwatchRow: Column {
    id: swatchRow
    property var cfg
    property string title: ""
    property string key: ""       // "colors.accent", "colors.line" or "colors.background"
    property string role: ""      // the role "theme" stands for, for resolveColor
    property string current: "theme"
    property var specs: []
    signal picked(string spec)
    readonly property bool custom: specs.indexOf(current.toLowerCase()) < 0
    width: parent ? parent.width : 0
    spacing: Style.space(6)

    Text {
      text: swatchRow.title
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      font.capitalization: Font.AllUppercase
      font.letterSpacing: Style.space(1.2)
      color: swatchRow.cfg.soft(0.6)
    }
    Flow {
      width: parent.width
      spacing: Style.space(4)
      Repeater {
        model: swatchRow.specs
        delegate: Pressable {
          id: sw
          required property string modelData
          readonly property bool auto: modelData === "theme"
          readonly property bool active: swatchRow.current.toLowerCase() === modelData
          readonly property color fill: swatchRow.cfg.resolveColor(modelData, swatchRow.role)
          label: swatchRow.title + ": " + (auto ? "Auto" : modelData)
          checkable: true
          checked: active
          ringColor: swatchRow.cfg.accentColor
          ringWidth: Math.max(2, Style.space(2))
          onActivated: swatchRow.picked(modelData)
          width: auto ? Style.space(56) : Style.space(40)
          height: Style.space(32)
          radius: Style.space(2)
          color: auto ? "transparent" : fill
          border.width: active ? Math.max(3, Style.space(3)) : Math.max(1, Style.space(1))
          border.color: active ? swatchRow.cfg.lineColor : Util.alpha(swatchRow.cfg.lineColor, 0.35)
          Text {
            anchors.centerIn: parent
            text: (sw.active ? "✓ " : "") + (sw.auto ? "Auto" : sw.modelData === "accent" ? "Acc"
                  : sw.modelData === "foreground" ? "FG" : sw.modelData === "background" ? "BG"
                  : sw.modelData.slice(5))
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            // dark text on light swatches, light on dark
            color: sw.auto ? swatchRow.cfg.lineColor
                 : (0.299 * sw.fill.r + 0.587 * sw.fill.g + 0.114 * sw.fill.b) > 0.55 ? "#111111" : "#f5f5f5"
          }
        }
      }
    }
    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      visible: swatchRow.custom
      text: "Custom value in config.json: " + swatchRow.current + ". Pick a swatch to replace it."
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      color: swatchRow.cfg.soft(0.5)
    }
  }

  // What a click (or a pen button) does: the current action with its place in the list ("4 of 32"),
  // and every action, grouped by where it helps, one press away. Left and Right still step through.
  component ActionPicker: Column {
    id: picker
    property var cfg
    property string title: ""
    property string label: ""     // what a screen reader says before the action
    property var options: []      // [{name, label, description}]
    property var current: ({})
    property bool expanded: false
    // The column the title takes; the chip, description and list start after it.
    readonly property int gutter: title !== "" ? Style.space(92) : 0
    signal picked(string name)
    readonly property int at: options.findIndex(function (a) { return a.name === current.name })
    function step(by) { if (options.length) picked(options[(Math.max(0, at) + by + options.length) % options.length].name) }
    width: parent ? parent.width : 0
    spacing: Style.space(4)

    Row {
      spacing: Style.space(8)
      Text {
        visible: picker.title !== ""
        width: Style.space(84)
        anchors.verticalCenter: parent.verticalCenter
        text: picker.title
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        color: picker.cfg.lineColor
      }
      Pressable {
        id: pickChip
        label: picker.label + ": " + picker.current.label + ", " + (picker.at + 1) + " of " + picker.options.length
               + (picker.expanded ? ". Press to close the list" : ". Press to list them all")
        ringColor: picker.cfg.accentColor
        ringWidth: Math.max(2, Style.space(2))
        onActivated: picker.expanded = !picker.expanded
        onAlternate: picker.step(-1)
        Keys.onRightPressed: picker.step(1)
        Keys.onLeftPressed: picker.step(-1)
        width: picker.width - picker.gutter
        height: Style.space(32)
        radius: Style.space(2)
        color: Util.alpha(picker.cfg.lineColor, pickChip.hovered ? 0.08 : 0)
        border.width: Math.max(1, Style.space(1))
        border.color: Util.alpha(picker.cfg.lineColor, 0.55)
        Text {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(10)
          anchors.right: countText.left
          anchors.verticalCenter: parent.verticalCenter
          elide: Text.ElideRight
          text: picker.current.label || ""
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          color: picker.cfg.lineColor
        }
        Text {
          id: countText
          anchors.right: parent.right
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          text: (picker.at + 1) + " OF " + picker.options.length + (picker.expanded ? "  \u25b4" : "  \u25be")
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.letterSpacing: Style.space(1)
          color: picker.cfg.soft(0.55)
        }
      }
    }

    Text {
      x: picker.gutter
      width: picker.width - picker.gutter
      text: picker.current.description || ""
      elide: Text.ElideRight
      maximumLineCount: 1
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      color: picker.cfg.soft(0.5)
    }

    // The whole list, grouped: Tab walks it (the dial's Settings tool too), Enter picks.
    Column {
      visible: picker.expanded
      x: picker.gutter
      width: picker.width - picker.gutter
      spacing: Style.space(8)
      topPadding: Style.space(4)
      bottomPadding: Style.space(8)
      Repeater {
        model: picker.expanded ? ActionGroups.grouped(picker.options) : []
        delegate: Column {
          id: grp
          required property var modelData
          width: parent.width
          spacing: Style.space(4)
          Text {
            text: grp.modelData.title
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.capitalization: Font.AllUppercase
            font.letterSpacing: Style.space(1.2)
            color: picker.cfg.soft(0.55)
          }
          Flow {
            width: parent.width
            spacing: Style.space(4)
            Repeater {
              model: grp.modelData.items
              delegate: Pressable {
                id: actChip
                required property var modelData
                readonly property bool active: modelData.name === picker.current.name
                label: picker.label + ": " + modelData.label + ". " + (modelData.description || "")
                checkable: true
                checked: active
                ringColor: picker.cfg.accentColor
                ringWidth: Math.max(2, Style.space(2))
                onActivated: { picker.picked(modelData.name); picker.expanded = false; pickChip.forceActiveFocus() }
                width: actText.implicitWidth + Style.space(20)
                height: Style.space(30)
                radius: Style.space(2)
                color: active ? picker.cfg.accentColor : "transparent"
                border.width: Math.max(1, Style.space(1))
                border.color: active ? picker.cfg.accentColor : Util.alpha(picker.cfg.lineColor, 0.4)
                Text {
                  id: actText
                  anchors.centerIn: parent
                  text: actChip.modelData.label
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: actChip.active ? picker.cfg.onAccent : picker.cfg.lineColor
                }
              }
            }
          }
        }
      }
    }
  }

  // The looks the chosen design language ships (LookResolve.offered), plus the Omarchy OSD layout.
  // A language offers only its own looks; nothing is borrowed from another one.
  Loader {
    id: pickedLanguage
    source: "languages/" + root.cfgValue("language", "classic") + "/Language.qml"
  }
  readonly property var appearanceOptions: LookResolve.offered(pickedLanguage.item).map(function (k) { return LookResolve.option(k, pickedLanguage.item) })
  readonly property string appearanceChoice: {
    var l = (configDoc && configDoc.layout) ? String(configDoc.layout) : "dial"
    var f = (configDoc && configDoc.face) ? String(configDoc.face) : "classic"
    return LookResolve.choice(l, f)
  }
  // After a language switch the saved look may be one the new language lacks: write its default
  // once, so the picker and the overlay agree on what is drawn.
  onAppearanceOptionsChanged: {
    var lang = pickedLanguage.item
    if (!lang || !lang.looks) return
    var keys = appearanceOptions.map(function (o) { return o.key })
    if (keys.indexOf(appearanceChoice) < 0 && lang.defaultLook) setAppearance(LookResolve.option(lang.defaultLook, lang))
  }
  function setAppearance(opt) {
    writeConfig(function (o) {
      o.layout = opt.layout
      if (opt.face) o.face = opt.face
    })
  }

  // Style (StylePresets.js): the quick controls live here for everyone; they used to be a fly-out
  // in one person's bar.
  function dialValue(key, fallback) {
    var v = getPath("dial." + key)
    return v === undefined ? fallback : v
  }
  readonly property string weightChoice: StylePresets.weightOf(configDoc.dial) || "widths set one by one"
  function drawn(what) { return StylePresets.drawn(what, cfg.layout, cfg.face, cfg.plate) }
  function setDial(values) {
    writeConfig(function (o) {
      var d = ({}), src = o.dial || {}
      for (var k in src) d[k] = src[k]
      for (var v in values) d[v] = values[v]
      o.dial = d
    })
  }

  // Click gestures. Options come from clicks.json / pen_clicks.json (written by the daemon at
  // startup); the choice lives in config.json and is re-read live. One picker, parametrized by
  // `group` ("dial" | "pentail"); the barrel button has its own block below.
  property var clickActions: []      // [{name, label, description}] -- dial
  property var clickDefaults: ({ "single": "tool", "double": "dictation", "triple": "enter" })
  property var penTailActions: []    // [{name, label, description}] -- pen tail button
  property var penTailDefaults: ({ "single": "space", "double": "enter", "hold": "menu" })
  property var penBarrelActions: []  // [{name, label, description}] -- pen barrel button
  property var penEraserActions: []  // [{name, label, description}] -- back of the pen: tap, hold
  property var penEraserDefaults: ({ "tap": "escape", "hold": "delete_word" })
  property string penBarrelDefault: "right_click"
  property bool everLoadedClicks: false
  property bool everLoadedPenClicks: false
  readonly property string clicksPath: dir + "/clicks.json"
  readonly property string penClicksPath: dir + "/pen_clicks.json"
  readonly property var clickKinds: [
    { key: "single", title: "Single click" },
    { key: "double", title: "Double click" },
    { key: "triple", title: "Triple click" }
  ]
  // The pen's tail button firmware only ever reports these three distinct
  // events -- there is no raw click counter, so a real triple-tap isn't
  // something to detect, only these three slots to make configurable.
  readonly property var tailKinds: [
    { group: "pentail", key: "single", title: "Single click" },
    { group: "pentail", key: "double", title: "Double click" },
    { group: "pentail", key: "hold", title: "Press & hold" }
  ]
  // The back of the pen. A scroll that starts with a light touch used to count as a tap and
  // press Escape, so each of these can be set to "Nothing".
  readonly property var eraserKinds: [
    { group: "eraser", key: "tap", title: "Quick tap" },
    { group: "eraser", key: "hold", title: "Press & hold" }
  ]
  function groupActions(group) {
    return group === "pentail" ? penTailActions : group === "eraser" ? penEraserActions : clickActions
  }
  function groupDefaults(group) {
    return group === "pentail" ? penTailDefaults : group === "eraser" ? penEraserDefaults : clickDefaults
  }
  function groupChoice(group) {
    if (group === "pentail")
      return (configDoc && configDoc.pen && configDoc.pen.tail_clicks) ? configDoc.pen.tail_clicks : {}
    if (group === "eraser")
      return (configDoc && configDoc.pen && configDoc.pen.eraser) ? configDoc.pen.eraser : {}
    return (configDoc && configDoc.clicks) ? configDoc.clicks : {}
  }
  // "tool" (the armed tool's own click) is dial-specific and single-click only.
  function clickOptions(group, kind) {
    return groupActions(group).filter(function (a) {
      return a.name !== "tool" || (group === "dial" && kind === "single")
    })
  }
  function clickAction(group, kind) {
    var chosen = groupChoice(group)[kind] ? String(groupChoice(group)[kind]) : ""
    var opts = clickOptions(group, kind)
    for (var i = 0; i < opts.length; i++) if (opts[i].name === chosen) return opts[i]
    var def = groupDefaults(group)[kind]
    for (var j = 0; j < opts.length; j++) if (opts[j].name === def) return opts[j]
    return opts.length ? opts[0] : ({ name: "", label: "(restart the dial daemon to load options)", description: "" })
  }
  // Clicks for one tool (config "tool_clicks"): yours, else the tool's own default (tools.json
  // "clicks"), else the click for every tool. "" in the picker means "no choice of yours".
  property string clickTool: ""
  readonly property string clickToolShown: selected.indexOf(clickTool) >= 0 ? clickTool
                                         : (selected.length > 1 ? selected[1] : (selected[0] || ""))
  function toolClickFallback(tool, kind) {
    var m = manifest.find(function (t) { return t.name === tool })
    var own = m && m.clicks ? m.clicks[kind] : undefined
    var all = clickActions.find(function (a) { return a.name === own })
    if (all) return (all.name === "tool" ? "its own click" : all.label) + " (" + tool + "'s default)"
    return clickAction("dial", kind).label + " (every tool)"
  }
  function toolClickOptions(tool, kind) {
    return [{ name: "", label: "Default: " + toolClickFallback(tool, kind),
              description: "No choice of yours for " + tool + "; this is what it does." }]
           .concat(clickActions)
  }
  function toolClickCurrent(tool, kind) {
    var v = getPath("tool_clicks." + tool + "." + kind)
    var opts = toolClickOptions(tool, kind)
    return opts.find(function (a) { return a.name === v }) || opts[0]
  }
  function setToolClick(tool, kind, name) {
    if (name === "") setPath("tool_clicks." + tool + "." + kind, undefined, true)
    else setPath("tool_clicks." + tool + "." + kind, name)
  }

  function setClick(group, kind, name) {
    if (group === "eraser") {
      writePen(function (pen) {
        var er = ({})
        if (pen.eraser) for (var e in pen.eraser) er[e] = pen.eraser[e]
        er[kind] = name
        pen.eraser = er
      })
    } else if (group === "pentail") {
      writePen(function (pen) {
        var tail = ({})
        if (pen.tail_clicks) for (var t in pen.tail_clicks) tail[t] = pen.tail_clicks[t]
        tail[kind] = name
        pen.tail_clicks = tail
      })
    } else {
      writeConfig(function (o) {
        var clicks = ({})
        if (o.clicks) for (var c in o.clicks) clicks[c] = o.clicks[c]
        clicks[kind] = name
        o.clicks = clicks
      })
    }
  }

  // Pen enable + barrel button: one action plus an enable toggle each, not a
  // set of kinds, so these get their own small block rather than forcing
  // them through the kind-based picker above.
  readonly property bool penEnabled: !(configDoc && configDoc.pen && configDoc.pen.enabled === false)
  readonly property bool barrelEnabled: !(configDoc && configDoc.pen && configDoc.pen.barrel
                                           && configDoc.pen.barrel.enabled === false)
  function barrelAction() {
    var chosen = (configDoc && configDoc.pen && configDoc.pen.barrel && configDoc.pen.barrel.action)
      ? String(configDoc.pen.barrel.action) : ""
    for (var i = 0; i < penBarrelActions.length; i++) if (penBarrelActions[i].name === chosen) return penBarrelActions[i]
    for (var j = 0; j < penBarrelActions.length; j++) if (penBarrelActions[j].name === penBarrelDefault) return penBarrelActions[j]
    return penBarrelActions.length ? penBarrelActions[0] : ({ name: "", label: "(restart the dial daemon to load options)", description: "" })
  }
  // Shared write-through for anything under the "pen" key: copies configDoc,
  // hands the caller a mutable copy of "pen" to edit, writes, reassigns --
  // same immediate-write pattern as setAnchor/setSize above.
  function writePen(mutate) {
    writeConfig(function (o) {
      var pen = ({})
      if (o.pen) for (var p in o.pen) pen[p] = o.pen[p]
      mutate(pen)
      o.pen = pen
    })
  }
  function setBarrelAction(name) {
    writePen(function (pen) {
      var barrel = ({})
      if (pen.barrel) for (var b in pen.barrel) barrel[b] = pen.barrel[b]
      barrel.action = name
      pen.barrel = barrel
    })
  }
  function setBarrelEnabled(v) {
    writePen(function (pen) {
      var barrel = ({})
      if (pen.barrel) for (var b in pen.barrel) barrel[b] = pen.barrel[b]
      barrel.enabled = v
      pen.barrel = barrel
    })
  }
  function setPenEnabled(v) {
    writePen(function (pen) { pen.enabled = v })
  }

  // Writes through immediately. Never assigns root.anchor directly: it's a binding off configDoc.
  function setAnchor(a) {
    writeConfig(function (o) { o.anchor = a })
  }

  // Hover / focus descriptions for tools. One shared tooltip, shown after a short pause over a
  // tool (or at once when it gets keyboard focus), hidden when the pointer or focus leaves.
  property Item tipItem: null
  property string tipTitle: ""
  property string tipBody: ""
  property Item tipPending: null
  function toolDescription(name) {
    var m = manifestByName(name)
    return (m && m.description) ? String(m.description) : ""
  }
  function tipEnter(item, name, immediate) {
    var body = toolDescription(name)
    if (!body) return
    tipPending = item
    tipTitle = name
    tipBody = body
    if (immediate) { tipTimer.stop(); tipItem = item }
    else tipTimer.restart()
  }
  function tipLeave(item) {
    if (tipPending !== item && tipItem !== item) return
    tipTimer.stop()
    tipPending = null
    tipItem = null
  }
  function tipHide() { tipTimer.stop(); tipPending = null; tipItem = null }
  Timer {
    id: tipTimer
    interval: 350
    onTriggered: root.tipItem = root.tipPending
  }
  // For `omarchy-shell dialtools tip <name>`: show a ring tool's tooltip right now.
  function tipForName(name) {
    var i = selected.indexOf(name)
    var it = i >= 0 ? ringRepeater.itemAt(i) : null
    if (!it) return false
    tipEnter(it, name, true)
    return true
  }

  function manifestByName(name) {
    for (var i = 0; i < manifest.length; i++)
      if (manifest[i].name === name) return manifest[i]
    return null
  }

  // Checked tools first (in the order they'll run), then anything not yet
  // selected appended in library order -- so a newly-added library tool
  // always shows up here rather than silently staying invisible.
  readonly property var rows: {
    var seen = ({})
    var out = []
    for (var i = 0; i < selected.length; i++) {
      var n = selected[i]
      var m = manifestByName(n)
      if (!m) continue   // stale name (tool removed from the library since)
      seen[n] = true
      out.push({ name: n, icon: m.icon, checked: true })
    }
    for (var j = 0; j < manifest.length; j++) {
      var mm = manifest[j]
      if (!seen[mm.name]) out.push({ name: mm.name, icon: mm.icon, checked: false })
    }
    return out
  }

  function toggleTool(name) {
    var i = selected.indexOf(name)
    var next = selected.slice()
    if (i >= 0) next.splice(i, 1)
    else next.push(name)
    selected = next
    save()
  }

  // Full reposition (splice out, splice back in), not an adjacent swap: a
  // ring drag can cross several slots in one gesture, and a swap-only move
  // can't express that in one call the way a real reorder can.
  function moveTo(name, newIndex) {
    var i = selected.indexOf(name)
    if (i < 0) return
    newIndex = Math.max(0, Math.min(selected.length - 1, newIndex))
    if (newIndex === i) return
    var next = selected.slice()
    next.splice(i, 1)
    next.splice(newIndex, 0, name)
    selected = next
    save()
  }

  function applyConfigText(raw) {
    var r = ConfigText.parse(raw)
    if (!r.ok) {
      console.warn("[redial] config.json cannot be read; keeping the last good copy and pausing writes")
      configBroken = true
      return
    }
    configBroken = false
    configDoc = r.doc
    var act = r.doc.active_tools
    selected = (Array.isArray(act) && act.length) ? currentNames(act)
                                                   : manifest.map(function (m) { return m.name })
  }
  // Tools merged into another (Word Nav and Select into Text): a ring saved with the old names
  // shows the new one, once. The daemon says which in tools.json ("replaces").
  function currentNames(names) {
    var out = []
    names.forEach(function (n) {
      var t = manifest.find(function (m) { return (m.replaces || []).indexOf(n) >= 0 })
      var now = t ? t.name : n
      if (out.indexOf(now) < 0) out.push(now)
    })
    return out
  }

  function save() {
    writeConfig(function (o) { o.active_tools = selected })
  }

  FileView {
    id: manifestFile
    path: root.manifestPath
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.everLoadedManifest = true
      try {
        var arr = JSON.parse(String(text() || "[]"))
        root.manifest = Array.isArray(arr) ? arr : []
        root.selected = root.currentNames(root.selected)  // the config may have loaded first
      } catch (e) {
        root.manifest = []
      }
    }
    onLoadFailed: { root.everLoadedManifest = true; root.manifest = [] }
    onFileChanged: reload()
  }

  // Dial status, written by the daemon every few seconds (status.json). A file that is missing or
  // has not been refreshed lately means the daemon itself is not running.
  property var status: ({})
  property real nowSec: Date.now() / 1000
  readonly property string statusPath: dir + "/status.json"
  readonly property bool statusFresh: status.updated !== undefined && nowSec - status.updated < 45
  readonly property string statusText: {
    if (!statusFresh) return "Dial service is not running. Press the button below to restart it."
    var batt = (typeof status.battery === "number") ? "  ·  battery " + status.battery + "%" : ""
    if (status.state === "ready") return "Connected" + batt
    if (status.state === "asleep") return "Dial is asleep. Click it to wake it." + batt
    return "Looking for the dial…"
  }
  readonly property bool statusGood: statusFresh && status.state === "ready"
  // "Restart dial service": runs bin/redial-restart (installed beside the daemon).
  Process {
    id: restartProc
    command: [Quickshell.env("HOME") + "/.local/bin/redial-restart"]
  }
  property bool introSeen: cfgValue("intro_seen", false) === true
  Timer {
    interval: 10000
    repeat: true
    running: root.visible
    onTriggered: root.nowSec = Date.now() / 1000
  }
  FileView {
    id: statusFile
    path: root.statusPath
    watchChanges: true
    printErrors: false
    onLoaded: {
      try { root.status = JSON.parse(text()) } catch (e) { root.status = ({}) }
      root.nowSec = Date.now() / 1000
    }
    onLoadFailed: root.status = ({})
    onFileChanged: reload()
  }

  FileView {
    id: clicksFile
    path: root.clicksPath
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.everLoadedClicks = true
      try {
        var o = JSON.parse(text())
        root.clickActions = Array.isArray(o.actions) ? o.actions : []
        if (o.defaults) root.clickDefaults = o.defaults
      } catch (e) { root.clickActions = [] }
    }
    onLoadFailed: { root.everLoadedClicks = true; root.clickActions = [] }
    onFileChanged: reload()
  }

  FileView {
    id: penClicksFile
    path: root.penClicksPath
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.everLoadedPenClicks = true
      try {
        var o = JSON.parse(text())
        root.penTailActions = (o.tail && Array.isArray(o.tail.actions)) ? o.tail.actions : []
        if (o.tail && o.tail.defaults) root.penTailDefaults = o.tail.defaults
        root.penEraserActions = (o.eraser && Array.isArray(o.eraser.actions)) ? o.eraser.actions : []
        if (o.eraser && o.eraser.defaults) root.penEraserDefaults = o.eraser.defaults
        root.penBarrelActions = (o.barrel && Array.isArray(o.barrel.actions)) ? o.barrel.actions : []
        if (o.barrel && o.barrel.default) root.penBarrelDefault = o.barrel.default
      } catch (e) { root.penTailActions = []; root.penBarrelActions = [] }
    }
    onLoadFailed: { root.everLoadedPenClicks = true; root.penTailActions = []; root.penBarrelActions = [] }
    onFileChanged: reload()
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: { root.everLoadedConfig = true; root.applyConfigText(text()) }
    onLoadFailed: { root.everLoadedConfig = true; root.applyConfigText("") }
    onFileChanged: reload()
  }

  // Poll until both files have loaded once each -- same reasoning as
  // Settings.qml's watcher: watchChanges only follows a file that already
  // exists, and tools.json/config.json may not exist yet on a fresh install.
  Timer {
    running: !root.everLoadedManifest || !root.everLoadedConfig || !root.everLoadedClicks
             || !root.everLoadedPenClicks
    interval: 1000
    repeat: true
    onTriggered: {
      if (!root.everLoadedManifest) manifestFile.reload()
      if (!root.everLoadedConfig) configFile.reload()
      if (!root.everLoadedClicks) clicksFile.reload()
      if (!root.everLoadedPenClicks) penClicksFile.reload()
    }
  }

    Rectangle {
      id: card
      // Height follows the column's real content height (nothing here
      // scrolls any more, unlike the old list-based layout) -- the ring is
      // fixed-size but the "inactive tools" row below it wraps, so a fixed
      // card height would either clip it or leave dead space.
      anchors.fill: parent
      // Forced fully opaque (alpha=1): the theme background can carry its own alpha. A settings
      // dialog must be fully legible, so this ignores plateOpacity.
      color: Qt.rgba(root.cfg.backgroundColor.r, root.cfg.backgroundColor.g,
                     root.cfg.backgroundColor.b, 1.0)

      // Taller than the screen (a small laptop, a large font): the content scrolls, and moving
      // keyboard focus to a control scrolls it into view.
      Flickable {
        id: scroller
        anchors.fill: parent
        contentWidth: width
        contentHeight: col.implicitHeight + Style.space(40)
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        interactive: contentHeight > height
        onContentYChanged: root.tipHide()
        // Always visible while there is more than fits, so the length of the page shows at a glance.
        ScrollBar.vertical: ScrollBar {
          policy: scroller.interactive ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
          contentItem: Rectangle { implicitWidth: Style.space(3); color: Util.alpha(root.cfg.lineColor, 0.45) }
          background: Rectangle { implicitWidth: Style.space(3); color: Util.alpha(root.cfg.lineColor, 0.08) }
        }

        Connections {
          target: root.Window.window
          function onActiveFocusItemChanged() {
            var it = root.Window.window ? root.Window.window.activeFocusItem : null
            if (!it || !col.contains(col.mapFromItem(it, 0, 0))) return
            var y = col.mapFromItem(it, 0, 0).y + Style.space(20)
            var pad = Style.space(12)
            if (y - pad < scroller.contentY) scroller.contentY = Math.max(0, y - pad)
            else if (y + it.height + pad > scroller.contentY + scroller.height)
              scroller.contentY = Math.min(scroller.contentHeight - scroller.height, y + it.height + pad - scroller.height)
          }
        }

      Column {
        id: col
        anchors.top: parent.top
        anchors.topMargin: Style.space(20)
        anchors.horizontalCenter: parent.horizontalCenter
        // shortcut: capped so lines stay readable on a maximised 4K window; no third column yet.
        width: Math.min(parent.width - Style.space(40), Style.space(1280))
        spacing: Style.space(9)

        Item {
          width: parent.width
          height: Math.max(titleText.implicitHeight, liveTab.height)

          Text {
            id: titleText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "re:dial"
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
            color: root.cfg.lineColor
          }
          Text {
            anchors.left: titleText.right
            anchors.leftMargin: Style.space(10)
            anchors.baseline: titleText.baseline
            text: "SETTINGS"
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.letterSpacing: Style.space(1.6)
            color: root.cfg.soft(0.6)
          }
          // Peek at the live overlay (see liveRequested above); press again to hide it.
          Pressable {
            id: liveTab
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            label: "Show the live dial display"
            color: "transparent"
            ringColor: root.cfg.accentColor
            ringWidth: Math.max(2, Style.space(2))
            width: liveTabText.implicitWidth + Style.space(16)
            height: Style.space(32)
            radius: Style.space(2)
            onActivated: root.liveRequested()
            Text {
              id: liveTabText
              anchors.centerIn: parent
              text: "Live ›"
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              color: liveTab.hovered ? root.cfg.accentText : root.cfg.soft(0.6)
            }
          }
        }
        Text {
          width: parent.width
          text: root.statusText
          wrapMode: Text.WordWrap
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          color: root.statusGood ? root.cfg.soft(0.7) : root.cfg.accentText
        }
        Pressable {
          visible: !root.statusFresh
          label: "Restart the dial service"
          ringColor: root.cfg.accentColor
          ringWidth: Math.max(2, Style.space(2))
          onActivated: restartProc.running = true
          width: restartText.implicitWidth + Style.space(24)
          height: Style.space(32)
          radius: Style.space(2)
          color: Util.alpha(root.cfg.lineColor, restartProc.running ? 0.04 : 0.1)
          border.width: Math.max(1, Style.space(1))
          border.color: root.cfg.accentColor
          Text {
            id: restartText
            anchors.centerIn: parent
            text: restartProc.running ? "Restarting…" : "Restart dial service"
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: root.cfg.lineColor
          }
        }

        // Shown instead of silently overwriting: config.json could not be read.
        Rectangle {
          visible: root.configBroken
          width: parent.width
          height: brokenText.implicitHeight + Style.space(20)
          radius: Style.space(2)
          color: Util.alpha(root.cfg.accentColor, 0.12)
          border.width: Math.max(1, Style.space(1))
          border.color: root.cfg.accentColor
          Text {
            id: brokenText
            anchors.fill: parent
            anchors.margins: Style.space(10)
            text: "config.json has a mistake in it, so changes here are paused to protect what you wrote. Fix the file (or restore a backup) and this clears by itself."
            wrapMode: Text.WordWrap
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: root.cfg.lineColor
          }
        }

        // First run: three lines on how the dial works, shown once on the Look page.
        Rectangle {
          visible: root.everLoadedConfig && !root.introSeen && root.page === "look"
          width: parent.width
          height: introCol.implicitHeight + Style.space(20)
          radius: Style.space(2)
          color: Util.alpha(root.cfg.accentColor, 0.12)
          border.width: Math.max(1, Style.space(1))
          border.color: root.cfg.accentColor
          Column {
            id: introCol
            anchors.fill: parent
            anchors.margins: Style.space(10)
            spacing: Style.space(6)
            Text {
              width: parent.width
              text: "Welcome. Turn the dial to change the volume. Hold its button to open the tool menu, turn to pick a tool, let go to choose it. Click, double-click and triple-click each do something you can change on the Feel page."
              wrapMode: Text.WordWrap
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              color: root.cfg.lineColor
            }
            Row {
              spacing: Style.space(8)
              Pressable {
                label: "Got it, hide this welcome"
                ringColor: root.cfg.accentColor
                ringWidth: Math.max(2, Style.space(2))
                onActivated: root.setConfigKey("intro_seen", true)
                width: gotItText.implicitWidth + Style.space(24)
                height: Style.space(32)
                radius: Style.space(2)
                color: root.cfg.accentColor
                Text {
                  id: gotItText
                  anchors.centerIn: parent
                  text: "Got it"
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  color: root.cfg.onAccent
                }
              }
              Pressable {
                label: "Show the Help page"
                ringColor: root.cfg.accentColor
                ringWidth: Math.max(2, Style.space(2))
                onActivated: { root.setConfigKey("intro_seen", true); root.page = "help" }
                width: helpText.implicitWidth + Style.space(24)
                height: Style.space(32)
                radius: Style.space(2)
                color: Util.alpha(root.cfg.lineColor, 0.1)
                Text {
                  id: helpText
                  anchors.centerIn: parent
                  text: "More help"
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: root.cfg.lineColor
                }
              }
            }
          }
        }
        // Device tabs: the Dial and the Pen each have their own settings; the Dial's pages sit below.
        Row {
          spacing: Style.space(18)
          Repeater {
            model: root.devices
            delegate: Pressable {
              id: deviceTab
              required property var modelData
              readonly property bool active: (root.page === "pen") === (modelData.key === "pen")
              label: modelData.label + " settings"
              checkable: true
              checked: active
              ringColor: root.cfg.accentColor
              ringWidth: Math.max(2, Style.space(2))
              width: deviceText.implicitWidth + Style.space(32)
              height: Style.space(40)
              radius: Style.space(2)
              color: active ? root.cfg.accentColor : Util.alpha(root.cfg.lineColor, 0.08)
              onActivated: root.page = modelData.key === "pen" ? "pen" : root.dialPage
              Text {
                id: deviceText
                anchors.centerIn: parent
                text: deviceTab.modelData.label
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
                font.capitalization: Font.AllUppercase
                font.letterSpacing: Style.space(1.2)
                color: deviceTab.active ? root.cfg.onAccent : root.cfg.soft(0.6)
              }
            }
          }
        }

        Row {
          visible: root.page !== "pen"
          spacing: Style.space(18)
          Repeater {
            model: root.pages
            delegate: Pressable {
              id: tabLabel
              required property var modelData
              readonly property bool active: root.page === modelData.key
              label: modelData.label + " page"
              checkable: true
              checked: active
              color: "transparent"
              ringColor: root.cfg.accentColor
              ringWidth: Math.max(2, Style.space(2))
              width: tabText.implicitWidth + Style.space(16)
              height: Style.space(32)
              radius: Style.space(2)
              onActivated: root.page = modelData.key
              Text {
                id: tabText
                anchors.centerIn: parent
                text: tabLabel.modelData.label
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: tabLabel.active
                color: tabLabel.active ? root.cfg.accentText : root.cfg.soft(0.6)
              }
              // the chosen sheet is underlined in the accent, like the lit part of the dial's scale
              Rectangle {
                anchors.bottom: parent.bottom
                anchors.horizontalCenter: parent.horizontalCenter
                width: tabText.implicitWidth
                height: Math.max(2, Style.space(2))
                color: root.cfg.accentColor
                visible: tabLabel.active
              }
            }
          }
        }

        Rectangle { width: parent.width; height: 1; color: Util.alpha(root.cfg.lineColor, 0.55) }

        Text {
          width: parent.width
          text: root.page === "look"
                ? "Drag the ring to reorder, or focus a tool and press Left or Right. Click \u2715 (or press Delete) to remove a tool, or a chip below to add one. Every change applies immediately."
                : root.page === "feel"
                  ? "How the dial feels to use. Everything on this page applies immediately."
                  : root.page === "pen"
                  ? "The Surface Pen: buttons you press away from the screen, and what the pen does on it, hovering or in contact. Everything here applies immediately."
                  : root.page === "all"
                    ? "Every setting re:dial has, with its key in config.json and its default. Changes apply immediately; Reset puts one back."
                    : "How to use the dial. Nothing here changes any setting."
          wrapMode: Text.WordWrap
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          color: root.cfg.soft(0.6)
        }

        // Narrow: one column, the ring below the controls. Wide (Look page): the ring beside them.
        Flow {
          id: body
          readonly property bool sideBySide: root.wide && root.page === "look"
          width: parent.width
          spacing: Style.space(36)

          Column {
            width: body.sideBySide ? body.width - ringSide.width - body.spacing : body.width
            spacing: col.spacing

            Row {
              width: parent.width
              spacing: Style.space(36)
              visible: root.page === "look"

            Column {
              spacing: Style.space(6)

              Text {
                text: "Position"
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                font.capitalization: Font.AllUppercase
                font.letterSpacing: Style.space(1.2)
                color: root.cfg.soft(0.6)
              }

              Column {
                spacing: Style.space(4)
                Repeater {
                  model: root.anchorGrid
                  delegate: Row {
                    required property var modelData
                    spacing: Style.space(4)
                    Repeater {
                      model: modelData
                      delegate: Pressable {
                        id: cell
                        required property string modelData
                        readonly property bool active: root.anchor === modelData
                        label: "Position " + modelData.replace("-", " ")
                        checkable: true
                        checked: active
                        ringColor: root.cfg.accentColor
                        ringWidth: Math.max(2, Style.space(2))
                        onActivated: root.setAnchor(modelData)
                        width: Style.space(32); height: width
                        radius: Style.space(2)
                        color: active ? root.cfg.accentColor : "transparent"
                        border.width: Math.max(1, Style.space(1))
                        border.color: active ? root.cfg.accentColor : Util.alpha(root.cfg.lineColor, 0.55)

                        // A filled dot shows which of the nine cells this is,
                        // independent of the accent-fill state, so the grid
                        // still reads as a 3x3 position map when nothing is
                        // active near it -- not just nine identical squares.
                        Rectangle {
                          anchors.centerIn: parent
                          width: Style.space(6); height: width
                          radius: width / 2
                          color: cell.active ? root.cfg.backgroundColor
                                              : Util.alpha(root.cfg.lineColor, 0.5)
                        }
                      }
                    }
                  }
                }
              }
            }

            Column {
              spacing: Style.space(6)

              Text {
                text: "Size"
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                font.capitalization: Font.AllUppercase
                font.letterSpacing: Style.space(1.2)
                color: root.cfg.soft(0.6)
              }

              Row {
                spacing: Style.space(4)
                Repeater {
                  model: root.sizeOptions
                  delegate: Pressable {
                    id: sizeBtn
                    required property var modelData
                    readonly property bool active: root.sizeChoice === modelData.key
                    label: "Size: " + modelData.label
                    checkable: true
                    checked: active
                    ringColor: root.cfg.accentColor
                    ringWidth: Math.max(2, Style.space(2))
                    onActivated: root.setSize(modelData.key)
                    width: Style.space(64); height: Style.space(32)
                    radius: Style.space(2)
                    color: active ? root.cfg.accentColor : "transparent"
                    border.width: Math.max(1, Style.space(1))
                    border.color: active ? root.cfg.accentColor : Util.alpha(root.cfg.lineColor, 0.55)

                    Text {
                      anchors.centerIn: parent
                      text: sizeBtn.modelData.label
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      color: sizeBtn.active ? root.cfg.onAccent : root.cfg.lineColor
                    }
                  }
                }
              }

              Text {
                text: "Applies immediately."
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: root.cfg.soft(0.5)
              }
            }
            }

            // Overall look. Flow, not Row: six chips don't fit one line at this
            // card width, so they wrap to a second rather than overflow it.
            Column {
              visible: root.page === "look"
              width: parent.width
              spacing: Style.space(6)

              Text {
                text: "Appearance"
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                font.capitalization: Font.AllUppercase
                font.letterSpacing: Style.space(1.2)
                color: root.cfg.soft(0.6)
              }

              Flow {
                width: parent.width
                spacing: Style.space(6)
                Repeater {
                  model: root.appearanceOptions
                  delegate: Pressable {
                    id: appearanceBtn
                    required property var modelData
                    readonly property bool active: root.appearanceChoice === modelData.key
                    label: "Appearance: " + modelData.label
                    checkable: true
                    checked: active
                    ringColor: root.cfg.accentColor
                    ringWidth: Math.max(2, Style.space(2))
                    onActivated: root.setAppearance(modelData)
                    width: appearanceText.implicitWidth + Style.space(20)
                    height: Style.space(32)
                    radius: Style.space(2)
                    color: active ? root.cfg.accentColor : "transparent"
                    border.width: Math.max(1, Style.space(1))
                    border.color: active ? root.cfg.accentColor : Util.alpha(root.cfg.lineColor, 0.55)

                    Text {
                      id: appearanceText
                      anchors.centerIn: parent
                      text: appearanceBtn.modelData.label
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      color: appearanceBtn.active ? root.cfg.onAccent : root.cfg.lineColor
                    }
                  }
                }
              }

              Text {
                text: "Applies immediately."
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: root.cfg.soft(0.5)
              }
            }

            // Colour and drawing: the design layers (docs/DESIGN.md#design-layers). They recolour the
            // dial, every look and this window together.
            ChoiceRow {
              visible: root.page === "look"
              cfg: root.cfg
              title: "Colour"
              help: "Light is ink on vellum. Match desktop takes your Omarchy theme's colours and follows it when it changes."
              options: [ { key: "light", label: "Light" }, { key: "dark", label: "Dark" },
                         { key: "theme", label: "Match desktop" } ]
              current: root.cfgValue("color_scheme", "light")
              onPicked: key => root.setConfigKey("color_scheme", key)
            }
            ChoiceRow {
              visible: root.page === "look"
              cfg: root.cfg
              title: "Reference lines"
              help: "Construction lines and registration marks behind the drawing. The scale and rings stay: they carry information."
              options: [ { key: true, label: "On" }, { key: false, label: "Off" } ]
              current: root.cfgValue("reference_lines", true)
              onPicked: key => root.setConfigKey("reference_lines", key)
            }
            ChoiceRow {
              visible: root.page === "look"
              cfg: root.cfg
              title: "Design language"
              help: "How the overlay is drawn and moves. Languages others make appear here once they are in plugin/redial/languages/."
              options: root.languageOptions
              current: root.cfgValue("language", "classic")
              onPicked: key => root.setConfigKey("language", key)
            }

            // Style: swatches and presets. Controls the chosen look does not draw are greyed.
            Text {
              visible: root.page === "look"
              width: parent.width
              wrapMode: Text.WordWrap
              text: "Style. Swatches follow your theme: switch themes and the dial re-colours. Greyed out: not drawn by this appearance. Finer control is on the Every setting page."
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              color: root.cfg.soft(0.6)
            }
            Repeater {
              model: [ { title: "Accent colour", key: "colors.accent", role: "accent" },
                       { title: "Ink colour", key: "colors.line", role: "foreground" },
                       { title: "Ground colour", key: "colors.background", role: "background" } ]
              delegate: SwatchRow {
                required property var modelData
                visible: root.page === "look"
                enabled: root.drawn("colors")
                opacity: enabled ? 1 : 0.4
                cfg: root.cfg
                title: modelData.title
                key: modelData.key
                role: modelData.role
                specs: StylePresets.SWATCHES
                current: String(root.getPath(modelData.key) || "theme")
                onPicked: spec => spec === "theme" ? root.setPath(modelData.key, "", true)
                                                   : root.setPath(modelData.key, spec)
              }
            }
            ChoiceRow {
              visible: root.page === "look"
              enabled: root.drawn("backing")
              opacity: enabled ? 1 : 0.4
              cfg: root.cfg
              title: "Backing strength"
              options: StylePresets.BACKING
              current: root.cfgValue("plateOpacity", 0.96)
              onPicked: key => root.setConfigKey("plateOpacity", key)
            }
            ChoiceRow {
              visible: root.page === "look"
              enabled: root.drawn("weight")
              opacity: enabled ? 1 : 0.4
              cfg: root.cfg
              title: "Line weight"
              options: StylePresets.WEIGHT
              current: root.weightChoice
              onPicked: key => {
                for (var i = 0; i < StylePresets.WEIGHT.length; i++)
                  if (StylePresets.WEIGHT[i].key === key) root.setDial(StylePresets.WEIGHT[i].w)
              }
            }
            ChoiceRow {
              visible: root.page === "look"
              enabled: root.drawn("density")
              opacity: enabled ? 1 : 0.4
              cfg: root.cfg
              title: "Scale density"
              options: StylePresets.DENSITY
              current: root.dialValue("barCount", 180)
              onPicked: key => root.setDial({ barCount: key })
            }
            Column {
              visible: root.page === "look"
              width: parent.width
              spacing: Style.space(6)
              Text {
                text: "Elements"
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                font.capitalization: Font.AllUppercase
                font.letterSpacing: Style.space(1.2)
                color: root.cfg.soft(0.6)
              }
              Flow {
                width: parent.width
                spacing: Style.space(4)
                Repeater {
                  model: StylePresets.ELEMENTS
                  delegate: Pressable {
                    id: elem
                    required property var modelData
                    readonly property bool on: root.dialValue(modelData.key, modelData.fallback) === true
                    enabled: root.drawn(modelData.key)
                    opacity: enabled ? 1 : 0.4
                    label: modelData.label + (on ? ": on" : ": off")
                    checkable: true
                    checked: on
                    ringColor: root.cfg.accentColor
                    ringWidth: Math.max(2, Style.space(2))
                    onActivated: { var v = ({}); v[modelData.key] = !on; root.setDial(v) }
                    width: elemText.implicitWidth + Style.space(20)
                    height: Style.space(32)
                    radius: Style.space(2)
                    color: on ? root.cfg.accentColor : "transparent"
                    border.width: Math.max(1, Style.space(1))
                    border.color: on ? root.cfg.accentColor : Util.alpha(root.cfg.lineColor, 0.55)
                    Text {
                      id: elemText
                      anchors.centerIn: parent
                      text: elem.modelData.label
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      color: elem.on ? root.cfg.onAccent : root.cfg.lineColor
                    }
                  }
                }
              }
              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: "Construction lines, crosshair and registration marks need Reference lines on."
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: root.cfg.soft(0.5)
              }
            }

            // Every setting: the whole schema, grouped, filterable, each row with its key, its default
            // and a reset. Lists and objects are edited in config.json (one click away).
            Column {
              visible: root.page === "all"
              width: parent.width
              spacing: Style.space(12)

              Row {
                width: parent.width
                spacing: Style.space(8)
                TextField {
                  id: filterField
                  width: parent.width - openFile.width - Style.space(8)
                  height: Style.space(32)
                  placeholderText: "Find a setting"
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: root.cfg.lineColor
                  placeholderTextColor: root.cfg.soft(0.5)
                  background: Rectangle {
                    color: "transparent"
                    radius: Style.space(2)
                    border.width: filterField.activeFocus ? Math.max(2, Style.space(2)) : 1
                    border.color: filterField.activeFocus ? root.cfg.accentColor : Util.alpha(root.cfg.lineColor, 0.55)
                  }
                  onTextChanged: root.allFilter = text
                }
                Pressable {
                  id: openFile
                  label: "Open config.json in your editor"
                  ringColor: root.cfg.accentColor
                  ringWidth: Math.max(2, Style.space(2))
                  onActivated: root.openConfigFile()
                  width: openFileText.implicitWidth + Style.space(20)
                  height: Style.space(32)
                  radius: Style.space(2)
                  color: "transparent"
                  border.width: 1
                  border.color: Util.alpha(root.cfg.lineColor, 0.55)
                  Text {
                    id: openFileText
                    anchors.centerIn: parent
                    text: "config.json \u2197"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    color: root.cfg.lineColor
                  }
                }
              }

              Flow {
                width: parent.width
                spacing: Style.space(24)
                Repeater {
                  model: root.schemaGroups
                  delegate: Column {
                    id: groupCol
                    required property var modelData
                    readonly property var items: modelData.items.filter(function (it) { return root.rowMatches(it) })
                    visible: items.length > 0
                    width: root.wide ? (parent.width - Style.space(24)) / 2 : parent.width
                    spacing: Style.space(14)

                    Text {
                      text: groupCol.modelData.title
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      font.capitalization: Font.AllUppercase
                      font.letterSpacing: Style.space(1.2)
                      color: root.cfg.accentText
                    }
                    Rectangle { width: parent.width; height: 1; color: Util.alpha(root.cfg.lineColor, 0.3) }

                    Repeater {
                      model: groupCol.items
                      delegate: Column {
                        id: setRow
                        required property var modelData
                        readonly property var item: modelData
                        readonly property var saved: root.getPath(item.key)
                        readonly property var value: saved === undefined ? item["default"] : saved
                        width: parent.width
                        spacing: Style.space(4)

                        Item {
                          width: parent.width
                          height: Math.max(rowLabel.implicitHeight + rowKey.implicitHeight, resetBtn.height)
                          Text {
                            id: rowLabel
                            anchors.left: parent.left
                            width: parent.width - resetBtn.width - Style.space(8)
                            elide: Text.ElideRight
                            text: setRow.item.label
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                            color: root.cfg.lineColor
                          }
                          Text {
                            id: rowKey
                            anchors.top: rowLabel.bottom
                            width: rowLabel.width
                            elide: Text.ElideRight
                            text: setRow.item.key + "   default " + root.shown(setRow.item["default"])
                                  + (setRow.item.unit && typeof setRow.item["default"] === "number" ? " " + setRow.item.unit : "")
                            font.family: "monospace"
                            font.pixelSize: Math.round(Style.font.caption * 0.85)
                            color: root.cfg.soft(0.5)
                          }
                          Pressable {
                            id: resetBtn
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            visible: setRow.saved !== undefined && setRow.item.type !== "json"
                            label: "Reset " + setRow.item.label + " to its default"
                            ringColor: root.cfg.accentColor
                            ringWidth: Math.max(2, Style.space(2))
                            onActivated: root.setPath(setRow.item.key, undefined, true)
                            width: resetText.implicitWidth + Style.space(16)
                            height: Style.space(28)
                            radius: Style.space(2)
                            color: "transparent"
                            Text {
                              id: resetText
                              anchors.centerIn: parent
                              text: "Reset"
                              font.family: Style.font.family
                              font.pixelSize: Style.font.caption
                              color: resetBtn.hovered ? root.cfg.accentText : root.cfg.soft(0.6)
                            }
                          }
                        }

                        // choices, on/off and languages: one chip per option
                        Flow {
                          visible: setRow.item.type === "bool" || setRow.item.type === "choice" || setRow.item.type === "language"
                          width: parent.width
                          spacing: Style.space(4)
                          Repeater {
                            model: !parent.visible ? []
                                   : setRow.item.type === "bool" ? [ { key: true, label: "On" }, { key: false, label: "Off" } ]
                                   : setRow.item.type === "language" ? root.languageOptions : setRow.item.options
                            delegate: Pressable {
                              id: optChip
                              required property var modelData
                              readonly property bool active: setRow.value === modelData.key
                              label: setRow.item.label + ": " + modelData.label
                              checkable: true
                              checked: active
                              ringColor: root.cfg.accentColor
                              ringWidth: Math.max(2, Style.space(2))
                              onActivated: root.setPath(setRow.item.key, modelData.key)
                              width: Math.max(Style.space(52), optText.implicitWidth + Style.space(18))
                              height: Style.space(28)
                              radius: Style.space(2)
                              color: active ? root.cfg.accentColor : "transparent"
                              border.width: 1
                              border.color: active ? root.cfg.accentColor : Util.alpha(root.cfg.lineColor, 0.55)
                              Text {
                                id: optText
                                anchors.centerIn: parent
                                text: optChip.modelData.label
                                font.family: Style.font.family
                                font.pixelSize: Style.font.caption
                                color: optChip.active ? root.cfg.onAccent : root.cfg.lineColor
                              }
                            }
                          }
                        }

                        // numbers: step down, the value, step up (clamped to the range the dial accepts)
                        Row {
                          visible: setRow.item.type === "number"
                          spacing: Style.space(6)
                          Repeater {
                            model: [ -1, 0, 1 ]
                            delegate: Item {
                              id: numCell
                              required property int modelData
                              width: modelData === 0 ? Style.space(96) : Style.space(32)
                              height: Style.space(28)
                              Text {
                                anchors.centerIn: parent
                                visible: numCell.modelData === 0
                                text: root.shown(setRow.value) + (setRow.item.unit ? " " + setRow.item.unit : "")
                                font.family: "monospace"
                                font.pixelSize: Style.font.caption
                                color: setRow.saved !== undefined ? root.cfg.accentText : root.cfg.lineColor
                              }
                              Pressable {
                                anchors.fill: parent
                                visible: numCell.modelData !== 0
                                label: (numCell.modelData < 0 ? "Less " : "More ") + setRow.item.label
                                ringColor: root.cfg.accentColor
                                ringWidth: Math.max(2, Style.space(2))
                                onActivated: root.nudge(setRow.item, numCell.modelData)
                                radius: Style.space(2)
                                color: "transparent"
                                border.width: 1
                                border.color: Util.alpha(root.cfg.lineColor, 0.55)
                                Text {
                                  anchors.centerIn: parent
                                  text: numCell.modelData < 0 ? "\u2212" : "+"
                                  font.family: Style.font.family
                                  font.pixelSize: Style.font.body
                                  color: root.cfg.lineColor
                                }
                              }
                            }
                          }
                          Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: setRow.item.min + " to " + setRow.item.max
                            font.family: Style.font.family
                            font.pixelSize: Math.round(Style.font.caption * 0.85)
                            color: root.cfg.soft(0.45)
                          }
                        }

                        // click actions: the same grouped picker as the Feel page
                        ActionPicker {
                          visible: setRow.item.type === "click"
                          cfg: root.cfg
                          label: setRow.item.label
                          options: visible ? root.clickChoices(setRow.item) : []
                          current: visible ? root.clickChoice(setRow.item) : ({})
                          onPicked: name => root.setPath(setRow.item.key, name)
                        }

                        // colours: typed, checked before saving
                        TextField {
                          id: textCtl
                          visible: setRow.item.type === "text"
                          width: parent.width
                          height: Style.space(30)
                          text: visible ? String(setRow.value) : ""
                          font.family: "monospace"
                          font.pixelSize: Style.font.caption
                          color: root.cfg.lineColor
                          background: Rectangle {
                            color: "transparent"
                            radius: Style.space(2)
                            border.width: textCtl.activeFocus ? Math.max(2, Style.space(2)) : 1
                            border.color: textCtl.activeFocus ? root.cfg.accentColor
                                          : textCtl.acceptableInput ? Util.alpha(root.cfg.lineColor, 0.55) : root.cfg.accentColor
                          }
                          validator: RegularExpressionValidator { regularExpression: root.colourSpec }
                          onEditingFinished: if (acceptableInput && text !== String(setRow.value)) root.setPath(setRow.item.key, text)
                        }

                        // lists and objects: shown as they are, edited in the file
                        Text {
                          visible: setRow.item.type === "json"
                          width: parent.width
                          text: root.shown(setRow.value)
                          wrapMode: Text.WrapAnywhere
                          maximumLineCount: 3
                          elide: Text.ElideRight
                          font.family: "monospace"
                          font.pixelSize: Math.round(Style.font.caption * 0.85)
                          color: setRow.saved !== undefined ? root.cfg.lineColor : root.cfg.soft(0.5)
                        }

                        Text {
                          visible: !!setRow.item.help
                          width: parent.width
                          text: setRow.item.help || ""
                          wrapMode: Text.WordWrap
                          font.family: Style.font.family
                          font.pixelSize: Math.round(Style.font.caption * 0.9)
                          color: root.cfg.soft(0.55)
                        }
                      }
                    }
                  }
                }
              }
            }

            // Help: what the gestures do, in the words the settings use.
            Column {
              visible: root.page === "help"
              width: parent.width
              spacing: Style.space(10)

              Repeater {
                model: root.helpTopics
                delegate: Column {
                  required property var modelData
                  width: parent.width
                  spacing: Style.space(2)
                  Text {
                    text: modelData.title
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    color: root.cfg.accentText
                  }
                  Text {
                    width: parent.width
                    text: modelData.body
                    wrapMode: Text.WordWrap
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    color: root.cfg.soft(0.85)
                  }
                }
              }
            }

            // Feel: how far you turn, how long things take, and the return-to-Volume behaviour.
            ChoiceRow {
              visible: root.page === "feel"
              cfg: root.cfg
              title: "Sensitivity"
              help: "How much you turn for each step. Higher means less turning."
              options: [ { key: 0.6, label: "Low" }, { key: 1, label: "Normal" },
                         { key: 1.5, label: "High" }, { key: 2, label: "Very high" } ]
              current: root.cfgValue("sensitivity", 1)
              onPicked: key => root.setConfigKey("sensitivity", key)
            }
            ChoiceRow {
              visible: root.page === "feel"
              cfg: root.cfg
              title: "Return to Volume after"
              unit: " s"
              help: "How long a tool stays armed after you stop turning. Zoom always returns after 10 s, because it holds Ctrl."
              options: [ { key: 6, label: "6 s" }, { key: 15, label: "15 s" },
                         { key: 30, label: "30 s" }, { key: 60, label: "60 s" } ]
              current: root.cfgValue("auto_return_s", 6)
              onPicked: key => root.setConfigKey("auto_return_s", key)
            }
            ChoiceRow {
              visible: root.page === "feel"
              cfg: root.cfg
              title: "On-screen display"
              help: "Shows the volume, brightness or tool name on screen as you turn. Handy when you are learning the dial, and for movies; turn it off for a cleaner screen."
              options: [ { key: true, label: "On" }, { key: false, label: "Off" } ]
              current: root.cfgValue("osd", true)
              onPicked: key => root.setConfigKey("osd", key)
            }
            ChoiceRow {
              visible: root.page === "feel"
              cfg: root.cfg
              title: "Hints while you learn"
              help: "Now and then shows a short line about the next thing the dial can do, when what you are doing suggests you are ready. Needs the on-screen display."
              options: [ { key: true, label: "On" }, { key: false, label: "Off" } ]
              current: root.cfgValue("guide", true)
              onPicked: key => root.setConfigKey("guide", key)
            }
            ChoiceRow {
              visible: root.page === "feel"
              cfg: root.cfg
              title: "How hints teach"
              help: "Adaptive shows each hint when what you do says you are ready. Discover says almost nothing: a hint to press and one to hold, and tool tips as you try each tool. Guided is a short tour on connect, one gesture at a time. Only applies while hints are on."
              options: [ { key: "adaptive", label: "Adaptive" }, { key: "discover", label: "Discover" },
                         { key: "guided", label: "Guided tour" } ]
              current: root.cfgValue("onboarding_mode", "adaptive")
              onPicked: key => root.setConfigKey("onboarding_mode", key)
            }
            ChoiceRow {
              visible: root.page === "feel"
              cfg: root.cfg
              title: "Buzz when returning to Volume"
              help: "A short buzz when a tool drops back to Volume."
              options: [ { key: true, label: "On" }, { key: false, label: "Off" } ]
              current: root.cfgValue("return_buzz", true)
              onPicked: key => root.setConfigKey("return_buzz", key)
            }
            ChoiceRow {
              visible: root.page === "feel"
              cfg: root.cfg
              title: "Double-click speed"
              unit: " ms"
              help: "How long a second press can take and still count as a double click."
              options: [ { key: 200, label: "Quick" }, { key: 250, label: "Normal" },
                         { key: 400, label: "Relaxed" }, { key: 600, label: "Slow" } ]
              current: root.cfgValue("double_click_ms", 250)
              onPicked: key => root.setConfigKey("double_click_ms", key)
            }
            ChoiceRow {
              visible: root.page === "feel"
              cfg: root.cfg
              title: "Hold to open the tool menu"
              unit: " ms"
              help: "How long to hold the button before the menu opens."
              options: [ { key: 250, label: "Quick" }, { key: 400, label: "Normal" },
                         { key: 700, label: "Relaxed" }, { key: 1000, label: "Slow" } ]
              current: root.cfgValue("hold_ms", 400)
              onPicked: key => root.setConfigKey("hold_ms", key)
            }
            ChoiceRow {
              visible: root.page === "feel"
              cfg: root.cfg
              title: "Speak the tool name"
              help: "Says the tool aloud as you arm it or move through the menu. Needs speech-dispatcher (spd-say) or espeak-ng installed."
              options: [ { key: false, label: "Off" }, { key: true, label: "On" } ]
              current: root.cfgValue("announce_tool", false)
              onPicked: key => root.setConfigKey("announce_tool", key)
            }
            ChoiceRow {
              visible: root.page === "feel"
              cfg: root.cfg
              title: "Reduce motion"
              help: "Turns off sliding, scaling and fading on the dial display: everything changes instantly."
              options: [ { key: false, label: "Off" }, { key: true, label: "On" } ]
              current: root.cfgValue("reduce_motion", false)
              onPicked: key => root.setConfigKey("reduce_motion", key)
            }
            ChoiceRow {
              visible: root.page === "feel"
              cfg: root.cfg
              title: "Ignore small turns"
              unit: " counts"
              help: "Ignores a bump or a tremor: after a pause, the dial has to turn this far before anything happens. Higher ignores more."
              options: [ { key: 0, label: "Off" }, { key: 12, label: "Light" },
                         { key: 30, label: "Medium" }, { key: 60, label: "Strong" } ]
              current: root.cfgValue("deadzone", 0)
              onPicked: key => root.setConfigKey("deadzone", key)
            }
            ChoiceRow {
              visible: root.page === "feel"
              cfg: root.cfg
              title: "Tool menu"
              help: "Hold: hold the button, turn, let go to choose. Tap: hold until it opens, let go, then turn and click to choose, with no need to hold while turning."
              options: [ { key: false, label: "Hold" }, { key: true, label: "Tap" } ]
              current: root.cfgValue("menu_latch", false)
              onPicked: key => root.setConfigKey("menu_latch", key)
            }
            SliderRow {
              visible: root.page === "feel" && root.cfgValue("menu_latch", false) === true
              cfg: root.cfg
              title: "Tap menu closes after"
              help: "How long an untouched tap-menu waits before closing without changing anything."
              from: 3000
              to: 12000
              stepSize: 500
              current: root.cfgValue("menu_timeout_ms", 8000)
              format: v => (v / 1000).toFixed(1) + " s"
              onPicked: value => root.setConfigKey("menu_timeout_ms", value)
            }
            ChoiceRow {
              visible: root.page === "feel"
              cfg: root.cfg
              title: "Keep the dial awake"
              help: "The dial sleeps after at most 5 minutes untouched, and only a press wakes it. On keeps it awake while you are using this computer, for an always-there feel: for a while after you last touched it, and never while the screen is locked. Uses more battery."
              options: [ { key: false, label: "Off" }, { key: true, label: "On" } ]
              current: root.cfgValue("keep_awake", false)
              onPicked: key => root.setConfigKey("keep_awake", key)
            }
            SliderRow {
              visible: root.page === "feel" && root.cfgValue("keep_awake", false) === true
              cfg: root.cfg
              title: "Stay awake after last use"
              help: "How long after you last touched the dial it is kept awake. After that it sleeps on its own, and a press wakes it."
              from: 5
              to: 240
              stepSize: 5
              current: root.cfgValue("keep_awake_minutes", 30)
              format: v => v + " min"
              onPicked: value => root.setConfigKey("keep_awake_minutes", value)
            }

            // What a single / double / triple click does with any tool (unless the tool has its own,
            // below). Each picker shows its place in the list and opens all of them, grouped.
            Column {
              visible: root.page === "feel"
              width: parent.width
              spacing: Style.space(6)

              Text {
                text: "Clicks for every tool"
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                font.capitalization: Font.AllUppercase
                font.letterSpacing: Style.space(1.2)
                color: root.cfg.soft(0.6)
              }

              Repeater {
                model: root.clickKinds
                delegate: ActionPicker {
                  required property var modelData
                  cfg: root.cfg
                  title: modelData.title
                  label: modelData.title
                  options: root.clickOptions("dial", modelData.key)
                  current: root.clickAction("dial", modelData.key)
                  onPicked: name => root.setClick("dial", modelData.key, name)
                }
              }

              Text {
                text: "Applies on the next click. A double click waits briefly for a possible triple; set Triple to Nothing to make it instant."
                width: parent.width
                wrapMode: Text.WordWrap
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: root.cfg.soft(0.5)
              }
            }

            // Clicks for one tool: the same three clicks, but only while that tool is armed. Pointer
            // comes with its own (click left, double flip, triple right); any tool can have them.
            Column {
              visible: root.page === "feel" && root.clickToolShown !== ""
              width: parent.width
              spacing: Style.space(6)

              ChoiceRow {
                cfg: root.cfg
                title: "Clicks for one tool"
                help: "While this tool is armed its clicks do these instead. Default is the tool's own, else the clicks above."
                options: root.selected.map(function (n) { return { key: n, label: n } })
                current: root.clickToolShown
                onPicked: key => root.clickTool = key
              }
              Repeater {
                model: root.clickKinds
                delegate: ActionPicker {
                  required property var modelData
                  cfg: root.cfg
                  title: modelData.title
                  label: root.clickToolShown + ", " + modelData.title
                  options: root.toolClickOptions(root.clickToolShown, modelData.key)
                  current: root.toolClickCurrent(root.clickToolShown, modelData.key)
                  onPicked: name => root.setToolClick(root.clickToolShown, modelData.key, name)
                }
              }
            }

            // Surface Pen: enable switch, tail-button chips (same picker as the
            // dial's Clicks above, group "pentail"), and the barrel button's own
            // enable toggle + single action chip. No daemon restart needed --
            // both buttons re-read config.json live, same as the dial's clicks.
            Column {
              visible: root.page === "pen"
              width: parent.width
              spacing: Style.space(6)

              Row {
                width: parent.width
                spacing: Style.space(8)
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Pen"
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.capitalization: Font.AllUppercase
                  font.letterSpacing: Style.space(1.2)
                  color: root.cfg.soft(0.6)
                }
                Pressable {
                  id: penEnableBtn
                  label: "Pen support"
                  checkable: true
                  checked: root.penEnabled
                  ringColor: root.cfg.accentColor
                  ringWidth: Math.max(2, Style.space(2))
                  onActivated: root.setPenEnabled(!root.penEnabled)
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(56); height: Style.space(32)
                  radius: height / 2
                  color: root.penEnabled ? root.cfg.accentColor : Util.alpha(root.cfg.lineColor, 0.12)
                  border.width: Math.max(1, Style.space(1))
                  border.color: root.penEnabled ? root.cfg.accentColor : Util.alpha(root.cfg.lineColor, 0.3)
                  Text {
                    anchors.centerIn: parent
                    text: root.penEnabled ? "On" : "Off"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    color: root.penEnabled ? root.cfg.onAccent : root.cfg.lineColor
                  }
                }
              }

              Column {
                width: parent.width
                spacing: Style.space(2)
                visible: root.penEnabled
                opacity: root.penEnabled ? 1 : 0.4

                Text {
                  text: "Away from screen: tail button"
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: root.cfg.soft(0.5)
                }

                Component {
                  id: penRowDelegate
                  ActionPicker {
                    required property var modelData
                    cfg: root.cfg
                    title: modelData.title
                    label: (modelData.group === "eraser" ? "Pen eraser, " : "Pen tail button, ") + modelData.title
                    options: root.clickOptions(modelData.group, modelData.key)
                    current: root.clickAction(modelData.group, modelData.key)
                    onPicked: name => root.setClick(modelData.group, modelData.key, name)
                  }
                }

                Repeater {
                  model: root.tailKinds
                  delegate: penRowDelegate
                }

                Item { width: 1; height: Style.space(4) }

                Text {
                  text: "On screen, hover: barrel button"
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: root.cfg.soft(0.5)
                }

                Row {
                  width: parent.width
                  spacing: Style.space(8)

                  Pressable {
                    id: barrelEnableBtn
                    label: "Pen barrel button"
                    checkable: true
                    checked: root.barrelEnabled
                    ringColor: root.cfg.accentColor
                    ringWidth: Math.max(2, Style.space(2))
                    onActivated: root.setBarrelEnabled(!root.barrelEnabled)
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(56); height: Style.space(32)
                    radius: height / 2
                    color: root.barrelEnabled ? root.cfg.accentColor : Util.alpha(root.cfg.lineColor, 0.12)
                    border.width: Math.max(1, Style.space(1))
                    border.color: root.barrelEnabled ? root.cfg.accentColor : Util.alpha(root.cfg.lineColor, 0.3)
                    Text {
                      anchors.centerIn: parent
                      text: root.barrelEnabled ? "On" : "Off"
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      color: root.barrelEnabled ? root.cfg.onAccent : root.cfg.lineColor
                    }
                  }

                }

                ActionPicker {
                  cfg: root.cfg
                  title: "Press"
                  label: "Pen barrel button"
                  enabled: root.barrelEnabled
                  opacity: root.barrelEnabled ? 1 : 0.4
                  options: root.penBarrelActions
                  current: root.barrelAction()
                  onPicked: name => root.setBarrelAction(name)
                }
              }

              Column {
                width: parent.width
                spacing: Style.space(2)
                visible: root.penEnabled
                opacity: root.penEnabled ? 1 : 0.4

                Text {
                  text: "On screen, in contact: eraser (the back of the pen)"
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: root.cfg.soft(0.5)
                }
                Repeater {
                  model: root.eraserKinds
                  delegate: penRowDelegate
                }
                ChoiceRow {
                  cfg: root.cfg
                  title: "Ignore light touches"
                  unit: " ms"
                  help: "A touch shorter than this is a brush, not a tap. Raise it if scrolling with the eraser sometimes presses Escape; Off counts every touch."
                  options: [ { key: 0, label: "Off" }, { key: 100, label: "100 ms" },
                             { key: 200, label: "200 ms" }, { key: 300, label: "300 ms" } ]
                  current: (root.configDoc && root.configDoc.pen && typeof root.configDoc.pen.eraser_tap_min_ms === "number")
                           ? root.configDoc.pen.eraser_tap_min_ms : 100
                  onPicked: key => root.writePen(function (pen) { pen.eraser_tap_min_ms = key })
                }
                ChoiceRow {
                  cfg: root.cfg
                  title: "Eraser scroll speed"
                  help: "How far a page moves per stroke of the eraser. Each app keeps its own base speed; this scales all of them."
                  options: [ { key: 0.5, label: "Slow" }, { key: 1, label: "Normal" },
                             { key: 2, label: "Fast" }, { key: 3, label: "Faster" } ]
                  current: (root.configDoc && root.configDoc.pen && typeof root.configDoc.pen.eraser_scroll_speed === "number")
                           ? root.configDoc.pen.eraser_scroll_speed : 1
                  onPicked: key => root.writePen(function (pen) { pen.eraser_scroll_speed = key })
                }
              }

              Text {
                text: "The buttons and the eraser apply immediately, no daemon restart needed."
                width: parent.width
                wrapMode: Text.WordWrap
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: root.cfg.soft(0.5)
              }
            }
          }

          Column {
            id: ringSide
            visible: root.page === "look"
            width: body.sideBySide ? Math.min(Math.round(body.width * 0.42), Style.space(520)) : body.width
            spacing: col.spacing

            // Active tools on a ring, in the same order as the real dial face; drag to reorder. Center
            // is empty on purpose (the dial's click zone). Reordering commits on release, not live: a
            // Repeater over a plain JS array has no stable delegate identity, so a live swap would
            // destroy the delegate being dragged. See docs/DESIGN.md#settings-window.
            Item {
              visible: root.page === "look"
              id: ring
              width: parent.width
              height: body.sideBySide ? Math.min(width, Style.space(420)) : Style.space(230)

              readonly property real cx: width / 2
              readonly property real cy: height / 2
              readonly property real radius: Math.min(width, height) / 2 - Style.space(26)
              readonly property int chipSize: Style.space(44)
              readonly property int count: root.selected.length

              function angleFor(i) {
                return -Math.PI / 2 + (2 * Math.PI * i / Math.max(1, count))
              }
              function slotPos(i) {
                var a = angleFor(i)
                return {
                  x: cx + radius * Math.cos(a) - chipSize / 2,
                  y: cy + radius * Math.sin(a) - chipSize / 2
                }
              }
              // Angle (from a center-relative point) back to a slot index --
              // the inverse of slotPos, used to figure out where a drag landed.
              function slotAt(px, py) {
                var a = Math.atan2(py - cy, px - cx)
                var norm = (a + Math.PI / 2) / (2 * Math.PI)
                norm = norm - Math.floor(norm)
                return Math.round(norm * count) % count
              }

              Rectangle {
                anchors.centerIn: parent
                width: ring.radius * 2; height: width
                radius: width / 2
                color: "transparent"
                border.width: 1
                border.color: Util.alpha(root.cfg.lineColor, 0.15)
              }
              Text {
                anchors.centerIn: parent
                text: "click"
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: root.cfg.soft(0.55)
              }

              Repeater {
                id: ringRepeater
                model: root.selected
                delegate: Rectangle {
                  id: chip
                  required property int index
                  required property string modelData
                  readonly property var meta: root.manifestByName(modelData)

                  // Keyboard: Left/Up and Right/Down move this tool round the ring, Delete takes
                  // it off. The same things the drag and the badge do with a pointer.
                  activeFocusOnTab: true
                  Accessible.role: Accessible.ListItem
                  Accessible.name: modelData + ", position " + (index + 1) + " of " + root.selected.length
                  Accessible.focusable: true
                  Component.onCompleted: if (root.ringFocus === modelData) chip.forceActiveFocus()
                  onActiveFocusChanged: if (activeFocus) root.tipEnter(chip, modelData, true); else root.tipLeave(chip)
                  Accessible.description: root.toolDescription(modelData) + " Left and Right move it round the ring. Delete removes it."
                  Keys.onPressed: event => {
                    var step = 0
                    if (event.key === Qt.Key_Left || event.key === Qt.Key_Up) step = -1
                    else if (event.key === Qt.Key_Right || event.key === Qt.Key_Down) step = 1
                    if (step !== 0) {
                      event.accepted = true
                      root.ringFocus = modelData
                      root.moveTo(modelData, index + step)
                    } else if (event.key === Qt.Key_Delete || event.key === Qt.Key_Backspace) {
                      event.accepted = true
                      root.ringFocus = ""
                      root.toggleTool(modelData)
                      root.forceActiveFocus()
                    }
                  }
                  Rectangle {
                    anchors.fill: parent
                    anchors.margins: -Math.max(2, Style.space(3))
                    radius: width / 2
                    color: "transparent"
                    border.width: Math.max(2, Style.space(2))
                    border.color: root.cfg.accentColor
                    visible: chip.activeFocus
                  }
                  readonly property var slot: ring.slotPos(index)
                  property real dragDX: 0
                  property real dragDY: 0

                  width: ring.chipSize; height: width
                  radius: width / 2
                  x: slot.x + (dragArea.pressed ? dragDX : 0)
                  y: slot.y + (dragArea.pressed ? dragDY : 0)
                  z: dragArea.pressed ? 10 : 1
                  color: Util.alpha(root.cfg.accentColor, dragArea.pressed ? 0.30 : 0.16)
                  border.width: Math.max(1, Style.space(1))
                  border.color: root.cfg.accentColor
                  Behavior on x { enabled: !dragArea.pressed; NumberAnimation { duration: cfg.motionBase; easing.type: Easing.OutCubic } }
                  Behavior on y { enabled: !dragArea.pressed; NumberAnimation { duration: cfg.motionBase; easing.type: Easing.OutCubic } }

                  Text {
                    anchors.centerIn: parent
                    text: chip.meta ? chip.meta.icon : "?"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    color: root.cfg.accentColor
                  }

                  // Small remove badge -- unchecking from here, not the ring
                  // drag gesture, which is reorder-only.
                  Rectangle {
                    width: Style.space(16); height: width
                    radius: width / 2
                    anchors.top: parent.top
                    anchors.right: parent.right
                    anchors.topMargin: -Style.space(4)
                    anchors.rightMargin: -Style.space(4)
                    color: root.cfg.backgroundColor
                    border.width: 1
                    border.color: Util.alpha(root.cfg.lineColor, 0.4)
                    z: 2  // above the drag area, so the whole badge takes the click
                    visible: !dragArea.pressed
                    Text {
                      anchors.centerIn: parent
                      text: "×"
                      font.pixelSize: Style.space(10)
                      color: root.cfg.soft(0.7)
                    }
                    MouseArea {
                      anchors.fill: parent
                      anchors.margins: -Style.space(8)  // a 32 px target around the 16 px badge
                      onClicked: root.toggleTool(chip.modelData)
                    }
                  }

                  MouseArea {
                    id: dragArea
                    anchors.fill: parent
                    hoverEnabled: true
                    onContainsMouseChanged: {
                      if (containsMouse && !pressed) root.tipEnter(chip, chip.modelData, false)
                      else root.tipLeave(chip)
                    }
                    onPressedChanged: if (pressed) root.tipLeave(chip)
                    property real startMouseX: 0
                    property real startMouseY: 0
                    onPressed: (mouse) => {
                      var p = mapToItem(ring, mouse.x, mouse.y)
                      startMouseX = p.x
                      startMouseY = p.y
                      chip.dragDX = 0
                      chip.dragDY = 0
                    }
                    onPositionChanged: (mouse) => {
                      if (!pressed) return
                      var p = mapToItem(ring, mouse.x, mouse.y)
                      chip.dragDX = p.x - startMouseX
                      chip.dragDY = p.y - startMouseY
                    }
                    onReleased: {
                      var centerX = chip.slot.x + ring.chipSize / 2 + chip.dragDX
                      var centerY = chip.slot.y + ring.chipSize / 2 + chip.dragDY
                      var target = ring.slotAt(centerX, centerY)
                      chip.dragDX = 0
                      chip.dragDY = 0
                      if (target !== chip.index) root.moveTo(chip.modelData, target)
                    }
                  }
                }
              }
            }

            // Inactive tools, tap to add to the end of the ring.
            Flow {
              visible: root.page === "look"
              width: parent.width
              spacing: Style.space(6)
              Repeater {
                model: root.rows.filter(function (r) { return !r.checked })
                delegate: Pressable {
                  id: addChip
                  required property var modelData
                  label: "Add " + modelData.name + " to the ring"
                  Accessible.description: root.toolDescription(modelData.name)
                  onHoveredChanged: if (hovered) root.tipEnter(addChip, modelData.name, false); else root.tipLeave(addChip)
                  onActiveFocusChanged: if (activeFocus) root.tipEnter(addChip, modelData.name, true); else root.tipLeave(addChip)
                  ringColor: root.cfg.accentColor
                  ringWidth: Math.max(2, Style.space(2))
                  onActivated: { root.toggleTool(modelData.name); root.forceActiveFocus() }
                  width: chipRow.implicitWidth + Style.space(16)
                  height: Style.space(32)
                  radius: height / 2
                  color: "transparent"
                  border.width: 1
                  border.color: Util.alpha(root.cfg.lineColor, 0.55)

                  Row {
                    id: chipRow
                    anchors.centerIn: parent
                    spacing: Style.space(6)
                    Text {
                      text: modelData.icon || ""
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      color: root.cfg.lineColor
                    }
                    Text {
                      text: modelData.name
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      color: root.cfg.soft(0.8)
                    }
                  }
                }
              }
            }
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(10)
          layoutDirection: Qt.RightToLeft

          Pressable {
            label: "Close settings"
            ringColor: root.cfg.accentColor
            ringWidth: Math.max(2, Style.space(2))
            onActivated: root.closeRequested()
            width: Style.space(80); height: Style.space(32)
            radius: Style.space(2)
            color: "transparent"
            Text {
              anchors.centerIn: parent
              text: "Close"
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              color: root.cfg.lineColor
            }
          }
          // The title block, as on the dial's own plate: which sheet of the settings this is.
          Text {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - Style.space(190)
            elide: Text.ElideRight
            text: root.page === "pen" ? "PEN"
                  : "SHEET " + root.pageNumber() + "/" + root.pages.length + "   " + root.pages[root.pageNumber() - 1].label.toUpperCase()
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.letterSpacing: Style.space(1.2)
            color: root.cfg.soft(0.55)
          }
        }
      }
      }

      // More above or below: the content fades into the edge, cut through the next row, with a
      // marker at the bottom. Drawn over the content; they take no input.
      Rectangle {
        anchors { left: parent.left; right: parent.right; top: parent.top }
        height: Style.space(28)
        visible: scroller.contentY > 1
        gradient: Gradient {
          GradientStop { position: 0; color: card.color }
          GradientStop { position: 1; color: Qt.rgba(card.color.r, card.color.g, card.color.b, 0) }
        }
      }
      Rectangle {
        id: moreBelow
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: Style.space(56)
        visible: scroller.contentY + scroller.height < scroller.contentHeight - 1
        gradient: Gradient {
          GradientStop { position: 0; color: Qt.rgba(card.color.r, card.color.g, card.color.b, 0) }
          GradientStop { position: 0.75; color: card.color }
        }
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          anchors.bottomMargin: Style.space(6)
          text: "MORE BELOW  \u25be"
          font.family: Style.font.family
          font.pixelSize: Math.round(Style.font.caption * 0.85)
          font.letterSpacing: Style.space(1.2)
          color: root.cfg.soft(0.5)
        }
      }

      // The shared tooltip. Lives in the card, above the scrolling content, so it is never clipped
      // by it; placed above the tool if there is room, below it otherwise.
      Rectangle {
        id: tip
        visible: root.tipItem !== null && root.tipBody !== ""
        z: 100
        readonly property point at: root.tipItem ? root.tipItem.mapToItem(card, 0, 0) : Qt.point(0, 0)
        width: Math.min(Style.space(260), card.width - Style.space(24))
        height: tipCol.implicitHeight + Style.space(16)
        x: Math.max(Style.space(12), Math.min(card.width - width - Style.space(12),
                                                 at.x + (root.tipItem ? root.tipItem.width / 2 : 0) - width / 2))
        y: at.y - height - Style.space(8) >= Style.space(8)
           ? at.y - height - Style.space(8)
           : at.y + (root.tipItem ? root.tipItem.height : 0) + Style.space(8)
        radius: Style.space(2)
        color: root.cfg.tint(0.1)
        border.width: Math.max(1, Style.space(1))
        border.color: root.cfg.accentColor

        Column {
          id: tipCol
          anchors.fill: parent
          anchors.margins: Style.space(8)
          spacing: Style.space(3)
          Text {
            width: parent.width
            text: root.tipTitle
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
            color: root.cfg.accentText
          }
          Text {
            width: parent.width
            text: root.tipBody
            wrapMode: Text.WordWrap
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: root.cfg.lineColor
          }
        }
      }
    }
}
