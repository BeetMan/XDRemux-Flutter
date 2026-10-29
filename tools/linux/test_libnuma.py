"""Exercise production libnuma cache/download verification without networking."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


@unittest.skipUnless(os.name == "posix", "requires Linux Bash and sha256sum")
class LibnumaVerificationTest(unittest.TestCase):
    def test_cache_and_download_integrity(self):
        source = Path(__file__).resolve().parent
        script = (source / "package_linux.sh").read_text()
        # Run its real resolver functions, stopping before artifact generation.
        prefix, separator, _ = script.partition('\nlibnuma="$(resolve_libnuma)"')
        self.assertTrue(separator)
        package_hash = hashlib.sha256(b"trusted package").hexdigest()
        library_hash = hashlib.sha256(b"trusted library").hexdigest()
        for scenario in ("valid-library", "poisoned-library", "poisoned-package", "bad-download"):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory(prefix="xdremux-numa-") as tmp:
                root = Path(tmp)
                scripts = root / "tools/linux"
                scripts.mkdir(parents=True)
                bundle = root / "bundle"
                bundle.mkdir()
                (bundle / "xdremux").touch(mode=0o755)
                for name in ("xdremux.desktop", "xdremux.png", "install.sh"):
                    (scripts / name).touch()
                cache = root / "cache with spaces/xdremux-linux-packaging"
                cache.mkdir(parents=True)
                library = cache / "libnuma-ubuntu22.04.so.1"
                package = cache / "libnuma1_2.0.14-3ubuntu2_amd64.deb"
                if scenario == "valid-library":
                    library.write_bytes(b"trusted library")
                elif scenario == "poisoned-library":
                    library.write_bytes(b"unverified old library")
                    package.write_bytes(b"trusted package")
                elif scenario == "poisoned-package":
                    package.write_bytes(b"unverified old package")
                driver = scripts / "driver.sh"
                driver.write_text(prefix + '\n' + f'''
LIBNUMA_DEB_SHA256={package_hash}
LIBNUMA_SO_SHA256={library_hash}
find_host_libnuma() {{ return 1; }}
libnuma_is_compatible() {{ return 0; }}
download_with_proxy_fallback() {{
  [[ "$1" == https://* ]] || exit 91
  [[ "$SCENARIO" != valid-library ]] || exit 92
  if [[ "$SCENARIO" == bad-download ]]; then
    printf 'tampered package' > "$2"
  else
    printf 'trusted package' > "$2"
  fi
}}
extract_deb_libnuma() {{
  touch "$TEST_ROOT/extracted"
  printf 'trusted library' > "$2"
}}
resolve_libnuma
''')
                env = dict(os.environ, XDG_CACHE_HOME=str(cache.parent),
                           TEST_ROOT=str(root), SCENARIO=scenario)
                env.pop("XDREMUX_LIBNUMA", None)
                result = subprocess.run(["bash", str(driver), "0.4.5", "--bundle", str(bundle)],
                                        env=env, capture_output=True, text=True)
                if scenario == "bad-download":
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("SHA256 mismatch", result.stderr)
                    self.assertFalse((root / "extracted").exists())
                    self.assertFalse(Path(str(package) + ".part").exists())
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.strip(), str(library))
                    self.assertEqual(library.read_bytes(), b"trusted library")
                    if scenario != "valid-library":
                        self.assertEqual(package.read_bytes(), b"trusted package")


if __name__ == "__main__":
    unittest.main()
