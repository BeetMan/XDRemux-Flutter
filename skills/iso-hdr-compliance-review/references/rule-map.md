# Compliance Rule Map

Use these rule ids in findings and reports. Treat `SHALL` as blocking unless the user explicitly scopes the work to compatibility-only analysis. Treat `SHOULD` as a gap or warning unless strict mode is requested.

## F: File-Level HEIF Structure

| ID | Type | Source | Check | Validator |
|---|---|---|---|---|
| F01 | SHALL | 23008-12 5.1, 6.2 | Object-structured file with file-level `meta` for image items | `iso_comprehensive_check.py` |
| F02 | SHALL | 23008-12 10.2.2, Annex B.4.1 | `mif1` in `ftyp.compatible_brands` for HEVC image files | `iso_comprehensive_check.py` |
| F03 | SHALL | Amd.1 10.2.6.1 | `tmap` brand present when a tone-map derived item exists | `iso_comprehensive_check.py` |
| F04 | SHALL | 23008-12 Annex B.4.1 | HEVC image brand such as `heic` or `heix` present for HEVC-coded outputs | `iso_comprehensive_check.py` |
| F05 | SHALL | 23008-12 6.2 | File-level `meta` contains required image-item boxes for the brand | `test_heic_parser.py`, `iso_comprehensive_check.py` |
| F06 | SHALL | 23008-12 6.2 | `hdlr.handler_type == "pict"` | `iso_comprehensive_check.py` |
| F07 | SHALL | 23008-12 6.2 | `pitm` primary item exists and identifies a coded or derived image | `test_heic_parser.py` |
| F08 | SHALL | 23008-12 6.2, 10.2.2 | `iinf`, `iloc`, `iprp`, and needed `iref` entries exist | `test_heic_parser.py` |
| F09 | SHALL | 23008-12 6.4.2 | Primary item is not hidden | `iso_comprehensive_check.py` |
| F10 | SHALL | 23008-12 6.4.2 | `altr` groups do not mix hidden and non-hidden image items | `test_heic_parser.py` |
| F11 | SHALL | 23008-12 6.7, Annex A.3 | XMP item, when used, is `mime` with `application/rdf+xml` and `cdsc` references | `test_heic_parser.py` |

## P: Item Properties and Coding

| ID | Type | Source | Check | Validator |
|---|---|---|---|---|
| P01 | SHALL | 23008-12 6.5.3 | Every image item has one `ispe` before transformative properties | `test_heic_parser.py`, `iso_comprehensive_check.py` |
| P02 | SHOULD | 23008-12 6.5.1 | Descriptive properties precede transformative or unrecognized properties | manual or targeted parser |
| P03 | SHALL | 23008-12 B.2.3.1 | `hvc1` items have exactly one essential `hvcC` | `test_heic_parser.py` |
| P04 | SHALL | 23008-12 6.6.1 | At most one `dimg` reference box per `from_item_ID` | `iso_comprehensive_check.py` |
| P05 | SHALL | 23008-12 B.4.1.1 | HEVC image items do not use unsupported essential properties | `iso_comprehensive_check.py` |
| P06 | SHOULD | 23008-12 6.5.14 | `clli` documents relevant HDR representations when appropriate | `--strict-should` and manual |

## T: Tone-Map Derived Item

| ID | Type | Source | Check | Validator |
|---|---|---|---|---|
| T01 | SHALL | Amd.1 6.6.2.4.1 | `tmap` has a `dimg` reference with `reference_count == 2` | `test_heic_parser.py`, `iso_comprehensive_check.py` |
| T02 | SHALL | Amd.1 6.6.2.4.1 | First `dimg.to_item_ID` is base input, second is gain map input | `test_heic_parser.py`, manual for ambiguous files |
| T03 | SHALL | Amd.1 6.6.2.4.1 | Base input image item has `colr` | `iso_comprehensive_check.py` |
| T04 | SHALL | Amd.1 6.6.2.4.1 | Gain map input has `colr` type `nclx` | `iso_comprehensive_check.py` |
| T05 | SHALL | Amd.1 6.6.2.4.1 | Gain map `nclx.colour_primaries == 2` and `transfer_characteristics == 2` | `iso_comprehensive_check.py` |
| T06 | SHALL | Amd.1 6.6.2.4.1 | `tmap` derived image item has `colr` for alternate image colorimetry | `iso_comprehensive_check.py` |
| T07 | SHALL | Amd.1 6.6.2.4.3 | `ToneMapImage.version == 0` | `test_heic_parser.py`, `iso_comprehensive_check.py` |
| T08 | SHOULD | Amd.1 6.6.2.4.1 | Gain map input image is hidden | `--strict-should` |
| T09 | SHOULD | Amd.1 6.6.2.4.1 | Base and `tmap` have `clli` where appropriate | `--strict-should` and manual |
| T10 | SHOULD | Amd.1 6.6.2.4.1 | `tmap` has `pixi` as decoder hint | `--strict-should` |
| T11 | REPO_POLICY | Amd.1 6.6.2.4.1 note | Base input and `tmap` are grouped in `altr` for backward compatibility | `test_heic_parser.py` currently enforces |

