import io
import struct
import unittest
import zipfile

from verify_apk import verify_apk


def fixture(abi="arm64-v8a", missing=None, wrong_machine=None, extra_abi=None):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as package:
        for name in ("libapp.so", "libflutter.so", "libxdremux_core.so", "libc++_shared.so"):
            if name == missing:
                continue
            header = bytearray(64)
            header[:6] = b"\x7fELF\x02\x01"
            machine = wrong_machine if name == "libxdremux_core.so" and wrong_machine else 183
            struct.pack_into("<H", header, 18, machine)
            package.writestr(f"lib/{abi}/{name}", header)
        if extra_abi:
            package.writestr(f"lib/{extra_abi}/libflutter.so", b"unexpected foreign engine")
    output.seek(0)
    return output


class AndroidABIGuardTest(unittest.TestCase):
    def test_complete_arm64_payload_passes(self):
        data = fixture()
        with zipfile.ZipFile(data) as package:
            self.assertIsNone(package.testzip())
        data.seek(0)
        self.assertEqual(verify_apk(data)["abis"], ["arm64-v8a"])

    def test_foreign_flutter_engines_fail_even_when_core_is_arm64(self):
        for abi in ("armeabi-v7a", "x86_64"):
            with self.subTest(abi=abi), self.assertRaisesRegex(ValueError, "ARM64-only"):
                verify_apk(fixture(extra_abi=abi))

    def test_missing_required_library_fails(self):
        with self.assertRaisesRegex(ValueError, "Missing Android native payload"):
            verify_apk(fixture(missing="libxdremux_core.so"))

    def test_mislabeled_elf_fails(self):
        with self.assertRaisesRegex(ValueError, "Not an ARM64 ELF"):
            verify_apk(fixture(wrong_machine=62))

    def test_bad_crc_fails(self):
        data = fixture()
        with zipfile.ZipFile(data) as package:
            header = package.getinfo("lib/arm64-v8a/libapp.so").header_offset
        corrupt = bytearray(data.getvalue())
        name_size, extra_size = struct.unpack_from("<HH", corrupt, header + 26)
        corrupt[header + 30 + name_size + extra_size + 63] ^= 1
        with self.assertRaisesRegex(ValueError, "CRC mismatch"):
            verify_apk(io.BytesIO(corrupt))


if __name__ == "__main__":
    unittest.main()
