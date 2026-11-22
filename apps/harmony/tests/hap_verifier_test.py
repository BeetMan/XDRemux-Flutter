from __future__ import annotations

import json
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS))
from verify_harmony_hap import VerificationError, verify_hap  # noqa: E402


def make_hap(path: Path, *, version_code: int = 40010, signed: bool = False) -> None:
    module = {
        "app": {
            "bundleName": "io.github.beetman.xdremux.arkui",
            "versionName": "0.4.2",
            "versionCode": version_code,
        }
    }
    package = {
        "summary": {
            "app": {
                "bundleName": "io.github.beetman.xdremux.arkui",
                "version": {"name": "0.4.2", "code": version_code},
            },
            "modules": [{"apiVersion": {"compatible": 18}}],
        }
    }
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("module.json", json.dumps(module))
        archive.writestr("pack.info", json.dumps(package))
        archive.writestr("libs/arm64-v8a/libentry.so", b"entry")
        archive.writestr("libs/arm64-v8a/libc++_shared.so", b"cxx")
        archive.writestr("libs/arm64-v8a/libxdremux_core.so", b"rust-core")
        if signed:
            archive.writestr("META-INF/HAP.RSA", b"signature")


class HapVerifierTest(unittest.TestCase):
    def test_accepts_expected_unsigned_package_and_reports_core_hash(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            hap = Path(temporary) / "test.hap"
            make_hap(hap)
            report = verify_hap(
                hap,
                bundle_name="io.github.beetman.xdremux.arkui",
                flutter_bundle_name="io.github.beetman.xdremux",
                version_name="0.4.2",
                version_code=40010,
                compatible_api=18,
            )
        self.assertTrue(report["unsigned"])
        self.assertEqual(report["packagedCoreBytes"], len(b"rust-core"))
        self.assertEqual(len(report["packagedCoreSha256"]), 64)

    def test_rejects_bundle_or_version_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            hap = Path(temporary) / "test.hap"
            make_hap(hap)
            for options in (
                {"bundle_name": "io.github.beetman.xdremux"},
                {"version_code": 40011},
            ):
                with self.subTest(options=options), self.assertRaises(VerificationError):
                    verify_hap(
                        hap,
                        bundle_name=options.get("bundle_name", "io.github.beetman.xdremux.arkui"),
                        flutter_bundle_name="io.github.beetman.xdremux",
                        version_name="0.4.2",
                        version_code=options.get("version_code", 40010),
                        compatible_api=18,
                    )

    def test_rejects_signature_entry(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            hap = Path(temporary) / "test.hap"
            make_hap(hap, signed=True)
            with self.assertRaisesRegex(VerificationError, "signature entries"):
                verify_hap(
                    hap,
                    bundle_name="io.github.beetman.xdremux.arkui",
                    flutter_bundle_name="io.github.beetman.xdremux",
                    version_name="0.4.2",
                    version_code=40010,
                    compatible_api=18,
                )

    def test_rejects_packaged_core_hash_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            hap = Path(temporary) / "test.hap"
            make_hap(hap)
            with self.assertRaisesRegex(VerificationError, "core SHA-256 mismatch"):
                verify_hap(
                    hap,
                    bundle_name="io.github.beetman.xdremux.arkui",
                    flutter_bundle_name="io.github.beetman.xdremux",
                    version_name="0.4.2",
                    version_code=40010,
                    compatible_api=18,
                    expected_core_sha256="0" * 64,
                )

    def test_rejects_flutter_bundle_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            hap = Path(temporary) / "test.hap"
            make_hap(hap)
            with self.assertRaisesRegex(VerificationError, "distinct from the Flutter app"):
                verify_hap(
                    hap,
                    bundle_name="io.github.beetman.xdremux",
                    flutter_bundle_name="io.github.beetman.xdremux",
                    version_name="0.4.2",
                    version_code=40010,
                    compatible_api=18,
                )


if __name__ == "__main__":
    unittest.main()
