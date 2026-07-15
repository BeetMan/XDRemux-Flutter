# XDRemux Conformance — Golden Snapshot v1

Generated: Phase B, `fe31900`

## Tier 1+2: Source File Inspect (Rust vs Python)

| Sample | Tier 1 | Tier 2 | XMP |
|--------|--------|--------|-----|
| IMG20260707155054.heic | ✅ 14/14 | ✅ MD5 match | ✅ |
| IMG20260711121521.heic | ✅ 14/14 | ✅ MD5 match | ✅ |

Tolerance: 1e-6. Max observed drift: 5.5e-8 (f32 precision).

## Tier 3: ISOBMFF Structure (Rust vs Swift)

| Field | 55054 | 121521 |
|-------|-------|--------|
| pitm | ✓ 10048 | ✓ 10192 |
| iinf | ✓ 65 items | ✓ 245 items |
| iref | ✓ 6 refs, identical | ✓ 6 refs, identical |
| iloc | ✓ 65 entries | ✓ 245 entries |
| ipma | ✓ 63 associations | ✓ 243 associations |
| ipco | 13 vs 14 (see below) | 13 vs 14 |
| ftyp | lacks "miaf" | lacks "miaf" |

### Known ipco differences (exempt from comparison)

| Property | Rust | Swift | Reason |
|----------|------|-------|--------|
| irot count | 1 | 2 | Swift adds separate irot for gain grid; Rust shares one. Both valid. |
| ispe count | 4 | 5 | Swift adds extra 4096×3072 ispe for tmap; Rust reuses primary grid's ispe. |
| colr count | 3 | 2 | Rust has dedicated sRGB colr for gain grid; Swift uses base grid's colr. |
| clli | 0 | 0 | Removed in Phase B. Neither writes clli now. |

## Tier 4: Pixel Decode (Rust vs Python)

| Metric | 55054 | 121521 |
|--------|-------|--------|
| SDR base YUV MD5 | ✓ bit-exact | ✓ bit-exact |
| gain map tiles | 60 tiles, 512×512 | 240 tiles, 512×512 |
| gain map decodable | ✓ | ✓ |

## Apple ImageIO Verification

All 8 output files (normal + oppo across both samples, Rust + Swift) pass
`CGImageSourceCopyAuxiliaryDataInfoAtIndex(kCGImageAuxiliaryDataTypeISOGainMap)`.

## Reproduction

```bash
cargo build --workspace
python3 tests/conformance/driver.py \
  --sample-dir ../example \
  --glob 'IMG20260*.heic' \
  --out-report conformance_report.md
```
