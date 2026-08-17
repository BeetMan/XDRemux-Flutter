#!/bin/bash
# Golden corpus generator for the Apple-features Rust port (research R2/R3).
#
# Samples are user photos and never enter git; this script regenerates the
# reference outputs from a local sample directory on demand.
#
# Usage:
#   tools/golden_corpus.sh <sample-dir> <out-dir>
#
# Requires:
#   - upstream XDRemux checkout built (auto-detected from Xcode SPM cache)
#   - /opt/homebrew/bin on PATH for the zstd CLI the macOS helpers use
#
# Produces under <out-dir>:
#   standard/<name>.heic                 Swift standard HDR output
#   styles/<name>.heic                   Styles output (constrained solver)
#   styles-identity/<name>.heic          Styles output (identity fallback)
#   debug/<name>/...                     per-sample debug dumps (scene
#                                        bundle, mattes, styleData, bplist)
#   inventory/<name>.{std,styles}.json   xdremux-conformance dumps
set -euo pipefail

SAMPLE_DIR="${1:?usage: golden_corpus.sh <sample-dir> <out-dir>}"
OUT_DIR="${2:?usage: golden_corpus.sh <sample-dir> <out-dir>}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$(ls -t ~/Library/Developer/Xcode/DerivedData/Runner-*/SourcePackages/checkouts/XDRemux/.build/debug/xdremux 2>/dev/null | head -1)"
if [ -z "$CLI" ] || [ ! -x "$CLI" ]; then
  echo "error: upstream xdremux CLI not found; open the macOS Flutter app once" >&2
  echo "       (Xcode resolves the SPM checkout) and rebuild via 'swift build'." >&2
  exit 1
fi
CONFORMANCE="$REPO_ROOT/target/release/xdremux-conformance"
[ -x "$CONFORMANCE" ] || { echo "error: build xdremux-conformance first (cargo build --release)" >&2; exit 1; }

export PATH="/opt/homebrew/bin:/usr/bin:/bin:$PATH"
mkdir -p "$OUT_DIR"/{standard,styles,styles-identity,debug,inventory}

for input in "$SAMPLE_DIR"/*.heic; do
  name="$(basename "$input" .heic)"
  echo "==> $name"

  "$CLI" convert --input "$input" \
    --output "$OUT_DIR/standard/$name.heic" 2>/dev/null || echo "  standard: FAILED"

  "$CLI" convert --input "$input" \
    --output "$OUT_DIR/styles/$name.heic" \
    --apple-photographic-styles --debug-dir "$OUT_DIR/debug" 2>/dev/null \
    || echo "  styles(constrained): FAILED"

  "$CLI" convert --input "$input" \
    --output "$OUT_DIR/styles-identity/$name.heic" \
    --apple-photographic-styles --apple-style-data-producer identity-fallback \
    --debug-dir "$OUT_DIR/debug" 2>/dev/null \
    || echo "  styles(identity): FAILED"

  "$CONFORMANCE" dump "$OUT_DIR/standard/$name.heic" \
    "$OUT_DIR/inventory/$name.std.json" 2>/dev/null || true
  "$CONFORMANCE" dump "$OUT_DIR/styles/$name.heic" \
    "$OUT_DIR/inventory/$name.styles.json" 2>/dev/null || true
done

echo "==> corpus complete under $OUT_DIR"
