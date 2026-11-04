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

A **design language** is a folder: `languages/<name>/`. Two ship: **re:dial classic** (`classic/`,
the standard, ten looks) and **re:dial basic** (`basic/`, nine looks; a working name). You can add a
language, or add a look to an existing language, without touching the rest.

## A language folder

```
languages/<name>/
  Language.qml   required: what the language is and which looks it draws
  <Look>.qml     one file per look it draws
  fonts/         optional: faces it bundles, each with its licence
```

`Language.qml` is a plain `QtObject`:

```qml
import QtQuick
QtObject {
  readonly property string name: "My language"
  readonly property var looks: ({ "classic": "MyClassic.qml" })   // look name -> file
  readonly property string defaultLook: "classic"                  // drawn for a look it lacks
  readonly property int lookCount: Object.keys(looks).length       // the library's "looks" tag
  readonly property var easeOut: [0.23, 1, 0.32, 1, 1, 1]          // things arriving
  readonly property var easeInOut: [0.77, 0, 0.175, 1, 1, 1]       // things moving on screen
}
```

Select it with `"language": "<name>"` in `config.json` (or Design language on the Look page). A
folder name is lowercase letters, digits and dashes. Look names are `classic`, `capsule`, `gauge`,
`pie`, `sundial`, `tag`, `wheel` (faces) and `deck`, `carousel`, `toast` (layouts).

**A language offers only the looks it ships.** Nothing is borrowed from another language: Settings
lists only the language's own looks (plus `omarchy`, the desktop's OSD), and a look the config names
but the language lacks draws its `defaultLook`. A look that fails to load draws the default too, and
a failed default draws classic's Classic, so a half-finished language never blanks the overlay. An
unknown or broken language falls back to `classic`. `lookCount` is how many looks a language ships;
a language library lists it as a tag, so people know what they are getting.

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

The look declares these back to the host:

| Property | What it is |
|---|---|
| `plateSize` | its size, `Qt.size(w, h)` in host units. It may change with the state (Sundial's half plate). The host sizes the overlay to it and draws no backing of its own: the look draws its plate |
| `wantsCallout` | `true` to have the host draw the callout column (label and value notes) beside it |
| `calloutX` | where that column starts, in look units |
| `leaderY` | where the look's leader arrives, so the host can line the callout up with it (it then sets `landY`) |
| `kind` | `"face"` (drawn in the dial layout) or `"layout"` (a layout of its own: deck, carousel, toast) |

And these for its tests (`tests/qml/tst_<language>_<look>.qml`): `selection` (the Item that shows
the choice), `litCount` (how much of its meter a level lights) and `stateDrawn` (`ring`, `turn`,
`hint` or `cant`, which is what it is drawing). Shared fixtures are in `tests/qml/lookkit/`, and
`tests/qml/render_looks.qml -- <language> <look> [dark]` writes each state as a PNG.

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

Besides the tool ring every look draws three states (`noteKind`): turning (a value), a hint, and
"can't act". re:dial classic draws them in drafting terms: the scale lit to the level with a
dimension arc, a revision cloud round the hint, section hatching for can't act, and the title block
naming the state (`NOTE 2/6`, `STATUS: ASLEEP`). re:dial basic draws them inside each look's own
frame: a meter (lit capsules, a filled pill, punched holes, the sun up its arc), a message with the
gesture's sign, and for can't act a sign or stamp. Only the `omarchy` layout leaves them to the
desktop's OSD; see the plugin README, "States".

## re:dial classic

A drafting plate. Information lives around the dial and is carried by lines: hairline rings,
construction lines to the plate edge with nodes at their ends, a graduated scale whose lit region is
the selection, a needle that is the hand, and an elbowed leader out to label and value notes.
`reference_lines: false` hides the construction lines, crosshair and registration marks; the rings
and scale stay because they carry information.

## re:dial basic

Soft and filled (round two of the 2026-10-22 mockups; the name is provisional). Every look sits on a
plate of its own with rounded shapes, tones mixed from the four roles (`Tones.js`: rim, surface,
card, track, muted, soft, ink, plus a paper set for the tag and the wheel's card), and readable type.
It ships nine looks and no Classic; `defaultLook` is `capsule`. Three faces are bundled under the
SIL Open Font License (each folder in `basic/fonts/` has its licence): Barlow Semi Condensed for
every look, Fraunces for the Sundial, Bricolage Grotesque for the Repair tag. They are static
weights cut to the Latin range to keep the installer small; a name outside it, or a face that fails
to load, falls back to the host's font.
