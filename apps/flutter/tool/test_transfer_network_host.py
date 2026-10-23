"""Offline checks for operator approvals, metadata and owned fixture creation."""
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest

import transfer_network_host as host


class NetworkHostTests(unittest.TestCase):
    def request(self, action="confirm-initial"):
        return {"checkpoint_id": "fresh", "action": action, "fingerprint": "A" * 64}

    def test_stale_checkpoint_never_authorizes_an_action(self):
        with self.assertRaisesRegex(RuntimeError, "Stale"):
            host.validate_answer({"checkpoint_id": "old", "action": "confirm-initial", "fingerprint": "A" * 64}, self.request())

    def test_wrong_action_never_substitutes_for_confirmation(self):
        with self.assertRaisesRegex(RuntimeError, "Wrong"):
            host.validate_answer({"checkpoint_id": "fresh", "action": "network-down"}, self.request())

    def test_fingerprint_mismatch_prevents_retry_approval(self):
        with self.assertRaisesRegex(RuntimeError, "Fingerprint"):
            host.validate_answer({"checkpoint_id": "fresh", "action": "confirm-retry", "fingerprint": "B" * 64}, self.request("confirm-retry"))

    def test_reconnect_requires_private_ipv4_and_explicit_adb_device(self):
        for address in ["127.0.0.1", "0.0.0.0", "224.0.0.167", "8.8.8.8", "::1"]:
            with self.subTest(address=address), self.assertRaises(RuntimeError):
                host.validate_answer({"checkpoint_id": "fresh", "action": "reconnect", "host": address, "device": "selected"}, self.request("reconnect"))
        with self.assertRaisesRegex(RuntimeError, "ADB"):
            host.validate_answer({"checkpoint_id": "fresh", "action": "reconnect", "host": "192.168.1.2"}, self.request("reconnect"))

    def test_offer_cannot_expand_to_other_files_or_metadata(self):
        manifest = {"pnet-one.bin": {"name": "pnet-one.bin", "size": host.SIZE, "sha256": "a" * 64}}
        for files in [[{"name": "personal.heic", "size": host.SIZE, "sha256": "a" * 64}],
                      [{"name": "pnet-one.bin", "size": host.SIZE - 1, "sha256": "a" * 64}],
                      [{"name": "pnet-one.bin", "size": host.SIZE, "sha256": "b" * 64}],
                      [manifest["pnet-one.bin"], manifest["pnet-one.bin"]]]:
            with self.subTest(files=files), self.assertRaises(RuntimeError):
                host.validate_offer(files, ["pnet-one.bin"], manifest)

    def test_prepare_is_not_device_pass_and_refuses_to_clobber(self):
        with tempfile.TemporaryDirectory(prefix="xdremux-network-check-") as temporary:
            directory = Path(temporary) / "pnet-0123456789abcdef"
            with contextlib.redirect_stdout(io.StringIO()):
                host.prepare(directory)
            manifest = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["deviceValidation"], "not_run")
            self.assertEqual(len(manifest["files"]), 2)
            self.assertNotEqual(manifest["files"][0]["sha256"], manifest["files"][1]["sha256"])
            original = host.digest(directory / host.NAMES[0])
            with self.assertRaises(FileExistsError):
                host.prepare(directory)
            self.assertEqual(host.digest(directory / host.NAMES[0]), original)

    def test_valid_confirmation_is_explicit_and_case_insensitive(self):
        answer = {"checkpoint_id": "fresh", "action": "confirm-initial", "fingerprint": "a" * 64}
        self.assertIs(host.validate_answer(answer, self.request()), answer)


if __name__ == "__main__":
    unittest.main()
