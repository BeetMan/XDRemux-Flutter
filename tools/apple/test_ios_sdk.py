"""Test SDK rejection/API-probe behaviour without installing Xcode."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


@unittest.skipUnless(os.name == "posix", "requires Bash")
class IosSDKPreflightTest(unittest.TestCase):
    def check_sdk(self, version, compiler_exit=0):
        script = Path(__file__).with_name("check_ios_sdk.sh").resolve()
        with tempfile.TemporaryDirectory(prefix="xdremux-apple-") as tmp:
            root = Path(tmp)
            executable_dir = root / "mock tools"
            executable_dir.mkdir()
            mock_build = executable_dir / "xcodebuild"
            mock_build.write_text("#!/bin/sh\nprintf 'Xcode 27.1\\nBuild version test\\n'\n")
            mock_build.chmod(0o755)
            mock_xcrun = executable_dir / "xcrun"
            mock_xcrun.write_text('''#!/bin/sh
test "$1" = --sdk && test "$2" = iphoneos || exit 90
case "$3" in
  --show-sdk-version) printf '%s\\n' "$TEST_SDK_VERSION" ;;
  --show-sdk-path) printf '/mock SDK/iPhoneOS.sdk\\n' ;;
  swiftc)
    printf '%s\\n' "$@" > "$TEST_PROBE_ARGS"
    cat > "$TEST_PROBE_SOURCE"
    exit "$TEST_COMPILER_EXIT"
    ;;
  *) exit 91 ;;
esac
''')
            mock_xcrun.chmod(0o755)
            arguments = root / "arguments"
            source = root / "source"
            env = dict(os.environ, PATH=str(executable_dir) + os.pathsep + os.environ["PATH"],
                       TEST_SDK_VERSION=version, TEST_COMPILER_EXIT=str(compiler_exit),
                       TEST_PROBE_ARGS=str(arguments), TEST_PROBE_SOURCE=str(source))
            result = subprocess.run(["bash", str(script)], env=env,
                                    capture_output=True, text=True)
            return (result, arguments.read_text() if arguments.exists() else None,
                    source.read_text() if source.exists() else None)

    def test_rejects_old_and_malformed_sdks_before_compilation(self):
        for version in ("26.6", "27.0", "27", "unknown", "27.1; echo unsafe"):
            with self.subTest(version=version):
                result, arguments, _ = self.check_sdk(version)
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(arguments)

    def test_supported_sdk_typechecks_real_duo_api(self):
        for version in ("27.1", "27.1.1", "27.2", "28.0"):
            with self.subTest(version=version):
                result, arguments, source = self.check_sdk(version)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("-sdk\n/mock SDK/iPhoneOS.sdk\n", arguments)
                self.assertIn("arm64-apple-ios15.0", arguments)
                self.assertIn("traits.verticalBarEdge", source)
                self.assertIn("case .trailing", source)

    def test_missing_duo_api_is_a_failure_even_with_new_sdk_label(self):
        result, arguments, _ = self.check_sdk("27.1", compiler_exit=42)
        self.assertEqual(result.returncode, 42)
        self.assertIsNotNone(arguments)
        self.assertNotIn("preflight passed", result.stdout)


if __name__ == "__main__":
    unittest.main()
