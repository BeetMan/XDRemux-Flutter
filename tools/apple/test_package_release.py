"""Test macOS signing/notarization resolution and DMG shortcut helpers."""
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest


APPLE_TOOLS_DIR = Path(__file__).resolve().parent


@unittest.skipUnless(os.name == "posix", "requires Bash")
class MacOSReleaseHelpersTest(unittest.TestCase):
    def _run_signing_fn(self, fn_call, env_overrides=None, mock_bins=None):
        helper = APPLE_TOOLS_DIR / "macos_release_signing.sh"
        with tempfile.TemporaryDirectory(prefix="xdremux-sign-test-") as tmp:
            root = Path(tmp)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            for name, content in (mock_bins or {}).items():
                p = bin_dir / name
                p.write_text(content)
                p.chmod(0o755)

            env = dict(os.environ)
            # Clear signing/notary env vars so host env never leaks into tests.
            for key in (
                "XDREMUX_TEAM_ID",
                "XDREMUX_MACOS_SIGN",
                "XDREMUX_DEVELOPER_ID",
                "XDREMUX_NOTARIZE",
                "XDREMUX_NOTARY_PROFILE",
                "XDREMUX_NOTARY_KEYCHAIN",
                "ASC_KEY_PATH",
                "ASC_KEY_ID",
                "ASC_ISSUER_ID",
            ):
                env.pop(key, None)
            env["PATH"] = str(bin_dir) + os.pathsep + env["PATH"]
            if env_overrides:
                env.update(env_overrides)

            cmd = (
                f'set -euo pipefail; source "{helper}"; {fn_call}; '
                'printf "MODE=%s\\nID=%s\\nNOTARIZE=%s\\nAUTH=%s\\n" '
                '"${MACOS_SIGN_MODE:-}" "${MACOS_SIGN_IDENTITY:-}" '
                '"${MACOS_DO_NOTARIZE:-}" "${MACOS_NOTARY_AUTH[*]-}"'
            )
            return subprocess.run(
                ["bash", "-c", cmd],
                env=env,
                capture_output=True,
                text=True,
            )

    def test_write_privacy_shortcut_creates_valid_inetloc(self):
        script = APPLE_TOOLS_DIR / "write_privacy_shortcut.sh"
        with tempfile.TemporaryDirectory(prefix="xdremux-inetloc-") as tmp:
            res = subprocess.run(
                ["bash", str(script), tmp],
                capture_output=True,
                text=True,
            )
            self.assertEqual(res.returncode, 0, res.stderr)
            inetloc = Path(tmp) / "打开隐私与安全性 (Privacy & Security).inetloc"
            self.assertTrue(inetloc.is_file())
            with inetloc.open("rb") as f:
                data = plistlib.load(f)
            self.assertEqual(
                data["URL"],
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
            )

    def test_auto_falls_back_to_adhoc_when_no_developer_id(self):
        res = self._run_signing_fn(
            "resolve_macos_signing; resolve_macos_notarization",
            mock_bins={"security": "#!/bin/sh\necho '     0 valid identities found'\n"},
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("MODE=ad-hoc", res.stdout)
        self.assertIn("ID=-", res.stdout)
        self.assertIn("NOTARIZE=0", res.stdout)

    def test_auto_picks_matching_team_cert_and_notary_profile(self):
        security = """#!/bin/sh
cat <<'EOF'
  1) AAAA "Developer ID Application: Other Team (OTHER12345)"
  2) BBBB "Developer ID Application: Beet Man (W94G5B6VGC)"
  3) CCCC "Apple Development: Beet Man (W94G5B6VGC)"
     3 valid identities found
EOF
"""
        res = self._run_signing_fn(
            "resolve_macos_signing; resolve_macos_notarization",
            env_overrides={"XDREMUX_NOTARY_PROFILE": "xdremux-notary"},
            mock_bins={"security": security},
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("MODE=developer-id", res.stdout)
        self.assertIn("ID=Developer ID Application: Beet Man (W94G5B6VGC)", res.stdout)
        self.assertIn("NOTARIZE=1", res.stdout)
        self.assertIn("AUTH=--keychain-profile xdremux-notary", res.stdout)

    def test_auto_rejects_ambiguous_developer_id_certs(self):
        security = """#!/bin/sh
cat <<'EOF'
  1) AAAA "Developer ID Application: Alice (W94G5B6VGC)"
  2) BBBB "Developer ID Application: Bob (W94G5B6VGC)"
EOF
"""
        res = self._run_signing_fn(
            "resolve_macos_signing",
            mock_bins={"security": security},
        )
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("multiple Developer ID Application certificates", res.stderr)

    def test_developer_id_mode_requires_cert(self):
        res = self._run_signing_fn(
            "resolve_macos_signing",
            env_overrides={"XDREMUX_MACOS_SIGN": "developer-id"},
            mock_bins={"security": "#!/bin/sh\nexit 0\n"},
        )
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("no Developer ID Application certificate found", res.stderr)

    def test_notarize_requires_developer_id_and_credentials(self):
        res1 = self._run_signing_fn(
            "resolve_macos_signing",
            env_overrides={"XDREMUX_MACOS_SIGN": "ad-hoc", "XDREMUX_NOTARIZE": "1"},
        )
        self.assertNotEqual(res1.returncode, 0)

        res2 = self._run_signing_fn(
            "resolve_macos_signing; resolve_macos_notarization",
            env_overrides={
                "XDREMUX_MACOS_SIGN": "developer-id",
                "XDREMUX_DEVELOPER_ID": "Developer ID Application: Beet Man (W94G5B6VGC)",
                "XDREMUX_NOTARIZE": "1",
            },
        )
        self.assertNotEqual(res2.returncode, 0)
        self.assertIn("XDREMUX_NOTARY_PROFILE", res2.stderr)

    def test_asc_key_credentials_build_notary_auth(self):
        with tempfile.NamedTemporaryFile(suffix=".p8") as key_file:
            res = self._run_signing_fn(
                "resolve_macos_signing; resolve_macos_notarization",
                env_overrides={
                    "XDREMUX_DEVELOPER_ID": "Developer ID Application: Beet Man (W94G5B6VGC)",
                    "ASC_KEY_PATH": key_file.name,
                    "ASC_KEY_ID": "KEY123",
                    "ASC_ISSUER_ID": "ISS456",
                },
            )
            self.assertEqual(res.returncode, 0, res.stderr)
            self.assertIn("NOTARIZE=1", res.stdout)
            self.assertIn(f"AUTH=--key {key_file.name} --key-id KEY123 --issuer ISS456", res.stdout)

    def test_sign_and_verify_sequence_inside_out(self):
        helper = APPLE_TOOLS_DIR / "macos_release_signing.sh"
        with tempfile.TemporaryDirectory(prefix="xdremux-codesign-") as tmp:
            root = Path(tmp)
            app = root / "XDRemux.app"
            fw = app / "Contents/Frameworks/XDRemuxTransferCore.framework"
            fw.mkdir(parents=True)
            ent = root / "ent.plist"
            ent.write_text("<plist/>")
            log = root / "codesign.log"
            bin_dir = root / "bin"
            bin_dir.mkdir()
            cs = bin_dir / "codesign"
            cs.write_text(f"""#!/bin/sh
echo "$*" >> "{log}"
case "$1" in
  -dvv)
    case "$2" in
      *XDRemuxTransferCore.framework)
        echo "Authority=Developer ID Application: Beet Man (W94G5B6VGC)" >&2
        echo "Timestamp=2026-11-26 21:00:00 +0000" >&2
        ;;
      *)
        echo "Authority=Developer ID Application: Beet Man (W94G5B6VGC)" >&2
        echo "flags=0x10000(runtime)" >&2
        echo "Timestamp=2026-11-26 21:00:00 +0000" >&2
        ;;
    esac
    ;;
esac
""")
            cs.chmod(0o755)
            env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ["PATH"])
            res = subprocess.run(
                [
                    "bash",
                    "-c",
                    f'set -euo pipefail; source "{helper}"; '
                    f'sign_macos_bundle_developer_id "{app}" "Developer ID Application: Beet Man (W94G5B6VGC)" "{ent}"; '
                    f'verify_macos_developer_id_signature "{app}"',
                ],
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(res.returncode, 0, res.stderr)
            lines = log.read_text().splitlines()
            self.assertIn("XDRemuxTransferCore.framework", lines[0])
            self.assertNotIn("--options runtime", lines[0])
            self.assertIn("--options runtime", lines[1])
            self.assertIn(f"--entitlements {ent}", lines[1])

    def test_verify_rejects_missing_runtime_or_timestamp(self):
        helper = APPLE_TOOLS_DIR / "macos_release_signing.sh"
        with tempfile.TemporaryDirectory(prefix="xdremux-bad-sig-") as tmp:
            root = Path(tmp)
            app = root / "XDRemux.app"
            app.mkdir()
            bin_dir = root / "bin"
            bin_dir.mkdir()
            cs = bin_dir / "codesign"
            cs.write_text(
                "#!/bin/sh\n"
                "echo 'Authority=Developer ID Application: Test' >&2\n"
                "echo 'Timestamp=none' >&2\n"
            )
            cs.chmod(0o755)
            env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ["PATH"])
            res = subprocess.run(
                [
                    "bash",
                    "-c",
                    f'set -euo pipefail; source "{helper}"; verify_macos_developer_id_signature "{app}"',
                ],
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(res.returncode, 0)

    def test_notarize_and_staple_handles_app_zip_and_dmg(self):
        helper = APPLE_TOOLS_DIR / "macos_release_signing.sh"
        with tempfile.TemporaryDirectory(prefix="xdremux-notary-") as tmp:
            root = Path(tmp)
            app = root / "XDRemux.app"
            (app / "Contents").mkdir(parents=True)
            dmg = root / "XDRemux.dmg"
            dmg.write_bytes(b"dmg")
            log = root / "xcrun.log"
            bin_dir = root / "bin"
            bin_dir.mkdir()
            ditto = bin_dir / "ditto"
            ditto.write_text("#!/bin/sh\nfor last; do :; done\ntouch \"$last\"\n")
            ditto.chmod(0o755)
            xcrun = bin_dir / "xcrun"
            xcrun.write_text(f"""#!/bin/sh
echo "$*" >> "{log}"
if [ "$1" = "notarytool" ]; then
  echo "  id: 11111111-2222-3333-4444-555555555555"
fi
if [ "${{FAIL_SUBMIT:-0}}" = "1" ] && [ "$1" = "notarytool" ]; then
  exit 3
fi
""")
            xcrun.chmod(0o755)
            env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ["PATH"])
            env["TMPDIR"] = str(root / "tmp")
            Path(env["TMPDIR"]).mkdir()

            res_app = subprocess.run(
                [
                    "bash",
                    "-c",
                    f'set -euo pipefail; source "{helper}"; '
                    f'MACOS_NOTARY_AUTH=(--keychain-profile test-prof); '
                    f'XDREMUX_NOTARY_TIMEOUT=15m; '
                    f'notarize_and_staple_target "{app}"',
                ],
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(res_app.returncode, 0, res_app.stderr)
            self.assertEqual(list(Path(env["TMPDIR"]).iterdir()), [])

            res_dmg = subprocess.run(
                [
                    "bash",
                    "-c",
                    f'set -euo pipefail; source "{helper}"; '
                    f'MACOS_NOTARY_AUTH=(--keychain-profile test-prof); '
                    f'notarize_and_staple_target "{dmg}"',
                ],
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(res_dmg.returncode, 0, res_dmg.stderr)

            log_lines = log.read_text().splitlines()
            self.assertIn("notarytool submit ", log_lines[0])
            self.assertIn(".zip --keychain-profile test-prof --wait --timeout 15m", log_lines[0])
            self.assertEqual(log_lines[1], f"stapler staple {app}")
            self.assertEqual(log_lines[2], f"stapler validate {app}")
            self.assertEqual(log_lines[3], f"notarytool submit {dmg} --keychain-profile test-prof --wait")
            self.assertEqual(log_lines[4], f"stapler staple {dmg}")
            self.assertEqual(log_lines[5], f"stapler validate {dmg}")

            env["FAIL_SUBMIT"] = "1"
            res_fail = subprocess.run(
                [
                    "bash",
                    "-c",
                    f'set -euo pipefail; source "{helper}"; '
                    f'MACOS_NOTARY_AUTH=(--keychain-profile test-prof); '
                    f'notarize_and_staple_target "{app}"',
                ],
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(res_fail.returncode, 0)
            self.assertIn("11111111-2222-3333-4444-555555555555", res_fail.stderr)
            self.assertIn("xcrun notarytool info 11111111-2222-3333-4444-555555555555", res_fail.stderr)
            self.assertEqual(list(Path(env["TMPDIR"]).iterdir()), [])


if __name__ == "__main__":
    unittest.main()
