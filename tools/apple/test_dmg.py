"""Tests for tools/apple/dmg installer helpers and layout invariants."""

import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest


APPLE_TOOLS_DIR = Path(__file__).resolve().parent
DMG_TOOLS_DIR = APPLE_TOOLS_DIR / "dmg"
sys.path.insert(0, str(DMG_TOOLS_DIR))
import set_file_icon  # noqa: E402


class DmgInstallerTests(unittest.TestCase):
    def test_resource_fork_wraps_icns_with_valid_offsets(self):
        fake_icns = b"icns" + b"\x00\x00\x00\x20" + (b"\xAB" * 24)
        fork = set_file_icon.resource_fork(fake_icns)

        data_offset, map_offset, data_len, map_len = struct.unpack(">IIII", fork[:16])
        self.assertEqual(data_offset, 256)
        self.assertEqual(data_len, 4 + len(fake_icns))
        self.assertEqual(map_offset, data_offset + data_len)
        self.assertEqual(len(fork), map_offset + map_len)

        embedded_len = struct.unpack(">I", fork[data_offset : data_offset + 4])[0]
        self.assertEqual(embedded_len, len(fake_icns))
        self.assertEqual(
            fork[data_offset + 4 : data_offset + 4 + len(fake_icns)], fake_icns
        )

    def test_set_file_icon_rejects_non_icns(self):
        with tempfile.TemporaryDirectory(prefix="xdremux-icns-test-") as tmp:
            root = Path(tmp)
            target = root / "sample.inetloc"
            target.write_text("placeholder", encoding="utf-8")
            bad_icns = root / "not_an_icon.icns"
            bad_icns.write_bytes(b"PNG!")
            with self.assertRaises(SystemExit):
                set_file_icon.set_file_icon(str(target), str(bad_icns))

    def test_settings_and_background_geometry_stay_aligned_and_clear(self):
        with tempfile.TemporaryDirectory(prefix="xdremux-dmg-settings-") as tmp:
            stage = Path(tmp) / "stage"
            stage.mkdir()
            (stage / "XDRemux.app").mkdir()
            (stage / "LICENSE.txt").write_text("gpl", encoding="utf-8")
            (stage / "LICENSING.md").write_text("notes", encoding="utf-8")
            (stage / "打开隐私与安全性 (Privacy & Security).inetloc").write_text(
                "plist", encoding="utf-8"
            )
            links = Path(tmp) / "links"
            links.mkdir()
            (links / "官网 xdremux.app.webloc").write_text("webloc", encoding="utf-8")

            ns = {
                "defines": {
                    "stage": str(stage),
                    "app": "XDRemux.app",
                    "icon": "",
                    "assets": str(DMG_TOOLS_DIR),
                    "decorated": "",
                    "links": str(links),
                }
            }
            settings_src = (DMG_TOOLS_DIR / "settings.py").read_text(encoding="utf-8")
            exec(compile(settings_src, str(DMG_TOOLS_DIR / "settings.py"), "exec"), ns)

            swift_src = (DMG_TOOLS_DIR / "gen_background.swift").read_text(
                encoding="utf-8"
            )
            content_w = float(re.search(r"let width = ([0-9.]+)", swift_src).group(1))
            content_h = float(
                re.search(r"let contentHeight = ([0-9.]+)", swift_src).group(1)
            )
            hero_y = float(re.search(r"let heroY = ([0-9.]+)", swift_src).group(1))
            small_y = float(re.search(r"let smallY = ([0-9.]+)", swift_src).group(1))
            link_match = re.search(
                r"let link = \(x: ([0-9.]+), y: ([0-9.]+)\)", swift_src
            )
            link_x, link_y = float(link_match.group(1)), float(link_match.group(2))
            link_mat_h = float(
                re.search(r"linkMat = CGRect\([^)]*height: ([0-9.]+)\)", swift_src).group(1)
            )

            self.assertEqual(ns["CONTENT"], (int(content_w), int(content_h)))
            self.assertEqual(ns["HERO_Y"], int(hero_y))
            self.assertEqual(ns["SMALL_Y"], int(small_y))
            self.assertEqual(ns["LINK"], (int(link_x), int(link_y)))

            # The website link label mat must keep a positive gap above the
            # top of the Applications icon below it.
            icon_half = ns["icon_size"] / 2.0
            link_mat_bottom = link_y + icon_half + 2.0 + link_mat_h
            apps_icon_top = hero_y - icon_half
            self.assertGreaterEqual(apps_icon_top - link_mat_bottom, 10.0)

            # Bottom row items stay centered symmetrically with margin for the
            # long Privacy & Security shortcut name.
            locs = ns["icon_locations"]
            self.assertGreaterEqual(
                content_w - locs["打开隐私与安全性 (Privacy & Security).inetloc"][0],
                120.0,
            )
            self.assertIn("官网 xdremux.app.webloc", ns["hide_extensions"])
            self.assertIn(
                "打开隐私与安全性 (Privacy & Security).inetloc", ns["hide_extensions"]
            )

    @unittest.skipUnless(os.name == "posix", "requires Bash")
    def test_make_dmg_rejects_missing_or_multiple_app_bundles(self):
        script = DMG_TOOLS_DIR / "make_dmg.sh"
        with tempfile.TemporaryDirectory(prefix="xdremux-dmg-stage-") as tmp:
            root = Path(tmp)
            stage = root / "stage"
            stage.mkdir()
            env = dict(os.environ)
            env["XDREMUX_DMG_VENV"] = str(Path.home() / ".cache/xdremux/dmgbuild-venv")

            # Zero .app bundles fails.
            no_app = subprocess.run(
                ["bash", str(script), "TestVol", str(root / "out.dmg"), str(stage)],
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(no_app.returncode, 0)

            # Two .app bundles fails explicitly rather than picking silently.
            (stage / "One.app").mkdir()
            (stage / "Two.app").mkdir()
            two_apps = subprocess.run(
                ["bash", str(script), "TestVol", str(root / "out.dmg"), str(stage)],
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(two_apps.returncode, 0)

    @unittest.skipUnless(
        sys.platform == "darwin"
        and (Path.home() / ".cache/xdremux/dmgbuild-venv/bin/dmgbuild").exists()
        and shutil.which("hdiutil") is not None,
        "requires macOS with cached dmgbuild-venv",
    )
    def test_make_dmg_strict_survives_missing_volume_icon(self):
        script = DMG_TOOLS_DIR / "make_dmg.sh"
        with tempfile.TemporaryDirectory(prefix="xdremux-dmg-strict-") as tmp:
            root = Path(tmp)
            stage = root / "stage"
            stage.mkdir()
            (stage / "Sample.app").mkdir()
            (stage / "Sample.app" / "Contents").mkdir()
            (stage / "LICENSE.txt").write_text("gpl", encoding="utf-8")
            (stage / "LICENSING.md").write_text("notes", encoding="utf-8")
            os.symlink("/Applications", stage / "Applications")

            out_dmg = root / "sample.dmg"
            env = dict(os.environ)
            env["XDREMUX_DMG_STRICT"] = "1"
            res = subprocess.run(
                [
                    "bash",
                    str(script),
                    "Sample",
                    str(out_dmg),
                    str(stage),
                    str(root / "nonexistent" / "AppIcon.icns"),
                ],
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(res.returncode, 0, res.stderr + res.stdout)
            self.assertIn("warning: volume icon not found", res.stderr)
            self.assertTrue(out_dmg.is_file())
