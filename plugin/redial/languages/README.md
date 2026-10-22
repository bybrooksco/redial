# Design languages and looks

re:dial draws its overlay in layers (see `docs/DESIGN.md#design-layers`):

| Layer | Decides | Where |
|---|---|---|
| Your settings | reference lines, size, position, reduced motion, tools | `~/.config/redial/config.json` |
| Colour scheme | fills four colour roles: `ground`, `line`, `accent`, `alert` | `ColourScheme.js` (`color_scheme`: light, dark, theme) |
| Look | one layout: Classic, Capsule, Gauge, ... | one QML file inside a language folder |
| Design language | how things are drawn and how they move | one folder here |
| Host | what the desktop offers | the Omarchy plugin (a standalone host is planned) |
| Engine | dial input, tools, states | `bin/redial-hypr` |

A **design language** is a folder: `languages/<name>/`. **re:dial classic** (`classic/`) is the
standard. You can add a language, or add a look to an existing language, without touching the rest.

## A language folder

```
languages/<name>/
  Language.qml   required: what the language is and which looks it draws
  <Look>.qml     one file per look it draws
```

`Language.qml` is a plain `QtObject`:

```qml
import QtQuick
QtObject {
  readonly property string name: "My language"
  readonly property var looks: ({ "classic": "MyClassic.qml" })   // face name -> file
  readonly property var easeOut: [0.23, 1, 0.32, 1, 1, 1]          // things arriving
  readonly property var easeInOut: [0.77, 0, 0.175, 1, 1, 1]       // things moving on screen
}
```

Select it with `"language": "<name>"` in `config.json`. A folder name is lowercase letters, digits
and dashes. A face your language does not list falls back to the built-in look, and an unknown or
broken language falls back to `classic`, so a half-finished language never blanks the overlay.

## A look

A look is an `Item`. The host sets these on it:

| Property | What it is |
|---|---|
| `cfg` (required) | the settings object: `cfg.roles` holds the four colours as `"#rrggbb"`; `cfg.motionBase`, `cfg.motionFast`, `cfg.motionFade` are durations already zeroed for reduced motion where they move things |
| `language` | the language's `QtObject` (curves, ink strengths) |
| `unit`, `fontFamily`, `type` | the host's spacing unit, font and type sizes (`caption`, `subtitle`, `title`, `display`, `displayLarge`) |
| `tools`, `index` | the tool list (`icon`, `name`, `hint`, optional `value`/`valueText`) and the chosen one |
| `position`, `live` | the continuous hand position in tool units (about 100 updates a second while turning) and whether it is driving |
| `noteKind`, `note` | a state to draw besides the ring: `"turn"` (`name`, `hint`, optional `value` 0-100 and `valueText`), `"hint"` (`prompt`, `gesture`, optional `step`/`steps`), `"cant"` (`reason`, `title`, `line`); `""` is the ring. The host draws the callout text; the look draws the state on the instrument |
| `landY` | where the host placed the callout's first line (-1: at the look's own `leaderY`), so a leader can meet a callout that was clamped |

Rules a look follows:

1. **Colours only through `cfg.roles`.** Then Light, Dark and theme matching all work for free.
2. **Follow the hand directly while `live`.** Interpolating on top only adds lag. Turn or move
   pre-drawn layers by transform; never repaint the whole drawing per detent.
3. **Respect reduced motion.** Use the `cfg.motion*` durations; they already drop movement and
   keep short fades.
4. **No imports from the Omarchy shell** (`qs.Commons`, `qs.Ui`), so the look can run under a
   standalone host. Take spacing and type from the host properties above.
5. **Plain text for names** (`textFormat: Text.PlainText`): a launcher named `<b>x` must not render
   as markup.

Besides the tool ring a look draws three states (`noteKind`): turning (a value), a hint, and "can't
act". re:dial classic draws them in drafting terms: the scale lit to the level with a dimension arc,
a revision cloud round the hint, section hatching for can't act, and the title block naming the
state (`NOTE 2/6`, `STATUS: ASLEEP`). A look that does not draw them yet leaves them to the host's
on-screen display; see the plugin README, "States".

## re:dial classic

A drafting plate. Information lives around the dial and is carried by lines: hairline rings,
construction lines to the plate edge with nodes at their ends, a graduated scale whose lit region is
the selection, a needle that is the hand, and an elbowed leader out to label and value notes.
`reference_lines: false` hides the construction lines, crosshair and registration marks; the rings
and scale stay because they carry information.
