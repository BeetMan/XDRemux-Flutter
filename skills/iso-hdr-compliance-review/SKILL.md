---
name: iso-hdr-compliance-review
description: Audit ISO HDR gain-map and HEIF compliance for ProXDR/LHDR/UHDR work. Use when reviewing HEIC/HEIF outputs, XDRemux Python or Swift changes, ISO 21496-1 GainMapMetadata, ISO/IEC 23008-12 image items/properties, ISO/IEC 23008-12 Amd.1 tmap tone-map derived items, hdrgm XMP, Apple 62B tmap compatibility, strict ISO tmap payloads, or compliance reports.
---

# ISO HDR Compliance Review

## Purpose

Use this skill to perform standards-grounded compliance reviews for XDRemux and related ProXDR/LHDR/UHDR HEIC work. Keep ISO wording out of reports except for short identifiers; cite standard, section, rule id, command evidence, and repository artifact instead.

## Source Order

1. Treat `organized/` and the latest validation artifacts as the repository truth for research conclusions.
2. Use the ISO documents in `docs/` as primary standards facts. Prefer English files for exact clause wording; use `_zh.md` files to clarify Chinese terminology.
3. Use existing validators before making new claims: `scripts/test_heic_parser.py`, `scripts/iso_comprehensive_check.py`, and `scripts/run_compliance_tests.py`.
4. Do not convert compatibility choices into strict ISO conformance claims. The repo currently distinguishes Apple 62B tmap payload compatibility from strict ISO `ToneMapImage + GainMapMetadata` payloads.

## References

Read only the reference needed for the task:

- `references/source-docs.md`: ISO source files, useful section line ranges, and repository evidence files.
- `references/rule-map.md`: Review checklist with rule ids, severity, ISO source, and validator coverage.
- `references/audit-workflow.md`: Audit workflow, command templates, output format, and self-review loop.

## Quick Workflow

1. Identify the artifact under review: HEIC file, generator code path, validator, report, or proposed change.
2. Determine the mode and compatibility target: Python vs Swift, passthrough vs reencode, OPPO compatibility, Apple 62B payload vs strict ISO 65B/145B payload.
3. Load `references/rule-map.md` and check only affected rule groups. Use file-level groups for container patches, `T*` for tmap changes, `M*` for strict payload changes, and `G*` for gain map image data.
4. Run the smallest matching validation:
   - Single HEIC: `python3 scripts/test_heic_parser.py <file.heic>`
   - Single HEIC comprehensive: `python3 scripts/iso_comprehensive_check.py --json <file.heic>`
   - SHOULD audit: `python3 scripts/test_heic_parser.py --strict-should <file.heic>`
   - Strict ISO tmap payload: `python3 scripts/test_heic_parser.py --strict-iso-tmap <file.heic>`
   - Matrix regression: `python3 scripts/run_compliance_tests.py`
   - Apple recognition, Swift outputs: `swift tools/swift/apple_imageio_dump.swift <file.heic> /tmp/<label>_imageio.json` and `swift tools/swift/check_hdr.swift <file.heic>`
5. Classify each issue as `SHALL_FAIL`, `SHOULD_GAP`, `REPO_POLICY`, `COMPAT_CHOICE`, `FUNCTIONAL_RISK`, or `DOC_CONFLICT`.
6. Report each finding with rule id, ISO source, file or command evidence, impact, and smallest repair.

## Guardrails

- Preserve repository layer boundaries: `oracle-dump/` must not depend on `tools/`; `tools/` must not depend on `oracle-dump/` runtime objects.
- Use Targeted Fix Mode unless the user asks for full verify, release/preflight, cross-module refactor, or CI rule changes.
- Do not read whole standards into context. Search headings and cite section ids or the source index.
- Do not quote long ISO text into code comments, docs, reports, or skill files. Paraphrase requirements into review rules.
- When a parser or validator lacks coverage for a rule affected by a code change, either add a targeted check or explicitly mark the residual risk.
- Keep Apple/CoreImage functional recognition separate from ISO compliance. Passing `check_hdr.swift` is not proof of strict ISO payload conformance.

## Completion Bar

Before calling the review complete, run the self-review loop in `references/audit-workflow.md`. Ask: "Do I have factual confidence that every affected SHALL/SHOULD/compatibility rule is covered by source evidence and validation?" If not, identify the specific hole, inspect the smallest source or artifact needed, apply or propose the smallest fix, and repeat.
