# re:dial basic: the quiet-track design language

Date: 2026-11-06 · Status: approved direction, waiting for Brooks's sign-off on this document ·
Branch: `redial-v1-settings`

Mockups (approved): `~/Work/redial-mockups/2026-11-06/`. `basic-faces-v4.png` shows all ten faces
and `basic-states.png` shows the four states. The `.py` files beside them regenerate the HTML.

## Why

re:dial basic never had a design language. It had a material ("filled shapes on a rimmed plate"),
and each look went off and found its own object: a sundial set in Fraunces, a luggage tag in
Bricolage, a rotary phone with a brass ring, a hand of cards. That produced two kinds of sameness
at once:

- most faces are a rimmed disc with a big name in the middle, so they repeat;
- the themed faces each invent their own world, so the set doesn't hang together.

Classic works because it has one premise, a drafting plate, written down and followed by every look.
Basic needs the same: one premise, written down, before any face is redrawn or added. Faces are
designed from these rules, not the other way round.

(On 2026-11-06 four basic looks drew as an empty plate on the shell. That was a bug, not design:
`basic/Message.qml` typed its `host` as `LookBase`, which Quickshell can't resolve. It's fixed: the
type is now `Item`. It's on the branch but not committed yet.)

## The premise

**Basic is a track, and a marker on it.**

Brooks's brief: the plain, flat Google/Material feel ("generic Android"), not Apple's current
direction, cleaned up into our own version. It's flat, quiet and simple. Of three directions, he
chose **C, the quiet track**: one thin track, an accent segment that marks the choice, and the words
in a small card beside it.

Variety between faces comes from **the shape of the track** (full ring, half arc, 270° arc,
straight bar, vertical bar, a stack of cards). It doesn't come from new objects, materials or fonts.
Each face changes one thing about the track.

## Goals

1. Write basic's rules down (this document, then the `basic` section of
   `plugin/redial/languages/README.md`), so new faces can be designed from them.
2. Redraw all nine basic looks on those rules, matching the approved mockups.
3. Every look draws all four states (ring, turning a level, hint, can't act) in the same way.

## Non-goals

- Classic doesn't change.
- The look contract (`languages/README.md`, "A look"), the daemon and the host don't change.
- No new looks. The "C" reference face in the mockups is the rule set drawn plainly; it isn't a
  tenth look.
- Not the final polish pass on every face. Once the language exists, the faces get their own
  design pass ("then we expand into the dial faces and make them aesthetically pleasing").

## Anti-goals (fail even if it works)

- A face that brings back its own object, material or font: brass, paper, luggage tags, serif hour
  numerals.
- Decoration that carries no information: rims, shadows, outlines, gradients, glints, ambient
  loops.
- The old sameness: a disc with a big name in the middle.
- Initials or text abbreviations standing in for tool icons.
- Icons bunched toward the centre, or not centred on their tool's position (Brooks's feedback on
  round 3).

## The rules

All sizes are in host units (`u()`), measured at the mockups' scale. The builder may tune them a
little on screen, but the rule stays.

### Colour

Colour only comes from `Tones.tones(cfg.roles)`. There are no new colours and no paper set.

| Use | Tone |
|---|---|
| Plate | `ground` |
| Track, unchosen segments, unchosen cards in a stack | `track` |
| The info card | `card` |
| Unchosen icons, card sub-line | `muted` |
| Card name, values | `ink` |
| Chosen segment, chosen icon, level fill, hint sign | `accent` (text on it: `onaccent`) |
| Can't act sign | `alert` |

### Plate

Each look draws a flat plate in `ground`, with a corner radius of about 16 and no rim. That's the
whole background.

### Track

- About 8 thick, in `track`, with round caps.
- It's the one structural line on a face. Pie's hairline spokes (1.2, `track`) are the only other
  lines.

### Marker (the choice)

- An accent segment on the track, the width of one tool's span minus a small margin, with round
  caps.
- **Live:** it follows the hand directly, with no easing (contract rule 2).
- **Stepped:** it eases with `language.easeInOut` over `cfg.motionBase`, the short way round. There's
  no bounce.

### Icons

Icons are always the tool's real glyph (`toolIcon(i)`, a Nerd Font glyph from the tool's `icon`).

- **Placement:** each icon's centre sits a fixed step (about 20) inside the track's centre line, on
  the exact angle (or offset, on straight tracks) of that tool's position.
- **Centring:** glyphs are centred on their visual middle, not their text baseline.
- **Chosen icon:** `accent` and slightly larger (about 16 against 13).
- **Others:** `muted`. Icons don't rotate; they stay upright.

### The card

- **Shape:** a rounded rectangle in `card` (radius about 12, padding about 12, height about 58). It
  grows with the name and is at least about 104 wide.
- **Line 1:** the tool name, about 15, semibold, `ink`.
- **Line 2:** about 10.5, regular, `muted`. In the ring state it reads `position / count · click
  action`, for example `1 / 10 · click mutes`.
- **Where it goes:**
  - to the right of full-ring faces;
  - centred below arc and straight-track faces;
  - built into the layouts: the front card of Deck, and Toast's pill.
- **Same everywhere:** the card is the same component, radius, spacing and type on every look. It's
  the only place words appear, apart from the List's row names.
- `wantsCallout` is `false` for every basic look, because the card replaces the host's callout.

### Type

- One face: Barlow Semi Condensed (already bundled), in two or three sizes.
- Fraunces and Bricolage Grotesque go, along with their font folders and licences.

### States

