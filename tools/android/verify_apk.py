"""Reject APKs advertising ABIs unsupported by the bundled Rust core."""
import json
from pathlib import Path
import struct
import sys
import zipfile


def verify_apk(path):
    with zipfile.ZipFile(path) as package:
        bad_member = package.testzip()
        if bad_member is not None:
            raise ValueError(f"APK CRC mismatch: {bad_member}")
        libraries = [name for name in package.namelist()
                     if name.startswith("lib/") and name.endswith(".so")]
        abis = {name.split("/")[1] for name in libraries}
        if abis != {"arm64-v8a"}:
            raise ValueError(f"APK must be ARM64-only; found ABIs: {sorted(abis)}")
        required = {"libapp.so", "libflutter.so", "libxdremux_core.so",
                    "libc++_shared.so", "libxdremux_transfer.so"}
        missing = required - {name.rsplit("/", 1)[1] for name in libraries}
        if missing:
            raise ValueError(f"Missing Android native payload: {sorted(missing)}")
        for name in libraries:
            with package.open(name) as library:
                header = library.read(64)
            if (len(header) < 64 or header[:6] != b"\x7fELF\x02\x01"
                    or struct.unpack_from("<H", header, 18)[0] != 183):
                raise ValueError(f"Not an ARM64 ELF library: {name}")
        return {"abis": sorted(abis),
                "elf_libraries": len(libraries), "crc": "pass"}


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: verify_apk.py <release.apk>")
    try:
        print(json.dumps({"apk": Path(sys.argv[1]).name, **verify_apk(sys.argv[1])}, indent=2))
    except (ValueError, OSError, zipfile.BadZipFile) as error:
        raise SystemExit(str(error))
