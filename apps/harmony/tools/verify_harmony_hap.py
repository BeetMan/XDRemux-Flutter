#!/usr/bin/env python3
"""Verify an unsigned native Harmony HAP's package metadata and bundled libs."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import zipfile
from pathlib import Path
from typing import Any


CORE_ENTRY = "libs/arm64-v8a/libxdremux_core.so"
REQUIRED_ENTRIES = (
    "module.json",
    "pack.info",
    "libs/arm64-v8a/libentry.so",
    "libs/arm64-v8a/libc++_shared.so",
    CORE_ENTRY,
)
SIGNATURE_ENTRY = re.compile(
    r"(^|/)(META-INF|SIGNATURES?)(/|$)|\.(sf|rsa|dsa|ec|sig)$", re.IGNORECASE
)
SHA256 = re.compile(r"^[0-9a-f]{64}$", re.IGNORECASE)


class VerificationError(ValueError):
    """The HAP is unreadable or does not match the requested package identity."""


def _read_json(archive: zipfile.ZipFile, entry_name: str) -> dict[str, Any]:
    try:
        parsed = json.loads(archive.read(entry_name))
    except (KeyError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise VerificationError(f"invalid or missing {entry_name}: {error}") from error
    if not isinstance(parsed, dict):
        raise VerificationError(f"{entry_name} must contain a JSON object")
    return parsed


def _require_equal(label: str, actual: Any, expected: Any) -> None:
    if actual != expected:
        raise VerificationError(f"{label} mismatch: expected {expected!r}, got {actual!r}")


def verify_hap(
    hap_path: Path,
    *,
    bundle_name: str,
    flutter_bundle_name: str,
    version_name: str,
    version_code: int,
    compatible_api: int,
    expected_core_sha256: str | None = None,
) -> dict[str, Any]:
    """Check identity/API, unsigned package form, and required arm64 libraries."""
    if bundle_name == flutter_bundle_name:
        raise VerificationError("native bundle name must remain distinct from the Flutter app")
    if expected_core_sha256 is not None and not SHA256.fullmatch(expected_core_sha256):
        raise VerificationError("expected core SHA-256 must be exactly 64 hexadecimal characters")
    if not hap_path.is_file():
        raise VerificationError(f"HAP file not found: {hap_path}")

    try:
        with zipfile.ZipFile(hap_path, "r") as archive:
            entries = {entry.filename for entry in archive.infolist()}
            missing = [name for name in REQUIRED_ENTRIES if name not in entries]
            if missing:
                raise VerificationError("missing required HAP entries: " + ", ".join(missing))

            signatures = sorted(name for name in entries if SIGNATURE_ENTRY.search(name))
            if signatures:
                raise VerificationError("HAP contains signature entries: " + ", ".join(signatures))

            module = _read_json(archive, "module.json")
            package = _read_json(archive, "pack.info")
            app = module.get("app")
            summary = package.get("summary")
            if not isinstance(summary, dict):
                raise VerificationError("pack.info lacks a package summary")
            summary_app = summary.get("app")
            modules = summary.get("modules")
            if not isinstance(app, dict) or not isinstance(summary_app, dict) or not isinstance(modules, list):
                raise VerificationError("HAP metadata lacks app identity or module API summary")
            summary_version = summary_app.get("version")
            if not isinstance(summary_version, dict):
                raise VerificationError("pack.info lacks app version metadata")

            _require_equal("bundle name (module.json)", app.get("bundleName"), bundle_name)
            _require_equal("bundle name (pack.info)", summary_app.get("bundleName"), bundle_name)
            _require_equal("version name (module.json)", app.get("versionName"), version_name)
            _require_equal("version name (pack.info)", summary_version.get("name"), version_name)
            _require_equal("version code (module.json)", app.get("versionCode"), version_code)
            _require_equal("version code (pack.info)", summary_version.get("code"), version_code)

            compatible_apis = [
                item.get("apiVersion", {}).get("compatible")
                for item in modules
                if isinstance(item, dict) and isinstance(item.get("apiVersion"), dict)
            ]
            if not compatible_apis:
                raise VerificationError("pack.info contains no compatible API version")
            if any(value != compatible_api for value in compatible_apis):
                raise VerificationError(
                    f"compatible API mismatch: expected {compatible_api}, got {compatible_apis!r}"
                )

            core_bytes = archive.read(CORE_ENTRY)
            core_hash = hashlib.sha256(core_bytes).hexdigest().upper()
            if expected_core_sha256 is not None:
                _require_equal("packaged core SHA-256", core_hash, expected_core_sha256.upper())
            package_bytes = hap_path.read_bytes()
    except (OSError, zipfile.BadZipFile, RuntimeError) as error:
        if isinstance(error, VerificationError):
            raise
        raise VerificationError(f"cannot read HAP archive: {error}") from error

    return {
        "hapPath": str(hap_path.resolve()),
        "hapBytes": len(package_bytes),
        "hapSha256": hashlib.sha256(package_bytes).hexdigest().upper(),
        "bundleName": bundle_name,
        "versionName": version_name,
        "versionCode": version_code,
        "compatibleApi": compatible_api,
        "unsigned": True,
        "signatureEntries": [],
        "packagedCorePath": CORE_ENTRY,
        "packagedCoreBytes": len(core_bytes),
        "packagedCoreSha256": core_hash,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("hap", type=Path)
    parser.add_argument("--bundle-name", default="io.github.beetman.xdremux.arkui")
    parser.add_argument("--flutter-bundle-name", default="io.github.beetman.xdremux")
    parser.add_argument("--version-name", required=True)
    parser.add_argument("--version-code", required=True, type=int)
    parser.add_argument("--compatible-api", default=18, type=int)
    parser.add_argument("--expected-core-sha256")
    parser.add_argument("--report", type=Path, help="write the verification JSON to this path")
    arguments = parser.parse_args(argv)

    try:
        report = verify_hap(
            arguments.hap,
            bundle_name=arguments.bundle_name,
            flutter_bundle_name=arguments.flutter_bundle_name,
            version_name=arguments.version_name,
            version_code=arguments.version_code,
            compatible_api=arguments.compatible_api,
            expected_core_sha256=arguments.expected_core_sha256,
        )
    except VerificationError as error:
        print(f"HAP verification failed: {error}", file=sys.stderr)
        return 1

    serialized = json.dumps(report, indent=2, ensure_ascii=False)
    print(serialized)
    if arguments.report is not None:
        arguments.report.write_text(serialized + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