The four states were approved in the "rules" mockup (`basic-states.png`):

| State | Track and marker | Card |
|---|---|---|
| Ring | Track, accent segment and icons, as above | Name; `position / count · click action` |
| Turning a level | The track fills from its start like a progress bar, in `accent`, to the level. Icons and marker hide. Ring faces show the value large in the middle | Name; "turning" (or the tool's `valueText`) |
| Hint | The track mutes (about 50% opacity); icons hide; an accent sign (the gesture, drawn by `Basic.sign`) sits in the middle | The prompt; its line; step dots for a guided hint |
| Can't act | The track mutes; the `alert` sign (crescent for asleep, struck circle otherwise) sits in the middle | The title (for example "Asleep"); its line (for example "turn to wake") |

There's no hatching and no stamps, and the plate never changes size between states. That replaces
Sundial's half plate. The current `Message.qml` content (sign, prompt, line, step dots) moves into
the card.

## The nine looks

The look keys don't change (`capsule`, `gauge`, `pie`, `sundial`, `tag`, `wheel`, `deck`,
`carousel`, `toast`), so existing configs keep working. `defaultLook` stays `capsule`.

| Look | Track shape | What it changes about the track | Card |
|---|---|---|---|
| **Capsule** (default) | Full ring | Broken into one short capsule per tool; the chosen capsule is the accent | Right |
| **Pie** | Full ring | Continuous track, plus a faint accent wedge (about 14% opacity) from the choice to the centre, and hairline spokes between tools | Right |
| **Finger wheel** | Full ring, slightly smaller | Each icon sits in a small hole (a `ground` disc with a thin `track` ring, the chosen one in `accent`) on the track. The **whole track turns with the hand** under a fixed accent stop mark at about 4 o'clock; let go and it eases onto the chosen hole. Keep the direction fix from `54a2e24`: clockwise turn, clockwise wheel | Right |
| **Sundial** | Half arc (180°, open at the bottom) | The marker is an accent disc (the sun, radius about 9) riding the track instead of a segment | Centred below |
| **Gauge** | 270° arc, gap at the bottom | Plain track and segment; the card sits in the gap | In the gap |
| **List** (key `tag`, was Repair Tag) | Vertical bar on the left | The accent segment at the chosen row; rows show icon and name, with the neighbours fading out; about five rows visible, scrolling with the choice | Right (name; click action) |
| **Carousel** | Straight horizontal bar | Icons above the bar; the accent segment under the chosen one | Centred below |
| **Deck** | A stack of cards, fanned (about ±7° and ±14°) | The cards are the track. Back cards are `track` with no content; the front card is the info card, with the icon at its top-left and a short accent bar at the bottom as the marker | It's the front card |
| **Toast** | A tiny straight bar inside the pill | The card is the whole look: an accent disc holding the icon, the name and click action, and a short track with the accent segment for position | It's the pill |

Settings shows basic's `tag` look as "List". The look labels live in one shared table
(`LookResolve.js`, `tag: "Repair tag"`), and classic's `tag` is still a Repair tag, so the label
can't just be renamed there. Instead, basic's `Language.qml` gets an optional
`labels: ({ tag: "List" })`, and the picker uses a language's own label before the shared one.

## Constraints

- Follow the look contract and its five rules (`languages/README.md`): colours from roles, follow
  the hand while live, reduced motion through `cfg.motion*`, no Omarchy shell imports, plain text
  for names.
- Draw static layers once and turn or move them by transform. Don't repaint per detent. A track
  that fills for a level may repaint when the level changes.
- **Don't type a property as a sibling QML type** (the `LookBase` bug). Use `Item` or `var`. The
  test runner resolves those types but the shell doesn't, so tests won't catch it.
- Keep each look's test properties: `selection`, `litCount`, `stateDrawn`.

## Testing

- Update `tests/qml/tst_basic_*.qml` for the new drawings. Keep coverage of selection following the
  index, live following the position, the release ease (wheel), each state's `stateDrawn`, and the
  level's `litCount`.
- The full QML suite must pass (343 today), plus the Python suite.
- Add a test that fails if any file in `languages/*/` declares a property typed as a sibling look
  type (a grep-style check is enough), so the black-plate bug can't come back.
- Render each look in each state (`tests/qml/render_looks.qml -- basic <look>`, or on screen if the
  headless render keeps failing) and compare against the mockups. Then **check on both machines**
  (Studio and laptop) before committing, because the shell, not the test runner, is the real host.

## Left to the builder

- Exact sizes within the ranges above, tuned on screen at the Studio's and laptop's scales.
- How the List scrolls (its rows can move by transform, like the wheel).
- How the card's text changes between tools (a quick `motionFade` cross-fade, or none).
- How the shared card is factored (a `Card.qml` in `basic/` is the obvious home; `Message.qml`
  folds into it).
- Ordering the work. A sensible order: shared pieces (`LookBase`, the card, the track helpers in
  `Basic.js`, the font removal), then the looks, then the tests and the README.

## Calls I made (for Brooks to check)

1. The `tag` key stays and shows as "List" in basic only (through a per-language label), so old
   configs don't break and classic's Repair tag keeps its name.
2. Barlow Semi Condensed is the one face; Fraunces and Bricolage are removed from the bundle.
3. The plate never changes size between states (Sundial loses its half plate).
4. Every basic look sets `wantsCallout: false`; the card does that job.
5. The "C" reference face isn't added as a tenth look; Capsule stays the default.
6. Turning a level fills the track itself and hides the icons and marker until the turn ends.
