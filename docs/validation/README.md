# Validation

This directory is for validation notes that explain how XDRemux outputs should be checked.

Good validation documents should distinguish:

- Structural checks: HEIF/ISOBMFF boxes, item references, metadata placement, gain-map association.
- Renderer checks: ImageIO recognition, Apple Photos behavior, Android/OPPO Gallery behavior.
- Regression checks: output hashes, metadata snapshots, and known sample behavior.
- Device checks: real-device observations such as HDR badge visibility or EDR brightness changes.

Keep actual test executables under `tests/` or `scripts/`; keep the rationale, acceptance criteria, and runbooks here.
