"""Tests for bin/redial-settings' GTK-free parts: reading, merging and writing the config.

Run: python3 tests/test_settings.py  (needs no GTK).
"""

import importlib.machinery
import importlib.util
import json
import os
import stat
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
_loader = importlib.machinery.SourceFileLoader(
    "redial_settings", os.path.join(HERE, "..", "bin", "redial-settings")
)
_spec = importlib.util.spec_from_loader("redial_settings", _loader)
s = importlib.util.module_from_spec(_spec)
_loader.exec_module(s)

TOOLS = [
    {"name": "Volume", "default": True},
    {"name": "Windows", "default": True, "works_here": False},
    {"name": "Scroll", "default": True},
    {"name": "Pages", "default": False},
]


class Config(unittest.TestCase):
    def test_a_missing_config_is_empty(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(s.read_config(os.path.join(d, "config.json")), ({}, None))

    def test_a_broken_config_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "config.json")
            for text in ("{not json", "[1, 2]"):
                with open(path, "w") as f:
                    f.write(text)
                doc, why = s.read_config(path)
                self.assertIsNone(doc)
                self.assertIn("nothing was changed", why)

    def test_saving_keeps_every_other_key(self):
        doc = {"sensitivity": 1.5, "clicks": {"double": "mute"}, "active_tools": ["Volume"]}
        out = s.merged(doc, ["Scroll", "Volume"], "strip")
        self.assertEqual(out["sensitivity"], 1.5)
        self.assertEqual(out["clicks"], {"double": "mute"})
        self.assertEqual(
            (out["active_tools"], out["overlay_style"]), (["Scroll", "Volume"], "strip")
        )
        self.assertEqual(doc["active_tools"], ["Volume"])  # the caller's copy is untouched

    def test_the_written_file_is_private_and_readable_back(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "sub", "config.json")
            s.write_config({"overlay_style": "card"}, path)
            self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
            with open(path) as f:
                self.assertEqual(json.load(f), {"overlay_style": "card"})

    def test_old_capsule_keys_are_ignored(self):
        # Keys from the retired built-in faces and inline deck: the config still loads, and saving
        # it leaves them alone (nothing reads them any more; they are the user's to delete).
        old = {"dial": {"capsuleFillet": 0.5, "capsuleSpan": 0.2}, "deck": {"cardWidth": 150, "gap": 14}}
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "config.json")
            s.write_config(old, path)
            doc, why = s.read_config(path)
            self.assertIsNone(why)
            out = s.merged(doc, ["Volume"], "strip")
            self.assertEqual(out["dial"], old["dial"])
            self.assertEqual(out["deck"], old["deck"])


class Ring(unittest.TestCase):
    def test_without_active_tools_the_ring_is_the_defaults(self):
        self.assertEqual(s.ring_now({}, TOOLS), ["Volume", "Windows", "Scroll"])

    def test_the_ring_comes_first_in_its_own_order(self):
        names = [t["name"] for t in s.ordered(TOOLS, ["Scroll", "Volume", "Gone"])]
        self.assertEqual(names, ["Scroll", "Volume", "Windows", "Pages"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
