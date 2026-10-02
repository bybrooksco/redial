import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Pick and reorder which of the daemon's tools are active on the dial.
//
// This is a settings screen, not a live instrument face, so unlike
// DialMenu.qml's overlay it takes real mouse input (no `mask: Region {}`)
// and needs no rotation socket -- it only reads/writes files.
//
// Also picks where the overlay itself sits on screen (the existing `anchor`
// config key, previously only reachable by hand-editing config.json or
// calling `omarchy-shell dialmenu anchor ...`).
//
// Two files, both in ~/.config/dial-radial/:
//   tools.json   - written by the daemon at every startup: [{name, icon}]
//                  for every tool it knows how to build, in its library
//                  order. This panel never hardcodes a tool list -- a tool
//                  added to the daemon's TOOL_LIBRARY just shows up here.
//   config.json  - the shared config. This panel only ever touches its
//                  "active_tools" and "anchor" keys; every other key --
//                  colours, dial/deck geometry -- is read whole and written
//                  back untouched.
//
// An active_tools change here is picked up live by the daemon the next time
// the dial is idle (see Dial.maybe_reload_tools there) -- no restart.
// anchor has no such lag: DialMenu.qml's Settings watches config.json live
// (see Settings.qml), so an anchor click here is written and takes effect
// immediately, with no Save step and no restart -- it isn't state the
// running daemon holds, just where Quickshell draws the overlay.
//
// Reordering active tools is still up/down arrows, not drag-and-drop: a drag
// gesture isn't something this session could verify without a live mouse in
// hand, and shipping an unverified drag interaction risked a worse result
// than the plain arrows. Worth revisiting if the arrows feel clunky in
// practice.
Item {
  id: root
  required property var cfg

  // Window lifecycle (opened/mode/mask/keyboard-focus) is owned by the
  // embedder now (DialMenu.qml), which shows this content on its "settings"
  // tab of one shared PanelWindow. This used to be a PanelWindow of its own;
  // see the Process Book, 2026-09-26, for why the two were merged. This
  // signal is the one thing the embedder still needs to react to.
  signal closeRequested()
  // Peek at the live tool-rail/radial overlay without leaving this window --
  // see closeRequested above for why the embedder (DialMenu.qml) owns what
  // happens next. There's no matching in-window way back (the live tab is
  // fully click-through by design, see DialMenu.qml), so getting back to
  // Settings goes through the same hotkey/bar-widget entry point as opening
  // it the first time -- that's a deliberate trade, not an oversight.
  signal liveRequested()
  property var manifest: []     // [{name, icon}], in TOOL_LIBRARY order
  property var configDoc: ({})  // full parsed config.json, kept intact
  property var selected: []     // ordered active_tools names
  property bool dirty: false
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
    var out = ({})
    for (var k in configDoc) out[k] = configDoc[k]
    out.size = s
    configFile.setText(JSON.stringify(out, null, 2))
    configDoc = out
  }

  // Appearance: one picker across all six overlay options, even though under
  // the hood three are a "face" (still layout "dial") and three are their own
  // top-level "layout" -- nobody picking a look needs to know that split.
  // Writes both keys in one go so a "layout"-only option (carousel/toast)
  // never leaves a stale "face" implying the wrong thing, and a "dial" option
  // never leaves a stale "layout" from a previous carousel/toast choice.
  readonly property var appearanceOptions: [
    { key: "classic",  label: "Classic",       layout: "dial",     face: "classic" },
    { key: "capsule",  label: "Capsule",       layout: "dial",     face: "capsule" },
    { key: "pie",      label: "Pie Wheel",     layout: "dial",     face: "pie" },
    { key: "gauge",    label: "Gauge",         layout: "dial",     face: "gauge" },
    { key: "carousel", label: "Carousel",      layout: "carousel", face: "" },
    { key: "toast",    label: "Minimal Toast", layout: "toast",    face: "" }
  ]
  readonly property string appearanceChoice: {
    var l = (configDoc && configDoc.layout) ? String(configDoc.layout) : "dial"
    var f = (configDoc && configDoc.face) ? String(configDoc.face) : "classic"
    if (l !== "dial") return (l === "carousel" || l === "toast") ? l : "classic"
    return (f === "pie" || f === "gauge" || f === "capsule") ? f : "classic"
  }
  function setAppearance(opt) {
    var out = ({})
    for (var k in configDoc) out[k] = configDoc[k]
    out.layout = opt.layout
    if (opt.face) out.face = opt.face
    configFile.setText(JSON.stringify(out, null, 2))
    configDoc = out
  }

  // Click gestures. The action list comes from the daemon (clicks.json /
  // pen_clicks.json, written at every startup) so this window never hardcodes
  // it; the choice lives in config.json ("clicks" for the dial, "pen.tail_clicks"
  // for the pen's tail button) and the daemon re-reads it live. Both use the
  // same picker logic below, parametrized by `group` ("dial" | "pentail") so
  // it isn't written out three times over (the barrel button is one action +
  // a toggle, not three kinds, and gets its own small block further down).
  property var clickActions: []      // [{name, label, description}] -- dial
  property var clickDefaults: ({ "single": "tool", "double": "dictation", "triple": "enter" })
  property var penTailActions: []    // [{name, label, description}] -- pen tail button
  property var penTailDefaults: ({ "single": "space", "double": "enter", "hold": "menu" })
  property var penBarrelActions: []  // [{name, label, description}] -- pen barrel button
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
    { key: "single", title: "Single click" },
    { key: "double", title: "Double click" },
    { key: "hold", title: "Press & hold" }
  ]
  function groupActions(group) { return group === "pentail" ? penTailActions : clickActions }
  function groupDefaults(group) { return group === "pentail" ? penTailDefaults : clickDefaults }
  function groupChoice(group) {
    if (group === "pentail")
      return (configDoc && configDoc.pen && configDoc.pen.tail_clicks) ? configDoc.pen.tail_clicks : {}
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
    var out = ({})
    for (var k in configDoc) out[k] = configDoc[k]
    if (group === "pentail") {
      var pen = ({})
      if (configDoc && configDoc.pen) for (var p in configDoc.pen) pen[p] = configDoc.pen[p]
      var tail = ({})
      if (pen.tail_clicks) for (var t in pen.tail_clicks) tail[t] = pen.tail_clicks[t]
      tail[kind] = name
      pen.tail_clicks = tail
      out.pen = pen
    } else {
      var clicks = ({})
      if (configDoc && configDoc.clicks) for (var c in configDoc.clicks) clicks[c] = configDoc.clicks[c]
      clicks[kind] = name
      out.clicks = clicks
    }
    configFile.setText(JSON.stringify(out, null, 2))
    configDoc = out
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
    var out = ({})
    for (var k in configDoc) out[k] = configDoc[k]
    var pen = ({})
    if (configDoc && configDoc.pen) for (var p in configDoc.pen) pen[p] = configDoc.pen[p]
    mutate(pen)
    out.pen = pen
    configFile.setText(JSON.stringify(out, null, 2))
    configDoc = out
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

  // Writes through immediately -- unlike active_tools, anchor is not state
  // the running daemon holds, so there's nothing to batch behind a restart.
  // Does not assign root.anchor directly: it's a binding off configDoc (see
  // above), and an imperative assignment would permanently break that
  // binding for the rest of this panel's life.
  function setAnchor(a) {
    var out = ({})
    for (var k in configDoc) out[k] = configDoc[k]
    out.anchor = a
    configFile.setText(JSON.stringify(out, null, 2))
    configDoc = out
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
    var text = String(raw || "").trim()
    var doc = ({})
    if (text !== "") {
      try {
        var parsed = JSON.parse(text)
        if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) doc = parsed
      } catch (e) {
        console.warn("[dial.radial] tool picker: config is not valid JSON, treating as empty:", e)
      }
    }
    configDoc = doc
    var act = doc.active_tools
    selected = (Array.isArray(act) && act.length) ? act.slice()
                                                   : manifest.map(function (m) { return m.name })
    dirty = false
  }

  function save() {
    var out = ({})
    for (var k in configDoc) out[k] = configDoc[k]
    out.active_tools = selected
    configFile.setText(JSON.stringify(out, null, 2))
    configDoc = out
    dirty = false
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
      height: col.implicitHeight + Style.space(40)
      radius: Style.cornerRadius
      // Forced fully opaque via explicit alpha=1, same reasoning as the
      // dial disc plate's backing (see DialMenu.qml): the resolved theme
      // background color can itself carry alpha, and "opacity: 1" on this
      // Rectangle doesn't fix that -- the color's OWN alpha channel still
      // lets desktop content read straight through. A settings dialog
      // needs to be fully legible, more so than the live dial overlay,
      // so this always forces full opacity rather than following a
      // configurable plateOpacity.
      color: Qt.rgba(root.cfg.backgroundColor.r, root.cfg.backgroundColor.g,
                     root.cfg.backgroundColor.b, 1.0)
      border.width: Math.max(1, Style.space(2))
      border.color: Util.alpha(root.cfg.lineColor, 0.30)

      // Eat clicks so they don't fall through to the dismiss MouseArea behind.
      MouseArea { anchors.fill: parent; onClicked: {} }

      Column {
        id: col
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: Style.space(20)
        spacing: Style.space(9)

        Item {
          width: parent.width
          height: Math.max(titleText.implicitHeight, liveTab.implicitHeight)

          Text {
            id: titleText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "Surface Dial Tools"
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
            color: root.cfg.lineColor
          }
          // Peek at the live tool-rail/radial overlay in the same window --
          // one-way (see liveRequested above); a stray click here is cheap,
          // the hotkey brings you right back to this same Settings tab.
          Text {
            id: liveTab
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "Live ›"
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: liveTabMouse.containsMouse ? root.cfg.accentColor : Util.alpha(root.cfg.lineColor, 0.6)
            MouseArea {
              id: liveTabMouse
              anchors.fill: parent
              anchors.margins: -Style.space(4)
              hoverEnabled: true
              onClicked: root.liveRequested()
            }
          }
        }
        Text {
          width: parent.width
          text: "Checked tools are active, top to bottom. Restart the dial daemon after saving."
          wrapMode: Text.WordWrap
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          color: Util.alpha(root.cfg.lineColor, 0.6)
        }

        Row {
          width: parent.width
          spacing: Style.space(36)

        Column {
          spacing: Style.space(6)

          Text {
            text: "Position"
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
            color: Util.alpha(root.cfg.lineColor, 0.6)
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
                  delegate: Rectangle {
                    id: cell
                    required property string modelData
                    readonly property bool active: root.anchor === modelData
                    width: Style.space(28); height: width
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

                    MouseArea {
                      anchors.fill: parent
                      onClicked: root.setAnchor(cell.modelData)
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
            color: Util.alpha(root.cfg.lineColor, 0.6)
          }

          Row {
            spacing: Style.space(4)
            Repeater {
              model: root.sizeOptions
              delegate: Rectangle {
                id: sizeBtn
                required property var modelData
                readonly property bool active: root.sizeChoice === modelData.key
                width: Style.space(64); height: Style.space(28)
                radius: Style.space(6)
                color: active ? root.cfg.accentColor : Util.alpha(root.cfg.lineColor, 0.08)
                border.width: Math.max(1, Style.space(1.5))
                border.color: active ? root.cfg.accentColor : Util.alpha(root.cfg.lineColor, 0.25)

                Text {
                  anchors.centerIn: parent
                  text: sizeBtn.modelData.label
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: sizeBtn.active ? root.cfg.backgroundColor : root.cfg.lineColor
                }

                MouseArea {
                  anchors.fill: parent
                  onClicked: root.setSize(sizeBtn.modelData.key)
                }
              }
            }
          }

          Text {
            text: "Applies immediately."
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: Util.alpha(root.cfg.lineColor, 0.45)
          }
        }
        }

        // Overall look. Flow, not Row: six chips don't fit one line at this
        // card width, so they wrap to a second rather than overflow it.
        Column {
          width: parent.width
          spacing: Style.space(6)

          Text {
            text: "Appearance"
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
            color: Util.alpha(root.cfg.lineColor, 0.6)
          }

          Flow {
            width: parent.width
            spacing: Style.space(6)
            Repeater {
              model: root.appearanceOptions
              delegate: Rectangle {
                id: appearanceBtn
                required property var modelData
                readonly property bool active: root.appearanceChoice === modelData.key
                width: label.implicitWidth + Style.space(20)
                height: Style.space(28)
                radius: Style.space(6)
                color: active ? root.cfg.accentColor : Util.alpha(root.cfg.lineColor, 0.08)
                border.width: Math.max(1, Style.space(1.5))
                border.color: active ? root.cfg.accentColor : Util.alpha(root.cfg.lineColor, 0.25)

                Text {
                  id: label
                  anchors.centerIn: parent
                  text: appearanceBtn.modelData.label
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: appearanceBtn.active ? root.cfg.backgroundColor : root.cfg.lineColor
                }

                MouseArea {
                  anchors.fill: parent
                  onClicked: root.setAppearance(appearanceBtn.modelData)
                }
              }
            }
          }

          Text {
            text: "Applies immediately."
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: Util.alpha(root.cfg.lineColor, 0.45)
          }
        }

        // What a single / double / triple click does. Each chip cycles through the
        // options (left-click forward, right-click back); the description below says
        // in plain words what the current choice will do.
        Column {
          width: parent.width
          spacing: Style.space(6)

          Text {
            text: "Clicks"
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
            color: Util.alpha(root.cfg.lineColor, 0.6)
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
                Rectangle {
                  width: clickRow.width - Style.space(92)
                  height: Style.space(28)
                  radius: Style.space(6)
                  color: Util.alpha(root.cfg.lineColor, chipMouse.containsMouse ? 0.14 : 0.08)
                  border.width: Math.max(1, Style.space(1.5))
                  border.color: Util.alpha(root.cfg.lineColor, 0.25)

                  Text {
                    anchors.centerIn: parent
                    text: "\u2039  " + clickRow.action.label + "  \u203a"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    color: root.cfg.lineColor
                  }
                  MouseArea {
                    id: chipMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onClicked: function (m) {
                      root.cycleClick("dial", clickRow.modelData.key, m.button === Qt.RightButton ? -1 : 1)
                    }
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
            color: Util.alpha(root.cfg.lineColor, 0.45)
          }
        }

        // Surface Pen: enable switch, tail-button chips (same picker as the
        // dial's Clicks above, group "pentail"), and the barrel button's own
        // enable toggle + single action chip. No daemon restart needed --
        // both buttons re-read config.json live, same as the dial's clicks.
        Column {
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
              color: Util.alpha(root.cfg.lineColor, 0.6)
            }
            Rectangle {
              id: penEnableBtn
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(52); height: Style.space(22)
              radius: height / 2
              color: root.penEnabled ? root.cfg.accentColor : Util.alpha(root.cfg.lineColor, 0.12)
              border.width: Math.max(1, Style.space(1.5))
              border.color: root.penEnabled ? root.cfg.accentColor : Util.alpha(root.cfg.lineColor, 0.3)
              Text {
                anchors.centerIn: parent
                text: root.penEnabled ? "On" : "Off"
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: root.penEnabled ? root.cfg.backgroundColor : root.cfg.lineColor
              }
              MouseArea { anchors.fill: parent; onClicked: root.setPenEnabled(!root.penEnabled) }
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
              color: Util.alpha(root.cfg.lineColor, 0.5)
            }

            Repeater {
              model: root.tailKinds
              delegate: Column {
                id: tailRow
                required property var modelData
                readonly property var action: root.clickAction("pentail", modelData.key)
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
                  Rectangle {
                    width: tailRow.width - Style.space(92)
                    height: Style.space(28)
                    radius: Style.space(6)
                    color: Util.alpha(root.cfg.lineColor, tailChipMouse.containsMouse ? 0.14 : 0.08)
                    border.width: Math.max(1, Style.space(1.5))
                    border.color: Util.alpha(root.cfg.lineColor, 0.25)

                    Text {
                      anchors.centerIn: parent
                      text: "\u2039  " + tailRow.action.label + "  \u203a"
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      color: root.cfg.lineColor
                    }
                    MouseArea {
                      id: tailChipMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      acceptedButtons: Qt.LeftButton | Qt.RightButton
                      onClicked: function (m) {
                        root.cycleClick("pentail", tailRow.modelData.key, m.button === Qt.RightButton ? -1 : 1)
                      }
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
                  color: Util.alpha(root.cfg.lineColor, 0.45)
                }
              }
            }

            Item { width: 1; height: Style.space(4) }

            Text {
              text: "Barrel button"
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              color: Util.alpha(root.cfg.lineColor, 0.5)
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Rectangle {
                id: barrelEnableBtn
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(52); height: Style.space(22)
                radius: height / 2
                color: root.barrelEnabled ? root.cfg.accentColor : Util.alpha(root.cfg.lineColor, 0.12)
                border.width: Math.max(1, Style.space(1.5))
                border.color: root.barrelEnabled ? root.cfg.accentColor : Util.alpha(root.cfg.lineColor, 0.3)
                Text {
                  anchors.centerIn: parent
                  text: root.barrelEnabled ? "On" : "Off"
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: root.barrelEnabled ? root.cfg.backgroundColor : root.cfg.lineColor
                }
                MouseArea { anchors.fill: parent; onClicked: root.setBarrelEnabled(!root.barrelEnabled) }
              }

              Rectangle {
                id: barrelActionChip
                readonly property var action: root.barrelAction()
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - Style.space(52) - Style.space(8)
                height: Style.space(28)
                radius: Style.space(6)
                opacity: root.barrelEnabled ? 1 : 0.4
                color: Util.alpha(root.cfg.lineColor, barrelChipMouse.containsMouse ? 0.14 : 0.08)
                border.width: Math.max(1, Style.space(1.5))
                border.color: Util.alpha(root.cfg.lineColor, 0.25)

                Text {
                  anchors.centerIn: parent
                  text: "\u2039  " + barrelActionChip.action.label + "  \u203a"
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: root.cfg.lineColor
                }
                MouseArea {
                  id: barrelChipMouse
                  anchors.fill: parent
                  enabled: root.barrelEnabled
                  hoverEnabled: true
                  acceptedButtons: Qt.LeftButton | Qt.RightButton
                  onClicked: function (m) {
                    root.cycleBarrelAction(m.button === Qt.RightButton ? -1 : 1)
                  }
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
              color: Util.alpha(root.cfg.lineColor, 0.45)
            }
          }

          Text {
            text: "Both buttons apply immediately, no daemon restart needed."
            width: parent.width
            wrapMode: Text.WordWrap
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: Util.alpha(root.cfg.lineColor, 0.45)
          }
        }

        // Active tools, arranged on a ring in the same order the real dial
        // face lays them out -- drag one around the circumference to
        // reorder. Center is deliberately empty: that's the click/dictation
        // zone on the actual dial, never a tool slot, so it stays empty here
        // too rather than implying a 10th position that doesn't exist.
        //
        // Reordering happens on release, not live mid-drag: a Repeater bound
        // to a plain JS array (root.selected) has no stable delegate
        // identity across a reorder, so live-swapping mid-gesture would
        // destroy and recreate the very delegate the mouse is holding,
        // aborting the drag. Simpler and more robust to let the dragged chip
        // move freely as a visual overlay, then commit one moveTo() on
        // release. The cost: other chips don't preview-shuffle while you
        // drag, they just settle once you let go.
        Item {
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
            color: Util.alpha(root.cfg.lineColor, 0.3)
          }

          Repeater {
            model: root.selected
            delegate: Rectangle {
              id: chip
              required property int index
              required property string modelData
              readonly property var meta: root.manifestByName(modelData)
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
              Behavior on x { enabled: !dragArea.pressed; NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
              Behavior on y { enabled: !dragArea.pressed; NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

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
                visible: !dragArea.pressed
                Text {
                  anchors.centerIn: parent
                  text: "×"
                  font.pixelSize: Style.space(10)
                  color: Util.alpha(root.cfg.lineColor, 0.7)
                }
                MouseArea {
                  anchors.fill: parent
                  onClicked: root.toggleTool(chip.modelData)
                }
              }

              MouseArea {
                id: dragArea
                anchors.fill: parent
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
          width: parent.width
          spacing: Style.space(6)
          Repeater {
            model: root.rows.filter(function (r) { return !r.checked })
            delegate: Rectangle {
              required property var modelData
              width: chipRow.implicitWidth + Style.space(16)
              height: Style.space(28)
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
                  color: Util.alpha(root.cfg.lineColor, 0.8)
                }
              }
              MouseArea {
                anchors.fill: parent
                onClicked: root.toggleTool(modelData.name)
              }
            }
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(10)
          layoutDirection: Qt.RightToLeft

          Rectangle {
            width: Style.space(80); height: Style.space(32)
            radius: Style.space(8)
            color: root.dirty ? root.cfg.accentColor : Util.alpha(root.cfg.lineColor, 0.15)
            Text {
              anchors.centerIn: parent
              text: "Save"
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              color: root.dirty ? root.cfg.backgroundColor : Util.alpha(root.cfg.lineColor, 0.5)
            }
            MouseArea {
              anchors.fill: parent
              enabled: root.dirty
              onClicked: root.save()
            }
          }
          Rectangle {
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
            MouseArea { anchors.fill: parent; onClicked: root.closeRequested() }
          }
        }
      }
    }
}
