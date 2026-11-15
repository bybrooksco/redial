# Design language library: install, remove, preview, check

Roadmap item 3 (vault: `Idea Bank/re-dial — Build Roadmap (2026-11-15).md`). Approved approach: **C**:
build **A** now (trust + a checker + a reviewed gallery later), add **B** (code-free "themes") once
the project is further along.

## Why

Brooks wants people to make and share design languages, a gallery or market of them, and to try
them before committing. Today a language is a folder of QML inside the plugin: adding one means
copying files into the install, an update can wipe it, and nothing stops a language from doing
anything the desktop shell can (network, open links, load code from anywhere). That last part is
the security problem.

## Goals

- Languages you add live in your own folder and survive updates and reinstalls.
- Settings shows a library: one card per language with its preview pictures, name, author, licence,
  version and how many looks it has. Built-in languages show there too, without Remove.
- Install from a folder in Settings, with a plain report of what the checker found. Remove from
  Settings.
- A checker that refuses a language that reaches outside its own folder: outside imports, network,
  loading other code, links, files that aren't drawing material.
- Previews for a language you haven't switched to are **pictures that ship with it**, never its
  code running.

## Non-goals (now)

- The public gallery/catalog itself: it waits on GitHub publishing (item 6). The manifest and the
  preview pictures are shaped so a catalog can list them later.
- Installing from a zip or URL. Folder only.
- Code-free themes (approach B). Later.
- Sandboxing QML at runtime. Not possible inside the shell; the checker plus review is the model.

## Anti-goals

- Saying "safe" anywhere. The checker catches mistakes and the obvious tricks; a determined author
  can disguise code. The install screen says the language runs code on your desktop and that only
  reviewed gallery languages have been read by a person.
- A broken or refused language ever blanking the overlay (the classic fallback stays).
- Breaking the two built-in languages or the existing look contract.

## Approaches considered

- **A. Trust + checker + reviewed gallery** (chosen now). Full power for authors; protection is
  partial and honest about it.
- **B. Code-free languages** (colours, fonts, SVG, settings, drawn by re:dial's own looks). Truly
  safe, but no new layouts or motion, and it needs a general look engine. Later, as a theme tier.
- **C. A now, B later.** Chosen by Brooks 11-15.

## Design

### Where languages live

- Built-in: `plugin/redial/languages/<name>/` (classic, basic), as today.
- Yours: `${XDG_DATA_HOME:-~/.local/share}/redial/languages/<name>/`. Installed only by the
  installer below, which records each install in `languages/index.json` (name, checker version,
  date, manifest). Settings and the overlay read that index (a FileView, so it updates live) and
  know only the languages in it, so a folder dropped in by hand isn't picked up unchecked.
- Built-in names are reserved; a user language can't shadow them.
- One place maps a name to its folder (`Settings.qml`: `languageDir(name)`), used by the overlay
  (`DialMenu.qml`) and both Settings loaders (`ToolPicker.qml`). Everything else (LookResolve, the
  classic fallback) is unchanged.

### `manifest.json` (required for installs; added to both built-ins)

```json
{
  "name": "My language",
  "author": "Someone",
  "licence": "MIT",
  "version": "1.0.0",
  "redial": "1",
  "description": "One line.",
  "previews": ["previews/capsule-ring.png", "previews/capsule-turn.png"]
}
```

`redial` is the look-contract version it was made for. The folder name stays the key in config.

### The checker and installer: `bin/redial-language`

Python, standard library only. Commands: `check <folder>`, `install <folder>`, `remove <name>`,
`list`, each with `--json` for Settings, and `preview <folder>` for authors (renders the pictures
with `tests/qml/render_looks.qml`; this runs the author's own code on their own machine).

`check` refuses, each with the file, line and a plain reason:

1. Files: only `.qml .js .json .png .svg .ttf .otf .txt .md` and `LICENSE*`; no symlinks, no
   executables, no hidden files; under 20 MB in all.
2. A valid `manifest.json` and `Language.qml`; every look file `looks` names exists.
3. Imports: only `QtQuick`, `QtQuick.Shapes`, `QtQuick.Effects` and relative files inside the
   folder (no `..`, no absolute paths, no URL schemes).
4. Code: no `XMLHttpRequest`, `Qt.createQmlObject`, `Qt.createComponent`, `Qt.openUrlExternally`,
   `Qt.include`, `eval`, `Function(`, `import(`, computed access on `Qt` (`Qt[`), `Loader`
   (looks don't need it), `WebSocket`, `Worker`.
5. Strings: no URL schemes (`http:`, `https:`, `file:`, `qrc:`, `data:`) and no `..`, so images
   and fonts load only from inside the folder.

Both built-ins must pass (a test). `install` checks, refuses a reserved or existing name (offers
`--replace`), copies to a temp folder beside the target, renames it into place, then adds it to
the index. `remove` deletes only folders the index lists, under the user folder.

### Settings: the library (Look page, by Design language)

- A card per language: first preview picture (or a "no preview" plate), name, author, licence,
  version, `N looks`, a Use button, and Remove for yours. Removing the language in use switches to
  classic first.
- "Install from folder…" opens a folder picker (`zenity --file-selection --directory`), runs
  `redial-language install --json`, and shows the report: pass, or each problem in plain words.
  Before installing it says: "A design language runs code on your desktop. re:dial checks it for
  the risky things it knows; only languages in the reviewed gallery have been read by a person."
- After install, the existing live peek shows the language for real once you pick it.

### Previews

`render_looks.qml` gains an output-folder argument. The built-ins ship two pictures each (default look, ring and turn), flattened on the paper ground
and kept small for the single-file installer. The future catalog's CI renders them for submissions.

## Tests

- Python: the checker against both built-ins (pass) and against small fixtures that each break one
  rule (fail, right reason); install/remove in temp folders (index, reserved names, replace,
  remove refuses unlisted or outside folders).
- QML: `languageDir` maps built-in and user names; an indexed user language loads from an absolute
  path and draws; an unknown one falls back to classic.
- By hand on the Studio: install a test language from a folder, see its previews, use it, remove
  it; a language with `XMLHttpRequest` is refused with a clear reason.

## Left to the builder

Card layout details within the existing Settings style; exact report wording; how the Library and
the existing Design language chips merge (the cards can replace the chips).

## Calls made while writing (Brooks to check)

- User folder under `~/.local/share/redial/languages` (data, not config), listed by an index the
  installer writes, so hand-copied folders are ignored.
- Folder installs only; zip/URL later with the gallery.
- `Loader` is banned in languages (neither built-in uses it), which closes the easiest way around
  the import rule.
- The library cards replace the Design language chips on the Look page.
