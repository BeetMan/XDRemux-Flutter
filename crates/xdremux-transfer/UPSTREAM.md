# LocalSend core provenance

`vendor/localsend/` is a source subset of [LocalSend v1.18.2](https://github.com/localsend/localsend/tree/af0416be50770a97760f7070684bc667b759a15c/packages/core), commit `af0416be50770a97760f7070684bc667b759a15c`. The original `src/`, `assets/`, `examples/` and `Cargo.toml` are copied, together with the repository's Apache-2.0 `LICENSE`. Original file SHA-256 values are in `vendor/localsend/upstream-files.json`. XDRemux's wrapper is MIT; this does not relicense LocalSend.

XDRemux modifications (all reproducible using `patch-vendor.py`):

- Add a transactional stream target. The consumer receives both chunks and an explicit clean-body signal; the server returns success only after the consumer confirms validation and final storage commit. Checksum mismatch maps to protocol 422.
- Limit request and response JSON to 1 MiB; metadata requests have a 10-second body deadline. Discard remote error strings, exposing HTTP status only.
- Bind pending/active sessions, uploads and cancellations to the authenticated client certificate as well as the IP. Include certificate identity in outgoing-cancel events.
- Allow explicit address binding, retaining the original port-only entry point. Bound accepted connections to 64 per listener and TLS handshakes to five seconds.
- Allow local pending-session cancellation, check cancellation during acceptance, and scope pending-session guard cleanup to its session ID.
- Replace upstream tracing calls with unit expressions; their arguments include paths and token-bearing URLs. Allow resulting diagnostic-only unused items in this private copy. The wrapper publishes redacted errors and structured events instead.

Normal builds use the committed source and `Cargo.lock`; no upstream clone, Git submodule or bootstrap is needed. To regenerate, use a clean checkout at the exact commit, then run `python patch-vendor.py <checkout>/packages/core`. Review the diff and rerun the complete transfer suite after any regeneration or upgrade. The script refuses tracked changes and untracked files in the source subtree. Do not format the vendored dependency when formatting the wrapper.

This is a pinned internal core, not a stable upstream SDK. HTTP and multicast features are enabled; WebRTC is disabled. Some upstream signaling code/dependencies remain unconditional. Native builds currently pin Rust 1.97.1. License aggregation for all actually distributed dependencies remains part of release preparation.
