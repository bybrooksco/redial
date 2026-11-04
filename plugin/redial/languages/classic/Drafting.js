.pragma library

// re:dial classic's drawing vocabulary, shared by every look so hatching, clouds, dimensions and
// scales read the same everywhere. Each draw function takes a Canvas 2D context first and a colour
// as "#rrggbb" (from cfg.roles). Angles are degrees, 0 = 3 o'clock, growing clockwise on screen.

function polar(cx, cy, r, deg) {
  var a = deg * Math.PI / 180
  return [cx + Math.cos(a) * r, cy + Math.sin(a) * r]
}

function ink(hex, alpha) {
  var v = parseInt(String(hex).replace("#", "").slice(0, 6), 16)
  return "rgba(" + ((v >> 16) & 255) + "," + ((v >> 8) & 255) + "," + (v & 255) + "," + alpha + ")"
}

// How many of n scale marks a level 0-100 lights.
function litCount(value, n) {
  return Math.round(Math.max(0, Math.min(100, Number(value) || 0)) / 100 * n)
}

function line(ctx, x1, y1, x2, y2, color, alpha, width, dash) {
  ctx.beginPath(); ctx.strokeStyle = ink(color, alpha); ctx.lineWidth = width || 1
  ctx.setLineDash ? ctx.setLineDash(dash || []) : 0
  ctx.moveTo(x1, y1); ctx.lineTo(x2, y2); ctx.stroke()
  if (dash && ctx.setLineDash) ctx.setLineDash([])
}

function ring(ctx, cx, cy, r, color, alpha, width) {
  ctx.beginPath(); ctx.strokeStyle = ink(color, alpha); ctx.lineWidth = width || 1
  ctx.arc(cx, cy, r, 0, Math.PI * 2); ctx.stroke()
}

function node(ctx, x, y, r, color, alpha) {
  ctx.beginPath(); ctx.fillStyle = ink(color, alpha); ctx.arc(x, y, r, 0, Math.PI * 2); ctx.fill()
}

// Section hatching (45°) inside whatever path `clip` traces on ctx: a drawing's mark for a cut face.
function hatch(ctx, clip, w, h, color, alpha, gap) {
  ctx.save(); ctx.beginPath(); clip(ctx); ctx.clip()
  ctx.strokeStyle = ink(color, alpha); ctx.lineWidth = 1.2
  for (var d = -h; d <= w + h; d += gap) {
    ctx.beginPath(); ctx.moveTo(d, h); ctx.lineTo(d + h, 0); ctx.stroke()
  }
  ctx.restore()
}

// A revision cloud round a rectangle: the scalloped outline a drawing puts round a change.
function cloudRectArcs(w, h, bump) {
  return 2 * Math.max(2, Math.round(w / bump)) + 2 * Math.max(1, Math.round(h / bump))
}
function cloudRect(ctx, x, y, w, h, bump, color) {
  var nx = Math.max(2, Math.round(w / bump)), ny = Math.max(1, Math.round(h / bump))
  ctx.strokeStyle = ink(color, 0.85); ctx.lineWidth = 1.2
  function side(x0, y0, x1, y1, n) {
    for (var i = 0; i < n; i++) {   // each scallop its own stroke: Qt's canvas joins arcs with stray lines
      var mx = x0 + (x1 - x0) * (i + 0.5) / n, my = y0 + (y1 - y0) * (i + 0.5) / n
      var r = Math.hypot(x1 - x0, y1 - y0) / n / 2, a = Math.atan2(y1 - y0, x1 - x0)
      ctx.beginPath(); ctx.arc(mx, my, r, a + Math.PI, a, false); ctx.stroke()
    }
  }
  side(x, y, x + w, y, nx); side(x + w, y, x + w, y + h, ny)
  side(x + w, y + h, x, y + h, nx); side(x, y + h, x, y, ny)
}
function cloudCircle(ctx, cx, cy, r, n, color) {
  ctx.strokeStyle = ink(color, 0.85); ctx.lineWidth = 1.2
  var half = Math.PI / n, br = r * Math.sin(half) * 1.05
  for (var i = 0; i < n; i++) {
    var a = -Math.PI / 2 + (i + 0.5) * 2 * half
    ctx.beginPath(); ctx.arc(cx + Math.cos(a) * r, cy + Math.sin(a) * r, br, a - Math.PI / 2, a + Math.PI / 2); ctx.stroke()
  }
}

