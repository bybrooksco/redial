# re:dial basic quiet-track language: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redraw all nine re:dial basic looks on the approved "quiet track" rules: one thin track,
an accent marker, real icons, and one shared card.

**Architecture:** Shared pieces go in `plugin/redial/languages/basic/`:
- `LookBase.qml` gains the track and icon metrics.
- A new `Card.qml` replaces `Message.qml`.
- New `Icon.qml` and `Sign.qml` items.

Each look keeps its file and look key, and is rewritten to draw its track on a `Canvas` with
`Basic.js` helpers. It places `Icon`s and one `Card`. Fonts and the paper tone set go last, once
no look uses them.

**Tech Stack:** Qt 6 QML (Quickshell plugin), JavaScript `.pragma library` helpers, QtTest
(`qmltestrunner`), Python `unittest` for the daemon suite.

**Spec:** `docs/superpowers/specs/2026-11-06-redial-basic-language-design.md`. Read it first; the
look table and the rules are not repeated here. Mockups: `~/Work/redial-mockups/2026-11-06/`
(`basic-faces-v4.png`, `basic-states.png`; the geometry below comes from `faces4.py`).

## Global Constraints

- Colours come only from `Tones.tones(cfg.roles)`: `ground` plate, `track` track, `card` card, `muted` unchosen icons and the sub-line, `ink` name, `accent` marker/chosen/level/hint sign, `onaccent` text on accent, `alert` for the can't-act sign.
- Plate: a flat `ground` rectangle, radius `u(16)`, no rim, no shadow, no outline. Its size never changes between states.
- Track: `u(8)` wide, `track` tone, round caps. The only other lines are Pie's spokes (`u(1.2)`, `track`).
- Icons: `toolIcon(i)` in the host's `fontFamily` (the Nerd Font), upright. The centre sits `iconGap` (`u(20)`) inside the track's centre line, on the tool's exact angle or offset. Chosen: `accent` at `u(16)`; others `muted` at `u(13)`.
- Card: `card` tone, radius `u(12)`, padding `u(12)`, at least `u(104)` wide, height `u(58)` (it grows for hint step dots). Name `u(15)` DemiBold `ink`; sub-line `u(10.5)` `muted`. Barlow Semi Condensed (`language.faceStandard`).
- Every basic look: `wantsCallout: false`. Look keys don't change. `defaultLook: "capsule"`.
- Motion: live follows `position` directly. Stepped changes ease with `easeInOut` over `cfg.motionBase`, the short way round. No bounce, no ambient loops.
- Never type a property as a QML file from the same folder (`required property LookBase host` drew empty plates on the shell). Use `Item` or `var`.
- Contract rules in `plugin/redial/languages/README.md` ("A look") still hold: plain text for names, no `qs.*` imports, and `cfg.motion*` for reduced motion.

## Review Focus

1. **Long tool names** (launcher names, "Window Size"): the card grows to `maxWidth` (`u(200)`), then elides, and never covers the track. *Test: Task 2.*
2. **Odd tool counts** (1, 2, 12): no division by zero, no overlapping icons. At 12 tools, neighbouring icon centres are at least `iconOnPx` apart. *Test: Task 3.*
3. **Empty tool list** (`tools = []`): every look loads and draws the ring state without a QML error. *Test: one per look task, `test_empty_tools_loads`.*
4. **Reduced motion** (`cfg.motionBase = 0`): the marker lands on the new tool at once, with no easing left running. *Test: Task 3 (ring marker) and Task 4 (wheel release).*
5. **Wrap-around** (last tool to first): the marker moves one step forward, not all the way back. *Test: Task 3.*

---

### Task 1: Shared foundation (metrics, Icon, Sign, label override, type guard)

