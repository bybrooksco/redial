#!/usr/bin/env python3
"""Add a "Surface Dial" row to the Omarchy menu (Setup -> Surface Dial).

Omarchy reads user menu rows from ~/.config/omarchy/extensions/omarchy-menu.jsonc, a JSON
file that may contain comments. This inserts one row without disturbing anything else in
it, checks that the result still parses, and leaves the file untouched if it doesn't.

    add-menu-entry.py [FILE]            # add the row (default file: the Omarchy user extension)
    add-menu-entry.py --remove [FILE]   # take it out again, only if it is still as written
"""

import json
import os
import sys

ID = "setup.redial"
ROW = (
    "  // Surface Dial: added by its install.sh\n"
    '  "setup.redial": {"icon":"\\uf192","label":"Surface Dial",'
    '"aliases":["dial","surface dial"],'
    '"description":"Tools, size, clicks and appearance",'
    '"when":"[[ -x $HOME/.local/bin/redial-hypr ]]",'
    '"action":"omarchy-shell dialtools toggle"}\n'
)
DEFAULT = os.path.expanduser("~/.config/omarchy/extensions/omarchy-menu.jsonc")


def structure(text):
    """Yield (index, char) for every character outside comments, and not whitespace."""
    i, n, in_str = 0, len(text), False
    while i < n:
        c = text[i]
        if in_str:
            if c == "\\":
                yield i, c
                i += 1
                yield i, text[i]
            else:
                yield i, c
                in_str = c != '"'
        elif c == '"':
            in_str = True
            yield i, c
        elif text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j == -1 else j
            continue
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            i = n if j == -1 else j + 2
            continue
        elif not c.isspace():
            yield i, c
        i += 1


def parse_jsonc(text):
    """json.loads for text with comments and trailing commas."""
    sig = list(structure(text))
    keep = []
    for k, (_, c) in enumerate(sig):
        if c == "," and k + 1 < len(sig) and sig[k + 1][1] in "}]":
            continue
        keep.append(c)
    return json.loads("".join(keep))


def add_row(text):
    """Return `text` with the row inserted before the final brace; None if already there."""
    if f'"{ID}"' in text:
        return None
    sig = list(structure(text))
    if not sig or sig[-1][1] != "}":
        raise ValueError("expected a JSON object ending in }")
    close = sig[-1][0]
    prev_i, prev_c = sig[-2] if len(sig) > 1 else (None, "{")
    # `{` (empty object) or `,` (trailing comma) need nothing; anything else needs a comma.
    if prev_c not in "{,":
        text = text[: prev_i + 1] + "," + text[prev_i + 1 :]
        close += 1
    head = text[:close].rstrip(" \t")
    if not head.endswith("\n"):
        head += "\n"
    return head + ROW + text[close:]


def remove_row(text):
    """Return `text` without the row add_row() inserted; None if it is not there as inserted.

    Only the exact text this script wrote is removed. A row the user has since edited is left
    alone (the caller says so), and any comma that was added after the previous entry stays,
    which the menu file's format allows.
    """
    return text.replace(ROW, "", 1) if ROW in text else None


def remove(path):
    """Take the Surface Dial row out of the menu file. Returns a process exit code."""
    if not os.path.exists(path):
        print("no menu file; nothing to remove")
        return 0
    original = open(path, encoding="utf-8").read()
    if f'"{ID}"' not in original:
        print("menu entry not present")
        return 0
    new = remove_row(original)
    try:
        if new is None:
            raise ValueError("the entry was edited after install, so it was not touched")
        if ID in parse_jsonc(new):
            raise ValueError("entry still present after removal")
    except Exception as exc:
        print(f"add-menu-entry: left {path} untouched ({exc})", file=sys.stderr)
        return 1
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(new)
    os.replace(tmp, path)
    print(f"removed 'Surface Dial' from {path}")
    return 0


def main(argv):
    if len(argv) > 1 and argv[1] == "--remove":
        return remove(argv[2] if len(argv) > 2 else DEFAULT)
    path = argv[1] if len(argv) > 1 else DEFAULT
    os.makedirs(os.path.dirname(path), exist_ok=True)
    original = open(path, encoding="utf-8").read() if os.path.exists(path) else "{\n}\n"
    try:
        new = add_row(original)
        if new is None:
            print("menu entry already present")
            return 0
        parsed = parse_jsonc(new)
        assert ID in parsed, "row missing after insert"
    except Exception as exc:
        print(f"add-menu-entry: left {path} untouched ({exc})", file=sys.stderr)
        return 1
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(new)
    os.replace(tmp, path)
    print(f"added 'Surface Dial' to {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