// A dimension arc from a0 to a1 with a filled arrowhead at each end (k: head length).
function dimArc(ctx, cx, cy, r, a0, a1, color, k) {
  var s = a0 * Math.PI / 180, e = a1 * Math.PI / 180
  if (Math.abs(e - s) < 0.08) return
  ctx.strokeStyle = ink(color, 1); ctx.fillStyle = ink(color, 1); ctx.lineWidth = 1
  ctx.beginPath(); ctx.arc(cx, cy, r, Math.min(s, e), Math.max(s, e)); ctx.stroke()
  function head(at, dir) {
    var px = cx + Math.cos(at) * r, py = cy + Math.sin(at) * r
    var tx = -Math.sin(at) * dir, ty = Math.cos(at) * dir, w = k / 3
    ctx.beginPath(); ctx.moveTo(px, py)
    ctx.lineTo(px - tx * k - ty * w, py - ty * k + tx * w)
    ctx.lineTo(px - tx * k + ty * w, py - ty * k - tx * w)
    ctx.closePath(); ctx.fill()
  }
  head(Math.min(s, e), -1); head(Math.max(s, e), 1)
}

// A graduated scale of n marks from a0 to a1, every majEvery-th one longer and darker.
function scaleBars(ctx, cx, cy, a0, a1, n, rBase, rMin, rMaj, majEvery, color) {
  for (var b = 0; b < n; b++) {
    var a = a0 + b * (a1 - a0) / n, maj = b % majEvery === 0
    var p = polar(cx, cy, rBase, a), q = polar(cx, cy, maj ? rMaj : rMin, a)
    line(ctx, p[0], p[1], q[0], q[1], color, maj ? 0.45 : 0.2, 1)
  }
}
// The same marks in the accent, the first `lit` of them (a level, or a selected region).
function litBars(ctx, cx, cy, a0, a1, n, rBase, rAct, lit, color, width) {
  for (var b = 0; b < Math.min(n, lit); b++) {
    var a = a0 + b * (a1 - a0) / n, p = polar(cx, cy, rBase, a), q = polar(cx, cy, rAct, a)
    line(ctx, p[0], p[1], q[0], q[1], color, 0.95, width || 1.5)
  }
}

// Registration marks in the four corners (part of the reference lines).
function regMarks(ctx, w, h, m, s, color) {
  var corners = [[m, m, 1, 1], [w - m, m, -1, 1], [w - m, h - m, -1, -1], [m, h - m, 1, -1]]
  ctx.strokeStyle = ink(color, 0.45); ctx.lineWidth = 1
  for (var i = 0; i < 4; i++) {
    var c = corners[i]
    ctx.beginPath(); ctx.moveTo(c[0], c[1] + c[3] * s); ctx.lineTo(c[0], c[1]); ctx.lineTo(c[0] + c[2] * s, c[1]); ctx.stroke()
  }
}

// The title block's frame, bottom right: two cells. Its text is QML Text, so it stays plain text.
// Returns the cells' text origins so the look can place its labels: [x0, x1, baselineY].
function titleBlock(ctx, w, h, u, color) {
  var x = w - u * 222, y = h - u * 46, bw = u * 206, bh = u * 30
  ctx.strokeStyle = ink(color, 0.4); ctx.lineWidth = 1
  ctx.strokeRect(x, y, bw, bh)
  ctx.beginPath(); ctx.moveTo(w - u * 140, y); ctx.lineTo(w - u * 140, y + bh); ctx.stroke()
  return [w - u * 212, w - u * 130, h - u * 26]
}
