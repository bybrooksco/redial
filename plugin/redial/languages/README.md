# Design languages and looks

re:dial draws its overlay in layers (see `docs/DESIGN.md#design-layers`):

| Layer | Decides | Where |
|---|---|---|
| Your settings | reference lines, size, position, reduced motion, tools | `~/.config/redial/config.json` |
| Colour scheme | fills four colour roles: `ground`, `line`, `accent`, `alert` | `ColourScheme.js` (`color_scheme`: light, dark, theme) |
| Look | one layout: Classic, Capsule, Gauge, ... | one QML file inside a language folder |
| Design language | how things are drawn and how they move | one folder here |
| Host | what the desktop offers | the Omarchy plugin (a standalone host is planned) |
| Engine | dial input, tools, states | `redial/` (the daemon) |

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

## Your languages: install, remove, check

Languages you add live in `${XDG_DATA_HOME:-~/.local/share}/redial/languages/<name>/`, so updates
leave them alone. Install them with **Install from folder** on the Look page or
`redial-language install FOLDER`; remove with the card's Remove or `redial-language remove NAME`.
Only languages the installer's `index.json` lists load: a folder copied in by hand is ignored, and
a config naming one draws classic. `classic` and `basic` are reserved.

Every language needs a `manifest.json`:

```json
{ "name": "My language", "author": "You", "licence": "MIT", "version": "1.0.0", "redial": "1",
  "description": "One line.", "previews": ["previews/capsule-ring.png"] }
```

`previews` are pictures (`.png`, `.svg`) inside the folder; Settings shows them, never the
language's code, until you pick it. From a re:dial checkout, `redial-language preview FOLDER`
renders every look's states into `previews/` with `tests/qml/render_looks.qml`.

**What the checker refuses** (`redial-language check FOLDER` runs it alone): imports other than
`QtQuick`, `QtQuick.Shapes`, `QtQuick.Effects` and the language's own files; `XMLHttpRequest`,
`WebSocket`, `Worker`, `Loader`, `Qt.createQmlObject`, `Qt.createComponent`, `Qt.include`,
`Qt.openUrlExternally`, `eval`, `Function(`, `import(`, `Qt[` and `globalThis`; strings naming a
link (`https:`, `file:`, ...), `..` or an absolute path; symlinks, hidden or executable files, any
file that isn't `.qml .js .json .png .svg .ttf .otf .txt .md` or `LICENSE*`; over 20 MB. Comments
don't count. A language is QML, code that runs in your desktop shell: the checker catches mistakes
and the obvious tricks, not a determined author. Only languages in the reviewed gallery (planned)
have been read by a person.

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
naming the state (`NOTE 2/6`, `STATUS: ASLEEP`). re:dial basic draws them on its track: a level
fills the track like a progress bar; a hint or can't act mutes the track and shows the sign, with
the words in the look's card. Only the `omarchy` layout leaves them to the
desktop's OSD; see the plugin README, "States".

## re:dial classic

A drafting plate. Information lives around the dial and is carried by lines: hairline rings,
construction lines to the plate edge with nodes at their ends, a graduated scale whose lit region is
the selection, a needle that is the hand, and an elbowed leader out to label and value notes.
`reference_lines: false` hides the construction lines, crosshair and registration marks; the rings
and scale stay because they carry information.

## re:dial basic

The quiet track (working name; spec: `docs/superpowers/specs/2026-11-06-redial-basic-language-design.md`).
Every look is **a track, and a marker on it**: one thin track (8 units, the `track` tone, round
caps), an accent segment marking the choice, each tool's own icon one step (20 units) inside the
track on that tool's exact position, and one shared card (`Card.qml`) for the words. The looks
differ only in the track's shape: a segmented ring (Capsule, the default), a ring with a wedge
(Pie), a ring of holes that turns under a fixed stop (Finger wheel), a half arc with a sun
(Sundial), a 270° arc (Gauge), a vertical bar (List; its key stays `tag`, and the language's
`labels` names it), a straight bar (Carousel), a fan of cards (Deck) and a pill (Toast).

Flat theme tones only (`Tones.js`: ground, card, track, muted, ink, accent, onaccent, alert): no
rims, shadows, outlines or per-look materials. One bundled face, Barlow Semi Condensed, under the
SIL Open Font License (`basic/fonts/barlow/`), cut to the Latin range; a face that fails to load
falls back to the host's font. A look's plate keeps its size in every state. Shared pieces:
`LookBase.qml` (contract properties and the track metrics), `Card.qml`, `Icon.qml`, `Sign.qml`, and
the two track bases `RingFace.qml` (Capsule, Pie) and `ArcFace.qml` (Sundial, Gauge).
