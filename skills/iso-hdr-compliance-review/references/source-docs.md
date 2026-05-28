# Source Documents

Use this file as the source index for ISO standard references.

## ISO Standards

Use English files for exact clause checks and Chinese files for terminology cross-checks.

- ISO 21496-1:2025
- ISO/IEC 23008-12:2025
- ISO/IEC 23008-12:2025/Amd.1:2025

## Useful Clause Ranges

ISO 21496-1:2025:

- Sections 4.1-4.5, gain map requirements
- Sections 5.2.2-5.2.8, required metadata
- Sections 5.3.2-5.3.4, colorimetry metadata
- Sections 6.2-6.3, unnormalize/resample/apply algorithm
- Annex C.2, binary metadata payload and semantics

ISO/IEC 23008-12:2025:

- Sections 5.1-5.4, general file/reader requirements
- Sections 6.1-6.4.2, file-level `meta`, primary item, hidden items, `altr`
- Sections 6.5.1-6.5.6, item properties, `ispe`, `colr`, `pixi`
- Sections 6.5.10 and 6.5.14, `irot` and `clli`
- Sections 6.6.1-6.6.2.3, `dimg` and `grid` derived images
- Section 6.7 and Annex A.3, metadata item and XMP storage
- Section 10.2.2, `mif1` structural brand
- Annex B.2/B.4.1, HEVC image item and HEVC brands

ISO/IEC 23008-12:2025/Amd.1:2025:

- Terms 3.1.54-3.1.56, tmap/base/gain map item definitions
- Section 6.6.2.4, tone-map derivation rules
- Section 10.2.6, `tmap` brand
- Clause J.7, tone-map derivation example

## Repository Evidence

- Latest broad audit: `docs/xdremux/iso-compliance-report-v2-20260514.md`
- Earlier audit and compatibility notes: `docs/xdremux/iso-conformance-audit-20260511.md`
- Single-file comprehensive checker: `scripts/iso_comprehensive_check.py`
- Base HEIC parser/validator: `evals/test_heic_parser.py`
- Low-level GainMapMetadata checks: `scripts/_iso_check_parse.py`
- Matrix runner: `scripts/run_compliance_tests.py`

## Existing Compatibility Decisions

- Apple 62B `tmap` payload is a deliberate compatibility path and should be reported as `COMPAT_CHOICE`, not strict ISO C.2.2 conformance.
- Strict ISO `ToneMapImage` payload is 1 byte `version` plus ISO 21496-1 `GainMapMetadata`; current helper and validators treat 65B one-channel and 145B three-channel payloads as strict paths.
- Half-resolution gain maps are a known ISO 21496-1 SHOULD gap or accepted optimization depending on review mode. ISO 21496-1 allows resampling, but maximum-accuracy guidance prefers matching base dimensions.
- Swift `clli` on `tmap` is a known SHOULD-level gap when ImageIO does not expose a write path.
