# re:dial Phase 3: two design languages, every look — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two selectable design languages, each a self-contained set of looks: **re:dial classic** (the drafting language, 10 looks: Classic, Capsule, Gauge, Pie, Sundial, Repair tag, Finger wheel, Deck, Carousel, Toast) and **re:dial basic** (working name for the mockups' "Round two (soft)", 9 looks: the same minus Classic). Every look draws the turning / hint / can't-act states itself. Switching language in Settings switches the whole set.

**Architecture:** Builds on the Phase 1 contract in `plugin/redial/languages/README.md`: a language is a folder with `Language.qml` and one QML file per look. **A language offers only the looks it ships; nothing is borrowed from another language** (Brooks, 2026-11-04: full customization, and a future language library will tag each language with its look count). This plan (a) lets languages draw the three non-dial layouts (deck, carousel, toast) as looks too, (b) makes the Settings look picker show only the chosen language's looks, (c) adds the looks, and (d) retires the daemon's "only Classic draws states" gate and the built-in look files.

**Tech Stack:** Qt 6 Quick (QML, `Canvas` for drawing, as `languages/classic/Classic.qml` does), JS helpers (`.pragma library`), QtTest via `/usr/lib/qt6/bin/qmltestrunner`, Python `unittest` for the daemon.

**Spec:** the approved mockups, `~/Work/redial-mockups/2026-10-22/` on the Studio (private artifact "re:dial Classic Mockups", https://claude.ai/artifact/UCmhNdTazfnfAbpKB6m2KB). Serve with `python3 -m http.server` in that folder and open `index.html`.
- re:dial classic looks: `draft.js` (`DCL`, `DTOAST`, `DCAP`, `DGAU`, `DPIE`, `DDECK`, `DCAR`) and `classic3.js` (`DSUN`, `DTAG`, `DWHL`); their `NOTES.*_draft` strings are the design intent per look.
- re:dial basic looks: `looks.js` (`CAP`, `GAU`, `PIE`, `DECK`, `CAR`, `TOAST`) and `index.html` (`SUN`, `TAG`, `WHL`); `NOTES.*` strings are the design intent.
- Each mockup object's `mount()` is the geometry and `frame()` the motion. Port the geometry (sizes in px become `u(px)` on the host unit) and the motion rules; do not port the mockup's page chrome, input simulation, or HTML.
- Session decisions: vault `Session Notes/Session Log (2026-10-22) - re-dial classic design language, Phase 1.md`, "Design decisions".

## Global Constraints

- Colours only through `cfg.roles` (`ground`, `line`, `accent`, `alert`); no hex literals in a look. re:dial basic's extra tones (`surface`, `rim`, `track`, `muted`, `soft`) are derived from the four roles in `languages/basic/Tones.js`, never hard-coded.
- Imports: `QtQuick` (and `QtQuick.Shapes` only if a look cannot be drawn with `Canvas`). No `qs.*` / Omarchy shell imports.
- While `live`, follow `position` directly; no easing layered on the hand. Exceptions the mockups specify, and only these: Sundial's sun lags (time constant 60 ms), Gauge needle spring (k = 600, damping 28), Deck / Carousel smoothing (40 ms / 35 ms).
- Reduced motion: use `cfg.motionBase`, `cfg.motionFast`, `cfg.motionFade` only; they are already zero where motion must stop.
- Turn or move pre-drawn layers by transform; never repaint a whole drawing per detent.
- Tool names render with `textFormat: Text.PlainText`.
- `reference_lines: false` hides construction lines, crosshair and registration marks only (rings and scales stay).
- Out of scope (Phase 4, do not build): Omarchy-edition extras — ambient loops (sun corona, tag sway, brass glint), Hyprland blur, theme-switch reveal, plate draw-in animation. The Portable motion in the mockups is the target.
- Settings keys stay backward compatible: an existing `config.json` with `face: classic|capsule|pie|gauge` and `layout: dial|deck|carousel|toast|omarchy` must keep working.
- The `omarchy` layout (Omarchy's native OSD box) is not a language look; leave it as is.
- Never touch pen input handling. The pen must stay fully usable on screen.

## Review Focus

1. A look the config names but the language does not ship (after switching language, or a hand-edited config) must draw the language's `defaultLook`; a look file that fails to load must draw the language's `defaultLook`, and if that fails too, `languages/classic/Classic.qml` (crash guard only, not borrowing). Never a blank overlay. Test in Task 1.
2. Fewer than 8 tools (1, 2, 3) and more (12): geometry derived from `n` must not divide by zero or overlap labels. Each look's test runs with 1 and 12 tools.
3. Switching `language` or `face` while the ring is open must reload without a stale note or a stuck needle. Test in Task 1.
4. A turn note without `value` (tools with no level) must draw the ring state, not a 0% scale. Each look's test covers `note: { name: "Tabs" }`.
5. Tool names with markup (`<b>x`) and long names (`Workspaces and windows`) render as plain text and stay inside the plate. Each look's test covers one.

---

## File Structure

- Create `plugin/redial/LookResolve.js`: pure function picking the file for a look. One job, testable without QML scenes.
- Modify `plugin/redial/DialMenu.qml`: one Loader path for all language looks (dial faces and the deck/carousel/toast layouts); callout shown for any look whose `wantsCallout` is true; delete the inline deck, carousel and toast implementations once classic draws them (Task 11).
- Create `plugin/redial/languages/classic/{Capsule,Gauge,Pie,Toast,Deck,Carousel,Sundial,Tag,Wheel}.qml`; modify `languages/classic/Language.qml` (`looks` map).
- Create `plugin/redial/languages/classic/Drafting.js`: the shared drafting drawing helpers ported from `draft.js` (`L`, `C`, `NODE`, registration marks, hatch, arrowheads, revision cloud, scale bars, title block) as `Canvas` 2D-context functions. One place, so every classic look draws hatching and clouds the same way.
- Create `plugin/redial/languages/basic/{Language.qml,Tones.js,Capsule.qml,Gauge.qml,Pie.qml,Toast.qml,Deck.qml,Carousel.qml,Sundial.qml,Tag.qml,Wheel.qml}` and `languages/basic/fonts/` (Fraunces, Bricolage Grotesque, Barlow Semi Condensed, all SIL OFL 1.1, with their `OFL.txt`).
- Modify `plugin/redial/schema.json`, `Settings.qml` (face validation), `ToolPicker.qml` (style list at :521), `StylePresets.js` (`dialUses`): new faces `sundial`, `tag`, `wheel`; language option `basic`.
- Modify `bin/redial-hypr` `overlay_draws_states()` (:1894) and its tests in `tests/test_dial.py`.
- Tests: `tests/qml/tst_lookresolve.qml`, one `tests/qml/tst_<language>_<look>.qml` per look, `tests/qml/render_looks.qml` (offscreen PNG renders for visual review).
- Docs: `plugin/redial/languages/README.md` (contract additions), `docs/DESIGN.md`, `CHANGELOG.md`.

## Contract additions (decided here; every look task relies on them)

A look may declare, besides the Phase 1 properties in `languages/README.md`:
- `readonly property bool wantsCallout` — default `false`. `true`: the host draws its callout column (title + key/value rows, revision cloud for hints) to the right of the look, as for Classic, and the look provides `leaderY` and consumes `landY`.
- `readonly property size plateSize` — the look's natural size in host units at `unit = 1` (e.g. Classic `Qt.size(880, 580)`, Toast `Qt.size(400, 60)`). The host sizes and anchors the Loader from it instead of per-face branches.
- `readonly property string kind` — `"face"` (drawn in the dial layout) or `"layout"` (deck, carousel, toast: replaces the layout).

`Language.looks` keys are face names (`classic`, `capsule`, `pie`, `gauge`, `sundial`, `tag`, `wheel`) and layout names (`deck`, `carousel`, `toast`).

---

### Task 1: Look resolver and one host path for language looks

**Files:**
- Create: `plugin/redial/LookResolve.js`
- Modify: `plugin/redial/DialMenu.qml:914-975` (faceLoader), `:287`, `:452`, `:558` (layout visibility)
- Test: `tests/qml/tst_lookresolve.qml`

**Interfaces:**
- Produces: `LookResolve.resolve(languageDir: string, language: {looks, defaultLook}|null, name: string, failed: bool) -> string` (a file path). `name` in `language.looks` and not `failed` → `languageDir + "/" + looks[name]`; otherwise `languageDir + "/" + looks[defaultLook]`; `language` null, or `failed` on the default look itself → `"languages/classic/Classic.qml"`.
- Produces: `LookResolve.offered(language) -> [string]` — the keys of `language.looks` in their declared order, plus `"omarchy"` last (the desktop's OSD layout is not a language look and is always offered).
- Produces on every `Language.qml`: `readonly property string defaultLook` (classic: `"classic"`, basic: `"capsule"`) and `readonly property int lookCount: Object.keys(looks).length` (the library tag; derived so it cannot drift).
- Produces: `LookResolve.lookName(layout: string, face: string) -> string` — `face` when `layout === "dial"`, else `layout` for `deck|carousel|toast`, else `""` (omarchy: no language look).

- [ ] **Step 1: Write the failing tests** in `tst_lookresolve.qml`: `test_own_look_wins` (basic lists `pie` → `languages/basic/Pie.qml`); `test_look_the_language_lacks_draws_its_default` (basic, name `classic` → `languages/basic/Capsule.qml`, never a classic file); `test_failed_look_draws_the_default`; `test_failed_default_is_the_crash_guard` (→ `languages/classic/Classic.qml`); `test_null_language_is_the_crash_guard`; `test_offered_is_the_languages_own_looks_plus_omarchy` (basic: 9 keys + `omarchy`, no `classic`); `test_lookName` for all five layouts.
- [ ] **Step 2: Run** `QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml/tst_lookresolve.qml` — expected FAIL (no LookResolve.js).
- [ ] **Step 3: Implement** `LookResolve.js` (`.pragma library`). In `DialMenu.qml`, `faceLoader.reload()` calls `resolve()` with `lookName(cfg.layout, cfg.face)`; on `Loader.Error` it reloads once with `failed = true`. Until Task 11 deletes them, the inline deck/carousel/toast blocks get `visible: root.layout === "<x>" && !faceLoader.item` so they show only while classic does not ship that look yet. Size and anchor the loader from `item.plateSize` when present; keep the existing classic branch values when absent. Show the callout when `faceLoader.item && faceLoader.item.wantsCallout` (replaces `plate.classic && ...` at :1015).
- [ ] **Step 4: Run all QML tests**, expected PASS: `QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml`
- [ ] **Step 5: Commit** `re:dial: one host path for language looks, classic fallback`

DialMenu needs the Omarchy shell and cannot run headless, so Review Focus item 3 (switching language or face with the ring open) is a manual check in Task 13, Step 4.

### Task 2: Settings for new faces and the basic language

**Files:** `plugin/redial/schema.json:7,12`, `Settings.qml:44,203-214`, `ToolPicker.qml:521-532`, `StylePresets.js:50-56`; tests `tests/test_settings.py`, `tests/qml/tst_stylepresets.qml`.

**Interfaces:** Produces face keys `sundial` (label "Sundial"), `tag` ("Repair tag"), `wheel` ("Finger wheel"); language option `basic` (label "re:dial basic", a working name: the folder and label get renamed before release, so keep the string in `Language.qml` `name` and the schema label only). `Settings.face` accepts the seven face keys, anything else → `classic`. Plate for the new faces: `"rect"` (they draw their own plate, like Classic). The ToolPicker style list (:521) shows only `LookResolve.offered(language)`: switching language re-filters it, and if the saved look is not offered the picker writes the language's `defaultLook` to config (one write, so the overlay and the picker agree).

- [ ] **Step 1: Failing tests:** `tst_lookresolve.qml` `test_lookCount_matches_looks` (classic 10, basic 9, once both exist: assert `lookCount === Object.keys(looks).length` now); `tst_stylepresets.qml` `test_new_faces_use_callout_controls` (`dialUses("callout", "sundial")` true; `"tag"`, `"wheel"` true); `test_settings.py` `test_new_face_names_survive_validation` (each of the three) and `test_unknown_face_is_classic`.
- [ ] **Step 2: Run** both suites, expected FAIL.
- [ ] **Step 3: Implement** the schema options, validation, ToolPicker style entries (`{ key: "sundial", label: "Sundial", layout: "dial", face: "sundial" }`, same shape for tag and wheel), and `dialUses` (new faces behave like `classic` for weight, density, callout, constructionLines).
- [ ] **Step 4: Run** `python3 -m unittest discover -s tests` and the QML suite, expected OK.
- [ ] **Step 5: Commit** `re:dial: Sundial, Repair tag and Finger wheel faces; basic language option`

### Task 3: Drafting helpers

**Files:** Create `plugin/redial/languages/classic/Drafting.js`; test `tests/qml/tst_drafting.qml`.

**Interfaces:** Produces, each taking a Canvas 2D `ctx` first: `hatch(ctx, path2dFn, color, alpha, gap)`, `cloudRect(ctx, x, y, w, h, bump, color)`, `cloudCircle(ctx, cx, cy, r, n, color)`, `arrowArc(ctx, cx, cy, r, a0, a1, color)` (dimension arc with both arrowheads), `regMarks(ctx, w, h, m, s, color)`, `scaleBars(ctx, cx, cy, a0, a1, n, rBase, rMin, rMaj, majEvery, color, majAlpha, minAlpha)`, `titleBlock(ctx, w, h, unit, color)` (frame only; text is a QML `Text` so it stays PlainText). Plus pure `polar(cx, cy, r, deg) -> [x, y]` and `ink(color, alpha) -> string` (`rgba(...)`). Geometry and alphas come from `draft.js` lines 26-61.

- [ ] **Step 1: Failing tests:** `test_polar_quarter_turns` (0°, 90°, 180° on r = 10); `test_cloud_bump_count` (a 100×40 rect with bump 10 makes `2*round(100/20)+2*round(40/20)` arcs: expose `cloudRectArcs(w, h, bump) -> int` for this); `test_ink_alpha_string`.
- [ ] **Step 2: Run**, expected FAIL. **Step 3: Implement.** **Step 4: Run**, PASS.
- [ ] **Step 5: Refactor** `languages/classic/Classic.qml`'s own hatch / cloud / scale drawing to call `Drafting.js` where it duplicates it; `tst_classiclook.qml` must still pass unchanged.
- [ ] **Step 6: Commit** `re:dial classic: shared drafting helpers`

### Tasks 4-10: re:dial classic looks (one task each)

Each look task has the same shape. **Files:** create `plugin/redial/languages/classic/<Look>.qml`, add its key to `languages/classic/Language.qml` `looks`, create `tests/qml/tst_classic_<look>.qml`, add the look to `tests/qml/render_looks.qml`.

**Interfaces:** Consumes the Phase 1 look properties (`cfg`, `language`, `unit`, `fontFamily`, `type`, `tools`, `index`, `position`, `live`, `noteKind`, `note`, `landY`), the contract additions above, and `Drafting.js`. Produces one look file; nothing else depends on it.

Steps for each:
- [ ] **Step 1: Write the failing test** `tst_classic_<look>.qml`, modelled on `tests/qml/tst_classiclook.qml` (same `fakeCfg`, same eight tools). Required test functions, with the look's own values:
  - `test_listed_by_the_language` — `lang.looks["<key>"] === "<Look>.qml"`.
  - `test_plate_size` — `look.plateSize` equals the size in the table below.
  - `test_selection_follows_index` — set `index = 3`; the look's selection item (named `selection`, see table) is at the angle / offset for tool 3.
  - `test_live_follows_position_directly` — `live = true; position = 2.5`; `selection` rotation / x equals the value for 2.5 with no easing (skip for Sundial, whose sun lags by design; assert instead it moves toward 2.5 and reaches it within 400 ms of `wait`).
  - `test_turn_with_value_lights_scale` — `noteKind = "turn"; note = { name: "Volume", value: 42, valueText: "42%" }`; the look's `litCount` property (exposed for tests) equals the lit-bar count the mockup computes for 42 (column in table).
  - `test_turn_without_value_keeps_ring` — `note = { name: "Tabs" }`; `litCount === 0` and the ring is visible.
  - `test_hint_and_cant_states` — set each; `look.stateDrawn` (readonly, exposed for tests) is `"hint"` / `"cant"`.
  - `test_one_and_twelve_tools` — loads and positions without errors for `tools.slice(0,1)` and a 12-tool list.
  - `test_markup_name_is_plain` — a tool named `<b>x` renders `textFormat === Text.PlainText` on every name `Text`.
- [ ] **Step 2: Run** `QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml/tst_classic_<look>.qml`, expected FAIL.
- [ ] **Step 3: Implement** the look by porting the mockup object named in the table (geometry from `mount()`, motion from `frame()`, its `NOTES.<key>_draft` string as the design intent).
- [ ] **Step 4: Run** the look's test, expected PASS; then the whole QML suite.
- [ ] **Step 5: Render and compare.** `QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qml tests/qml/render_looks.qml -- classic <key>` writes `/tmp/redial-render/classic-<key>-{ring,turn,hint,cant}.png` (the harness uses `grabToImage`). Open the PNGs next to the mockup in the same state (mockup URL params: `?sys=draft&dir=<mockup dir>&state=<state>&pal=light&ed=portable&ref=on`). Fix differences in geometry or ink before committing; list any you deliberately keep in the commit message.
- [ ] **Step 6: Commit** `re:dial classic: <Look> look`

| Task | Look file | key | Mockup object | plateSize | `selection` is | lit bars at value 42 | Notes |
|---|---|---|---|---|---|---|---|
| 4 | `Capsule.qml` | capsule | `DCAP` (draft.js:187) | 400×400 | the chosen capsule group, translated 12 outward | 10 of 24 capsules (`< v*.24`) | rim callout with short leader; `wantsCallout: false` (draws its own rim label) |
| 5 | `Gauge.qml` | gauge | `DGAU` (draft.js:228) | 400×376 | needle rotation | 57 of 135 bars (`< v*1.35`) | spring needle (k 600, d 28) unless reduced motion; wrap from last tool to first jumps, never sweeps back; dead gauge rests at zero on can't act |
| 6 | `Pie.qml` | pie | `DPIE` (draft.js:270) | 400×400 | hatched wedge rotation, cumulative (always forward) | sector path to 42% (`litCount` = 42) | dimension arc outside on turn |
| 7 | `Toast.qml` | toast | `DTOAST` (draft.js:159) | 400×60 | n/a: `selection` is the name Text; test its text instead of angle | 10 of 24 ticks (`< v*.24`) | `kind: "layout"`; title block cells; "Sheet n/N" |
| 8 | `Deck.qml` | deck | `DDECK` (draft.js:305) | 544×262 | front sheet = card whose index nearest `position`; test its `z` is highest | 10 of 26 (`< v*.26`) | `kind: "layout"`; only the front sheet's text is opaque |
| 9 | `Carousel.qml` | carousel | `DCAR` (draft.js:345) | 640×168 | cursor x = `x0 + p*pitch` (x0 52, pitch 76 in units) | cursor at 42% of the rule | `kind: "layout"`; slide rule |
| 10a | `Sundial.qml` | sundial | `DSUN` (classic3.js:32) | ring 640×440, half plate 640×330 (ring size is `plateSize`) | the sun's angle | dimension arc to 42% (`litCount` = 42) | sun lags hand (τ 60 ms); shadow dashed; can't act = hatched moon slides in once (420 ms, ease-in-out); `wantsCallout: true` |
| 10b | `Tag.qml` | tag | `DTAG` (classic3.js:100) | 640×330 | outline marker over checklist row (4 rows × 2 cols) | 4 of 10 holes filled (`round(v/10)`) | stamp lands once on can't act (170 ms, delay 90); `wantsCallout: true` |
| 10c | `Wheel.qml` | wheel | `DWHL` (classic3.js:155) | 640×440 | wheel rotation = `-position*360/n` (the wheel is the hand, no easing) | 42 of 100 bars | angle dimension from rest; spin back to rest when `live` goes false (260 ms, `[0.32,0.72,0,1]`); `wantsCallout: true` |

(Tasks 10a-c are one task each; same steps.)

### Task 11: Retire the inline layouts and the daemon gate

**Files:** `plugin/redial/DialMenu.qml` (delete the inline deck :287-447, carousel :448-557, toast :558-668 blocks, unreachable once classic ships all three); delete `plugin/redial/FaceCapsule.qml`, `FacePie.qml`, `FaceGauge.qml` (no language borrows built-ins) and the settings only they read (`dial.capsuleFillet`, `dial.capsuleSpan` in `Settings.qml:68-71,236-237`, their schema rows, their `StylePresets.js` cases, the gauge/pie `plate` special cases at `Settings.qml:207-214`); grep `tests/`, `config/`, `plugin/redial/config.example.json` and the Rise bar note in `docs/` for each name first; `bin/redial-hypr:1894-1904`, `tests/test_dial.py`. Existing configs that still carry the deleted keys must load without error (unknown keys are ignored: add `test_old_capsule_keys_are_ignored` to `tests/test_settings.py`).

**Interfaces:** `overlay_draws_states() -> bool` becomes: Omarchy shell present and layout in `("dial", "deck", "carousel", "toast")`. Remove the `shortcut:` comment (its condition is met).

- [ ] **Step 1: Failing tests** in `tests/test_dial.py`: `test_states_go_to_the_overlay_for_every_language_layout` (each of the four layouts, faces `classic`, `pie`, `wheel`) and `test_omarchy_layout_keeps_the_osd`.
- [ ] **Step 2: Run** `python3 -m unittest tests.test_dial -k states`, expected FAIL.
- [ ] **Step 3: Implement** the gate; delete the three inline blocks and any properties only they used (grep each property name across `plugin/` and `tests/` before deleting).
- [ ] **Step 4: Run** the full Python and QML suites and `/usr/lib/qt6/bin/qmllint plugin/redial/*.qml plugin/redial/languages/*/*.qml` (compare warning count to the baseline recorded before Task 1; no new warning kinds).
- [ ] **Step 5: Commit** `re:dial: every language look draws its own states`

### Task 12: re:dial basic language (three tasks: 12a faces, 12b layouts, 12c new looks)

**Files:** create `plugin/redial/languages/basic/Language.qml`, `Tones.js`, `fonts/` (three OFL families, `.ttf`, with `OFL.txt` each), the look files below, `tests/qml/tst_basic_<look>.qml` each; add `basic` looks to `render_looks.qml`.

**Interfaces:**
- `Language.qml`: `name: "re:dial basic"`, `defaultLook: "capsule"`, `looks` lists `capsule, gauge, pie, sundial, tag, wheel, deck, carousel, toast` (9; no Classic: the mockups never drew a soft Classic, and a language offers only what it ships). Motion: `easeOut [0.23,1,0.32,1,1,1]`, `easeInOut [0.77,0,0.175,1,1,1]`, `easeDrawer [0.32,0.72,0,1,1,1]`.
- `Tones.js`: `tones(roles: {ground, line, accent, alert}) -> {ground, rim, surface, card, track, muted, soft, ink, accent, onaccent, alert}` by mixing `ground` toward `line` at fixed fractions (rim 0.06, surface 0.10, card 0.13, track 0.10, muted 0.35, soft 0.70, ink 1.0); `onaccent` is `ground` or `line`, whichever has the higher contrast on `accent` (reuse `Contrast.qml`'s ratio formula; move it to a JS function if it is not callable from a library).
- Fonts load through `FontLoader` in `Language.qml` (`readonly property string faceSundial`, `faceTag`, `faceStandard`); a failed load falls back to the host `fontFamily`.

Each look follows the Tasks 4-10 steps (same tests, with `tst_basic_<look>.qml`), porting:

| Task | Look | Mockup object | plateSize | lit at 42 |
|---|---|---|---|---|
| 12a | `Capsule.qml` | `CAP` (looks.js:33) | 336×336 | 8 of 20 segments (`< round(v/5)`) |
| 12a | `Gauge.qml` | `GAU` (looks.js:60) | 320×320 | track dash 42 |
| 12a | `Pie.qml` | `PIE` (looks.js:104) | 336×336 | fill dash 42 |
| 12b | `Toast.qml` | `TOAST` (looks.js:210) | 330×60 | pill fill to 42% |
| 12b | `Deck.qml` | `DECK` (looks.js:136) | 540×250 | bar 42% |
| 12b | `Carousel.qml` | `CAR` (looks.js:174) | 588×150 | bar 42% |
| 12c | `Sundial.qml` | `SUN` (index.html:203) | 336×336 ring / 336×226 half | arc dash 42 |
| 12c | `Tag.qml` | `TAG` (index.html:295) | 350×240 ring / 340×172 | 4 of 10 holes |
| 12c | `Wheel.qml` | `WHL` (index.html:377) | 336×336 ring / 264×264 turn | arc dash 42 |

Basic-only rules from the mockups: the Tag's punched holes show the desktop through them (cut from the plate, not painted); the Tag pivots at its eyelet (`transformOrigin` at the eyelet, it swings, never scales); the Wheel spins back to rest on release like Task 10c; idle-state toast borrowing (`if (st === "idle") return TOAST.mount()`) is a mockup artifact, not ported (the host hides the overlay when idle).

Commit per sub-task: `re:dial basic: <looks>`.

### Task 13: Docs, release notes, deploy for review

**Files:** `plugin/redial/languages/README.md` (contract additions section, the basic language), `docs/DESIGN.md#design-layers`, `CHANGELOG.md` (Unreleased: Added both languages' looks, three new faces; Changed: states drawn by every look).

- [ ] **Step 1:** Write the docs.
- [ ] **Step 2:** Full checks: Python suite, QML suite, qmllint (no new warning kinds), `shellcheck` unchanged files untouched.
- [ ] **Step 3: Deploy to the Studio for Brooks's review.** Back up `~/.config/omarchy/plugins/redial` and `~/.local/bin/redial-hypr` to `~/Backups/redial-pre-phase3-<date>/`; copy `plugin/redial` and `bin/redial-hypr`; run `omarchy-restart-shell` (the shell keeps old plugin QML otherwise) and `redial-restart`. Do not change `~/.config/redial/config.json`; Brooks picks language and face in Settings.
- [ ] **Step 4:** Brooks's check: each look in both languages, ring / turn / hint / can't act; switch language and face while holding the ring open (no stale note, no stuck needle); and a pen stroke on screen afterwards. Record findings; fixes are new commits.
- [ ] **Step 5: Commit** docs; push the branch only when Brooks says so.