## M: Strict ISO 21496-1 GainMapMetadata

Apply these only when reviewing strict ISO `ToneMapImage` payloads. For Apple 62B payloads, mark `COMPAT_CHOICE` and do not claim M-rule conformance.

| ID | Type | Source | Check | Validator |
|---|---|---|---|---|
| M01 | SHALL | 21496-1 5.2.8, C.2.3 | `minimum_version == 0` | `--strict-iso-tmap`, `_iso_check_parse.py` |
| M02 | SHALL | 21496-1 C.2.3 | `writer_version >= minimum_version` | `--strict-iso-tmap` |
| M03 | SHALL | 21496-1 C.2.2/C.2.3 | Reserved flag bits are zero; channel count derives from `is_multichannel` | `--strict-iso-tmap` |
| M04 | SHALL | 21496-1 C.2.3 | All rational denominators are non-zero | `--strict-iso-tmap` |
| M05 | SHALL | 21496-1 5.2.5.3 | `gain_map_max >= gain_map_min` per metadata component | `--strict-iso-tmap` |
| M06 | SHALL | 21496-1 5.2.5.6 | `gamma > 0` | `--strict-iso-tmap` |
| M07 | SHALL | 21496-1 5.2.7 | `alternate_hdr_headroom != baseline_hdr_headroom` | `--strict-iso-tmap` |
| M08 | SHALL | 21496-1 C.2.1 | Payload uses big-endian numeric fields | code review or targeted binary test |

## G: Gain Map Image Requirements

| ID | Type | Source | Check | Validator |
|---|---|---|---|---|
| G01 | SHALL | 21496-1 4.2, 5.2.2; 23008-12 6.5.3 | Gain map dimensions are declared, normally via `ispe` | `iso_comprehensive_check.py` |
| G02 | SHOULD | 21496-1 4.2 | Gain map dimensions equal base dimensions for maximum accuracy | `--strict-should`, comprehensive warning |
| G03 | SHALL | 21496-1 4.3, 5.2.4; 23008-12 6.5.6 | Gain map component count is declared, via `pixi` or codec-derived metadata | `test_heic_parser.py` |
| G04 | SHALL | 21496-1 4.4, 5.2.3 | Gain map bit depth is declared, via `pixi` or codec-derived metadata | `test_heic_parser.py` |
| G05 | SHOULD | 21496-1 4.4 | Gain map bit depth is at least 8 bits per component | `test_heic_parser.py` currently enforces as repo policy |
| G06 | SHALL | 21496-1 4.5; 23008-12 6.5.10 | Gain map orientation matches base orientation | `test_heic_parser.py`, comprehensive `irot_check` |
| G07 | SHALL | 21496-1 6.2.2 | If dimensions differ, review path applies resampling before gain application | code review or decoder behavior evidence |

## Known Review Classifications

- Apple 62B `tmap` payload: `COMPAT_CHOICE`, not M01-M08 conformance.
- Half-resolution gain map: `SHOULD_GAP` in strict review; acceptable compatibility optimization when documented.
- Gain map bit depth below 8: ISO 21496-1 phrases the threshold as SHOULD, while this repository's validator currently treats it as a blocking repo policy failure.
- Swift missing `clli` on `tmap`: `SHOULD_GAP` if still blocked by ImageIO writer APIs.
- OPPO metadata tail or tagflags: functional ecosystem compatibility; not an ISO compliance substitute.
