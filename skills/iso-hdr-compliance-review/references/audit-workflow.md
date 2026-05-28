# Audit Workflow

## Task Triage

Classify the task before reading widely:

- HEIC output audit: run validators first, then inspect failing rule groups.
- Code change audit: map touched code to rule groups, then run targeted files or tests.
- Report review: check claims against `source-docs.md`, latest validation output, and `docs/xdremux/iso-compliance-report-v2-20260514.md`.
- Validator change: verify that the parser rule matches ISO source and that at least one fixture or sample exercises the path.

## Command Templates

Single-file baseline:

```bash
python3 evals/test_heic_parser.py <file.heic>
python3 scripts/iso_comprehensive_check.py --json <file.heic>
```

Strict modes:

```bash
python3 evals/test_heic_parser.py --strict-should <file.heic>
python3 evals/test_heic_parser.py --strict-iso-tmap <file.heic>
```

Matrix regression:

```bash
python3 scripts/run_compliance_tests.py
```

Apple recognition for Swift/ImageIO outputs:

```bash
swift tools/swift/apple_imageio_dump.swift <file.heic> /tmp/<label>_imageio.json
swift tools/swift/check_hdr.swift <file.heic>
```

When output is large, store JSON in `/tmp` and summarize only the failing rule ids, warning ids, and compatibility choices.

## Finding Format

Use this compact format:

```text
<CLASS> <RULE_ID>: <short title>
Source: <standard section> via <source file or reference>
Evidence: <command or file:line>
Impact: <why it matters>
Fix: <smallest repair or reason no code change is appropriate>
```

Classes:

- `SHALL_FAIL`: violates a mandatory requirement or validator-equivalent.
- `SHOULD_GAP`: violates a recommendation or quality guidance.
- `REPO_POLICY`: enforced by this repository's validator or compatibility profile beyond explicit ISO normative language.
- `COMPAT_CHOICE`: intentional divergence for Apple/CoreImage or OPPO compatibility.
- `FUNCTIONAL_RISK`: not ISO compliance itself, but affects platform HDR recognition.
- `DOC_CONFLICT`: documentation or report is stale relative to validation artifacts.

## Self-Review Loop

Before declaring completion, ask these questions in order:

1. Source coverage: Did I check every affected rule group in `rule-map.md` against the ISO source index or latest validation report?
2. Artifact coverage: Did I validate the exact output, mode, branch, or code path the user asked about?
3. Strictness coverage: Did I separate `SHALL`, `SHOULD`, compatibility, and functional platform recognition?
4. Payload coverage: Did I avoid treating Apple 62B payload as strict ISO C.2.2 metadata?
5. Parser coverage: If I rely on a validator, does that validator actually check the rule I cite?
6. Residual risk: Is any remaining uncertainty caused by missing samples, device-only behavior, ImageIO behavior, or a parser limitation?

If any answer is not defensible:

1. Name the hole precisely.
2. Read the smallest ISO section, code path, or validation artifact that can close it.
3. Add a targeted check, adjust the report, or mark residual risk.
4. Repeat the loop.

Completion is acceptable when no known affected `SHALL` rule lacks source evidence and validation, every affected `SHOULD` is either satisfied or explicitly classified, repository policy is separated from ISO normative language, and compatibility choices are not mislabeled as strict conformance.

## Repair Guidance

- For missing container structure or property associations, prefer targeted changes in the writer or patcher plus a parser test.
- For parser gaps, add a narrow validator check with a fixture or real generated sample where possible.
- For ImageIO limitations, document the API boundary and preserve functional validation evidence.
- For documentation drift, update the latest report or source map with exact command evidence.
- Do not run full `make verify` unless the user requests full verify or the change crosses module/CI boundaries.
