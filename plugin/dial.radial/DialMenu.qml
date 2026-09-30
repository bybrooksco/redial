import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Surface Dial tool dashboard.
//
// A horizontal strip of cards that slots past a fixed centre as the dial turns:
// the active tool sits in the middle at full size, its neighbours flank it
// dimmed, and rotation slides the whole rail. A dial is a 1-D control, so a
// 1-D rail reads more honestly than a ring - and unlike a ring it stays legible
// when parked along a screen edge.
//
// Driven over IPC by ~/.local/bin/surface-dial-hypr:
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

  // One shared window, two tabs (merged 2026-09-26 -- see the Process Book
  // entry for that date for why): "live" is the tool-rail/radial overlay
  // below, driven by the daemon while the dial is actually turning; "settings"
  // is ToolPicker's content, driven by the "dialtools" IPC target (bar widget,
  // SUPER+SHIFT+CTRL+D). `opened` gates the one PanelWindow either mode uses;
  // `mode` picks which content (and which mask/keyboard-focus policy) is live.
  property string mode: "live"
  // True only while the *current* live-mode display is actually being driven
  // by dial rotation right now (the "pos"/"open" paths below set it). Used to
  // scope the inactivity watchdog to the "popped up because you're using the
  // dial" case -- not to a manual peek at the Live tab from Settings, which
  // should sit there until you leave it, same as Settings itself does today.
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
      // anchor/layout are NOT taken from the daemon's payload (found and
      // fixed 2026-09-30): both already have their own live binding to cfg
      // (see `property string anchor: cfg.anchor` / `layout: cfg.layout`
      // above), reading the same config file the daemon also reads. Assigning
      // them here imperatively, even to the "right" value, permanently
      // replaces that binding with a static one -- and the daemon validates
      // "layout" against its own allowed-values tuple, so the moment that
      // tuple was stale (missing carousel/toast) the daemon silently sent
      // "dial" back on every real dial rotation, which then froze root.layout
      // at "dial" forever, no matter what the settings window wrote to
      // config.json afterward. cfg's own binding is the single source of
      // truth; nothing needs to round-trip through the daemon to reach it.
      freeX = p.x === undefined ? -1 : p.x
      freeY = p.y === undefined ? -1 : p.y
      mode = "live"
      liveDriven = true
      opened = true
    } catch (e) {}
  }

  readonly property int n: tools.length

  function setIndex(i) {
    // Each call is its own fire-and-forget IPC round trip (see the daemon's
    // MenuUI.highlight): under fast rotation several can be in flight at
    // once with no ordering guarantee, so a stale one arriving after a
    // fresher pos-socket update must not flicker the highlight backwards.
    // Once the socket is live it alone drives index/position.
    if (i >= 0 && i < tools.length && !live) {
      index = i
      position = i
    }
    watchdog.restart()
  }
  function close() { opened = false; live = false; watchdog.stop() }

  // Safety net only - the daemon owns the real lifecycle. Generous enough that
  // a long deliberate hold never trips it.
  property alias watchdog: watchdog

  Timer {
    id: watchdog
    interval: cfg.watchdogMs
    // Only auto-closes the "popped up because the dial is turning" case --
    // a manual peek at Live from Settings (mode flips, liveDriven doesn't)
    // sits there like Settings itself does, no timeout.
    onTriggered: if (root.mode === "live" && root.liveDriven) root.opened = false
  }

  onOpenedChanged: if (opened) watchdog.restart(); else watchdog.stop()

  // Rotation arrives here, not over IPC: the dial emits ~100 events a second
  // and every omarchy-shell call spawns a process, so the needle could only
  // ever step per detent through that path. A socket makes the motion
  // continuous at no meaningful cost.
  SocketServer {
    active: true
    path: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/dial-radial.sock"

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
  // SUPER+SHIFT+CTRL+D). Moved here from ToolPicker.qml when the two windows
  // merged, 2026-09-26 -- see the Process Book entry for that date.
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
    function ping(): string { return "ok" }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "dial-dashboard"
    WlrLayershell.layer: WlrLayer.Overlay
    // Live: the dial (not the mouse) is the input device, so this must never
    // eat a click meant for the window underneath -- unchanged from before
    // the merge. Settings: real mouse/keyboard input, same as ToolPicker's
    // own window used to be. Both windows used to be fixed one way or the
    // other; now one window switches policy with `mode`.
    WlrLayershell.keyboardFocus: root.mode === "settings" ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
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

      readonly property bool free: root.freeX >= 0 && root.freeY >= 0
      readonly property bool atTop: root.anchor.indexOf("top") === 0
      readonly property bool atBottom: root.anchor.indexOf("bottom") === 0
      readonly property bool atLeft: root.anchor.indexOf("left") === 0 || root.anchor.indexOf("-left") > 0
      readonly property bool atRight: root.anchor.indexOf("right") === 0 || root.anchor.indexOf("-right") > 0

      x: free ? Math.max(root.edgeMargin, Math.min(parent.width - width - root.edgeMargin, root.freeX - width / 2))
              : (atLeft ? root.edgeMargin
                        : (atRight ? parent.width - width - root.edgeMargin
                                   : (parent.width - width) / 2))
      y: free ? Math.max(root.edgeMargin, Math.min(parent.height - height - root.edgeMargin, root.freeY - height / 2))
              : (atTop ? root.edgeMargin
                       : (atBottom ? parent.height - height - root.edgeMargin
                                   : (parent.height - height) / 2))

      Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
      Behavior on y { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

      opacity: root.opened ? 1 : 0
      scale: root.opened ? 1 : 0.96
      Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
      Behavior on scale { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

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
          text: "Surface Dial"
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

              Behavior on opacity { NumberAnimation { duration: 140 } }
              Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
              Behavior on color { ColorAnimation { duration: 140 } }
              Behavior on border.color { ColorAnimation { duration: 140 } }

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
                      Behavior on width { NumberAnimation { duration: 120 } }
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

    // Carousel: a friendlier, lower-detail restyle of the same "row of cards"
    // idea as deck above -- not routed through the face Loader below, same
    // reasoning deck never was: it's not circular, so the dial face contract
    // (angleOf, a square Canvas) would fight it rather than fit it. Sizing is
    // binary (selected = large, everyone else = small) rather than a
    // continuous falloff by distance from selection -- the sum of one large
    // plus (n-1) small card widths is constant regardless of WHICH one is
    // large, so the container's own width/height never has to be
    // recomputed as the selection moves, only individual card sizes.
    Rectangle {
      id: carousel
      visible: root.mode === "live" && root.layout === "carousel"
      readonly property int cardSmall: Style.space(64)
      readonly property int cardLarge: Style.space(104)
      width: row.implicitWidth + Style.space(40)
      height: row.implicitHeight + Style.space(40)
      radius: Style.cornerRadius
      color: cfg.backgroundColor
      border.width: Math.max(1, Style.space(2))
      border.color: Util.alpha(cfg.lineColor, 0.30)

      readonly property bool free: root.freeX >= 0 && root.freeY >= 0
      readonly property bool atTop: root.anchor.indexOf("top") === 0
      readonly property bool atBottom: root.anchor.indexOf("bottom") === 0
      readonly property bool atLeft: root.anchor.indexOf("left") === 0 || root.anchor.indexOf("-left") > 0
      readonly property bool atRight: root.anchor.indexOf("right") === 0 || root.anchor.indexOf("-right") > 0

      x: free ? Math.max(root.edgeMargin, Math.min(parent.width - width - root.edgeMargin, root.freeX - width / 2))
              : (atLeft ? root.edgeMargin
                        : (atRight ? parent.width - width - root.edgeMargin
                                   : (parent.width - width) / 2))
      y: free ? Math.max(root.edgeMargin, Math.min(parent.height - height - root.edgeMargin, root.freeY - height / 2))
              : (atTop ? root.edgeMargin
                       : (atBottom ? parent.height - height - root.edgeMargin
                                   : (parent.height - height) / 2))

      Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
      Behavior on y { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
      Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
      Behavior on height { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

      opacity: root.opened ? 1 : 0
      scale: root.opened ? 1 : 0.96
      Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
      Behavior on scale { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

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
            readonly property bool active: index === root.index
            readonly property real size: active ? carousel.cardLarge : carousel.cardSmall
            width: size; height: size
            radius: Style.space(16)
            color: active ? cfg.accentColor : Util.alpha(cfg.lineColor, 0.08)
            Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
            Behavior on height { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 150 } }

            Column {
              anchors.centerIn: parent
              spacing: Style.space(4)
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: card.modelData.icon || ""
                font.family: Style.font.family
                font.pixelSize: card.active ? Style.font.displayLarge : Style.font.title
                color: card.active ? cfg.backgroundColor : Util.alpha(cfg.lineColor, 0.55)
                Behavior on font.pixelSize { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }
                Behavior on color { ColorAnimation { duration: 130 } }
              }
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: card.active
                text: card.modelData.name || ""
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                color: cfg.backgroundColor
                elide: Text.ElideRight
                width: card.width - Style.space(12)
                horizontalAlignment: Text.AlignHCenter
              }
            }
          }
        }
      }
    }

    // Minimal Toast: the smallest-footprint option -- one pill naming the
    // armed tool (icon, name, click hint) plus a dot-pagination strip, same
    // idea as a phone onboarding screen's "3 of 6". No rings, no needle, no
    // per-tool layout math -- the tradeoff called out when this was scoped
    // is that it gives up the free "how far to the next tool" feedback every
    // other layout/face shows just by being circular or ordered.
    Item {
      id: toast
      visible: root.mode === "live" && root.layout === "toast"
      readonly property var activeTool: root.tools.length > root.index ? root.tools[root.index] : null
      // dots (a Row) never has its own `width` set explicitly, so unlike
      // `pill` (an explicit width) its `width` property itself stays 0 --
      // `implicitWidth`/`implicitHeight` are the ones that actually reflect
      // its content size, same property Carousel's `row` above is read
      // through for exactly this reason.
      width: Math.max(pill.width, dots.implicitWidth)
      height: pill.height + Style.space(14) + dots.implicitHeight

      readonly property bool free: root.freeX >= 0 && root.freeY >= 0
      readonly property bool atTop: root.anchor.indexOf("top") === 0
      readonly property bool atBottom: root.anchor.indexOf("bottom") === 0
      readonly property bool atLeft: root.anchor.indexOf("left") === 0 || root.anchor.indexOf("-left") > 0
      readonly property bool atRight: root.anchor.indexOf("right") === 0 || root.anchor.indexOf("-right") > 0

      x: free ? Math.max(root.edgeMargin, Math.min(parent.width - width - root.edgeMargin, root.freeX - width / 2))
              : (atLeft ? root.edgeMargin
                        : (atRight ? parent.width - width - root.edgeMargin
                                   : (parent.width - width) / 2))
      y: free ? Math.max(root.edgeMargin, Math.min(parent.height - height - root.edgeMargin, root.freeY - height / 2))
              : (atTop ? root.edgeMargin
                       : (atBottom ? parent.height - height - root.edgeMargin
                                   : (parent.height - height) / 2))

      Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
      Behavior on y { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

      opacity: root.opened ? 1 : 0
      scale: root.opened ? 1 : 0.96
      Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
      Behavior on scale { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

      Rectangle {
        id: pill
        anchors.horizontalCenter: parent.horizontalCenter
        width: pillRow.implicitWidth + Style.space(36)
        height: Style.space(64)
        radius: height / 2
        color: cfg.backgroundColor
        border.width: Math.max(1, Style.space(2))
        border.color: Util.alpha(cfg.lineColor, 0.30)

        Row {
          id: pillRow
          anchors.centerIn: parent
          spacing: Style.space(12)

          Rectangle {
            width: Style.space(40); height: width
            radius: width / 2
            color: cfg.accentColor
            anchors.verticalCenter: parent.verticalCenter
            Text {
              anchors.centerIn: parent
              text: toast.activeTool ? (toast.activeTool.icon || "") : ""
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              color: cfg.backgroundColor
            }
          }
          Column {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(1)
            Text {
              text: toast.activeTool ? (toast.activeTool.name || "") : ""
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
              color: cfg.lineColor
            }
            Text {
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
            width: active ? Style.space(16) : Style.space(7)
            height: Style.space(7)
            radius: height / 2
            color: active ? cfg.accentColor : Util.alpha(cfg.lineColor, 0.25)
            Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
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

      readonly property bool free: root.freeX >= 0 && root.freeY >= 0
      readonly property bool atTop: root.anchor.indexOf("top") === 0
      readonly property bool atBottom: root.anchor.indexOf("bottom") === 0
      readonly property bool atLeft: root.anchor.indexOf("left") === 0 || root.anchor.indexOf("-left") > 0
      readonly property bool atRight: root.anchor.indexOf("right") === 0 || root.anchor.indexOf("-right") > 0
      readonly property int edge: Style.space(24)

      // The dial honours `anchor` exactly as the deck does. Bottom is the
      // reachable edge one-handed on a large panel, and centred the face
      // collides with the bar, so this is a reachability requirement rather
      // than a preference.
      x: free ? Math.max(edge, Math.min(parent.width - width - edge, root.freeX - width / 2))
              : (atLeft ? edge
                        : (atRight ? parent.width - width - edge
                                   : (parent.width - width) / 2))
      y: free ? Math.max(edge, Math.min(parent.height - height - edge, root.freeY - height / 2))
              : (atTop ? edge
                       : (atBottom ? parent.height - height - edge
                                   : (parent.height - height) / 2))

      Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
      Behavior on y { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

      opacity: root.opened ? 1 : 0
      // Size is a uniform scale about the edge/corner the overlay is anchored to, so
      // a smaller dial stays parked where `anchor` put it rather than shrinking
      // toward the middle of the screen. Layout metrics stay at full size.
      transformOrigin: free ? Item.Center
        : (atTop ? (atLeft ? Item.TopLeft : (atRight ? Item.TopRight : Item.Top))
        : (atBottom ? (atLeft ? Item.BottomLeft : (atRight ? Item.BottomRight : Item.Bottom))
        : (atLeft ? Item.Left : (atRight ? Item.Right : Item.Center))))
      scale: (root.opened ? 1 : 0.97) * cfg.sizeScale
      Behavior on opacity { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }
      Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

      // Backing. `none` is the default; `disc` exists because 0.5px hairlines
      // over arbitrary desktop content can wash out, and it is one config value
      // away rather than a redesign.
      Rectangle {
        visible: cfg.plate === "disc"
        anchors.centerIn: parent
        // Hugs the face's own content radius (each disc face declares one)
        // plus a small margin, rather than always filling the full square --
        // that used to leave a wide ring of dead backing past the wedges/
        // capsules. Faces that don't declare one (there are none today, but
        // a future one might not need a disc at all) fall back to the old
        // full-square sizing.
        readonly property real contentR: (faceLoader.item && faceLoader.item.contentRadius !== undefined)
                                          ? faceLoader.item.contentRadius
                                          : Math.min(parent.width, parent.height) / 2
        width: (contentR + 28) * 2
        height: width
        radius: width / 2
        // The theme's background can itself carry alpha, so take only its RGB
        // and set the alpha here - otherwise "opacity: 0.97" still lets a
        // terminal read straight through, which measurably it did.
        // The theme's background can itself carry alpha, so take only its RGB
        // and set the alpha here - otherwise the backing lets content read
        // straight through, which is the whole thing it exists to prevent.
        color: Qt.rgba(cfg.backgroundColor.r, cfg.backgroundColor.g,
                       cfg.backgroundColor.b, cfg.plateOpacity)
      }
      Rectangle {
        visible: cfg.plate === "rect"
        anchors.fill: parent
        color: Qt.rgba(cfg.backgroundColor.r, cfg.backgroundColor.g,
                       cfg.backgroundColor.b, cfg.plateOpacity)
        radius: Style.space(4)
        border.width: 1
        border.color: Util.alpha(cfg.lineColor, 0.16)
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
            color: Util.alpha(cfg.lineColor, 0.45)
            y: mark.atBottom ? parent.height - 1 : 0
          }
          Rectangle {
            width: 1; height: parent.height
            color: Util.alpha(cfg.lineColor, 0.45)
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
          "classic": "FaceClassic.qml",
          "capsule": "FaceCapsule.qml",
          "pie": "FacePie.qml",
          "gauge": "FaceGauge.qml"
        })
        // setSource rather than `source:`, because the faces declare cfg as a
        // required property and those must be supplied at construction - a
        // binding applied in onLoaded arrives one frame too late.
        function reload() {
          setSource(faceFiles[cfg.face] || "FaceClassic.qml", { "cfg": cfg })
        }
        Component.onCompleted: reload()
        Connections {
          target: cfg
          function onFaceChanged() { faceLoader.reload() }
        }
        onLoaded: {
            item.tools = Qt.binding(function () { return root.tools })
            item.index = Qt.binding(function () { return root.index })
            item.position = Qt.binding(function () { return root.position })
            item.live = Qt.binding(function () { return root.live })
        }
      }

      // Classic callout column. Restored rather than rebuilt - the leader line
      // in FaceClassic runs out to exactly this block, which is what makes that
      // face landscape.
      Column {
        visible: plate.classic && cfg.showCallout && faceLoader.item !== null
        x: faceLoader.x + faceLoader.height + Style.space(56)
        // Sits where the leader lands, clamped so a selection at the top or
        // bottom cannot push it off the plate.
        y: {
          var ly = faceLoader.item && faceLoader.item.leaderY !== undefined
                   ? faceLoader.item.leaderY : plate.height / 2
          return Math.max(Style.space(58),
                   Math.min(plate.height - height - Style.space(34),
                            faceLoader.y + ly - height / 2))
        }
        Behavior on y { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
        spacing: Style.space(3)
        // Never wider than the room left on the plate (30-unit right margin): this column
        // used to end 4 units short of the border, so a long click label ran over it.
        width: Math.min(Style.space(210), plate.width - x - Style.space(30))

        Text {
          width: parent.width
          elide: Text.ElideRight
          text: root.tools.length > root.index ? (root.tools[root.index].name || "") : ""
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
          color: cfg.accentColor
        }
        Rectangle {
          width: Style.space(34); height: 1
          color: Util.alpha(cfg.lineColor, 0.35)
        }
        // Key/value rows: the value gets its own column so a long click label wraps
        // (two lines, then elides) inside the callout instead of running past it.
        Row {
          id: clickRow
          readonly property string hint: {
            if (!root.tools.length || root.index >= root.tools.length) return ""
            var h = root.tools[root.index].hint
            return (h && h !== "\u2014") ? h : ""
          }
          visible: hint !== ""
          width: parent.width
          spacing: Style.space(8)
          Text {
            width: Style.space(48)
            text: "CLICK"
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: Util.alpha(cfg.lineColor, 0.42)
          }
          Text {
            width: clickRow.width - Style.space(56)
            text: clickRow.hint
            wrapMode: Text.WordWrap
            maximumLineCount: 2
            elide: Text.ElideRight
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: Util.alpha(cfg.lineColor, 0.62)
          }
        }
        Row {
          width: parent.width
          spacing: Style.space(8)
          Text {
            width: Style.space(48)
            text: "ROTATE"
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: Util.alpha(cfg.lineColor, 0.42)
          }
          Text {
            text: "select"
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: Util.alpha(cfg.lineColor, 0.42)
          }
        }
      }
    }
  }
}