**Files:**
- Modify: `plugin/redial/languages/basic/LookBase.qml`
- Create: `plugin/redial/languages/basic/Icon.qml`, `plugin/redial/languages/basic/Sign.qml`
- Modify: `plugin/redial/languages/basic/Basic.js` (add `bar`)
- Modify: `plugin/redial/languages/basic/Language.qml` (add `labels`)
- Modify: `plugin/redial/LookResolve.js:57-60` (`option`), `plugin/redial/ToolPicker.qml:600,612` (callers)
- Test: `tests/qml/tst_basic_language.qml`, `tests/qml/tst_lookresolve.qml`, `tests/test_dial.py`

**Interfaces:**
- Produces:
  - **LookBase.qml:**
    - `readonly property real trackW: u(8)`, `iconGap: u(20)`, `iconPx: u(13)`, `iconOnPx: u(16)`, `plateRadius: u(16)`
    - `readonly property real trackInk` (0.5 for hint and can't act, else 1)
    - `readonly property bool iconsShown` (`stateDrawn === "ring"`)
    - `function cardLine(i)`: `"<i+1> / <n>"`, plus `" · <hint>"` when the tool has a hint
  - **Icon.qml:** `Item { required property Item host; required property int i; property bool on; property real cx; property real cy; property real px }`. It's an `Item` box centred on `(cx, cy)` holding a centred `Text`. `px` defaults to `on ? host.iconOnPx : host.iconPx`.
  - **Sign.qml:** `Canvas { required property Item host; property real size: host.u(36) }`. It draws `Basic.sign(ctx, host.noteKind, host.note, size, accent, alert)` and repaints when `host.noteKind` or `host.note` changes.
  - **Basic.js:** `bar(ctx, x0, y0, x1, y1, color, width)` draws a round-capped straight line.
  - **Language.qml:** `readonly property var labels: ({ tag: "List" })`.
  - **LookResolve.js:** `option(key, language)` uses `language.labels[key]` when present, else `LABELS[key]`.

- [ ] **Step 1: Write the failing tests**

In `tst_basic_language.qml`, add:
```qml
function test_labels_rename_tag_only_here() { compare(lang.labels.tag, "List") }
function test_icon_box_is_centred_on_its_point() {
  var look = createTemporaryObject(capsuleComponent, top)   // add Component { id: capsuleComponent; Capsule { cfg: fakeCfg; language: lang } }
  look.tools = Kit.eight
  var ic = createTemporaryObject(iconComponent, look,   // add Component { id: iconComponent; Icon {} }
                                  { host: look, i: 0, on: true, cx: 50, cy: 40 })
  compare(ic.x + ic.width / 2, 50); compare(ic.y + ic.height / 2, 40)
  compare(ic.px, look.iconOnPx)
}
function test_card_line() {
  var look = createTemporaryObject(capsuleComponent, top)
  look.tools = [{ name: "Volume", icon: "x", hint: "mute" }, { name: "Scroll", icon: "y" }]
  compare(look.cardLine(0), "1 / 2 · mute"); compare(look.cardLine(1), "2 / 2")
}
```
In `tst_lookresolve.qml`, add:
```qml
function test_option_prefers_the_language_label() {
  compare(LookResolve.option("tag", { labels: { tag: "List" } }).label, "List")
  compare(LookResolve.option("tag", null).label, "Repair tag")
  compare(LookResolve.option("tag", {}).label, "Repair tag")
}
```
In `tests/test_dial.py`, add a `LanguageFiles` test case,
`test_no_property_typed_as_a_sibling_qml_file`. For each `plugin/redial/languages/*/` folder, it
collects that folder's `*.qml` basenames and asserts that no `.qml` in the folder matches
`r"\bproperty\s+(%s)\b" % "|".join(names)`.

- [ ] **Step 2: Run them and check they fail**

Run: `QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml 2>&1 | grep -E "^(FAIL|Totals)"` and `python3 tests/test_dial.py LanguageFiles -v`.
Expected: the new QML tests FAIL (no `labels`, `Icon`, `cardLine`); the Python guard PASSES (Message.qml is already fixed). Check the guard actually works: temporarily put `LookBase` back in `Message.qml` line 8, see the guard FAIL, then revert.

- [ ] **Step 3: Implement the interfaces above**

- `ToolPicker.qml:600` becomes `.map(function (k) { return LookResolve.option(k, pickedLanguage.item) })`, because `.map(LookResolve.option)` would pass the array index as `language`.
- Line 612 passes `lang` as the second argument.

- [ ] **Step 4: Run the full suites**

Run: both commands from Step 2, plus `python3 tests/test_dial.py`.
Expected: QML `Totals: 347 passed, 0 failed`; Python all OK.

- [ ] **Step 5: Commit**

`git commit -m "re:dial basic: shared track metrics, Icon, Sign, per-language look labels, type guard"`

---

### Task 2: The shared Card (replaces Message)

**Files:**
- Create: `plugin/redial/languages/basic/Card.qml`
- Delete: `plugin/redial/languages/basic/Message.qml` (in Task 9, after its last user is gone)
- Test: `tests/qml/tst_basic_card.qml` (new)

**Interfaces:**
- Consumes: the LookBase metrics, `cardLine`, and `Sign` from Task 1.
- Produces: `Card.qml`:
  ```
  Item {
    required property Item host
    property bool showSign: false        // straight tracks and layouts: the sign sits at the card's left
    property real maxWidth: host.u(200)
    property string ringLine: host.cardLine(host.chosen)   // the ring state's line 2; the List overrides it
    readonly property string title       // line 1
    readonly property string line        // line 2
    implicitWidth, implicitHeight
  }
  ```

What the card says in each state:

| State | `title` | `line` |
|---|---|---|
| ring | `toolName(chosen)` | `ringLine` |
| turn | `note.name`, or `toolName(chosen)` | `host.valueText` |
| hint | `note.prompt` | `note.line`, or `""` |
| cant | `note.title` | `note.line`, or `""` |

Step dots (an accent dot for `step`, `muted` for the rest) show under `line` when `note.steps > 1`.

- [ ] **Step 1: Write the failing tests** (`tst_basic_card.qml`, the same scaffold as `tst_basic_capsule.qml`, host = a Capsule)

```qml
function test_ring_text() { /* tools Kit.eight, index 2 */ compare(card.title, Kit.eight[2].name); compare(card.line, host.cardLine(2)) }
function test_turn_text() { host.noteKind = "turn"; host.note = { name: "Volume", value: 42, valueText: "42%" }; compare(card.title, "Volume"); compare(card.line, "42%") }
function test_hint_text_and_dots() { host.noteKind = "hint"; host.note = { prompt: "Turn the dial", line: "to set volume", step: 2, steps: 5 }; compare(card.title, "Turn the dial"); compare(card.line, "to set volume"); compare(card.dotCount, 5) }
function test_cant_text() { host.noteKind = "cant"; host.note = { reason: "asleep", title: "Asleep", line: "turn to wake" }; compare(card.title, "Asleep") }
function test_long_name_elides_at_max_width() { host.tools = [{ name: "An extremely long launcher name that goes on", icon: "x" }]; verify(card.width <= card.maxWidth + 0.5) }
function test_min_width() { host.tools = [{ name: "A", icon: "x" }]; compare(card.width, host.u(104)) }
```
Expose `readonly property int dotCount` (0 when no dots) for the test.

- [ ] **Step 2: Run and check they fail.** Run the QML suite. Expected: `tst_basic_card` FAILS (Card isn't defined).
- [ ] **Step 3: Implement `Card.qml`** from the Global Constraints values. Text uses `textFormat: Text.PlainText` and `elide: Text.ElideRight`. Width is `Math.min(maxWidth, Math.max(u(104), content + 2*padding))`.
- [ ] **Step 4: Run the QML suite.** Expected: all pass.
- [ ] **Step 5: Commit**: `"re:dial basic: one shared card for every look and state"`

---

### Task 3: Capsule and Pie (full-ring faces)

**Files:**
- Rewrite: `plugin/redial/languages/basic/Capsule.qml`, `plugin/redial/languages/basic/Pie.qml`
- Test: rewrite `tests/qml/tst_basic_capsule.qml`, `tests/qml/tst_basic_pie.qml`

**Interfaces:**
- Consumes: Task 1 metrics, `Icon`, `Sign`, `Basic.arc`; the Task 2 `Card`.

**Geometry (host units):**
- Plate `Qt.size(340, 248)`. Ring centre `(112, 124)`, `R = 90`. Card left edge `x = 220`, centred vertically.
- Span `seg = 360 / n`; tool `i` sits at `-90 + i*seg`.
- **Capsule:** the track is `n` arcs, each `seg - 12°` (6° margin each side). The chosen arc is `accent`.
- **Pie:**
  - one full `track` ring, plus an accent arc of `seg - 6°` on the chosen span;
  - a filled wedge from the centre to `R - trackW/2 - 1` over the chosen span, `accent` at opacity 0.14;
  - spokes on each span boundary from `r = 22` to the same outer radius.
- **Marker:** an `Item` named `selection`, centred at the ring centre, with `rotation` = the marker angle + 90. Live: `position * seg`. Stepped: `steppedDeg`, the short way round, eased. Copy the `_lastIndex` pattern from the current `Gauge.qml`. The accent arc is drawn inside `selection`, and the Pie wedge too.
- **Icons:** `Icon` at `polar(centre, R - iconGap, -90 + i*seg)`; `on` = `i === chosen`; visible while `iconsShown`.
- **States:**
  - **turn:** an accent arc from -90 to `-90 + level*3.6` on the track; `valueText` in the centre (`u(26)` DemiBold `ink`); `litCount` = `litOf(100)`.
  - **hint / cant:** the track at `trackInk`; a `Sign` centred on the ring; the marker hidden.

- [ ] **Step 1: Write the failing tests**, both files. Keep `test_listed_by_the_language`. Replace the rest:

```qml
function test_plate_size() { compare(look.plateSize.width, 340); compare(look.plateSize.height, 248); compare(look.wantsCallout, false); compare(look.kind, "face") }
function test_selection_follows_index() { look.index = 3; tryCompare(look.selection, "rotation", 3 * 45, 1000) }
function test_live_follows_position_directly() { look.live = true; look.position = 2.5; compare(look.selection.rotation, 2.5 * 45) }
function test_wraps_the_short_way() { look.index = 7; tryCompare(look.selection, "rotation", 315, 1000); look.index = 0; tryCompare(look.selection, "rotation", 360, 1000) }
function test_reduced_motion_lands_at_once() { fakeCfg.motionBase = 0; look.index = 2; compare(look.selection.rotation, 90) }
function test_icons_sit_one_gap_inside_the_track_on_their_angle() {
  // for each Icon child i: centre distance from (112,124) == 90 - 20 (±0.6) and atan2 angle == -90 + i*45 (±0.5°)
}
function test_twelve_tools_do_not_crowd() { look.tools = Kit.twelve(); /* neighbouring icon centres >= look.iconOnPx apart */ }
function test_empty_tools_loads() { look.tools = []; compare(look.stateDrawn, "ring") }
function test_turn_fills_the_track() { look.noteKind = "turn"; look.note = { name: "Volume", value: 42, valueText: "42%" }; compare(look.litCount, 42); compare(look.stateDrawn, "turn") }
function test_hint_and_cant_mute_the_track() { look.noteKind = "hint"; look.note = { prompt: "Press", gesture: "press" }; compare(look.trackInk, 0.5); compare(look.stateDrawn, "hint") }
```
Pie also gets `test_wedge_turns_with_the_marker`: the wedge is a child of `selection`.

- [ ] **Step 2: Run and check they fail.** Expected: the new assertions FAIL against the old drawings.
- [ ] **Step 3: Rewrite both looks** to the geometry above. Each draws the static track once on a `Canvas`. The marker and wedge are pre-drawn inside `selection` and turned by `rotation`, not repainted per detent.
- [ ] **Step 4: Run the QML suite.** Expected: all pass.
- [ ] **Step 5: Commit**: `"re:dial basic: Capsule and Pie on the quiet track"`

---

### Task 4: Finger wheel

**Files:** Rewrite `plugin/redial/languages/basic/Wheel.qml`; update `tests/qml/tst_basic_wheel.qml`.

**Interfaces:** Consumes Tasks 1-2. Keep the turning maths exactly as in `54a2e24`: `_holes`, the `releaseT` ease, `wheelDeg = live ? position*step : …`, holes at `stop - i*step`, `turned`. Only the drawing changes.

**Geometry:**
- Plate `Qt.size(340, 248)`, centre `(112, 124)`.
- Track `r = 76`, `track` tone. It turns: it's inside the `wheel` Item (`selection`, `rotation: wheelDeg`).
- Holes: radius `u(13)` at `polar(r, stop - i*step)`, filled `ground`, with a `track` ring `u(1.5)` (chosen: `accent`, `u(2.5)`). Each holds an upright `Icon` at `u(13)` (the counter-rotation is already in the current file).
- Fixed stop mark, outside the wheel: an accent line `u(5)` wide, from `r + 17` to `r + 27` at angle `stop + 15`.
- Card at `x = 220`.
- **States:**
  - **turn:** the holes hide; the track fills like Task 3.
  - **hint / cant:** the wheel rests at 0 (existing behaviour) at `trackInk`, with a `Sign` in the centre.

- [ ] **Step 1: Update tests.**
  - Keep the four rotation tests from `54a2e24` as they are.
  - Change `test_plate_size` to 340×248 with `wantsCallout` false.
  - Add `test_empty_tools_loads`.
  - Add `test_reduced_motion_release_snaps`: `motionBase = 0`, live → index 3, position 2.6, live false → `selection.rotation === 135` at once.
  - Add `test_stop_mark_does_not_turn`: the stop isn't a descendant of `selection`.
- [ ] **Step 2: Run and check they fail.** Expected: plate size, empty tools and stop-mark tests FAIL.
- [ ] **Step 3: Rewrite the drawing** to the geometry above.
- [ ] **Step 4: Run the QML suite.** Expected: all pass, including the 54a2e24 direction tests unchanged.
- [ ] **Step 5: Commit**: `"re:dial basic: Finger wheel on the quiet track"`

---

### Task 5: Sundial and Gauge (arc faces)

**Files:** Rewrite `Sundial.qml`, `Gauge.qml`; update `tst_basic_sundial.qml`, `tst_basic_gauge.qml`.

**Geometry:**
- **Sundial:**
  - plate `Qt.size(320, 250)` in every state (the half plate goes);
  - arc centre `(160, 150)`, `r = 104`, from 180° to 360°;
  - tool `i` at `180 + i * 180/(n-1)` (or 270 when `n === 1`).
  - The marker is the sun, an accent disc of radius `u(9)` on the track at the chosen angle; it's `selection`, positioned by angle.
  - Card centred at `y = 166`.
  - **turn:** the track fills from 180°.
- **Gauge:**
  - plate `Qt.size(320, 250)`; centre `(160, 100)`, `r = 74`, from 135° to 405°;
  - tool `i` at `135 + i * 270/(n-1)`;
  - the accent arc is ±9° around the chosen angle;
  - card centred at `y = 164`, in the gap;
  - **turn:** the track fills from 135°.
- **Both:**
  - icons at `r - iconGap` on each tool's angle;
  - **hint / cant:** a `Sign` at the arc centre, track at `trackInk`.
- Remove Fraunces use (`faceSundial`) from Sundial.

- [ ] **Step 1: Update tests.**
  - plate sizes, including `test_plate_never_changes_with_state` for Sundial: compare `plateSize` in ring, turn, hint and cant;
  - `test_selection_follows_index`: the sun or arc centre angle;
  - `test_live_follows_position_directly`;
  - `test_one_tool_sits_at_the_top`;
  - `test_icons_on_their_angles` (the same check as Task 3);
  - `test_empty_tools_loads`;
  - `test_turn_fills`: `litCount` 42.
- [ ] **Step 2: Run and check they fail.**
- [ ] **Step 3: Rewrite both looks.**
- [ ] **Step 4: Run the QML suite.** Expected: all pass.
- [ ] **Step 5: Commit**: `"re:dial basic: Sundial and Gauge on the quiet track"`

---

### Task 6: List (key `tag`, was Repair tag)

**Files:** Rewrite `plugin/redial/languages/basic/Tag.qml`; rewrite `tests/qml/tst_basic_tag.qml`.

**Geometry:**
- Plate `Qt.size(340, 248)`.
- Vertical track at `x = 34`, from `y = 28` to `y = 220`.
- Five rows are visible, pitch `38.4`. The chosen tool's row is the middle (third) row. The rows are an `Item` (`selection`'s sibling list) whose `y` moves by transform with `position` while live, eased while stepped.
- The marker (`selection`): an accent segment `u(24)` long on the track at the middle row; it's fixed.
- Each row:
  - `Icon` at `x = 34 + iconGap + 4`;
  - the name at `x = 34 + iconGap + 20`: chosen `u(13)` DemiBold `ink`, others `u(12)` `muted`;
  - outer rows at opacity 0.5.
- Card at `x = 220`. Its line is the click hint only: set `Card.ringLine` to the chosen tool's `hint`.
- **turn:** the track fills top to bottom.
- **hint / cant:** the track at `trackInk`, rows hidden, `Card.showSign: true`.
- Drop the paper tones, Bricolage, the string and the swing.

- [ ] **Step 1: Write tests:**
  - `test_listed_by_the_language`;
  - `test_plate_size`;
  - `test_chosen_row_is_the_middle_row`: index 3, then the visible middle row's name is `Kit.eight[3].name`;
  - `test_live_scrolls_directly`;
  - `test_wraps_the_short_way`;
  - `test_empty_tools_loads`;
  - `test_turn_fills`;
  - `test_hint_puts_the_sign_in_the_card`.
- [ ] **Step 2: Run and check they fail.**
- [ ] **Step 3: Rewrite the look.**
- [ ] **Step 4: Run the QML suite.** Expected: all pass.
- [ ] **Step 5: Commit**: `"re:dial basic: the List look replaces the Repair tag"`

---

### Task 7: Carousel and Toast (straight tracks)

**Files:** Rewrite `Carousel.qml`, `Toast.qml`; update `tst_basic_carousel.qml`, `tst_basic_toast.qml`.

**Geometry:**
- **Carousel:**
  - plate `Qt.size(340, 230)`;
  - track at `y = 96` from `x = 26` to `314`, pitch `288 / n`;
  - tool `i` sits at slot `(i - chosen + floor(n/2)) mod n`, so the chosen tool is centred. Slots shift by transform with `position`.
  - Icons at `y = 96 - iconGap - 2`;
  - marker: an accent segment `u(22)` long under the centre slot (`selection`);
  - card centred at `y = 140`;
  - **turn:** the track fills left to right; icons hide.
  - **hint / cant:** `Card.showSign: true`.
- **Toast:**
  - plate `Qt.size(300, 72)` in every state;
  - pill `244 × 56`, radius 28, `card` tone; it's the Card's frame, so it uses Card for the text with the disc as its sign slot;
  - accent disc radius `u(18)` with the chosen icon in `onaccent` (in hint/cant the disc shows the `Sign` instead);
  - mini track `u(66)` long, `u(5)` wide, at the pill's right;
  - marker length `max(u(8), u(66)/n)` at offset `chosen/n` (`selection`);
  - **turn:** the mini track fills.

- [ ] **Step 1: Update tests.** For each look:
  - plate size (and Toast's `test_plate_never_changes_with_state`);
  - `test_selection_follows_index`;
  - `test_live_follows_position_directly`;
  - `test_empty_tools_loads`;
  - `test_turn_fills`.
  Carousel also gets `test_chosen_icon_is_centred` (x = 170 ± 0.6).
- [ ] **Step 2: Run and check they fail.**
- [ ] **Step 3: Rewrite both looks.**
- [ ] **Step 4: Run the QML suite.** Expected: all pass.
- [ ] **Step 5: Commit**: `"re:dial basic: Carousel and Toast on the quiet track"`

---

### Task 8: Deck

**Files:** Rewrite `plugin/redial/languages/basic/Deck.qml`; update `tests/qml/tst_basic_deck.qml`.

**Geometry:**
- Plate `Qt.size(320, 230)`.
- The fan is fixed, which is my call: the old sliding hand goes, because the front card now carries everything.
- Four back cards (`108 × 130`, radius 12, `track` at opacity 0.75) rotate −14°, −7°, 7° and 14° about `(160, 330)`.
- The front card (`selection`, 0°) is a tall `Card` variant:
  - `Icon` (`on`, `u(18)`) at the top-left `(22, 24)`;
  - the title;
  - the line split onto two lines (position, then hint);
  - an accent bar `28 × 5` at the bottom as the marker.
  - Its text changes cross-fade over `cfg.motionFade`.
- **turn:** the accent bar becomes a meter across the card's inner width (`litCount` = `litOf(100)`).
- **hint / cant:** `showSign`, with the back cards at `trackInk`.

- [ ] **Step 1: Update tests:**
  - `test_plate_size`;
  - `test_front_card_names_the_choice`;
  - `test_back_cards_do_not_move`: their rotations don't change after index changes;
  - `test_empty_tools_loads`;
  - `test_turn_meter`: `litCount` 42;
  - `test_cant_dims_the_backs`.
- [ ] **Step 2: Run and check they fail.**
- [ ] **Step 3: Rewrite the look.**
- [ ] **Step 4: Run the QML suite.** Expected: all pass.
- [ ] **Step 5: Commit**: `"re:dial basic: Deck, the front card is the card"`

---

### Task 9: Remove what no look uses; docs; render and on-device check

**Files:**
- Delete: `plugin/redial/languages/basic/Message.qml`, `plugin/redial/languages/basic/fonts/fraunces/`, `plugin/redial/languages/basic/fonts/bricolage/`
- Modify: `Language.qml` (drop `_fraunces`, `_bricolage*`, `faceSundial`, `faceTag`), `LookBase.qml` (drop `paperTone`, `ringInk`), `Tones.js` (drop `paper`, plus `rim` and `surface` if `grep` finds no user)
- Modify: `plugin/redial/languages/README.md` (rewrite the "re:dial basic" section and basic's sentence in the states paragraph, from the spec's rules), `CHANGELOG.md` (an entry under the unreleased heading)
- Test: `tests/qml/tst_basic_language.qml` (drop the Fraunces/paper tests; `test_bundled_faces_load` checks only `faceStandard`)

- [ ] **Step 1:** `grep -rn "paperTone\|faceSundial\|faceTag\|Message {\|ringInk\|Tones.paper" plugin/ tests/`. Expected: no hits outside the lines being deleted.
- [ ] **Step 2:** Delete and edit as listed. Run both suites. Expected: QML all pass; Python all OK, including the Task 1 type guard.
- [ ] **Step 3: Render check.** Run `QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qml tests/qml/render_looks.qml -- basic <look>` for all nine. If the headless render still writes nothing (it didn't on 2026-11-06), skip to Step 4. Compare with `~/Work/redial-mockups/2026-11-06/basic-faces-v4.png` and `basic-states.png`.
- [ ] **Step 4: On-device check (Brooks).**
  1. Install on the Studio (`printf "y\n" | ./install.sh`, then `omarchy-restart-shell`).
  2. Commit and push, then pull and install on the laptop.
  3. Brooks switches to re:dial basic and steps through all nine looks in ring, turn, hint and can't act.
  4. On both machines, `journalctl --user --since -10min | grep languages/basic` must show no QML warnings.
- [ ] **Step 5: Commit** (before Step 4's push): `"re:dial basic: drop the paper tones and per-look fonts; document the quiet-track language"`
