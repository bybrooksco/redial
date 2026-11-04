.pragma library

// re:dial basic's drawing helpers. Angles are degrees, 0 = 3 o'clock, clockwise on screen.

function polar(cx, cy, r, deg) {
  var a = deg * Math.PI / 180
  return [cx + Math.cos(a) * r, cy + Math.sin(a) * r]
}

function litCount(value, n) {
  return Math.round(Math.max(0, Math.min(100, Number(value) || 0)) / 100 * n)
}

// An annular sector between angles a0 and a1 (degrees), as a path on ctx.
function sectorPath(ctx, cx, cy, r0, r1, a0, a1) {
  var s = a0 * Math.PI / 180, e = a1 * Math.PI / 180
  ctx.beginPath(); ctx.arc(cx, cy, r1, s, e, false); ctx.arc(cx, cy, r0, e, s, true); ctx.closePath()
}

// A round-capped arc stroke from a0 to a1 (degrees).
function arc(ctx, cx, cy, r, a0, a1, color, width) {
  if (Math.abs(a1 - a0) < 0.01) return
  ctx.beginPath(); ctx.strokeStyle = color; ctx.lineWidth = width; ctx.lineCap = "round"
  ctx.arc(cx, cy, r, a0 * Math.PI / 180, a1 * Math.PI / 180, a1 < a0); ctx.stroke()
}

// The state sign in a size×size box, soft and filled: a hint's gesture in `accent`, can't act in
// `alert` (asleep: a crescent; otherwise a struck circle).
function sign(ctx, kind, note, size, accent, alert) {
  var c = size / 2, k = size / 40, g = note ? note.gesture : ""
  ctx.save(); ctx.lineWidth = 3.2 * k; ctx.lineCap = "round"; ctx.lineJoin = "round"
  if (kind === "hint") {
    ctx.strokeStyle = accent; ctx.fillStyle = accent
    if (g === "turn") {
      ctx.beginPath(); ctx.arc(c, c, 13 * k, -Math.PI * 0.95, -Math.PI * 0.1); ctx.stroke()
      var ax = c + Math.cos(-Math.PI * 0.1) * 13 * k, ay = c + Math.sin(-Math.PI * 0.1) * 13 * k
      ctx.beginPath(); ctx.moveTo(ax - 7 * k, ay - 1 * k); ctx.lineTo(ax, ay); ctx.lineTo(ax + 1 * k, ay - 7 * k); ctx.stroke()
      ctx.beginPath(); ctx.arc(c, c, 5 * k, 0, Math.PI * 2); ctx.fill()
    } else if (g === "press" || g === "hold") {
      ctx.beginPath(); ctx.arc(c, c, 8 * k, 0, Math.PI * 2); ctx.fill()
      ctx.beginPath(); ctx.arc(c, c, 15 * k, -Math.PI / 2, g === "hold" ? Math.PI * 0.9 : Math.PI * 1.5); ctx.stroke()
    } else {
      ctx.beginPath(); ctx.arc(c, c, 6 * k, 0, Math.PI * 2); ctx.fill()
    }
  } else if (kind === "cant") {
    ctx.strokeStyle = alert; ctx.fillStyle = alert
    if (note && note.reason === "asleep") {
      ctx.beginPath(); ctx.arc(c - 1 * k, c, 14 * k, 0, Math.PI * 2); ctx.fill()
      ctx.globalCompositeOperation = "destination-out"
      ctx.beginPath(); ctx.arc(c + 7 * k, c - 6 * k, 12 * k, 0, Math.PI * 2); ctx.fill()
      ctx.globalCompositeOperation = "source-over"
    } else {
      ctx.beginPath(); ctx.arc(c, c, 14 * k, 0, Math.PI * 2); ctx.stroke()
      ctx.beginPath(); ctx.moveTo(c - 10 * k, c + 10 * k); ctx.lineTo(c + 10 * k, c - 10 * k); ctx.stroke()
    }
  }
  ctx.restore()
}
