"""Tests for bin/redial-language: the design language checker, installer and remover.

Run: python3 -m unittest tests.test_language
"""

import importlib.machinery
import importlib.util
import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
LANGS = HERE.parent / "plugin" / "redial" / "languages"


def load_tool():
    path = str(HERE.parent / "bin" / "redial-language")
    loader = importlib.machinery.SourceFileLoader("redial_language", path)
    mod = importlib.util.module_from_spec(
        importlib.util.spec_from_loader("redial_language", loader)
    )
    loader.exec_module(mod)
    return mod


L = load_tool()

LANGUAGE_QML = """import QtQuick
QtObject {
  readonly property string name: "Test"
  readonly property var looks: ({ "capsule": "Capsule.qml" })
  readonly property string defaultLook: "capsule"
}
"""
LOOK_QML = """import QtQuick
import "Tones.js" as Tones
Item { property var cfg; Text { text: "Loading..."; textFormat: Text.PlainText } }
"""
MANIFEST = {"name": "Test", "author": "Me", "licence": "MIT", "version": "1.0.0", "redial": "1"}


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.root = self.tmp / "user"

    def make(self, name="mylang", files=None, manifest=MANIFEST):
        d = self.tmp / "src" / name
        d.mkdir(parents=True)
        base = {"Language.qml": LANGUAGE_QML, "Capsule.qml": LOOK_QML, "Tones.js": "var x = 1\n"}
        base.update(files or {})
        for rel, text in base.items():
            if text is None:
                continue
            (d / rel).parent.mkdir(parents=True, exist_ok=True)
            (d / rel).write_text(text)
        if manifest is not None:
            (d / "manifest.json").write_text(json.dumps(manifest))
        return d

    def reasons(self, folder):
        return " | ".join(f"{p[0]}: {p[2]}" for p in L.check(folder))


class Check(Base):
    def test_the_built_in_languages_pass(self):
        for name in ("classic", "basic"):
            self.assertEqual(L.check(LANGS / name), [], name)

    def test_a_plain_language_passes(self):
        self.assertEqual(L.check(self.make()), [])

    def test_each_rule_refuses_with_its_reason(self):
        cases = {
            "an outside import": (
                {"Capsule.qml": "import Quickshell.Io\nItem {}\n"},
                "Quickshell.Io",
            ),
            "a relative import that leaves": (
                {"Capsule.qml": 'import "../x"\nItem {}\n'},
                "outside",
            ),
            "the network": ({"Tones.js": "var r = new XMLHttpRequest()\n"}, "XMLHttpRequest"),
            "a web link": (
                {"Capsule.qml": 'import QtQuick\nImage { source: "https://x/y.png" }\n'},
                "https:",
            ),
            "a path that leaves": (
                {"Capsule.qml": 'import QtQuick\nImage { source: "../../a.png" }\n'},
                "..",
            ),
            "an absolute path": (
                {"Capsule.qml": 'import QtQuick\nImage { source: "/usr/share/a.png" }\n'},
                "/usr",
            ),
            "a Loader": ({"Capsule.qml": "import QtQuick\nLoader { }\n"}, "Loader"),
            "dynamic code": ({"Tones.js": 'Qt.createQmlObject("x", null)\n'}, "createQmlObject"),
            "computed Qt access": ({"Tones.js": 'var f = Qt["open" + "UrlExternally"]\n'}, "Qt["),
            "a script file": ({"run.sh": "echo hi\n"}, "run.sh"),
            "a hidden file": ({".env": "x\n"}, ".env"),
            "a missing look file": ({"Capsule.qml": None}, "Capsule.qml"),
        }
        for what, (files, word) in cases.items():
            with self.subTest(what):
                d = self.make(name="l" + str(abs(hash(what)) % 10**8), files=files)
                self.assertIn(word, self.reasons(d), what)

    def test_a_missing_or_incomplete_manifest_is_refused(self):
        self.assertIn("manifest.json", self.reasons(self.make(manifest=None)))
        self.assertIn("author", self.reasons(self.make(name="b", manifest={"name": "x"})))

    def test_a_named_preview_must_exist_inside(self):
        m = dict(MANIFEST, previews=["previews/a.png"])
        self.assertIn("previews/a.png", self.reasons(self.make(manifest=m)))

    def test_a_symlink_is_refused(self):
        d = self.make()
        (d / "link.qml").symlink_to("/etc/passwd")
        self.assertIn("link", self.reasons(d))

    def test_an_executable_is_refused(self):
        d = self.make()
        os.chmod(d / "Tones.js", 0o755)
        self.assertIn("executable", self.reasons(d))

    def test_banned_words_in_comments_are_ignored(self):
        d = self.make(
            files={
                "Tones.js": "// no XMLHttpRequest, no Loader, no https://x\n/* Qt[ */ var a = 1\n"
            }
        )
        self.assertEqual(L.check(d), [])

    def test_a_problem_names_its_line(self):
        d = self.make(files={"Tones.js": "var a = 1\nvar b = 2\nvar r = new XMLHttpRequest()\n"})
        self.assertIn(("Tones.js", 3), [(p[0], p[1]) for p in L.check(d)])


