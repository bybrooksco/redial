pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Placement.js" as Place
import "Notes.js" as Notes

// re:dial tool dashboard.
//
// A card rail: the active tool sits at full size in the centre, neighbours dimmed, and
// rotation slides the rail. A dial is a 1-D control, so a 1-D rail reads more honestly than
// a ring, and stays legible when parked along a screen edge.
//
// Driven over IPC by ~/.local/bin/redial-hypr:
//   omarchy-shell dialmenu open '{"tools":[{"icon":"♫","name":"Volume","hint":"mute"}],
//                                 "index":0,"anchor":"bottom"}'
//   omarchy-shell dialmenu highlight 2
//   omarchy-shell dialmenu anchor bottom-right
//   omarchy-shell dialmenu close
//
// anchor: center | top | bottom | left | right | top-left | top-right |
//         bottom-left | bottom-right   (or pass x/y to place it freely)
Item {
  id: root

  // All tunables live here, with defaults in code - see Settings.qml.
  Settings { id: cfg }

  // The design language (languages/<name>/Language.qml, see languages/README.md). An unknown or
  // broken one falls back to re:dial classic, so a half-finished language never blanks the overlay.
  Loader {
    id: languageLoader
    property bool failed: false
    readonly property string dir: "languages/" + (failed ? "classic" : cfg.language)
    source: dir + "/Language.qml"
    onStatusChanged: if (status === Loader.Error && !failed) failed = true
    Connections { target: cfg; function onLanguageChanged() { languageLoader.failed = false } }
  }
  readonly property var language: languageLoader.item
  readonly property var easeOut: [0.23, 1, 0.32, 1, 1, 1]

  // The colour scheme's roles (see ColourScheme.js), as colours, for the parts of the classic
  // plate this file draws itself.
  readonly property color roleGround: cfg.roles.ground
  readonly property color roleLine: cfg.roles.line
  readonly property color roleAccent: cfg.roles.accent
  readonly property color roleAlert: cfg.roles.alert
  function roleInk(a) { return Qt.rgba(roleLine.r, roleLine.g, roleLine.b, a) }

  // One shared window, two modes: "live" is the daemon-driven overlay; "settings" is
  // ToolPicker's content (IPC target "dialtools"). `mode` picks the content and the mask/focus
  // policy. See docs/DESIGN.md#overlay-window.
  property string mode: "live"
  // True only while the live display is being driven by dial rotation; scopes the inactivity
  // watchdog (a manual peek from Settings should stay up).
  property bool liveDriven: false

  property bool opened: false
  property var tools: []
  property int index: 0
  property string anchor: cfg.anchor
  // "deck" = the card rail; "dial" = the radial instrument face.
  property string layout: cfg.layout

  // Continuous angular position in tool units - 2.37 means "between tool 2 and
  // tool 3". Fed by the daemon over a socket at rotation rate; `index` is
  // derived from it. IPC-driven highlights set it too, so both paths agree.
  property real position: 0
  property bool live: false
  property real freeX: -1
  property real freeY: -1

  readonly property int cardW: Style.space(cfg.cardWidth)
  readonly property int cardH: Style.space(cfg.cardHeight)
  readonly property int cardGap: Style.space(cfg.cardGap)
  readonly property int stride: cardW + cardGap
  // The deck is exactly as wide as the tools it holds.
  readonly property int visibleSpan: Math.max(1, tools.length) * stride - cardGap
  readonly property int pad: Style.space(18)
  readonly property int edgeMargin: Style.space(56)
  // Kept as a constant rather than read off the header Item: deriving the
  // deck height from a child that is itself anchored to the deck is a
  // binding loop, and QML resolves it by collapsing the deck to zero height.
  readonly property int headerH: Style.font.body + Style.space(4)

  function open(payloadJson) {
    try {
      var p = JSON.parse(payloadJson || "{}")
      if (p.tools !== undefined) tools = p.tools
      // While the position socket is live it's the sole source of truth for
      // which icon is selected - a stray "open" call (e.g. Volume's live
      // readout refresh) landing late must not stomp a newer pos-derived index.
      if (p.index !== undefined && !live) index = p.index
      // anchor/layout are deliberately not taken from the daemon's payload: assigning them here
      // would replace their live bindings to cfg for good. cfg is the single source of truth.
      // See docs/DESIGN.md#config-bindings.
      freeX = p.x === undefined ? -1 : p.x
      freeY = p.y === undefined ? -1 : p.y
      mode = "live"
      liveDriven = true
      ringOpen = true
      if (noteKind === "turn") { noteKind = ""; noteTimer.stop() }   // the ring shows the tool itself
      opened = true
    } catch (e) {}
  }

  // States the daemon reports over the socket, drawn by a look that knows them (re:dial classic's
  // Classic): "turn" a tool turning (name, icon, hint, value?, valueText?), "hint" a guide line
  // (prompt, gesture, step?, steps?), "cant" the dial cannot act (reason, title, line). "" is the
  // ring. A note shows for its time and then goes, unless the ring is open underneath it.
  property string noteKind: ""
  property var note: ({})
  property bool ringOpen: false
  property real noteAt: 0
  function showNote(kind, payloadJson) {
    var doc
    try { doc = JSON.parse(payloadJson || "{}") } catch (e) { return }
    if (typeof doc !== "object" || doc === null) return
    if (!Notes.accept(kind, { kind: noteKind, ringOpen: ringOpen, settings: opened && mode === "settings",
                              ageMs: Date.now() - noteAt })) return
    if (kind === "turn" && !live) {
      for (var i = 0; i < tools.length; i++) if (tools[i].name === doc.name) { index = i; position = i }
    }
    note = doc
    noteKind = kind
    noteAt = Date.now()
    noteTimer.interval = Notes.MS[kind]
    noteTimer.restart()
    mode = "live"
    liveDriven = true
    opened = true
  }
  Timer {
    id: noteTimer
    onTriggered: { root.noteKind = ""; if (!root.ringOpen) root.opened = false }
  }

  readonly property int n: tools.length

  function setIndex(i) {
    // Each call is a fire-and-forget IPC round trip with no ordering guarantee; once the pos
    // socket is live it alone drives index/position, so a stale call can't flicker the highlight.
    if (i >= 0 && i < tools.length && !live) {
      index = i
      position = i
    }
    watchdog.restart()
  }
  // Closing the ring leaves a note on screen to finish its time.
  function close() {
    ringOpen = false; live = false; watchdog.stop()
    if (!noteTimer.running) opened = false
  }

  // Safety net only - the daemon owns the real lifecycle. Generous enough that
  // a long deliberate hold never trips it.
  property alias watchdog: watchdog

  Timer {
    id: watchdog
    interval: cfg.watchdogMs
    // Only auto-closes the "popped up because the dial is turning" case --
    // a manual peek at Live from Settings (mode flips, liveDriven doesn't)
    // sits there like Settings itself does, no timeout.
    onTriggered: if (root.mode === "live" && root.liveDriven) root.close()  // close() also clears `live`
  }

  onOpenedChanged: if (opened) watchdog.restart(); else watchdog.stop()

  // Rotation arrives here, not over IPC: the dial emits ~100 events a second
  // and every omarchy-shell call spawns a process, so the needle could only
  // ever step per detent through that path. A socket makes the motion
  // continuous at no meaningful cost.
  SocketServer {
    // No /tmp fallback: it is shared, so another user could plant a socket there.
    active: !!Quickshell.env("XDG_RUNTIME_DIR")
    path: Quickshell.env("XDG_RUNTIME_DIR") + "/redial.sock"

    handler: Socket {
      parser: SplitParser {
        splitMarker: "\n"
        onRead: function (line) {
          var t = String(line).trim()
          if (t === "") return
          var sp = t.indexOf(" ")
          var cmd = sp < 0 ? t : t.substring(0, sp)
          var arg = sp < 0 ? "" : t.substring(sp + 1)

          if (cmd === "pos") {
            // continuous position while the menu is held open
            var v = parseFloat(arg)
            if (!isNaN(v) && root.tools.length) {
              root.live = true
              root.mode = "live"
              root.liveDriven = true
              root.position = v
              var n = root.tools.length
              var i = Math.round(v) % n
              if (i < 0) i += n
              root.index = i
              root.watchdog.restart()
            }
          } else if (cmd === "open") {
            root.open(arg)
          } else if (cmd === "close") {
            root.live = false
            root.close()
          } else if (cmd === "turn" || cmd === "hint" || cmd === "cant") {
            root.showNote(cmd, arg)
          }
        }
      }
    }
  }

  IpcHandler {
    target: "dialmenu"
    function open(payloadJson: string): string { root.open(payloadJson); return "ok" }
    function highlight(i: string): string { root.setIndex(parseInt(i)); return "ok" }
    function anchor(a: string): string { root.anchor = a; return "ok" }
    function layout(l: string): string { root.layout = l; return "ok" }
    function close(): string { root.close(); return "ok" }
    function state(): string { return root.opened ? "open" : "closed" }
    function ping(): string { return "ok" }
  }

  // Settings tab of the same shared window (bar widget left-click,
  // Omarchy menu > Setup > re:dial). Moved here from ToolPicker.qml when the two windows
  // merged (see docs/DESIGN.md#overlay-window).
  IpcHandler {
    target: "dialtools"
    function open(): string { root.mode = "settings"; root.liveDriven = false; root.opened = true; return "ok" }
    function close(): string { if (root.mode === "settings") root.close(); return "ok" }
    function toggle(): string {
      if (root.opened && root.mode === "settings") root.close()
      else { root.mode = "settings"; root.liveDriven = false; root.opened = true }
      return "ok"
    }
    function state(): string { return (root.opened && root.mode === "settings") ? "open" : "closed" }
    function tip(name: string): string { return toolPicker.tipForName(name) ? "ok" : "not on the ring" }
    function page(name: string): string { toolPicker.page = (name === "feel" || name === "help") ? name : "look"; return "ok" }
    function ping(): string { return "ok" }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "dial-dashboard"
    WlrLayershell.layer: WlrLayer.Overlay
    // Live: click-through (the dial is the input device). Settings: real mouse/keyboard input.
    WlrLayershell.keyboardFocus: root.mode === "settings" ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    mask: root.mode === "settings" ? null : clickThroughMask

    Region { id: clickThroughMask }

    // Settings tab content + its background-dismiss, only reachable (and
    // only rendered) while mode is "settings" -- Live stays exactly the
    // click-through overlay it always was.
    MouseArea {
      anchors.fill: parent
      visible: root.mode === "settings"
      enabled: root.mode === "settings"
      onClicked: root.close()
    }
    ToolPicker {
      id: toolPicker
      cfg: cfg
      anchors.fill: parent
      visible: root.mode === "settings"
      onCloseRequested: root.close()
      onLiveRequested: root.mode = "live"
    }

    // Deck: the dashboard surface the cards ride in.
    Rectangle {
      id: deck
      visible: root.mode === "live" && root.layout === "deck"
      width: Math.min(root.visibleSpan + root.pad * 2, parent.width - root.edgeMargin * 2)
      height: root.pad * 2 + root.headerH + Style.space(6) + root.cardH
      radius: Style.cornerRadius
      color: cfg.backgroundColor
      border.width: Math.max(1, Style.space(2))
      border.color: Util.alpha(cfg.lineColor, 0.30)


      x: Place.x(root.anchor, root.freeX, root.freeY, width, parent.width, root.edgeMargin)
      y: Place.y(root.anchor, root.freeX, root.freeY, height, parent.height, root.edgeMargin)

      Behavior on x { NumberAnimation { duration: cfg.motionBase; easing.type: Easing.OutCubic } }
      Behavior on y { NumberAnimation { duration: cfg.motionBase; easing.type: Easing.OutCubic } }

      opacity: root.opened ? 1 : 0
      scale: root.opened ? 1 : 0.96
      Behavior on opacity { NumberAnimation { duration: cfg.motionFast; easing.type: Easing.OutCubic } }
      Behavior on scale { NumberAnimation { duration: cfg.motionBase; easing.type: Easing.OutCubic } }

      // Header: names the selection, so the deck reads even at a glance.
      Item {
        id: header
        anchors { top: parent.top; left: parent.left; right: parent.right }
        anchors.topMargin: root.pad
        anchors.leftMargin: root.pad
        anchors.rightMargin: root.pad
        height: root.headerH

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "re:dial"
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
          color: Util.alpha(cfg.lineColor, 0.55)
        }
        Text {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: root.tools.length ? (root.index + 1) + " / " + root.tools.length : ""
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          color: Util.alpha(cfg.lineColor, 0.55)
        }
      }

      // Rail viewport - cards hold still; only the selection moves.
      Item {
        id: viewport
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        anchors.bottomMargin: root.pad
        anchors.leftMargin: root.pad
        anchors.rightMargin: root.pad
        height: root.cardH

        Row {
          id: rail
          spacing: root.cardGap
          height: parent.height
          anchors.horizontalCenter: parent.horizontalCenter

          Repeater {
            model: root.tools
            delegate: Rectangle {
              required property int index
              required property var modelData
              readonly property bool active: index === root.index

              width: root.cardW
              height: root.cardH
              radius: Style.cornerRadius
              color: active ? Util.alpha(cfg.accentColor, 0.18) : Util.alpha(cfg.lineColor, 0.08)
              border.width: Math.max(1, Style.space(2))
              border.color: active ? cfg.accentColor : Util.alpha(cfg.lineColor, 0.20)
              opacity: active ? 1 : 0.62
              scale: active ? 1 : 0.93

              Behavior on opacity { NumberAnimation { duration: cfg.motionBase } }
              Behavior on scale { NumberAnimation { duration: cfg.motionBase; easing.type: Easing.OutCubic } }
              Behavior on color { ColorAnimation { duration: cfg.motionBase } }
              Behavior on border.color { ColorAnimation { duration: cfg.motionBase } }

              Column {
                anchors.centerIn: parent
                width: parent.width - Style.space(16)
                spacing: Style.space(8)

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: modelData.icon || ""
                  font.family: Style.font.family
                  font.pixelSize: Style.font.displayLarge
                  color: active ? cfg.accentColor : cfg.lineColor
                }
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: modelData.name || ""
                  textFormat: Text.PlainText  // a tool named "<b>x" must not render as markup
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                  color: cfg.lineColor
                  elide: Text.ElideRight
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                }
                // Live value, when the tool has one. Only on the active card:
                // a rail of five progress bars would read as a chart, not a menu.
                Item {
                  visible: active && modelData.value !== undefined
                  width: parent.width
                  height: visible ? Style.space(18) : 0
                  Rectangle {
                    id: track
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    height: Style.space(6)
                    radius: height / 2
                    color: Util.alpha(cfg.lineColor, 0.18)
                    Rectangle {
                      height: parent.height
                      radius: parent.radius
                      width: parent.width * Math.max(0, Math.min(1, (modelData.value || 0) / 100))
                      color: cfg.accentColor
                      Behavior on width { NumberAnimation { duration: cfg.motionFast } }
                    }
                  }
                }
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  visible: active && modelData.valueText !== undefined
                  text: modelData.valueText || ""
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  color: cfg.accentColor
                }

                // The click action is the half of a tool you cannot infer from
                // its name, so it rides on the card rather than in a tooltip.
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  visible: !!modelData.hint && modelData.hint !== "—"
                  text: "click: " + (modelData.hint || "")
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: Util.alpha(cfg.lineColor, 0.6)
                  elide: Text.ElideRight
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                }
              }
            }
          }
        }
      }
    }

    // Carousel: binary sizing (selected large, others small) keeps the container's total size
    // constant as the selection moves. Not routed through the face Loader: it isn't circular.
    // See docs/DESIGN.md#faces-and-layouts.
    Rectangle {
      id: carousel
      visible: root.mode === "live" && root.layout === "carousel"
      readonly property int cardSmall: Style.space(64)
      readonly property int cardLarge: Style.space(104)
      width: row.implicitWidth + Style.space(40)
      height: row.implicitHeight + Style.space(40)
      radius: Style.cornerRadius
      // Solid fill, no border -- same pass as Gauge's/Toast's backdrops and
      // Pie's hub: an outline here was just competing with the cards for
      // attention, and the fill already reads as a defined panel on its own.
      color: cfg.backgroundColor


      x: Place.x(root.anchor, root.freeX, root.freeY, width, parent.width, root.edgeMargin)
      y: Place.y(root.anchor, root.freeX, root.freeY, height, parent.height, root.edgeMargin)

      Behavior on x { NumberAnimation { duration: cfg.motionBase; easing.type: Easing.OutCubic } }
      Behavior on y { NumberAnimation { duration: cfg.motionBase; easing.type: Easing.OutCubic } }

      opacity: root.opened ? 1 : 0
      scale: root.opened ? 1 : 0.96
      Behavior on opacity { NumberAnimation { duration: cfg.motionFast; easing.type: Easing.OutCubic } }
      Behavior on scale { NumberAnimation { duration: cfg.motionBase; easing.type: Easing.OutCubic } }

      // One animated scalar drives every card. A card's weight is a "hat" of its distance from
      // `pos`, and the weights always sum to exactly 1, so the row's total width is constant on
      // every frame, even when the dial outruns the animation. See docs/DESIGN.md#faces-and-layouts.
      property real pos: 0
      Component.onCompleted: snapTo(root.index)
      Connections {
        target: root
        function onIndexChanged() { carousel.glideTo(root.index) }
        function onNChanged() { carousel.snapTo(root.index) }
        function onOpenedChanged() { if (root.opened) carousel.snapTo(root.index) }
      }
      function snapTo(i) { posAnim.stop(); pos = i }
      function glideTo(i) {
        posAnim.stop()
        // Hidden, or a wrap-around: jump instead of sweeping across every card.
        if (!root.opened || Math.abs(i - pos) > 1.5) { pos = i; return }
        posAnim.from = pos
        posAnim.to = i
        posAnim.start()
      }
      function mix(a, b, t) {
        return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t,
                       a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t)
      }
      NumberAnimation { id: posAnim; target: carousel; property: "pos"; duration: cfg.motionBase; easing.type: Easing.OutCubic }

      Row {
        id: row
        anchors.centerIn: parent
        spacing: Style.space(10)

        Repeater {
          model: root.tools
          delegate: Rectangle {
            id: card
            required property int index
            required property var modelData
            // 1 on the selection, 0 two or more cards away, linear in between.
            readonly property real t: Math.max(0, 1 - Math.abs(index - carousel.pos))
            width: carousel.cardSmall + (carousel.cardLarge - carousel.cardSmall) * t
            height: width
            radius: Style.space(16)
            color: carousel.mix(Util.alpha(cfg.lineColor, 0.08), cfg.accentColor, t)

            // The icon is laid out once at its largest size and only scaled, so nothing relayouts
            // or re-rasterises mid-transition. The label fades in below it; it is always laid out.
            Text {
              id: glyph
              readonly property real smallScale: Style.font.title / Style.font.displayLarge
              readonly property real lift: (label.implicitHeight + Style.space(4)) / 2
              textFormat: Text.PlainText
              anchors.horizontalCenter: parent.horizontalCenter
              y: (parent.height - height) / 2 - lift * card.t
              scale: smallScale + (1 - smallScale) * card.t
              text: card.modelData.icon || ""
              font.family: Style.font.family
              font.pixelSize: Style.font.displayLarge
              color: carousel.mix(Util.alpha(cfg.lineColor, 0.55), cfg.backgroundColor, card.t)
            }
            Text {
              id: label
              textFormat: Text.PlainText
              width: carousel.cardLarge - Style.space(12)
              x: (parent.width - width) / 2
              y: parent.height / 2 - glyph.lift * card.t + glyph.height * glyph.scale / 2 + Style.space(4)
              opacity: Math.max(0, Math.min(1, (card.t - 0.6) / 0.4))
              text: card.modelData.name || ""
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              color: cfg.backgroundColor
              elide: Text.ElideRight
              horizontalAlignment: Text.AlignHCenter
            }
          }
        }
      }
    }

    // Minimal Toast: one pill naming the armed tool plus a dot strip. Gives up the free
    // distance-to-next-tool feedback that circular and ordered layouts show.
    Item {
      id: toast
      visible: root.mode === "live" && root.layout === "toast"
      readonly property var activeTool: root.tools.length > root.index ? root.tools[root.index] : null
      // dots never sets `width`, so read implicitWidth/implicitHeight (as Carousel's row is).
      width: Math.max(pill.width, dots.implicitWidth)
      height: pill.height + Style.space(14) + dots.implicitHeight


      x: Place.x(root.anchor, root.freeX, root.freeY, width, parent.width, root.edgeMargin)
      y: Place.y(root.anchor, root.freeX, root.freeY, height, parent.height, root.edgeMargin)

      Behavior on x { NumberAnimation { duration: cfg.motionBase; easing.type: Easing.OutCubic } }
      Behavior on y { NumberAnimation { duration: cfg.motionBase; easing.type: Easing.OutCubic } }

      opacity: root.opened ? 1 : 0
      scale: root.opened ? 1 : 0.96
      Behavior on opacity { NumberAnimation { duration: cfg.motionFast; easing.type: Easing.OutCubic } }
      Behavior on scale { NumberAnimation { duration: cfg.motionBase; easing.type: Easing.OutCubic } }

      Rectangle {
        id: pill
        anchors.horizontalCenter: parent.horizontalCenter
        // Fixed size, solid fill, no border: a pill that resized per tool name caused the jitter.
        // Long names elide. See docs/DESIGN.md#faces-and-layouts.
        width: Style.space(240)
        height: Style.space(64)
        radius: height / 2
        color: cfg.backgroundColor

        Rectangle {
          id: pillIcon
          anchors.left: parent.left
          anchors.leftMargin: Style.space(12)
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(40); height: width
          radius: width / 2
          color: cfg.accentColor
          Text {
            anchors.centerIn: parent
            text: toast.activeTool ? (toast.activeTool.icon || "") : ""
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            color: cfg.backgroundColor
          }
        }
        // Left-anchored off the icon, not centered as one group with it --
        // centering the pair would itself have moved the icon sideways by
        // however much shorter or longer the next tool's name is, same
        // jitter one layer in.
        Column {
          anchors.left: pillIcon.right
          anchors.leftMargin: Style.space(12)
          anchors.right: parent.right
          anchors.rightMargin: Style.space(12)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(1)
          Text {
            width: parent.width
            elide: Text.ElideRight
            text: toast.activeTool ? (toast.activeTool.name || "") : ""
            textFormat: Text.PlainText  // a tool named "<b>x" must not render as markup
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
            color: cfg.lineColor
          }
          Text {
            width: parent.width
            elide: Text.ElideRight
            visible: text !== ""
            text: {
              var h = toast.activeTool ? toast.activeTool.hint : ""
              return (h && h !== "—") ? ("click: " + h) : ""
            }
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: Util.alpha(cfg.lineColor, 0.55)
          }
        }
      }

      Row {
        id: dots
        anchors.top: pill.bottom
        anchors.topMargin: Style.space(14)
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(7)

        Repeater {
          model: root.tools
          delegate: Rectangle {
            required property int index
            readonly property bool active: index === root.index
            // Fixed size: a dot that widened on selection reflowed the Row (the other half of the
            // jitter). Scale doesn't affect layout.
            width: Style.space(7)
            height: Style.space(7)
            radius: height / 2
            scale: active ? 1.7 : 1
            color: active ? cfg.accentColor : Util.alpha(cfg.lineColor, 0.25)
            Behavior on scale { NumberAnimation { duration: cfg.motionBase; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: cfg.motionBase } }
          }
        }
      }
    }

    // Omarchy: the shell's own OSD grammar (BorderSurface, popups border, popups text, accent bar,
    // fixed-width columns so nothing shifts) carrying the dial's state. Follows the Omarchy theme
    // rather than cfg.colors. See docs/DESIGN.md#faces-and-layouts.
    Item {
      id: omarchy
      visible: root.mode === "live" && root.layout === "omarchy"
      width: omarchyCard.width
      height: omarchyCard.height

      readonly property var activeTool: root.tools.length > root.index ? root.tools[root.index] : null
      readonly property bool hasValue: activeTool !== null && activeTool.value !== undefined
      readonly property int pad: Style.space(16)
      readonly property int gap: Style.space(16)
      readonly property int iconW: Math.round(Style.font.displayLarge * 1.1)
      readonly property int barW: Style.space(142)
      readonly property int readoutW: Math.ceil(readoutMetrics.advanceWidth)
      // Widest tool name, so the card is one size for every tool.
      property int nameW: 0
      function measureNames() {
        var w = 0
        for (var i = 0; i < nameProbe.count; i++) {
          var it = nameProbe.itemAt(i)
          if (it) w = Math.max(w, Math.ceil(it.implicitWidth))
        }
        nameW = Math.min(w, Style.space(190))
      }
      Repeater {
        id: nameProbe
        model: root.tools
        delegate: Text {
          required property var modelData
          visible: false
          text: modelData.name || ""
          textFormat: Text.PlainText  // a tool named "<b>x" must not render as markup
          font.family: Style.font.family
          font.bold: true
          font.pixelSize: Style.font.title
        }
        onItemAdded: omarchy.measureNames()
        onItemRemoved: omarchy.measureNames()
      }
      TextMetrics {
        id: readoutMetrics
        font.family: Style.font.family
        font.bold: true
        font.pixelSize: Style.font.title
        text: "100%"
      }

      // Bottom-centre sits in the OSD's own slot, so the two read as one family.
      readonly property int bottomMargin: Style.space(67)

      x: Place.x(root.anchor, root.freeX, root.freeY, width, parent.width, root.edgeMargin)
      y: Place.y(root.anchor, root.freeX, root.freeY, height, parent.height, root.edgeMargin, bottomMargin)
      Behavior on x { NumberAnimation { duration: cfg.motionBase; easing.type: Easing.OutCubic } }
      Behavior on y { NumberAnimation { duration: cfg.motionBase; easing.type: Easing.OutCubic } }

      opacity: root.opened ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: cfg.motionFast; easing.type: Easing.OutCubic } }

      BorderSurface {
        id: omarchyCard
        width: borderLeft + omarchy.pad + omarchy.iconW + omarchy.gap + omarchy.nameW + omarchy.gap
               + omarchy.barW + omarchy.gap + omarchy.readoutW + omarchy.pad + borderRight
        height: borderTop + omarchy.pad + Style.font.displayLarge + omarchy.pad + borderBottom
        color: Util.alpha(Color.background, 0.97)
        borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
        radius: Style.cornerRadius

        Row {
          anchors.fill: parent
          anchors.topMargin: omarchyCard.borderTop + omarchy.pad
          anchors.rightMargin: omarchyCard.borderRight + omarchy.pad
          anchors.bottomMargin: omarchyCard.borderBottom + omarchy.pad
          anchors.leftMargin: omarchyCard.borderLeft + omarchy.pad
          spacing: omarchy.gap

          Item {
            width: omarchy.iconW
            height: parent.height
            Text {
              textFormat: Text.PlainText
              anchors.centerIn: parent
              text: omarchy.activeTool ? (omarchy.activeTool.icon || "") : ""
              font.family: Style.font.family
              font.pixelSize: Style.font.displayLarge
              color: Color.popups.text
            }
          }

          Text {
            textFormat: Text.PlainText
            width: omarchy.nameW
            anchors.verticalCenter: parent.verticalCenter
            text: omarchy.activeTool ? (omarchy.activeTool.name || "") : ""
            font.family: Style.font.family
            font.bold: true
            font.pixelSize: Style.font.title
            color: Color.popups.text
            elide: Text.ElideRight
            maximumLineCount: 1
          }

          // A value bar when the tool has a live value (Volume, Brightness), exactly as the OSD
          // draws it; otherwise one segment per tool, so position in the list stays visible.
          Item {
            width: omarchy.barW
            height: Math.max(Style.space(6), Style.spacing.sm)
            anchors.verticalCenter: parent.verticalCenter

            Rectangle {
              visible: omarchy.hasValue
              anchors.fill: parent
              color: Util.alpha(Color.popups.text, 0.45)
              Rectangle {
                height: parent.height
                width: parent.width * Math.max(0, Math.min(1, (omarchy.hasValue ? omarchy.activeTool.value : 0) / 100))
                color: Color.accent
                Behavior on width { NumberAnimation { duration: cfg.motionBase; easing.type: Easing.OutCubic } }
              }
            }

            Row {
              visible: !omarchy.hasValue
              anchors.fill: parent
              spacing: Style.space(3)
              Repeater {
                model: root.tools
                delegate: Rectangle {
                  required property int index
                  width: Math.max(1, (omarchy.barW - Style.space(3) * (root.tools.length - 1)) / Math.max(1, root.tools.length))
                  height: parent.height
                  color: index === root.index ? Color.accent : Util.alpha(Color.popups.text, 0.45)
                  Behavior on color { ColorAnimation { duration: cfg.motionBase } }
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            width: omarchy.readoutW
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignRight
            text: omarchy.hasValue ? (omarchy.activeTool.valueText || "") : ((root.index + 1) + "/" + root.tools.length)
            font.family: Style.font.family
            font.bold: true
            font.pixelSize: Style.font.title
            color: Color.popups.text
          }
        }
      }
    }

    // ---------------------------------------------------------- instrument
    // Round by default. The face is square and the backing is either absent, a
    // disc, or the old rectangular plate - nothing about the layout assumes a
    // slab any more, because the selection is called out on the ring itself.
    Item {
      id: plate
      visible: root.mode === "live" && root.layout === "dial"
      // Classic is landscape because its callout column sits beside the dial;
      // the capsule face carries its callout on the rim and so is square.
      readonly property bool classic: cfg.face === "classic"
      width: classic ? Style.space(880) : Style.space(760)
      height: classic ? Style.space(640) : width

      readonly property int edge: Style.space(24)

      // The dial honours `anchor` exactly as the deck does. Bottom is the
      // reachable edge one-handed on a large panel, and centred the face
      // collides with the bar, so this is a reachability requirement rather
      // than a preference.
      x: Place.x(root.anchor, root.freeX, root.freeY, width, parent.width, edge)
      y: Place.y(root.anchor, root.freeX, root.freeY, height, parent.height, edge)

      Behavior on x { NumberAnimation { duration: cfg.motionBase; easing.type: Easing.OutCubic } }
      Behavior on y { NumberAnimation { duration: cfg.motionBase; easing.type: Easing.OutCubic } }

      opacity: root.opened ? 1 : 0
      // Size is a uniform scale about the edge/corner the overlay is anchored to, so
      // a smaller dial stays parked where `anchor` put it rather than shrinking
      // toward the middle of the screen. Layout metrics stay at full size.
      transformOrigin: Place.origin(root.anchor, root.freeX, root.freeY)
      scale: (root.opened ? 1 : 0.97) * cfg.sizeScale
      // Opening fades in; closing is quicker. The fade survives reduced motion (it moves nothing).
      Behavior on opacity { NumberAnimation { duration: root.opened ? cfg.motionFade : cfg.motionExit; easing.type: Easing.BezierSpline; easing.bezierCurve: root.easeOut } }
      Behavior on scale { NumberAnimation { duration: cfg.motionBase; easing.type: Easing.BezierSpline; easing.bezierCurve: root.easeOut } }

      // Backing. `none` is the default; `disc` exists because 0.5px hairlines
      // over arbitrary desktop content can wash out, and it is one config value
      // away rather than a redesign.
      Rectangle {
        visible: cfg.plate === "disc"
        anchors.centerIn: parent
        // Hugs the face's declared content radius plus a margin; faces that declare none fall
        // back to full-square sizing.
        readonly property real contentR: (faceLoader.item && faceLoader.item.contentRadius !== undefined)
                                          ? faceLoader.item.contentRadius
                                          : Math.min(parent.width, parent.height) / 2
        width: (contentR + 28) * 2
        height: width
        radius: width / 2
        // Use only the theme background's RGB and set alpha here: the theme color can carry its own
        // alpha, which lets content read straight through.
        color: Qt.rgba(cfg.backgroundColor.r, cfg.backgroundColor.g,
                       cfg.backgroundColor.b, cfg.plateOpacity)
      }
      Rectangle {
        visible: cfg.plate === "rect"
        anchors.fill: parent
        // The classic plate takes the colour scheme's ground; a light plate is opaque, because
        // desktop text showing through vellum reads as dirt. Other faces keep the theme colours.
        color: plate.classic
               ? Qt.rgba(root.roleGround.r, root.roleGround.g, root.roleGround.b,
                         cfg.colorScheme === "light" ? 1 : cfg.plateOpacity)
               : Qt.rgba(cfg.backgroundColor.r, cfg.backgroundColor.g,
                         cfg.backgroundColor.b, cfg.plateOpacity)
        radius: Style.space(4)
        border.width: 1
        border.color: plate.classic ? root.roleInk(0.16) : Util.alpha(cfg.lineColor, 0.16)
      }

      // Corner registration marks belong to the rectangular plate; a disc has
      // no corners to register.
      Repeater {
        model: (cfg.plate === "rect" && cfg.registrationMarks) ? 4 : 0
        delegate: Item {
          id: mark
          required property int index
          readonly property bool atRight: index === 1 || index === 2
          readonly property bool atBottom: index >= 2
          width: Style.space(18); height: width
          x: atRight ? plate.width - width - Style.space(12) : Style.space(12)
          y: atBottom ? plate.height - height - Style.space(12) : Style.space(12)
          Rectangle {
            width: parent.width; height: 1
            color: plate.classic ? root.roleInk(0.45) : Util.alpha(cfg.lineColor, 0.45)
            y: mark.atBottom ? parent.height - 1 : 0
          }
          Rectangle {
            width: 1; height: parent.height
            color: plate.classic ? root.roleInk(0.45) : Util.alpha(cfg.lineColor, 0.45)
            x: mark.atRight ? parent.width - 1 : 0
          }
        }
      }

      // One contract, two faces. They differ in geometry, in what the rings
      // mean and in where the callout lives, so they are peers behind a
      // Loader rather than branches inside one component - still one plugin,
      // one config and one daemon.
      Loader {
        id: faceLoader
        anchors.fill: plate.classic ? undefined : parent
        // Classic keeps its own landscape placement: the dial is left-aligned
        // and the space to its right carries the leader out to the callout.
        height: plate.classic ? Style.space(580) : 0
        width: plate.classic ? Style.space(880) : 0
        x: plate.classic ? Style.space(30) : 0
        anchors.verticalCenter: plate.classic ? parent.verticalCenter : undefined
        // One contract, four faces now. Unknown/missing names fall back to
        // Classic, same as before this map existed - a bad config value
        // degrades to the safe default rather than an empty Loader.
        readonly property var faceFiles: ({
          "classic": "languages/classic/Classic.qml",
          "capsule": "FaceCapsule.qml",
          "pie": "FacePie.qml",
          "gauge": "FaceGauge.qml"
        })
        // setSource rather than `source:`, because the faces declare cfg as a
        // required property and those must be supplied at construction - a
        // binding applied in onLoaded arrives one frame too late.
        // The language draws the faces it lists (languages/<name>/); any other face falls back to
        // the built-in file.
        // True when the face came from a language folder: those take the host's metrics below.
        property bool languageLook: false
        function reload() {
          var own = root.language && root.language.looks ? root.language.looks[cfg.face] : undefined
          var file = own ? languageLoader.dir + "/" + own : (faceFiles[cfg.face] || faceFiles.classic)
          languageLook = file.indexOf("languages/") === 0
          setSource(file, { "cfg": cfg })
        }
        Component.onCompleted: reload()
        Connections {
          target: cfg
          function onFaceChanged() { faceLoader.reload() }
        }
        Connections {
          target: languageLoader
          function onLoaded() { faceLoader.reload() }
        }
        onLoaded: {
            item.tools = Qt.binding(function () { return root.tools })
            item.index = Qt.binding(function () { return root.index })
            item.position = Qt.binding(function () { return root.position })
            item.live = Qt.binding(function () { return root.live })
            // Language looks take the host's metrics instead of importing the shell's Style.
            if (faceLoader.languageLook) {   // see languages/README.md
              item["language"] = Qt.binding(function () { return root.language })
              item["noteKind"] = Qt.binding(function () { return root.noteKind })
              item["landY"] = Qt.binding(function () { return callout.y - faceLoader.y + calloutTitle.height / 2 })
              item["note"] = Qt.binding(function () { return root.note })
              item["unit"] = Qt.binding(function () { return Style.spaceReal(1) })
              item["fontFamily"] = Qt.binding(function () { return Style.font.family })
              item["type"] = Qt.binding(function () {
                return { caption: Style.font.caption, subtitle: Style.font.subtitle, title: Style.font.title,
                         display: Style.font.display, displayLarge: Style.font.displayLarge }
              })
            }
        }
      }

      // A hint is a revision cloud: the scalloped outline a drawing puts round a change.
      Canvas {
        id: cloud
        readonly property int pad: Style.space(20)
        visible: callout.visible && root.noteKind === "hint"
        x: callout.x - pad; y: callout.y - pad
        width: callout.width + pad * 2; height: callout.height + pad * 2
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onVisibleChanged: if (visible) requestPaint()
        Connections { target: root; function onRoleAccentChanged() { cloud.requestPaint() } }
        renderStrategy: Canvas.Cooperative
        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          var bump = Style.space(16), m = Math.ceil(bump / 2) + 2, w = width - 2 * m, h = height - 2 * m
          ctx.strokeStyle = String(root.roleAccent); ctx.globalAlpha = 0.85; ctx.lineWidth = 1.2
          // walk the rectangle clockwise, one outward half circle per bump, each its own stroke
          // (Qt's canvas draws stray lines between arcs that share a path)
          function side(x0, y0, x1, y1) {
            var len = Math.hypot(x1 - x0, y1 - y0), n = Math.max(1, Math.round(len / bump))
            for (var i = 0; i < n; i++) {
              var ax = x0 + (x1 - x0) * i / n, ay = y0 + (y1 - y0) * i / n
              var mx = x0 + (x1 - x0) * (i + 0.5) / n, my = y0 + (y1 - y0) * (i + 0.5) / n
              var start = Math.atan2(ay - my, ax - mx)
              ctx.beginPath(); ctx.arc(mx, my, len / n / 2, start, start + Math.PI, false); ctx.stroke()
            }
          }
          side(m, m, m + w, m); side(m + w, m, m + w, m + h)
          side(m + w, m + h, m, m + h); side(m, m + h, m, m)
        }
      }

      // Classic callout column. Restored rather than rebuilt - the leader line
      // in FaceClassic runs out to exactly this block, which is what makes that
      // face landscape.
      Column {
        id: callout
        visible: plate.classic && cfg.showCallout && faceLoader.item !== null
        x: faceLoader.x + faceLoader.height + Style.space(56)
        // Its first line sits where the leader lands, clamped so a selection at the top or bottom
        // cannot push it off the plate or onto the title block (the leader then bends to meet it).
        y: {
          var ly = faceLoader.item && faceLoader.item.leaderY !== undefined
                   ? faceLoader.item.leaderY : plate.height / 2
          return Math.max(Style.space(58),
                   Math.min(plate.height - height - Style.space(root.noteKind === "hint" ? 84 : 70),
                            faceLoader.y + ly - calloutTitle.height / 2))
        }
        Behavior on y { NumberAnimation { duration: cfg.motionBase; easing.type: Easing.BezierSpline; easing.bezierCurve: root.easeOut } }
        spacing: Style.space(3)
        // Never wider than the room left on the plate (30-unit right margin): this column
        // used to end 4 units short of the border, so a long click label ran over it.
        width: Math.min(Style.space(210), plate.width - x - Style.space(30))

        // What the callout says, per state: a title, then key/value rows.
        readonly property string stamp: ({ asleep: "ASLEEP", waiting: "NO DIAL" })[root.note.reason] || "CAN'T ACT"
        readonly property var ringTool: root.tools.length > root.index ? root.tools[root.index] : ({})
        readonly property string title: root.noteKind === "turn" ? (root.note.name || "")
                                        : root.noteKind === "hint" ? (root.note.prompt || "")
                                        : root.noteKind === "cant" ? (root.note.title || "")
                                        : (ringTool.name || "")
        readonly property var rows: {
          function click(h) { return (h && h !== "\u2014") ? [{ k: "CLICK", v: h }] : [] }
          if (root.noteKind === "turn") {
            var level = root.note.valueText !== undefined
            return (level ? [{ k: "VALUE", v: root.note.valueText }] : [])
                   .concat(click(root.note.hint), [{ k: "ROTATE", v: level ? "level" : "use" }])
          }
          if (root.noteKind === "hint") return []
          if (root.noteKind === "cant") return [{ k: "STATE", v: stamp, alert: true }, { k: "DO", v: root.note.line || "" }]
          return click(ringTool.hint).concat([{ k: "ROTATE", v: "select" }])
        }

        Text {
          id: calloutTitle
          width: parent.width
          elide: Text.ElideRight
          wrapMode: root.noteKind === "hint" ? Text.WordWrap : Text.NoWrap
          maximumLineCount: 3
          text: callout.title
          textFormat: Text.PlainText  // a tool named "<b>x" must not render as markup
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
          color: root.noteKind === "cant" ? root.roleAlert : root.noteKind === "hint" ? root.roleLine : root.roleAccent
        }
        Rectangle {
          width: Style.space(34); height: 1
          color: root.roleInk(0.35)
        }
        // Key/value rows: the value gets its own column so a long value wraps (two lines, then
        // elides) inside the callout instead of running past it.
        Repeater {
          model: callout.rows
          delegate: Row {
            id: kv
            required property var modelData
            width: callout.width
            spacing: Style.space(8)
            Text {
              width: Style.space(48)
              text: kv.modelData.k
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              color: root.roleInk(0.55)
            }
            Text {
              width: kv.width - Style.space(56)
              text: kv.modelData.v
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              maximumLineCount: 2
              elide: Text.ElideRight
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: !!kv.modelData.alert
              color: kv.modelData.alert ? root.roleAlert : root.roleInk(0.78)
            }
          }
        }
        // A guided step's place in the tour: one square per step, filled up to this one.
        Row {
          visible: root.noteKind === "hint" && root.note.steps > 0
          spacing: Style.space(5)
          topPadding: Style.space(4)
          Repeater {
            model: root.noteKind === "hint" ? (root.note.steps || 0) : 0
            delegate: Rectangle {
              id: dot
              required property int index
              width: Style.space(8); height: width
              color: dot.index < root.note.step ? root.roleAccent : "transparent"
              border.width: dot.index < root.note.step ? 0 : 1
              border.color: root.roleInk(0.5)
            }
          }
        }
      }

      // Title block, as a drawing is labelled: the tool's place on the ring (Sheet 3/8).
      Row {
        visible: plate.classic && cfg.showCallout && (root.tools.length > 0 || root.noteKind !== "")
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.rightMargin: Style.space(30)
        anchors.bottomMargin: Style.space(26)
        spacing: -1   // cells share one border
        Repeater {
          model: ["RE:DIAL", root.noteKind === "cant" ? "STATUS: " + callout.stamp
                             : root.noteKind === "hint" ? (root.note.steps > 0 ? "NOTE " + root.note.step + "/" + root.note.steps : "NOTE")
                             : root.tools.length ? "SHEET " + (root.index + 1) + "/" + root.tools.length : "SHEET"]
          delegate: Rectangle {
            required property string modelData
            width: cellText.implicitWidth + Style.space(24)
            height: Style.space(30)
            color: "transparent"
            border.width: 1
            border.color: root.roleInk(0.4)
            Text {
              id: cellText
              anchors.centerIn: parent
              text: parent.modelData
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1.2
              color: root.roleInk(0.7)
            }
          }
        }
      }
    }
  }
}
