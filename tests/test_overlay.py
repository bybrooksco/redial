"""Tests for bin/redial-overlay's GTK-free parts: the line protocol, the themes, the style choice.

Run: python3 tests/test_overlay.py  (needs no GTK; the window code is only imported by main()).
"""

import importlib.machinery
import importlib.util
import os
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
PATH = os.path.join(HERE, "..", "bin", "redial-overlay")
_loader = importlib.machinery.SourceFileLoader("redial_overlay", PATH)
_spec = importlib.util.spec_from_loader("redial_overlay", _loader)
o = importlib.util.module_from_spec(_spec)
_loader.exec_module(o)

COSMIC_BG = """(
    base: (
        red: 0.1805025,
        green: 0.07281732,
        blue: 0.0913957,
        alpha: 1.0,
    ),
    component: (
        base: (
            red: 0.27053404,
            green: 0.15367943,
            blue: 0.17093372,
            alpha: 1.0,
        ),
        on: (
            red: 0.5,
            green: 0.5,
            blue: 0.5,
            alpha: 1.0,
        ),
    ),
    on: (
        red: 1.0,
        green: 0.8968342,
        blue: 0.85222167,
        alpha: 1.0,
    ),
)"""
COSMIC_ACCENT = (
    "(\n    base: (\n        red: 0.87177604,\n        green: 0.3934868,\n"
    "        blue: 0.3260805,\n"
)
COSMIC_PRIMARY = (
    "(\n    base: (\n        red: 0.23808262,\n        green: 0.124362744,\n"
    "        blue: 0.1419189,\n"
)


def write(root, rel, text):
    path = os.path.join(root, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


class Protocol(unittest.TestCase):
    def test_the_lines_the_daemon_sends(self):
        self.assertEqual(o.parse_line('open {"tools": [], "index": 2}\n')[0], "open")
        self.assertEqual(o.parse_line("highlight 3"), ("highlight", 3))
        self.assertEqual(o.parse_line("pos 2.6000"), ("highlight", 3))
        self.assertEqual(o.parse_line("close"), ("close", None))

    def test_anything_else_is_ignored(self):
        for line in ("turn {}", "open not-json", 'open {"index": 1}', "highlight x", ""):
            self.assertIsNone(o.parse_line(line), line)


class Themes(unittest.TestCase):
    def test_cosmic_colours_come_from_its_theme_files(self):
        with tempfile.TemporaryDirectory() as home:
            d = ".config/cosmic/com.system76.CosmicTheme.Dark/v1/"
            write(home, ".config/cosmic/com.system76.CosmicTheme.Mode/v1/is_dark", "true")
            write(home, d + "background", COSMIC_BG)
            write(home, d + "accent", COSMIC_ACCENT)
            write(home, d + "primary", COSMIC_PRIMARY)
            write(home, d + "corner_radii", "(\n    radius_s: (2.0, 2.0, 2.0, 2.0),\n)")
            t = o.theme(home, "COSMIC")
        self.assertEqual(
            (t["bg"], t["fg"], t["accent"], t["surface"], t["radius"]),
            ("#2e1317", "#ffe5d9", "#de6453", "#3d2024", 2),
        )

    def test_cosmic_light_mode_reads_the_light_theme(self):
        with tempfile.TemporaryDirectory() as home:
            write(home, ".config/cosmic/com.system76.CosmicTheme.Mode/v1/is_dark", "false")
            d = ".config/cosmic/com.system76.CosmicTheme.Light/v1/"
            for name, text in (("background", COSMIC_BG), ("accent", COSMIC_ACCENT)):
                write(home, d + name, text)
            write(home, d + "primary", COSMIC_PRIMARY)
            self.assertEqual(o.theme(home, "COSMIC")["radius"], 2)  # no corner file: default

    def test_kde_colours_and_font_come_from_kdeglobals(self):
        with tempfile.TemporaryDirectory() as home:
            write(
                home,
                ".config/kdeglobals",
                "[General]\nAccentColor=61,174,233\nfixed=Hack,10,-1,5,50\n"
                "[Colors:Window]\nBackgroundNormal=32,35,38\nForegroundNormal=252,252,252\n"
                "[Colors:View]\nBackgroundAlternate=41,44,48\n",
            )
            t = o.theme(home, "KDE")
        self.assertEqual((t["bg"], t["accent"], t["font"]), ("#202326", "#3daee9", "Hack"))

    def test_a_missing_theme_falls_back_to_gtk(self):
        with tempfile.TemporaryDirectory() as home:
            self.assertIsNone(o.theme(home, "COSMIC"))
            self.assertIsNone(o.theme(home, "KDE"))
            self.assertIsNone(o.theme(home, "sway"))

    def test_css_uses_the_theme(self):
        sheet = o.css(dict(o.FALLBACK, radius=2, font="Fira Mono"))
        self.assertIn("#3584e4", sheet)
        self.assertIn('"Fira Mono"', sheet)


class Style(unittest.TestCase):
    def test_the_three_styles_and_the_default(self):
        for s in o.STYLES:
            self.assertEqual(o.style_from({"overlay_style": s}), s)
        self.assertEqual(o.style_from({"overlay_style": "nope"}), "menu")
        self.assertEqual(o.style_from([]), "menu")


if __name__ == "__main__":
    unittest.main(verbosity=2)
