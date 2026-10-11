import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "ConfigText.js" as ConfigText

// Pick and reorder which of the daemon's tools are active, and where the overlay sits.
//
// A settings screen: real mouse input, no rotation socket; it only reads and writes files in
// ~/.config/dial-radial/:
//   tools.json   - written by the daemon at startup: [{name, icon}] for every tool it can
//                  build, so a tool added to TOOL_LIBRARY just shows up here.
//   status.json  - written by the daemon every few seconds ({state, battery, updated, ...});
//                  shown as the status line under the title.
//   config.json  - the shared config. Keys this panel doesn't own are read whole and
//                  written back untouched.
//
// Position, size, appearance, clicks and pen apply immediately. Tool changes are staged and
// written on Save; the daemon then reloads them while the dial is idle, so no restart either way.
Item {
  id: root
  required property var cfg

  // Window lifecycle is owned by the embedder (DialMenu.qml); this signal is all it needs.
  signal closeRequested()
  // Peek at the live overlay. There's no in-window way back (the live tab is click-through by
  // design); return via the same hotkey/bar widget. Deliberate.
  signal liveRequested()
  property var manifest: []     // [{name, icon}], in TOOL_LIBRARY order
  property var configDoc: ({})  // full parsed config.json, kept intact
  property var selected: []     // ordered active_tools names
  property bool dirty: false
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

  // The window takes keyboard focus when it opens (see DialMenu.qml), Escape closes it, and Tab
  // walks every control in reading order.
  focus: true
  Keys.onEscapePressed: root.closeRequested()
  onVisibleChanged: if (visible) root.forceActiveFocus()
  property bool everLoadedManifest: false
  property bool everLoadedConfig: false

  readonly property string dir:
    (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/dial-radial"
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
  // (sensitivity, timings, clicks, pen). Everything on "feel" applies immediately.
  property string page: "look"

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
    { title: "Keyboard", body: "Tab moves between controls, Enter or Space presses one, Shift+Enter goes back through a list of choices, Escape closes this window." },
    { title: "About", body: "Surface Dial " + (status.version || "(unknown version)") + ", beta. Please mention this number when you report a problem." },
    { title: "Something wrong?", body: "The line under the title says whether the dial is connected. If it says the service is not running, press Restart dial service. If that does not help, run surface-dial-setup in a terminal; it checks everything and says what to fix." }
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
          radius: Style.space(6)
          color: active ? choiceRow.cfg.accentColor : Util.alpha(choiceRow.cfg.lineColor, 0.08)
          border.width: Math.max(1, Style.space(1.5))
          border.color: active ? choiceRow.cfg.accentColor : Util.alpha(choiceRow.cfg.lineColor, 0.25)

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

  // One picker across all seven overlay options, though four are a "face" and three a "layout".
  // Writes both keys together so neither is left stale.
  readonly property var appearanceOptions: [
    { key: "classic",  label: "Classic",       layout: "dial",     face: "classic" },
    { key: "capsule",  label: "Capsule",       layout: "dial",     face: "capsule" },
    { key: "pie",      label: "Pie Wheel",     layout: "dial",     face: "pie" },
    { key: "gauge",    label: "Gauge",         layout: "dial",     face: "gauge" },
    { key: "carousel", label: "Carousel",      layout: "carousel", face: "" },
    { key: "toast",    label: "Minimal Toast", layout: "toast",    face: "" },
    { key: "omarchy",  label: "Omarchy",       layout: "omarchy",  face: "" }
  ]
  readonly property string appearanceChoice: {
    var l = (configDoc && configDoc.layout) ? String(configDoc.layout) : "dial"
    var f = (configDoc && configDoc.face) ? String(configDoc.face) : "classic"
    if (l !== "dial") return (l === "carousel" || l === "toast" || l === "omarchy") ? l : "classic"
    return (f === "pie" || f === "gauge" || f === "capsule") ? f : "classic"
  }
  function setAppearance(opt) {
    writeConfig(function (o) {
      o.layout = opt.layout
      if (opt.face) o.face = opt.face
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
  function cycleClick(group, kind, step) {
    var opts = clickOptions(group, kind)
    if (!opts.length) return
    var cur = clickAction(group, kind).name, at = 0
    for (var i = 0; i < opts.length; i++) if (opts[i].name === cur) at = i
    setClick(group, kind, opts[(at + step + opts.length) % opts.length].name)
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
  function cycleBarrelAction(step) {
    if (!penBarrelActions.length) return
    var cur = barrelAction().name, at = 0
    for (var i = 0; i < penBarrelActions.length; i++) if (penBarrelActions[i].name === cur) at = i
    setBarrelAction(penBarrelActions[(at + step + penBarrelActions.length) % penBarrelActions.length].name)
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
    dirty = true
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
    dirty = true
  }

  function applyConfigText(raw) {
    var r = ConfigText.parse(raw)
    if (!r.ok) {
      console.warn("[dial.radial] config.json cannot be read; keeping the last good copy and pausing writes")
      configBroken = true
      return
    }
    configBroken = false
    configDoc = r.doc
    // Unsaved tool edits survive a reload: every setting on the other pages rewrites the file, and
    // the watcher's reload used to reset the list under the person's hands.
    if (dirty) return
    var act = r.doc.active_tools
    selected = (Array.isArray(act) && act.length) ? act.slice()
                                                   : manifest.map(function (m) { return m.name })
  }

  function save() {
    if (writeConfig(function (o) { o.active_tools = selected })) dirty = false
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
  // "Restart dial service": runs bin/surface-dial-restart (installed beside the daemon).
  Process {
    id: restartProc
    command: [Quickshell.env("HOME") + "/.local/bin/surface-dial-restart"]
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
      anchors.centerIn: parent
      width: Style.space(420)
      height: Math.min(col.implicitHeight + Style.space(40), root.height - Style.space(48))
      radius: Style.cornerRadius
      // Forced fully opaque (alpha=1): the theme background can carry its own alpha. A settings
      // dialog must be fully legible, so this ignores plateOpacity.
      color: Qt.rgba(root.cfg.backgroundColor.r, root.cfg.backgroundColor.g,
                     root.cfg.backgroundColor.b, 1.0)
      border.width: Math.max(1, Style.space(2))
      border.color: Util.alpha(root.cfg.lineColor, 0.30)

      // Eat clicks so they don't fall through to the dismiss MouseArea behind.
      MouseArea { anchors.fill: parent; onClicked: {} }

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
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: Style.space(20)
        spacing: Style.space(9)

        Item {
          width: parent.width
          height: Math.max(titleText.implicitHeight, liveTab.height)

          Text {
            id: titleText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "Surface Dial"
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
            color: root.cfg.lineColor
          }
          // Peek at the live tool-rail/radial overlay in the same window --
          // one-way (see liveRequested above); a stray click here is cheap,
          // the hotkey brings you right back to this same Settings tab.
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
            radius: Style.space(6)
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
          radius: Style.space(6)
          color: Util.alpha(root.cfg.lineColor, restartProc.running ? 0.04 : 0.1)
          border.width: Math.max(1, Style.space(1.5))
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
          radius: Style.space(8)
          color: Util.alpha(root.cfg.accentColor, 0.12)
          border.width: Math.max(1, Style.space(1.5))
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
          radius: Style.space(8)
          color: Util.alpha(root.cfg.accentColor, 0.12)
          border.width: Math.max(1, Style.space(1.5))
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
                radius: Style.space(6)
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
                radius: Style.space(6)
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
        Row {
          spacing: Style.space(18)
          Repeater {
            model: [ { key: "look", label: "Look" }, { key: "feel", label: "Feel" }, { key: "help", label: "Help" } ]
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
              radius: Style.space(6)
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
            }
          }
        }

        Text {
          width: parent.width
          text: root.page === "look"
                ? "Drag the ring to reorder, or focus a tool and press Left or Right. Click \u2715 (or press Delete) to remove a tool, or a chip below to add one. Tool changes apply when you press Save; everything else applies immediately."
                : root.page === "feel"
                  ? "How the dial feels to use. Everything on this page applies immediately."
                  : "How to use the dial. Nothing here changes any setting."
          wrapMode: Text.WordWrap
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          color: root.cfg.soft(0.6)
        }

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
                    radius: Style.space(6)
                    color: active ? root.cfg.accentColor : Util.alpha(root.cfg.lineColor, 0.08)
                    border.width: Math.max(1, Style.space(1.5))
                    border.color: active ? root.cfg.accentColor : Util.alpha(root.cfg.lineColor, 0.25)

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
                radius: Style.space(6)
                color: active ? root.cfg.accentColor : Util.alpha(root.cfg.lineColor, 0.08)
                border.width: Math.max(1, Style.space(1.5))
                border.color: active ? root.cfg.accentColor : Util.alpha(root.cfg.lineColor, 0.25)

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
                radius: Style.space(6)
                color: active ? root.cfg.accentColor : Util.alpha(root.cfg.lineColor, 0.08)
                border.width: Math.max(1, Style.space(1.5))
                border.color: active ? root.cfg.accentColor : Util.alpha(root.cfg.lineColor, 0.25)

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
        ChoiceRow {
          visible: root.page === "feel" && root.cfgValue("menu_latch", false) === true
          cfg: root.cfg
          title: "Tap menu closes after"
          unit: " ms"
          help: "How long an untouched tap-menu waits before closing without changing anything."
          options: [ { key: 5000, label: "5 s" }, { key: 8000, label: "8 s" },
                     { key: 12000, label: "12 s" } ]
          current: root.cfgValue("menu_timeout_ms", 8000)
          onPicked: key => root.setConfigKey("menu_timeout_ms", key)
        }

        // What a single / double / triple click does. Each chip cycles through the
        // options (left-click forward, right-click back); the description below says
        // in plain words what the current choice will do.
        Column {
          visible: root.page === "feel"
          width: parent.width
          spacing: Style.space(6)

          Text {
            text: "Clicks"
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
            color: root.cfg.soft(0.6)
          }

          Repeater {
            model: root.clickKinds
            delegate: Column {
              id: clickRow
              required property var modelData
              readonly property var action: root.clickAction("dial", modelData.key)
              width: parent.width
              spacing: Style.space(2)

              Row {
                spacing: Style.space(8)
                Text {
                  width: Style.space(84)
                  anchors.verticalCenter: parent.verticalCenter
                  text: clickRow.modelData.title
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: root.cfg.lineColor
                }
                Pressable {
                  id: clickChip
                  label: clickRow.modelData.title + ": " + clickRow.action.label
                  ringColor: root.cfg.accentColor
                  ringWidth: Math.max(2, Style.space(2))
                  onActivated: root.cycleClick("dial", clickRow.modelData.key, 1)
                  onAlternate: root.cycleClick("dial", clickRow.modelData.key, -1)
                  Keys.onRightPressed: activated()
                  Keys.onLeftPressed: alternate()
                  width: clickRow.width - Style.space(92)
                  height: Style.space(32)
                  radius: Style.space(6)
                  color: Util.alpha(root.cfg.lineColor, clickChip.hovered ? 0.14 : 0.08)
                  border.width: Math.max(1, Style.space(1.5))
                  border.color: Util.alpha(root.cfg.lineColor, 0.25)

                  Text {
                    anchors.centerIn: parent
                    text: "\u2039  " + clickRow.action.label + "  \u203a"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    color: root.cfg.lineColor
                  }
                }
              }

              Text {
                x: Style.space(92)
                width: parent.width - Style.space(92)
                text: clickRow.action.description
                // One line, elided: three wrapped descriptions were what made this window
                // nearly as tall as the screen.
                elide: Text.ElideRight
                maximumLineCount: 1
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: Util.alpha(root.cfg.lineColor, 0.45)
              }
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

        // Surface Pen: enable switch, tail-button chips (same picker as the
        // dial's Clicks above, group "pentail"), and the barrel button's own
        // enable toggle + single action chip. No daemon restart needed --
        // both buttons re-read config.json live, same as the dial's clicks.
        Column {
          visible: root.page === "feel"
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
              border.width: Math.max(1, Style.space(1.5))
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
              text: "Tail button"
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              color: root.cfg.soft(0.5)
            }

            Component {
              id: penRowDelegate
              Column {
                id: tailRow
                required property var modelData
                readonly property var action: root.clickAction(modelData.group, modelData.key)
                width: parent.width
                spacing: Style.space(2)

                Row {
                  spacing: Style.space(8)
                  Text {
                    width: Style.space(84)
                    anchors.verticalCenter: parent.verticalCenter
                    text: tailRow.modelData.title
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    color: root.cfg.lineColor
                  }
                  Pressable {
                    id: tailChip
                    label: (tailRow.modelData.group === "eraser" ? "Pen eraser, " : "Pen tail button, ") + tailRow.modelData.title + ": " + tailRow.action.label
                    ringColor: root.cfg.accentColor
                    ringWidth: Math.max(2, Style.space(2))
                    onActivated: root.cycleClick(tailRow.modelData.group, tailRow.modelData.key, 1)
                    onAlternate: root.cycleClick(tailRow.modelData.group, tailRow.modelData.key, -1)
                    Keys.onRightPressed: activated()
                    Keys.onLeftPressed: alternate()
                    width: tailRow.width - Style.space(92)
                    height: Style.space(32)
                    radius: Style.space(6)
                    color: Util.alpha(root.cfg.lineColor, tailChip.hovered ? 0.14 : 0.08)
                    border.width: Math.max(1, Style.space(1.5))
                    border.color: Util.alpha(root.cfg.lineColor, 0.25)

                    Text {
                      anchors.centerIn: parent
                      text: "\u2039  " + tailRow.action.label + "  \u203a"
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      color: root.cfg.lineColor
                    }
                  }
                }

                Text {
                  x: Style.space(92)
                  width: parent.width - Style.space(92)
                  text: tailRow.action.description
                  elide: Text.ElideRight
                  maximumLineCount: 1
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: root.cfg.soft(0.5)
                }
              }
            }

            Repeater {
              model: root.tailKinds
              delegate: penRowDelegate
            }

            Item { width: 1; height: Style.space(4) }

            Text {
              text: "Barrel button"
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
                border.width: Math.max(1, Style.space(1.5))
                border.color: root.barrelEnabled ? root.cfg.accentColor : Util.alpha(root.cfg.lineColor, 0.3)
                Text {
                  anchors.centerIn: parent
                  text: root.barrelEnabled ? "On" : "Off"
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: root.barrelEnabled ? root.cfg.onAccent : root.cfg.lineColor
                }
              }

              Pressable {
                id: barrelActionChip
                readonly property var action: root.barrelAction()
                label: "Pen barrel button: " + action.label
                enabled: root.barrelEnabled
                ringColor: root.cfg.accentColor
                ringWidth: Math.max(2, Style.space(2))
                onActivated: root.cycleBarrelAction(1)
                onAlternate: root.cycleBarrelAction(-1)
                Keys.onRightPressed: activated()
                Keys.onLeftPressed: alternate()
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - Style.space(56) - Style.space(8)
                height: Style.space(32)
                radius: Style.space(6)
                opacity: root.barrelEnabled ? 1 : 0.4
                color: Util.alpha(root.cfg.lineColor, barrelActionChip.hovered ? 0.14 : 0.08)
                border.width: Math.max(1, Style.space(1.5))
                border.color: Util.alpha(root.cfg.lineColor, 0.25)

                Text {
                  anchors.centerIn: parent
                  text: "\u2039  " + barrelActionChip.action.label + "  \u203a"
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: root.cfg.lineColor
                }
              }
            }

            Text {
              width: parent.width
              text: barrelActionChip.action.description
              elide: Text.ElideRight
              maximumLineCount: 1
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              color: root.cfg.soft(0.5)
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(2)
            visible: root.penEnabled
            opacity: root.penEnabled ? 1 : 0.4

            Text {
              text: "Eraser (the back of the pen)"
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

        // Active tools on a ring, in the same order as the real dial face; drag to reorder. Center
        // is empty on purpose (the dial's click zone). Reordering commits on release, not live: a
        // Repeater over a plain JS array has no stable delegate identity, so a live swap would
        // destroy the delegate being dragged. See docs/DESIGN.md#settings-window.
        Item {
          visible: root.page === "look"
          id: ring
          width: parent.width
          height: Style.space(230)

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
              border.width: Math.max(1, Style.space(1.5))
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
              color: Util.alpha(root.cfg.lineColor, 0.08)
              border.width: 1
              border.color: Util.alpha(root.cfg.lineColor, 0.2)

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

        Row {
          width: parent.width
          spacing: Style.space(10)
          layoutDirection: Qt.RightToLeft

          Pressable {
            visible: root.page === "look"  // Save is for tool changes; the Feel page applies at once
            label: root.dirty ? "Save tool changes" : "Save (nothing to save)"
            enabled: root.dirty
            ringColor: root.cfg.accentColor
            ringWidth: Math.max(2, Style.space(2))
            onActivated: root.save()
            width: Style.space(80); height: Style.space(32)
            radius: Style.space(8)
            color: root.dirty ? root.cfg.accentColor : Util.alpha(root.cfg.lineColor, 0.15)
            Text {
              anchors.centerIn: parent
              text: "Save"
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              color: root.dirty ? root.cfg.onAccent : root.cfg.soft(0.5)
            }
          }
          Pressable {
            label: "Close settings"
            ringColor: root.cfg.accentColor
            ringWidth: Math.max(2, Style.space(2))
            onActivated: root.closeRequested()
            width: Style.space(80); height: Style.space(32)
            radius: Style.space(8)
            color: Util.alpha(root.cfg.lineColor, 0.08)
            Text {
              anchors.centerIn: parent
              text: "Close"
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              color: root.cfg.lineColor
            }
          }
        }
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
        radius: Style.space(8)
        color: root.cfg.tint(0.1)
        border.width: Math.max(1, Style.space(1.5))
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
