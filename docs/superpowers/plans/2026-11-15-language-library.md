# Design Language Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install, remove, check and preview design languages from Settings, with user languages in their own folder.

**Architecture:** A stdlib Python CLI (`bin/redial-language`) checks, installs, removes and lists languages and keeps `index.json` in the user folder. The plugin reads that index with a FileView and maps a language name to its folder in one pure JS function (`Languages.js`), used by the overlay and Settings. Settings shows a card library and drives the CLI through `Process`.

**Tech Stack:** Python 3 stdlib, QML (Quickshell), qmltestrunner, unittest.

**Spec:** `docs/superpowers/specs/2026-11-15-language-library-design.md`

## Global Constraints

- User folder: `${XDG_DATA_HOME:-~/.local/share}/redial/languages/<name>/`, index `.../languages/index.json`.
- Reserved names: `classic`, `basic`. Folder names: lowercase letters, digits, dashes.
- Allowed files: `.qml .js .json .png .svg .ttf .otf .txt .md`, `LICENSE*`; no symlinks, executables, hidden files; total < 20 MB.
- Allowed imports: `QtQuick`, `QtQuick.Shapes`, `QtQuick.Effects`, relative paths inside the folder.
- Banned code: `XMLHttpRequest`, `Qt.createQmlObject`, `Qt.createComponent`, `Qt.openUrlExternally`, `Qt.include`, `eval`, `Function(`, `import(`, `Qt[`, `Loader`, `WebSocket`, `Worker`.
- Banned strings: `http:`, `https:`, `file:`, `qrc:`, `data:`, `..`.
- Never say "safe". Install warning copy (exact): "A design language runs code on your desktop. re:dial checks it for the risky things it knows; only languages in the reviewed gallery have been read by a person."

## Review Focus

- Comments containing a banned word (`// no XMLHttpRequest here`) should not refuse a language → strip comments before scanning (test in Task 1).
- Config names a language that was removed or never indexed → overlay falls back to classic (test in Task 3).
- Removing the language in use → config switches to classic before the folder goes (Task 4, by hand).
- Missing or malformed `index.json` → only built-ins listed, no error (tests in Task 1 and 3).
- Install over an existing name without `--replace` → refused, old copy untouched (test in Task 1).

---

### Task 1: `bin/redial-language` (check, install, remove, list)

**Files:** Create `bin/redial-language`, `tests/test_language.py`, fixtures built in temp dirs inside the tests.

**Interfaces — Produces:**
- `check(folder: Path) -> list[Problem]` where `Problem = (file: str, line: int, reason: str)`; empty = pass.
- `install(folder: Path, root: Path, replace=False) -> (ok: bool, problems: list)`; `remove(name: str, root: Path) -> bool`; `read_index(root) -> dict[name, entry]`.
- CLI: `redial-language {check,install,remove,list} [--json]`, `--replace` on install; JSON shape `{"ok": bool, "problems": [{"file","line","reason"}], "name": str}`; `list --json` → `[{"name","builtin","manifest"}]`.

- [ ] Tests: both built-ins pass `check`; one fixture per rule fails with its reason (banned import, `XMLHttpRequest`, `"https://x"`, `"../x.png"`, `Loader`, symlink, `.sh` file, missing manifest, look file missing); banned word inside a comment passes; install writes the folder + index entry; reserved name refused; existing name refused without `replace`, replaced with it; remove refuses an unlisted name and deletes a listed one; malformed index reads as `{}`.
- [ ] Run `python3 -m unittest tests.test_language` → fails (no module).
- [ ] Implement. Load in tests via `importlib.machinery.SourceFileLoader` like `test_dial.py`. Comment stripping: drop `//...` and `/*...*/` outside string literals with a small tokenizer; keep line numbers.
- [ ] Tests pass; `uvx ruff check bin/redial-language tests/test_language.py`; commit.

### Task 2: Manifests and preview pictures

**Files:** Create `plugin/redial/languages/{classic,basic}/manifest.json`, `.../previews/*.png`; modify `tests/qml/render_looks.qml` (3rd/4th arg: output folder), `bin/redial-language` (`preview <folder>`), `plugin/redial/languages/README.md`.

- [ ] Manifests per the spec (author "By Brooks", licence as the repo's, version "1.0.0", redial "1"); previews `previews/<look>-ring.png` for the default look + 2 more.
- [ ] `preview <folder>` runs `/usr/lib/qt6/bin/qml render_looks.qml -- <folder> <look> light <out>` per look into `<folder>/previews`; render_looks accepts a folder path as language.
- [ ] Render built-in previews, commit them; Task 1 tests still pass (pngs allowed).

### Task 3: Name → folder in the plugin

**Files:** Create `plugin/redial/Languages.js`, `tests/qml/tst_languages.qml`; modify `Settings.qml` (props `userLanguagesDir`, `languageIndex` from a FileView on `index.json`, `languageDir`), `DialMenu.qml:40`, `ToolPicker.qml:106-118,599`.

**Interfaces — Produces:** `Languages.dir(name, index, userDir) -> string` (built-in → `"languages/<name>"`, indexed → `"file://<userDir>/<name>"`, else `"languages/classic"`); `Languages.options(index) -> [{key,label,builtin,manifest}]`.

- [ ] Tests: built-in, indexed user, unindexed user → classic, `null` index; an indexed user language copied into a temp dir loads its Language.qml through a Loader from the returned dir.
- [ ] Implement; DialMenu `dir` and both ToolPicker loaders use `cfg.languageDir(...)`; languageOptions from `Languages.options`. All QML tests pass.
- [ ] Commit.

### Task 4: Settings library

**Files:** Modify `ToolPicker.qml` (replace the Design language ChoiceRow), maybe create `LanguageCard.qml`.

- [ ] Cards: preview image (built-in: `languages/<n>/<preview>`, user: file URL), name, author, licence, version, `N looks`, Use, Remove (user only; switches config to classic first if in use).
- [ ] "Install from folder…": warning copy, `zenity --file-selection --directory` then `redial-language install --json <dir>` via Process; show report (ok, or each problem); "Replace" offered when the name exists.
- [ ] qmllint clean; screenshot on the Studio.
- [ ] Commit.

### Task 5: Ship it

- [ ] `install.sh`, `install-generic.sh`, `uninstall.sh` include `redial-language`; shellcheck.
- [ ] README/CHANGELOG/languages README; full test run; deploy to the Studio with backups; by-hand test from the spec (incl. a refused `XMLHttpRequest` language).
- [ ] Commit; update roadmap + memory.