class InstallRemove(Base):
    def test_install_copies_and_lists_it(self):
        ok, problems = L.install(self.make(), self.root)
        self.assertTrue(ok, problems)
        self.assertTrue((self.root / "mylang" / "Language.qml").exists())
        entry = L.read_index(self.root)["mylang"]
        self.assertEqual(entry["manifest"]["author"], "Me")
        self.assertEqual(entry["looks"], 1)

    def test_a_refused_language_is_not_installed(self):
        ok, problems = L.install(self.make(files={"Tones.js": "new XMLHttpRequest()\n"}), self.root)
        self.assertFalse(ok)
        self.assertTrue(problems)
        self.assertFalse((self.root / "mylang").exists())
        self.assertEqual(L.read_index(self.root), {})

    def test_built_in_names_and_bad_names_are_refused(self):
        for name in ("classic", "basic", "Bad_Name"):
            with self.subTest(name):
                ok, problems = L.install(self.make(name=name), self.root)
                self.assertFalse(ok)

    def test_an_existing_name_needs_replace(self):
        L.install(self.make(), self.root)
        newer = self.tmp / "v2" / "mylang"
        shutil.copytree(self.tmp / "src" / "mylang", newer)
        (newer / "manifest.json").write_text(json.dumps(dict(MANIFEST, version="2.0.0")))
        ok, problems = L.install(newer, self.root)
        self.assertFalse(ok)
        self.assertIn("already installed", problems[0][2])
        self.assertEqual(L.read_index(self.root)["mylang"]["manifest"]["version"], "1.0.0")
        ok, _ = L.install(newer, self.root, replace=True)
        self.assertTrue(ok)
        self.assertEqual(L.read_index(self.root)["mylang"]["manifest"]["version"], "2.0.0")
        self.assertEqual(sorted(p.name for p in self.root.iterdir()), ["index.json", "mylang"])

    def test_remove_only_touches_listed_languages(self):
        L.install(self.make(), self.root)
        (self.root / "stray").mkdir()
        self.assertFalse(L.remove("stray", self.root))
        self.assertTrue((self.root / "stray").exists())
        self.assertFalse(L.remove("classic", self.root))
        self.assertTrue(L.remove("mylang", self.root))
        self.assertFalse((self.root / "mylang").exists())
        self.assertEqual(L.read_index(self.root), {})

    def test_a_missing_or_broken_index_reads_empty(self):
        self.assertEqual(L.read_index(self.root), {})
        self.root.mkdir(parents=True)
        (self.root / "index.json").write_text("{nope")
        self.assertEqual(L.read_index(self.root), {})

    def test_the_cli_reports_json(self):
        import contextlib
        import io

        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = L.main(["check", "--json", str(self.make(files={"Tones.js": "eval('1')\n"}))])
        report = json.loads(out.getvalue())
        self.assertEqual(code, 1)
        self.assertFalse(report["ok"])
        self.assertEqual(report["problems"][0]["file"], "Tones.js")


if __name__ == "__main__":
    unittest.main()
