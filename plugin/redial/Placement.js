.pragma library

// Where an overlay sits on the screen: one helper for every look (it was pasted five times).
//
// anchor: center | top | bottom | left | right | top-left | top-right | bottom-left | bottom-right.
// A free point (freeX and freeY both >= 0) wins over the anchor and is clamped to the margins.
// `bottomMargin`, when given, replaces `margin` on the bottom edge only (Omarchy's OSD slot).

function edges(anchor) {
  var a = String(anchor || "")
  return {
    top: a.indexOf("top") === 0,
    bottom: a.indexOf("bottom") === 0,
    left: a.indexOf("left") === 0 || a.indexOf("-left") > 0,
    right: a.indexOf("right") === 0 || a.indexOf("-right") > 0
  }
}

function isFree(freeX, freeY) { return freeX >= 0 && freeY >= 0 }

function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

function x(anchor, freeX, freeY, w, pw, margin) {
  if (isFree(freeX, freeY)) return clamp(freeX - w / 2, margin, pw - w - margin)
  var e = edges(anchor)
  return e.left ? margin : (e.right ? pw - w - margin : (pw - w) / 2)
}

function y(anchor, freeX, freeY, h, ph, margin, bottomMargin) {
  if (isFree(freeX, freeY)) return clamp(freeY - h / 2, margin, ph - h - margin)
  var e = edges(anchor)
  var b = bottomMargin === undefined ? margin : bottomMargin
  return e.top ? margin : (e.bottom ? ph - h - b : (ph - h) / 2)
}

// The Item.TransformOrigin for an anchor, so scaling keeps the overlay parked on its edge.
// Values match QtQuick's enum: TopLeft 0, Top 1, TopRight 2, Left 3, Center 4, Right 5,
// BottomLeft 6, Bottom 7, BottomRight 8.
function origin(anchor, freeX, freeY) {
  if (isFree(freeX, freeY)) return 4
  var e = edges(anchor)
  var row = e.top ? 0 : (e.bottom ? 2 : 1)
  var col = e.left ? 0 : (e.right ? 2 : 1)
  return row * 3 + col
}
