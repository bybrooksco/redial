import QtQuick

// A tool's icon on a basic look: the tool's own glyph in the host's font (a Nerd Font), upright,
// in a box centred on (cx, cy) so it sits exactly on its tool's position.
Item {
  id: icon
  required property Item host
  required property int i
  property bool on: false
  property real cx: 0
  property real cy: 0
  property real px: on ? host.iconOnPx : host.iconPx
  width: px * 1.6; height: width
  x: cx - width / 2; y: cy - height / 2
  Text {
    anchors.fill: parent
    horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
    text: icon.host.toolIcon(icon.i)
    textFormat: Text.PlainText
    font.family: icon.host.fontFamily; font.pixelSize: icon.px
    color: icon.on ? icon.host.tone.accent : icon.host.tone.muted
  }
}
