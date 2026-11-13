import QtQuick

// re:dial basic: the Sundial look on the quiet track. A half arc over the top; the sun (an accent
// disc) rides the track to the choice. Everything else is the shared arc (ArcFace.qml).
ArcFace {
  arcFrom: 180; arcSpan: 180
  sun: true
  cx: u(160); cy: u(150); r: u(104)
  cardTop: u(166); signY: u(150) - u(44)
}
