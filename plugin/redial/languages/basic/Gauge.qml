import QtQuick

// re:dial basic: the Gauge look on the quiet track. A 270° arc open at the bottom; an accent segment
// marks the choice and the card sits in the gap. Everything else is the shared arc (ArcFace.qml).
ArcFace {
  arcFrom: 135; arcSpan: 270
  cx: u(160); cy: u(100); r: u(74)
  cardTop: u(164); signY: u(100)
}
