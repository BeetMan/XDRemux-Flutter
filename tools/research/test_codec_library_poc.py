import unittest

from codec_library_poc import metadata_comparison, rust_report


class ComparisonTests(unittest.TestCase):
    def test_scalar_metadata_matches_replicated_rust_channels(self):
        floats = [1, 1, 1, 0, 4, 4, 4, 1, 1, 1, 0, 0, 0, 0, 0, 0, 1, 4, 4, 0]
        reference = "\n".join(["--minContentBoost 1", "--maxContentBoost 4", "--gamma 1",
                               "--offsetSdr 0", "--offsetHdr 0", "--hdrCapacityMin 1",
                               "--hdrCapacityMax 4"])
        self.assertTrue(metadata_comparison(reference, floats)["allMatch"])
        self.assertFalse(metadata_comparison(reference.replace("--gamma 1", "--gamma 2"),
                                             floats)["allMatch"])

    def test_identity_fallback_is_not_an_hdr_mismatch(self):
        self.assertFalse(metadata_comparison("", [1] * 20)["compared"])

    def test_application_color_space_flag_is_compared_when_available(self):
        floats = [1, 1, 1, 0, 4, 4, 4, 1, 1, 1, 0, 0, 0, 0, 0, 0, 1, 4, 4, 0]
        reference = "\n".join(["--minContentBoost 1", "--maxContentBoost 4", "--gamma 1",
                               "--offsetSdr 0", "--offsetHdr 0", "--hdrCapacityMin 1",
                               "--hdrCapacityMax 4", "--useBaseColorSpace 0"])
        self.assertTrue(metadata_comparison(reference, floats, False)["allMatch"])
        self.assertFalse(metadata_comparison(reference, floats, True)["allMatch"])

    def test_reference_only_is_not_a_successful_comparison(self):
        self.assertFalse(metadata_comparison("--gamma 1", None)["compared"])

    def test_missing_reference_field_is_not_a_match(self):
        self.assertFalse(metadata_comparison("--gamma 1", [1] * 20)["allMatch"])

    def test_rust_diagnostics_do_not_hide_json(self):
        self.assertEqual(rust_report({"stdout": 'warning\n{"ok": true}\n'}), {"ok": True})
        self.assertIsNone(rust_report({"stdout": "no report"}))


if __name__ == "__main__":
    unittest.main()
