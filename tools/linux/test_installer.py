"""Linux installer regression tests; all writes/installations stay in a temp dir."""
import ctypes
import ctypes.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest


@unittest.skipUnless(os.name == "posix", "requires Linux Bash and GLib")
class InstallerTest(unittest.TestCase):
    def test_desktop_launcher_paths(self):
        gio = ctypes.CDLL(ctypes.util.find_library("gio-2.0"))
        gio.g_desktop_app_info_new_from_filename.argtypes = [ctypes.c_char_p]
        gio.g_desktop_app_info_new_from_filename.restype = ctypes.c_void_p
        gio.g_app_launch_context_new.restype = ctypes.c_void_p
        gio.g_app_launch_context_setenv.argtypes = [
            ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p
        ]
        gio.g_app_info_launch.argtypes = [
            ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_void_p)
        ]
        gio.g_app_info_launch.restype = ctypes.c_int
        gobject = ctypes.CDLL(ctypes.util.find_library("gobject-2.0"))
        gobject.g_object_unref.argtypes = [ctypes.c_void_p]
        source = Path(__file__).resolve().parent
        for name in ("ordinary", "name with spaces & pipe|", 'quo"te $cash `tick\\slash %f'):
            with self.subTest(name=name), tempfile.TemporaryDirectory(prefix="xdremux-install-") as tmp:
                root = Path(tmp)
                package = root / "package"
                (package / "bundle").mkdir(parents=True)
                for filename in ("install.sh", "xdremux.desktop"):
                    (package / filename).write_text((source / filename).read_text())
                shutil.copyfile(source / "xdremux.png", package / "xdremux.png")
                binary = package / "bundle/xdremux"
                binary.write_text('#!/bin/sh\nprintf "%s\\n" "$0" > "$XDREMUX_INSTALL_TEST_OUTPUT"\n')
                binary.chmod(0o755)
                test_home = root / name
                test_home.mkdir()
                marker = root / "launched.txt"
                # Only child processes see this synthetic HOME. Never install
                # the test application into the developer's actual account.
                env = dict(os.environ, HOME=str(test_home))
                env.pop("XDG_DATA_HOME", None)
                subprocess.run(["bash", str(package / "install.sh")], env=env,
                               check=True, capture_output=True, text=True)
                desktop = test_home / ".local/share/applications/xdremux.desktop"
                app = gio.g_desktop_app_info_new_from_filename(os.fsencode(desktop))
                self.assertTrue(app, desktop.read_text())
                context = gio.g_app_launch_context_new()
                try:
                    for key, value in {
                        "HOME": str(test_home),
                        "XDG_DATA_HOME": str(test_home / ".local/share"),
                        "XDREMUX_INSTALL_TEST_OUTPUT": str(marker),
                    }.items():
                        gio.g_app_launch_context_setenv(context, key.encode(), os.fsencode(value))
                    error = ctypes.c_void_p()
                    self.assertTrue(gio.g_app_info_launch(app, None, context, ctypes.byref(error)),
                                    desktop.read_text())
                    deadline = time.monotonic() + 5
                    while not marker.exists() and time.monotonic() < deadline:
                        time.sleep(0.05)
                    self.assertTrue(marker.exists(), "desktop entry did not launch the installed binary")
                    self.assertEqual(marker.read_text().strip(),
                                     str(test_home / ".local/share/xdremux/xdremux"))
                finally:
                    gobject.g_object_unref(context)
                    gobject.g_object_unref(app)


if __name__ == "__main__":
    unittest.main()
