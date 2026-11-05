# Tests

This directory is reserved for repository-level validation that is not tied to a specific app shell.

Use this directory for tests and validation harnesses that compare converter behavior across entry points, inspect HEIF/ISOBMFF structure, or validate ISO gain-map metadata.

Current layout:

- `tests/conformance/` holds the conformance crate (`xdremux-conformance`) and `driver.py`. See `docs/testing/conformance-suite.md`.
- Real photos and golden corpora are not committed. Policy is in `fixtures/README.md`.

App-specific tests live with each app. Flutter tests are in `apps/flutter/test/` (`flutter test`). Native Apple tests are in `apps/apple/Packages/XDRemuxKit/Tests/` (`swift test`; build the XCFramework first). Converter correctness tests belong in the Rust core or here, so they do not depend on any app layout.

## Running tests

The fast test suite is self-contained and must not require private photos or
write beside user files:

```powershell
cargo test --workspace
```

Real-photo regression is deliberately opt-in. Point `XDREMUX_SAMPLE_DIR` at a
directory containing only source `.heic` photos, then run the ignored test. It
writes conversion results to a unique temporary directory and deletes them when
the test exits:

```powershell
$env:XDREMUX_SAMPLE_DIR = 'C:\path\to\ProXDR-samples'
cargo test -p xdremux-core --test local_samples -- --ignored --nocapture
```

For cross-implementation inspection and ISOBMFF-structure comparison, use the
conformance driver. It also uses a temporary directory for converted files:

```powershell
python tests/conformance/driver.py `
  --sample-dir $env:XDREMUX_SAMPLE_DIR `
  --out-report conformance_report.md
```

Do not commit real photos. Keep a small inventory next to the local sample
directory with the sample ID, source device, format family, SHA-256, expected
behavior, and notes. Converted variants should use a suffix such as `_py`,
`_final`, `_oppo`, `_out`, `_normal`, or `_iso`; the local regression test skips
those files during discovery.
