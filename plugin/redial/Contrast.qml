import QtQuick

// WCAG contrast arithmetic, so text colours can be made legible on whatever theme is active.
// Pure functions of colours; imports nothing from the shell so it can be tested on its own
// (tests/qml/tst_contrast.qml). Colours are Qt colours (r, g, b in 0..1).
QtObject {
  readonly property real minimum: 4.5   // WCAG AA for normal-size text

  function _lin(c) { return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4) }
  function luminance(c) { return 0.2126 * _lin(c.r) + 0.7152 * _lin(c.g) + 0.0722 * _lin(c.b) }
  function ratio(a, b) {
    var x = luminance(a), y = luminance(b)
    return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05)
  }
  // `fg` laid over `bg` at opacity t, as an opaque colour.
  function mix(fg, bg, t) {
    return Qt.rgba(fg.r * t + bg.r * (1 - t), fg.g * t + bg.g * (1 - t), fg.b * t + bg.b * (1 - t), 1)
  }

  // `fg` at about `alpha` opacity over `bg`, made no fainter than needed to reach `minimum`.
  function soft(fg, bg, alpha) {
    var t = Math.max(0, Math.min(1, alpha))
    while (t < 1 && ratio(mix(fg, bg, t), bg) < minimum) t += 0.02
    return mix(fg, bg, Math.min(t, 1))
  }

  // A brand colour used as text on `bg`: unchanged if legible, otherwise pulled toward `fg`.
  function asText(color, fg, bg) {
    var t = 0
    while (t < 1 && ratio(mix(fg, color, t), bg) < minimum) t += 0.02
    return mix(fg, color, Math.min(t, 1))
  }

  // Text on top of a solid `fill`: the first of the usual colours that is legible, else the
  // better of black and white.
  function onFill(fill, preferred, alternate) {
    if (ratio(preferred, fill) >= minimum) return preferred
    if (ratio(alternate, fill) >= minimum) return alternate
    var black = Qt.rgba(0, 0, 0, 1), white = Qt.rgba(1, 1, 1, 1)
    return ratio(black, fill) >= ratio(white, fill) ? black : white
  }
}
