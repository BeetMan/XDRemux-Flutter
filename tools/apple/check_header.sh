#!/bin/bash
# Fail when xdremux/rust/include/xdremux_core.h is out of date with lib.rs.
# Used locally and in CI; requires `cargo install cbindgen`.
set -euo pipefail
cd "$(dirname "$0")/../../xdremux/rust"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
cbindgen --config cbindgen.toml --crate xdremux-core --output "$tmp" --quiet
if ! diff -u include/xdremux_core.h "$tmp"; then
  echo "xdremux_core.h is stale; regenerate with:" >&2
  echo "  cbindgen --config cbindgen.toml --crate xdremux-core --output include/xdremux_core.h" >&2
  exit 1
fi
echo "xdremux_core.h is up to date"
