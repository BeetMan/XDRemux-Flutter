"""HEIC I/O — cross-platform via pillow-heif.

Read: pillow-heif for base image decode.
Write: pillow-heif dual-image encode + ISOBMFF binary patch for ISO 21496-1.

After pillow-heif writes the base file, isobmff_patch.py patches the binary
to add auxC box (urn:iso:std:iso:ts:21496:-1), convert gain map to tmap type,
and insert iref/auxl reference — enabling HDR detection by macOS/iOS.
"""

import json
import io
import os
import struct
import sys
import tempfile

from PIL import Image
import numpy as np

from . import container
from . import iso21496


OPPO_ULTRA_HDR_FLAG = 0x20000000
OPPO_TAGFLAG_PREFIXES = (
    b"ASCIIOplus_",
    b"ASCIIoppo_",
    b"Oplus_",
    b"oplus_",
    b"oppo_",
)
EXIF_USER_COMMENT_ASCII_PREFIX = b"ASCII\x00\x00\x00"
OPPO_EXTENSION_TAG = b"jxrs"


def _read_be(data: bytes | bytearray, offset: int, size: int) -> tuple[int, int]:
    if size == 0:
        return 0, offset
    return int.from_bytes(data[offset:offset + size], "big"), offset + size


def _parse_iloc_entries(data: bytes | bytearray, iloc_ds: int) -> list[dict]:
    """Parse iloc and normalize base_offset + extent_offset into one offset."""
    from .isobmff_patch import _fullbox

    iloc_v, _, iloc_body = _fullbox(data, iloc_ds)
    b0 = data[iloc_body]
    osz = (b0 >> 4) & 0xF
    lsz = b0 & 0xF
    b1 = data[iloc_body + 1]
    bosz = (b1 >> 4) & 0xF
    isz = (b1 & 0xF) if iloc_v in (1, 2) else 0
    pos = iloc_body + 2
    cnt_size = 4 if iloc_v >= 2 else 2
    item_id_size = 4 if iloc_v >= 2 else 2
    count, pos = _read_be(data, pos, cnt_size)

    entries = []
    for _ in range(count):
        item_id, pos = _read_be(data, pos, item_id_size)
        construction_method = 0
        if iloc_v in (1, 2):
            construction_method, pos = _read_be(data, pos, 2)
            construction_method &= 0xF
        data_ref_index, pos = _read_be(data, pos, 2)
        base_offset, pos = _read_be(data, pos, bosz)
        extent_count, pos = _read_be(data, pos, 2)
        extents = []
        for _ in range(extent_count):
            if iloc_v in (1, 2) and isz:
                _, pos = _read_be(data, pos, isz)
            extent_offset, pos = _read_be(data, pos, osz)
            extent_length, pos = _read_be(data, pos, lsz)
            extents.append((base_offset + extent_offset, extent_length))
        entries.append({
            "iid": item_id,
            "cm": construction_method,
            "dri": data_ref_index,
            "extents": extents,
        })
    return entries


def _parse_ipma_entries(data: bytes | bytearray, ipma_ds: int) -> tuple[int, int, list[dict]]:
    from .isobmff_patch import _fullbox

    ipma_v, ipma_f, ipma_body = _fullbox(data, ipma_ds)
    count = struct.unpack_from(">I", data, ipma_body)[0]
    pos = ipma_body + 4
    entries = []
    item_id_size = 4 if (ipma_f & 1) else 2
    assoc_size = 2 if (ipma_f & 1) else 1
    for _ in range(count):
        item_id, pos = _read_be(data, pos, item_id_size)
        assoc_count = data[pos]
        pos += 1
        assocs = []
        for _ in range(assoc_count):
            value, pos = _read_be(data, pos, assoc_size)
            assocs.append(value)
        entries.append({"iid": item_id, "assocs": assocs})
    return ipma_v, ipma_f, entries


def _extract_heif_hvc_payload_and_config(data: bytes) -> tuple[bytes, bytes]:
    """Return the first hvc1 item's payload bytes and its associated hvcC box."""
    from .isobmff_patch import _boxes, _fullbox, _parse_all_items

    top = {}
    for tp, ds, de, bs, bsz in _boxes(data, 0, len(data)):
        top[tp] = {"ds": ds, "de": de, "bs": bs, "sz": bsz}
    if "meta" not in top:
        raise ValueError("temporary gain map HEIF missing meta")

    _, _, meta_body = _fullbox(data, top["meta"]["ds"])
    child = {}
    for tp, ds, de, bs, bsz in _boxes(data, meta_body, top["meta"]["de"]):
        child[tp] = {"ds": ds, "de": de, "bs": bs, "sz": bsz}

    for name in ("iinf", "iloc", "iprp"):
        if name not in child:
            raise ValueError(f"temporary gain map HEIF missing {name}")

    item_types, _ = _parse_all_items(data, child["iinf"]["ds"], child["iinf"]["de"])
    hvc_item_id = next((iid for iid, item_type in item_types.items() if item_type == "hvc1"), None)
    if hvc_item_id is None:
        raise ValueError("temporary gain map HEIF has no hvc1 item")

    ipco = ipma = None
    for tp, ds, de, bs, bsz in _boxes(data, child["iprp"]["ds"], child["iprp"]["de"]):
        if tp == "ipco":
            ipco = {"ds": ds, "de": de}
        elif tp == "ipma":
            ipma = {"ds": ds, "de": de}
    if ipco is None or ipma is None:
        raise ValueError("temporary gain map HEIF missing ipco/ipma")

    props = []
    for tp, ds, de, bs, bsz in _boxes(data, ipco["ds"], ipco["de"]):
        props.append({"type": tp, "raw": data[bs:de]})

    _, ipma_f, ipma_entries = _parse_ipma_entries(data, ipma["ds"])
    prop_mask = 0x7FFF if (ipma_f & 1) else 0x7F
    hvcc_prop_idx = None
    for entry in ipma_entries:
        if entry["iid"] != hvc_item_id:
            continue
        for value in entry["assocs"]:
            prop_idx = value & prop_mask
            if 1 <= prop_idx <= len(props) and props[prop_idx - 1]["type"] == "hvcC":
                hvcc_prop_idx = prop_idx
                break
        if hvcc_prop_idx is not None:
            break
    if hvcc_prop_idx is None:
        hvcc_prop_idx = next(
            (idx for idx, prop in enumerate(props, start=1) if prop["type"] == "hvcC"),
            None,
        )
    if hvcc_prop_idx is None:
        raise ValueError("temporary gain map HEIF has no hvcC property")
    hvcc_box = props[hvcc_prop_idx - 1]["raw"]

    iloc_entries = _parse_iloc_entries(data, child["iloc"]["ds"])
    hvc_loc = next((entry for entry in iloc_entries if entry["iid"] == hvc_item_id), None)
    if hvc_loc is None:
        raise ValueError("temporary gain map HEIF has no iloc entry for hvc1")

    chunks = []
    for offset, length in hvc_loc["extents"]:
        if hvc_loc["cm"] == 0:
            start = offset
        elif hvc_loc["cm"] == 1 and "idat" in child:
            start = child["idat"]["ds"] + offset
        else:
            raise ValueError(f"unsupported temporary gain map construction_method={hvc_loc['cm']}")
        end = start + length
        if start < 0 or end > len(data):
            raise ValueError("temporary gain map iloc extent is out of bounds")
        chunks.append(data[start:end])

    payload = b"".join(chunks)
    if not payload:
        raise ValueError("temporary gain map hvc1 payload is empty")
    return payload, hvcc_box


def _infe_box(item_id: int, item_type: str, *, flags: int = 0) -> bytes:
    if item_id > 0xFFFF:
        return (
            struct.pack(">I", 23) + b"infe"
            + bytes([2, (flags >> 16) & 0xFF, (flags >> 8) & 0xFF, flags & 0xFF])
            + struct.pack(">I", item_id)
            + struct.pack(">H", 0)
            + item_type.encode("ascii")
            + b"\x00"
        )
    return (
        struct.pack(">I", 21) + b"infe"
        + bytes([2, (flags >> 16) & 0xFF, (flags >> 8) & 0xFF, flags & 0xFF])
        + struct.pack(">H", item_id)
        + struct.pack(">H", 0)
        + item_type.encode("ascii")
        + b"\x00"
    )


def _iref_box(ref_type: bytes, from_id: int, to_ids: list[int], *, version: int) -> bytes:
    id_size = 4 if version >= 1 else 2
    payload = from_id.to_bytes(id_size, "big") + struct.pack(">H", len(to_ids))
    payload += b"".join(to_id.to_bytes(id_size, "big") for to_id in to_ids)
    return struct.pack(">I", 8 + len(payload)) + ref_type + payload


def _colr_icc_box(icc_profile: bytes) -> bytes:
    return struct.pack(">I", 8 + len(icc_profile)) + b"colr" + icc_profile


def _infe_with_flags(raw_box: bytes, flags_to_set: int) -> bytes:
    raw = bytearray(raw_box)
    if len(raw) >= 12 and raw[4:8] == b"infe":
        flags = int.from_bytes(raw[9:12], "big") | flags_to_set
        raw[9:12] = flags.to_bytes(3, "big")
    return bytes(raw)


def read_heic(path: str) -> dict:
    """Read a ProXDR HEIC file."""
    from .edr import edr_scale_calculator

    lhdr = container.extract_lhdr(path)
    if lhdr.mode == "uhdr":
        iso_meta = iso21496.build_iso21496_metadata_from_uhdr(lhdr.meta_floats)
        edr_scale = iso_meta.get("scale", 1.0)
    else:
        edr_scale = edr_scale_calculator(list(lhdr.meta_floats))
        iso_meta = iso21496.build_iso21496_metadata(edr_scale)

    base_image = None
    try:
        from pillow_heif import open_heif
        heif_img = open_heif(path, convert_hdr_to_8bit=False)
        base = heif_img[0] if hasattr(heif_img, '__getitem__') else heif_img
        base_image = base.to_pillow()
    except ImportError:
        pass
    except Exception as e:
        print(f"note: HEIC decode failed: {e}", file=sys.stderr)

    return {
        "base_image": base_image,
        "lhdr": lhdr,
        "edr_scale": edr_scale,
        "iso_meta": iso_meta,
        "mode": lhdr.mode,
    }


def _as_uint8_array(array: np.ndarray) -> np.ndarray:
    """Return an array Pillow can encode predictably as 8-bit image data."""
    if array.dtype == np.uint8:
        return array
    return np.clip(np.round(array), 0, 255).astype(np.uint8)


def _normalize_gainmap_image(gainmap) -> Image.Image:
    """Convert gain map input to a JPEG/HEIF-ready image without dropping RGB channels."""
    if isinstance(gainmap, Image.Image):
        if gainmap.mode in ("L", "RGB"):
            return gainmap.copy()
        if gainmap.mode in ("P", "PA", "YCbCr") or len(gainmap.getbands()) >= 3:
            return gainmap.convert("RGB")
        return gainmap.convert("L")

    if isinstance(gainmap, np.ndarray):
        array = _as_uint8_array(np.asarray(gainmap))
        if array.ndim == 2:
            return Image.fromarray(array).convert("L")
        if array.ndim == 3:
            channels = array.shape[2]
            if channels == 1:
                return Image.fromarray(array[:, :, 0]).convert("L")
            if channels >= 3:
                return Image.fromarray(array[:, :, :3]).convert("RGB")

    raise ValueError(f"Unsupported gainmap type or shape: {type(gainmap)}")


def _pad_tile_to_size(tile: Image.Image, tile_size: int) -> Image.Image:
    """Pad edge tiles by extending their last row/column to a fixed canvas."""
    if tile.size == (tile_size, tile_size):
        return tile

    padded = Image.new(tile.mode, (tile_size, tile_size))
    padded.paste(tile, (0, 0))
    width, height = tile.size

    if width < tile_size and width > 0:
        right_edge = tile.crop((width - 1, 0, width, height))
        padded.paste(right_edge.resize((tile_size - width, height)), (width, 0))

    if height < tile_size and height > 0:
        bottom_edge = padded.crop((0, height - 1, tile_size, height))
        padded.paste(bottom_edge.resize((tile_size, tile_size - height)), (0, height))

    return padded


def _encode_gainmap_tiles(gm_img: Image.Image, output_dir: str,
                          tile_size: int = 512) -> tuple[list[bytes], bytes, int, int]:
    """Encode a gain map as HEVC tiles and return tile payloads plus hvcC."""
    from pillow_heif import from_pillow

    gm_width, gm_height = gm_img.size
    columns = (gm_width + tile_size - 1) // tile_size
    rows = (gm_height + tile_size - 1) // tile_size
    tile_payloads: list[bytes] = []
    tile_hvcc: bytes | None = None

    for row in range(rows):
        for column in range(columns):
            left = column * tile_size
            top = row * tile_size
            right = min(left + tile_size, gm_width)
            bottom = min(top + tile_size, gm_height)
            tile = gm_img.crop((left, top, right, bottom))
            tile = _pad_tile_to_size(tile, tile_size)

            gm_tmp_path = None
            try:
                fd, gm_tmp_path = tempfile.mkstemp(
                    prefix="proxdr_gainmap_tile_", suffix=".heic", dir=output_dir or None,
                )
                os.close(fd)
                from_pillow(tile).save(gm_tmp_path, quality=90)
                with open(gm_tmp_path, "rb") as f:
                    gm_data = f.read()
                payload, hvcc = _extract_heif_hvc_payload_and_config(gm_data)
            finally:
                if gm_tmp_path:
                    try:
                        os.remove(gm_tmp_path)
                    except OSError:
                        pass

            if tile_hvcc is None:
                tile_hvcc = hvcc
            tile_payloads.append(payload)

    if tile_hvcc is None:
        raise ValueError("unable to encode gain map tiles")
    return tile_payloads, tile_hvcc, rows, columns


def write_heic(output_path: str, base_image: Image.Image,
               gainmap, iso_meta: dict,
               oppo_compat: bool = True, lhdr=None,
               replace_primary_colr: bool = False,
               exif_data: bytes | None = None) -> None:
    """Write HEIC with gain map as secondary image + ISO 21496-1 patch."""
    if base_image is None:
        raise ValueError("base_image is None")

    from pillow_heif import from_pillow

    # Keep ICC profile if we need to convert modes.
    icc_profile = base_image.info.get("icc_profile")
    if base_image.mode != "RGB":
        base_image = base_image.convert("RGB")
        if icc_profile and not base_image.info.get("icc_profile"):
            base_image.info["icc_profile"] = icc_profile

    gm_img = _normalize_gainmap_image(gainmap)

    heif = from_pillow(base_image)
    heif.add_from_pillow(gm_img)

    # Build save kwargs — passthrough source EXIF (shooting params, GPS, orientation)
    save_kwargs = {"quality": 90}
    if exif_data is not None:
        save_kwargs["exif"] = exif_data

    # OPPO compat: merge patched UserComment into EXIF before save.
    # If exif_data is provided, merge into it; otherwise inject into heif object.
    if oppo_compat and lhdr is not None:
        patched_comment = _get_patched_oppo_user_comment(lhdr)
        if patched_comment:
            if exif_data is not None:
                save_kwargs["exif"] = _merge_exif_user_comment(exif_data, patched_comment)
            else:
                _inject_exif_user_comment(heif, patched_comment)

    heif.save(output_path, **save_kwargs)

    # Binary-patch for ISO 21496-1 compliance
    try:
        from .isobmff_patch import patch_heic_for_iso21496
        patched = patch_heic_for_iso21496(
            output_path,
            iso_meta=iso_meta,
            replace_primary_colr=replace_primary_colr,
        )
        if not patched:
            print("note: auxC already present or patching skipped", file=sys.stderr)
    except Exception as e:
        print(f"warning: auxC patching failed: {e}", file=sys.stderr)

    # OPPO Gallery compatibility: append UHDR extension blocks
    if oppo_compat and lhdr is not None:
        _append_oppo_trailing_payload(output_path, iso_meta, gm_img, lhdr)


def write_heic_passthrough(source_path: str, output_path: str,
                            gainmap, iso_meta: dict,
                            lhdr=None, oppo_compat: bool = True,
                            replace_primary_colr: bool = False,
                            exif_data: bytes | None = None) -> None:
    """Passthrough mode: copy source base image HEVC data without re-encoding.

    Only the gain map is encoded fresh. Base image compressed data is copied
    byte-for-byte from the source mdat, preserving original quality.
    """
    from .isobmff_patch import (
        _boxes, _build_tmap_config, _fullbox, _parse_all_items, _parse_infe_item_id,
        build_grid_payload,
        AUXC_BOX, DINF_BOX, COLR_NCLX_PQ_BOX, COLR_NCLX_SRGB_BOX,
        IROT_BOX, PIXI_RGB10_BOX, PIXI_RGB8_BOX, SWIFT_PQ_ICC_PROFILE,
    )

    # ── 1. Read source file and parse top-level boxes ──────────────
    with open(source_path, 'rb') as f:
        src = f.read()

    src_ftyp_sz = struct.unpack_from('>I', src, 0)[0]
    src_meta_bs = src_meta_sz = src_meta_ds = src_meta_de = None
    src_mdat_off = src_mdat_ds = src_mdat_sz = None
    src_intermediate = b''

    for tp, ds, de, bs, bsz in _boxes(src, 0, len(src)):
        if tp == 'meta':
            src_meta_bs, src_meta_sz, src_meta_ds, src_meta_de = bs, bsz, ds, de
        elif tp == 'mdat':
            src_mdat_off, src_mdat_ds, src_mdat_sz = bs, ds, bsz

    if src_meta_bs is None or src_mdat_off is None:
        raise ValueError("Source missing meta or mdat")

    # Collect intermediate boxes between meta and mdat (e.g., free)
    src_meta_end = src_meta_bs + src_meta_sz
    if src_meta_end < src_mdat_off:
        src_intermediate = src[src_meta_end:src_mdat_off]

    # mdat content: use ds (data start) to handle extended-size boxes
    src_mdat_content = src[src_mdat_ds:src_mdat_off + src_mdat_sz]

    # ── 2. Parse source meta structure ─────────────────────────────
    _, _, meta_body = _fullbox(src, src_meta_ds)

    # Collect meta children
    meta_children = []  # [(type, box_start, data_start, data_end, box_size)]
    child = {}
    for tp, ds, de, bs, bsz in _boxes(src, meta_body, src_meta_de):
        meta_children.append((tp, bs, ds, de, bsz))
        child[tp] = {'off': bs, 'ds': ds, 'de': de, 'sz': bsz}

    for name in ("iinf", "iloc", "iprp", "pitm"):
        if name not in child:
            raise ValueError(f"Source meta missing {name}")

    # Parse iprp children (ipco and ipma are inside iprp)
    ipco = ipma = None
    for tp, ds, de, bs, bsz in _boxes(src, child['iprp']['ds'], child['iprp']['de']):
        if tp == 'ipco':
            ipco = {'off': bs, 'ds': ds, 'de': de, 'sz': bsz}
        elif tp == 'ipma':
            ipma = {'off': bs, 'ds': ds, 'de': de, 'sz': bsz}
    if ipco is None or ipma is None:
        raise ValueError("Source iprp missing ipco or ipma")

    parsed_iloc = _parse_iloc_entries(src, child['iloc']['ds'])
    old_iloc_cnt = len(parsed_iloc)

    # Parse iinf for item types
    item_types, iinf_v = _parse_all_items(src, child['iinf']['ds'], child['iinf']['de'])

    if oppo_compat and lhdr is not None and lhdr.mode == "uhdr":
        patched_comment = _get_patched_oppo_user_comment(lhdr)
        if patched_comment:
            src_mdat_content = _patch_passthrough_exif_user_comment(
                src_mdat_content,
                src_mdat_ds,
                parsed_iloc,
                item_types,
                patched_comment,
            )

    # Parse pitm
    pitm_v = src[child['pitm']['ds']]
    pitm_body = child['pitm']['ds'] + 4
    pitm_id = struct.unpack_from('>H' if pitm_v == 0 else '>I',
                                   src, pitm_body)[0]

    # Parse ipco properties
    ipco_prop_types = {}
    ispe_sizes = {}
    ipco_idx = 1
    for tp, ds, de, bs, bsz in _boxes(src, ipco['ds'], ipco['de']):
        ipco_prop_types[ipco_idx] = tp
        if tp == "ispe" and de - ds >= 12:
            ispe_sizes[ipco_idx] = (
                struct.unpack_from(">I", src, ds + 4)[0],
                struct.unpack_from(">I", src, ds + 8)[0],
            )
        ipco_idx += 1
    prop_count = len(ipco_prop_types)

    # Parse ipma and find primary's ispe/colr/pixi indices.
    ipma_v, ipma_f, ipma_entries = _parse_ipma_entries(src, ipma['ds'])
    primary_ispe_idx = primary_colr_idx = primary_pixi_idx = None

    pidx_mask = 0x7FFF if (ipma_f & 1) else 0x7F
    for entry in ipma_entries:
        if entry['iid'] == pitm_id:
            for v in entry['assocs']:
                pidx = v & pidx_mask
                pt = ipco_prop_types.get(pidx)
                if pt == 'ispe' and primary_ispe_idx is None:
                    primary_ispe_idx = pidx
                elif pt == 'colr' and primary_colr_idx is None:
                    primary_colr_idx = pidx
                elif pt == 'pixi' and primary_pixi_idx is None:
                    primary_pixi_idx = pidx

    # ── 3. Encode gain map ─────────────────────────────────────────
    gm_img = _normalize_gainmap_image(gainmap)

    gm_width, gm_height = gm_img.size
    gm_tile_payloads, gm_hvcC, gm_rows, gm_columns = _encode_gainmap_tiles(
        gm_img,
        os.path.dirname(os.path.abspath(output_path)),
    )

    # ── 4. Prepare building blocks ─────────────────────────────────
    next_id = max(item_types.keys()) + 1
    add_primary_grid = item_types.get(pitm_id) != "grid"
    primary_grid_id = next_id if add_primary_grid else pitm_id
    gm_tile_start_id = next_id + (1 if add_primary_grid else 0)
    gm_tile_ids = list(range(gm_tile_start_id, gm_tile_start_id + len(gm_tile_payloads)))
    gm_grid_id = gm_tile_start_id + len(gm_tile_payloads)
    tmap_item_id = gm_grid_id + 1
    if tmap_item_id > 0xFFFF:
        raise ValueError("Passthrough mode currently requires 16-bit HEIF item IDs")

    auxc_prop_idx = prop_count + 1
    irot_prop_idx = prop_count + 2
    pq_nclx_prop_idx = prop_count + 3
    srgb_nclx_prop_idx = prop_count + 4
    hdr_pixi_prop_idx = prop_count + 5
    gm_pixi_prop_idx = prop_count + 6
    gm_hvcC_prop_idx = prop_count + 7
    gm_grid_ispe_prop_idx = prop_count + 8
    gm_tile_ispe_prop_idx = prop_count + 9
    if not (ipma_f & 1) and gm_tile_ispe_prop_idx > 0x7F:
        raise ValueError("Passthrough mode cannot encode more than 127 properties in ipma flags=0")
    if primary_ispe_idx is None:
        raise ValueError(f"Primary item {pitm_id} has no ispe property association")

    tmap_config = _build_tmap_config(iso_meta)

    primary_width, primary_height = ispe_sizes.get(primary_ispe_idx, (0, 0))
    primary_grid_config = build_grid_payload(primary_width, primary_height) if add_primary_grid else b""
    gm_grid_config = build_grid_payload(gm_width, gm_height, rows=gm_rows, columns=gm_columns)
    idat_payload = primary_grid_config + gm_grid_config + tmap_config

    new_infe = (
        (_infe_box(primary_grid_id, 'grid', flags=0) if add_primary_grid else b"")
        + b"".join(_infe_box(gm_item_id, 'hvc1', flags=1) for gm_item_id in gm_tile_ids)
        + _infe_box(gm_grid_id, 'grid', flags=1)
        + _infe_box(tmap_item_id, 'tmap', flags=0)
    )

    # Find EXIF item ID from source iref (cdsc reference)
    exif_item_id = None
    iref_v = 0
    if 'iref' in child:
        iref_ds = child['iref']['ds']
        iref_v, _, iref_body = _fullbox(src, iref_ds)
        iref_end = child['iref']['de']
        ref_pos = iref_body
        while ref_pos + 8 <= iref_end:
            ref_sz = struct.unpack_from('>I', src, ref_pos)[0]
            ref_type = src[ref_pos+4:ref_pos+8]
            id_size = 4 if iref_v >= 1 else 2
            if ref_sz < 8 + id_size + 2 or ref_pos + ref_sz > iref_end:
                break
            from_id = int.from_bytes(src[ref_pos + 8:ref_pos + 8 + id_size], "big")
            count_pos = ref_pos + 8 + id_size
            ref_count = struct.unpack_from('>H', src, count_pos)[0]
            targets_pos = count_pos + 2
            targets = [
                int.from_bytes(src[targets_pos + i * id_size:targets_pos + (i + 1) * id_size], "big")
                for i in range(ref_count)
                if targets_pos + (i + 1) * id_size <= ref_pos + ref_sz
            ]
            if ref_type == b'cdsc' and (pitm_id in targets or exif_item_id is None):
                exif_item_id = from_id
            ref_pos += ref_sz

    # Find first colr property index (ICC profile) for primary grid
    first_colr_idx = None
    for idx, pt in ipco_prop_types.items():
        if pt == 'colr':
            first_colr_idx = idx
            break

    # New ipma entries
    def _encode_ipma_entry(iid, assocs):
        entry = bytearray()
        if ipma_f & 1:
            entry += struct.pack('>I', iid)
        else:
            entry += struct.pack('>H', iid)
        entry += bytes([len(assocs)])
        for pidx_val, essential in assocs:
            if ipma_f & 1:
                entry += struct.pack('>H', (0x8000 if essential else 0) | pidx_val)
            else:
                entry += bytes([(0x80 if essential else 0) | pidx_val])
        return bytes(entry)

    # Keep an existing primary grid's property associations byte-for-byte. OPPO
    # Gallery is picky here: adding otherwise-valid properties can make the
    # original image path fall back to thumbnail-only decode.
    primary_assocs = []
    pitm_ipma_entry = next((entry for entry in ipma_entries if entry['iid'] == pitm_id), None)
    if pitm_ipma_entry is not None:
        primary_assocs = [
            (value & pidx_mask, bool(value & (0x8000 if (ipma_f & 1) else 0x80)))
            for value in pitm_ipma_entry['assocs']
        ]
    else:
        if first_colr_idx is not None:
            primary_assocs.append((first_colr_idx, True))
        if primary_ispe_idx is not None:
            primary_assocs.append((primary_ispe_idx, True))
        if primary_pixi_idx is not None:
            primary_assocs.append((primary_pixi_idx, True))
    new_ipma_entries = []
    if add_primary_grid:
        new_ipma_entries.append(_encode_ipma_entry(primary_grid_id, primary_assocs))

    gm_assocs = [(gm_hvcC_prop_idx, True), (gm_tile_ispe_prop_idx, True)]
    if first_colr_idx is not None:
        gm_assocs.append((first_colr_idx, True))
    for gm_item_id in gm_tile_ids:
        new_ipma_entries.append(_encode_ipma_entry(gm_item_id, gm_assocs))

    gm_grid_assocs = [
        (gm_grid_ispe_prop_idx, True),
        (srgb_nclx_prop_idx, True),
        (gm_pixi_prop_idx, True),
    ]
    new_ipma_entries.append(_encode_ipma_entry(gm_grid_id, gm_grid_assocs))

    tmap_assocs = [(pq_nclx_prop_idx, True), (hdr_pixi_prop_idx, True),
                   (primary_ispe_idx, True)]
    new_ipma_entries.append(_encode_ipma_entry(tmap_item_id, tmap_assocs))

    # New iref references
    iref_new_content = (
        _iref_box(b'dimg', primary_grid_id, [pitm_id], version=iref_v)
        if add_primary_grid else b""
    ) + (
        _iref_box(b'dimg', gm_grid_id, gm_tile_ids, version=iref_v)
        + _iref_box(b'dimg', tmap_item_id, [primary_grid_id, gm_grid_id], version=iref_v)
    )

    # cdsc: EXIF references both primary grid and tmap (matches normal mode)
    if exif_item_id is not None:
        iref_new_content += _iref_box(b'cdsc', exif_item_id, [primary_grid_id, tmap_item_id], version=iref_v)

    # ── 5. Build meta children as bytearrays ───────────────────────
    # Build each child, then compute actual sizes for the meta box.
    meta_parts = []  # list of bytearray, one per logical child

    for tp, bs, ds, de, bsz in meta_children:
        if tp == 'hdlr':
            meta_parts.append(bytearray(src[bs:de]))
            meta_parts.append(bytearray(DINF_BOX))

        elif tp == 'pitm':
            meta_parts.append(bytearray(
                struct.pack('>I', 14) + b'pitm'
                + struct.pack('>I', 0)
                + struct.pack('>H', primary_grid_id if add_primary_grid else pitm_id)
            ))

        elif tp == 'iinf':
            part = bytearray()
            part += b'\x00\x00\x00\x00' + b'iinf'
            ec_pos = child['iinf']['ds'] + 4
            ec_size = 4 if iinf_v >= 1 else 2
            part += src[ds:ec_pos + ec_size]
            for tp2, ds2, de2, bs2, bsz2 in _boxes(src, ec_pos + ec_size, child['iinf']['de']):
                if tp2 == 'infe':
                    raw_infe = bytes(src[bs2:de2])
                    if add_primary_grid and _parse_infe_item_id(raw_infe) == pitm_id:
                        raw_infe = _infe_with_flags(raw_infe, 1)
                    part += raw_infe
            old_cnt = struct.unpack_from('>H' if ec_size == 2 else '>I', src, ec_pos)[0]
            new_cnt = old_cnt + len(gm_tile_ids) + 2 + (1 if add_primary_grid else 0)
            if ec_size == 2:
                struct.pack_into('>H', part, 8 + 4, new_cnt)
            else:
                struct.pack_into('>I', part, 8 + 4, new_cnt)
            part += new_infe
            struct.pack_into('>I', part, 0, len(part))
            meta_parts.append(part)

        elif tp == 'iloc':
            part = bytearray()
            part += b'\x00\x00\x00\x00' + b'iloc'
            part += bytes([1, 0, 0, 0])  # version=1, flags=0
            part += bytes([0x44, 0x00])  # osz=4, lsz=4, bosz=0, isz=0
            part += struct.pack('>H', old_iloc_cnt + len(gm_tile_ids) + 2 + (1 if add_primary_grid else 0))
            for entry in parsed_iloc:
                part += struct.pack('>H', entry['iid'])
                part += struct.pack('>H', entry['cm'])
                part += struct.pack('>H', entry['dri'])
                part += struct.pack('>H', len(entry['extents']))
                for eo, el in entry['extents']:
                    # cm=0 offsets will be patched in step 6 after we know iloc_delta
                    part += struct.pack('>I', eo)
                    part += struct.pack('>I', el)
            old_idat_data_sz = child['idat']['sz'] - 8 if 'idat' in child else 0
            if add_primary_grid:
                # primary grid (cm=1, in idat)
                part += struct.pack('>H', primary_grid_id) + struct.pack('>H', 1)
                part += struct.pack('>H', 0) + struct.pack('>H', 1)
                part += struct.pack('>I', old_idat_data_sz) + struct.pack('>I', len(primary_grid_config))
            # gain map hvc1 tiles (cm=0, in mdat) — offsets patched later
            for gm_item_id, gm_tile_payload in zip(gm_tile_ids, gm_tile_payloads):
                part += struct.pack('>H', gm_item_id) + struct.pack('>H', 0)
                part += struct.pack('>H', 0) + struct.pack('>H', 1)
                part += struct.pack('>I', 0) + struct.pack('>I', len(gm_tile_payload))
            # gm grid (cm=1, in idat)
            part += struct.pack('>H', gm_grid_id) + struct.pack('>H', 1)
            part += struct.pack('>H', 0) + struct.pack('>H', 1)
            part += struct.pack('>I', old_idat_data_sz + len(primary_grid_config))
            part += struct.pack('>I', len(gm_grid_config))
            # tmap (cm=1, in idat)
            part += struct.pack('>H', tmap_item_id) + struct.pack('>H', 1)
            part += struct.pack('>H', 0) + struct.pack('>H', 1)
            part += struct.pack('>I', old_idat_data_sz + len(primary_grid_config) + len(gm_grid_config))
            part += struct.pack('>I', len(tmap_config))
            struct.pack_into('>I', part, 0, len(part))
            meta_parts.append(part)

        elif tp == 'iprp':
            # Build ipco
            ipco_part = bytearray()
            ipco_part += b'\x00\x00\x00\x00' + b'ipco'
            replace_colr_idx = primary_colr_idx or first_colr_idx
            prop_idx = 1
            for tp2, ds2, de2, bs2, bsz2 in _boxes(src, ipco['ds'], ipco['de']):
                if replace_primary_colr and tp2 == 'colr' and prop_idx == replace_colr_idx:
                    ipco_part += _colr_icc_box(SWIFT_PQ_ICC_PROFILE)
                else:
                    ipco_part += src[bs2:de2]
                prop_idx += 1
            ipco_part += AUXC_BOX + IROT_BOX + COLR_NCLX_PQ_BOX + COLR_NCLX_SRGB_BOX + PIXI_RGB10_BOX
            ipco_part += PIXI_RGB8_BOX
            ipco_part += gm_hvcC
            ipco_part += struct.pack('>I', 20) + b'ispe' + struct.pack('>I', 0)
            ipco_part += struct.pack('>II', gm_width, gm_height)
            ipco_part += struct.pack('>I', 20) + b'ispe' + struct.pack('>I', 0)
            ipco_part += struct.pack('>II', 512, 512)
            struct.pack_into('>I', ipco_part, 0, len(ipco_part))

            # Build ipma — re-serialize existing entries, skipping pitm_id
            # (we replace it with our new entry that adds colr/pixi/irot)
            ipma_part = bytearray()
            ipma_part += b'\x00\x00\x00\x00' + b'ipma'
            ipma_part += src[ipma['ds']:ipma['ds'] + 4]  # fullbox header
            # Count: keep existing source associations, then append only new
            # Path-B items. Existing primary grids must remain untouched.
            existing_count = len(ipma_entries)
            ipma_part += struct.pack('>I', existing_count + len(new_ipma_entries))
            for entry in ipma_entries:
                if ipma_f & 1:
                    ipma_part += struct.pack('>I', entry['iid'])
                else:
                    ipma_part += struct.pack('>H', entry['iid'])
                ipma_part += bytes([len(entry['assocs'])])
                for val in entry['assocs']:
                    if ipma_f & 1:
                        ipma_part += struct.pack('>H', val)
                    else:
                        ipma_part += bytes([val])
            for entry_bytes in new_ipma_entries:
                ipma_part += entry_bytes
            struct.pack_into('>I', ipma_part, 0, len(ipma_part))

            # Build iprp wrapper
            iprp_part = bytearray()
            iprp_part += b'\x00\x00\x00\x00' + b'iprp'
            iprp_part += bytes(ipco_part)
            iprp_part += bytes(ipma_part)
            struct.pack_into('>I', iprp_part, 0, len(iprp_part))
            meta_parts.append(iprp_part)

        elif tp == 'iref':
            part = bytearray()
            part += b'\x00\x00\x00\x00' + b'iref'
            part += src[ds:ds + 4]  # fullbox header
            part += src[ds + 4:de]  # existing refs
            part += iref_new_content
            struct.pack_into('>I', part, 0, len(part))
            meta_parts.append(part)

        elif tp == 'idat':
            part = bytearray()
            part += b'\x00\x00\x00\x00' + b'idat'
            part += src[ds:de]
            part += idat_payload
            struct.pack_into('>I', part, 0, len(part))
            meta_parts.append(part)

        else:
            meta_parts.append(bytearray(src[bs:de]))

    if 'iref' not in child:
        part = bytearray()
        part += b'\x00\x00\x00\x00' + b'iref'
        part += bytes([iref_v, 0, 0, 0])
        part += iref_new_content
        struct.pack_into('>I', part, 0, len(part))
        meta_parts.append(part)

    if 'idat' not in child:
        part = bytearray()
        part += b'\x00\x00\x00\x00' + b'idat'
        part += idat_payload
        struct.pack_into('>I', part, 0, len(part))
        meta_parts.append(part)

    # grpl/altr (appended as a meta child)
    existing_group_ids = []
    if 'grpl' in child:
        for tp, ds, de, bs, bsz in _boxes(src, child['grpl']['ds'], child['grpl']['de']):
            if tp == 'altr' and de - ds >= 12:
                existing_group_ids.append(struct.unpack_from('>I', src, ds + 4)[0])
    new_altr_group_id = max(
        [*item_types.keys(), primary_grid_id, *gm_tile_ids, gm_grid_id, tmap_item_id, *existing_group_ids],
        default=tmap_item_id,
    ) + 1
    meta_parts.append(bytearray(
        struct.pack('>I', 36) + b'grpl'
        + struct.pack('>I', 28) + b'altr'
        + struct.pack('>I', 0)
        + struct.pack('>I', new_altr_group_id)
        + struct.pack('>I', 2)
        + struct.pack('>I', tmap_item_id)
        + struct.pack('>I', primary_grid_id)
    ))

    # ── 6. Compute sizes from actual parts ─────────────────────────
    meta_content_sz = sum(len(p) for p in meta_parts)
    new_meta_sz = 12 + meta_content_sz
    ftyp_brands = {src[i:i + 4] for i in range(8, src_ftyp_sz, 4) if i + 4 <= src_ftyp_sz}
    missing_brands = b''.join(brand for brand in (b'tmap', b'MiHE', b'MiHB') if brand not in ftyp_brands)
    new_ftyp_sz = src_ftyp_sz + len(missing_brands)
    # iloc delta: difference in file position of mdat content
    # Source: mdat content at src_mdat_ds
    # Output: mdat content at new_ftyp_sz + new_meta_sz + len(intermediate) + 8
    new_mdat_file_off = new_ftyp_sz + new_meta_sz + len(src_intermediate)
    file_delta = (new_mdat_file_off + 8) - src_mdat_ds
    gm_mdat_offsets_in_file = {}
    gm_mdat_cursor = new_mdat_file_off + 8 + len(src_mdat_content)
    for gm_item_id, gm_tile_payload in zip(gm_tile_ids, gm_tile_payloads):
        gm_mdat_offsets_in_file[gm_item_id] = gm_mdat_cursor
        gm_mdat_cursor += len(gm_tile_payload)

    # Patch iloc cm=0 offsets: add file_delta to original offsets,
    # and set gm hvc1 offset to gm_mdat_offset_in_file.
    # Find iloc part by iterating children and parts together.
    iloc_part_idx = 0
    part_idx = 0
    for tp, bs, ds, de, bsz in meta_children:
        if tp == 'hdlr':
            part_idx += 2  # hdlr + dinf
        else:
            if tp == 'iloc':
                iloc_part_idx = part_idx
            part_idx += 1
    iloc_part = meta_parts[iloc_part_idx]

    # Patch: walk iloc entries and adjust cm=0 offsets
    # Header: size(4) + type(4) + version/flags(4) + fields(2) + count(2) = 16
    iloc_off = 16
    total_new_items = old_iloc_cnt + len(gm_tile_ids) + 2 + (1 if add_primary_grid else 0)
    for i in range(total_new_items):
        current_iid = struct.unpack_from('>H', iloc_part, iloc_off)[0]
        iloc_off += 2  # item_id
        iloc_off += 2  # construction_method + reserved
        iloc_off += 2  # data_ref_index
        ec_off = iloc_off
        ec = struct.unpack_from('>H', iloc_part, iloc_off)[0]
        iloc_off += 2
        for j in range(ec):
            iloc_off += 4  # extent_offset (osz=4)
            el_off = iloc_off
            iloc_off += 4  # extent_length (lsz=4)
            if i < old_iloc_cnt:
                entry = parsed_iloc[i]
                if entry['cm'] == 0 and j < len(entry['extents']):
                    old_eo = entry['extents'][j][0]
                    struct.pack_into('>I', iloc_part, el_off - 4, old_eo + file_delta)
            elif current_iid in gm_mdat_offsets_in_file:
                # gain map hvc1 tile — set offset
                struct.pack_into('>I', iloc_part, el_off - 4, gm_mdat_offsets_in_file[current_iid])

    # ── 7. Assemble output ─────────────────────────────────────────
    out = bytearray()

    # ftyp
    out += struct.pack('>I', new_ftyp_sz) + src[4:src_ftyp_sz] + missing_brands

    # meta header
    out += struct.pack('>I', new_meta_sz) + b'meta'
    out += src[src_meta_ds:src_meta_ds + 4]  # fullbox header

    # meta children
    for part in meta_parts:
        out += bytes(part)

    # intermediate boxes between meta and mdat (e.g., free)
    out += src_intermediate

    # mdat: source tiles + gain map HEVC tiles
    gm_mdat_data = b"".join(gm_tile_payloads)
    new_mdat_content_sz = len(src_mdat_content) + len(gm_mdat_data)
    out += struct.pack('>I', new_mdat_content_sz + 8)  # 8-byte box header
    out += b'mdat'
    out += src_mdat_content
    out += gm_mdat_data

    with open(output_path, 'wb') as f:
        f.write(out)

    if oppo_compat and lhdr is not None:
        _append_oppo_trailing_payload(output_path, iso_meta, gm_img, lhdr)


def _patch_oppo_tagflags_bytes(data: bytes) -> tuple[bytes, str | None]:
    """Patch the first OPPO tagflags prefix in raw bytes."""
    for prefix in OPPO_TAGFLAG_PREFIXES:
        search_at = 0
        while True:
            start = data.find(prefix, search_at)
            if start < 0:
                break
            digit_start = start + len(prefix)
            digit_end = digit_start
            while digit_end < len(data) and 48 <= data[digit_end] <= 57:
                digit_end += 1
            if digit_end > digit_start:
                original_flags = int(data[digit_start:digit_end])
                patched = str(original_flags | OPPO_ULTRA_HDR_FLAG).encode("ascii")
                patched_data = data[:digit_start] + patched + data[digit_end:]
                patched_comment = (prefix + patched).decode("ascii")
                return patched_data, patched_comment
            search_at = start + 1
    return data, None


def _get_patched_oppo_user_comment(lhdr) -> str | None:
    """Extract and patch OPPO tagflags to add OPLUS_ULTRA_HDR."""
    if lhdr.file_data is None:
        return None
    _, patched_comment = _patch_oppo_tagflags_bytes(lhdr.file_data)
    return patched_comment


def _split_exif_payload(exif_bytes: bytes) -> tuple[bytes, bytes] | None:
    if len(exif_bytes) >= 10 and exif_bytes[:4] == b"\x00\x00\x00\x06" and exif_bytes[4:10] == b"Exif\x00\x00":
        return exif_bytes[:10], exif_bytes[10:]
    if exif_bytes.startswith(b"Exif\x00\x00"):
        return exif_bytes[:6], exif_bytes[6:]
    if exif_bytes.startswith((b"II*\x00", b"MM\x00*")):
        return b"", exif_bytes
    return None


def _patch_tiff_user_comment(tiff_bytes: bytes, comment: str) -> bytes | None:
    if len(tiff_bytes) < 8:
        return None
    if tiff_bytes[:4] == b"II*\x00":
        endian = "<"
    elif tiff_bytes[:4] == b"MM\x00*":
        endian = ">"
    else:
        return None

    tiff = bytearray(tiff_bytes)

    def read_u16(offset: int) -> int:
        return struct.unpack_from(endian + "H", tiff, offset)[0]

    def read_u32(offset: int) -> int:
        return struct.unpack_from(endian + "I", tiff, offset)[0]

    def write_u16(offset: int, value: int) -> None:
        struct.pack_into(endian + "H", tiff, offset, value)

    def write_u32(offset: int, value: int) -> None:
        struct.pack_into(endian + "I", tiff, offset, value)

    def ifd_entry_bounds(ifd_offset: int) -> tuple[int, int, int] | None:
        if ifd_offset <= 0 or ifd_offset + 2 > len(tiff):
            return None
        count = read_u16(ifd_offset)
        entries_start = ifd_offset + 2
        entries_end = entries_start + count * 12
        if entries_end + 4 > len(tiff):
            return None
        return count, entries_start, entries_end

    def find_ifd_entry(ifd_offset: int, tag: int) -> int | None:
        bounds = ifd_entry_bounds(ifd_offset)
        if bounds is None:
            return None
        count, entries_start, _ = bounds
        for index in range(count):
            entry_offset = entries_start + index * 12
            if read_u16(entry_offset) == tag:
                return entry_offset
        return None

    def encode_entry(tag: int, entry_type: int, count: int, value: bytes | int) -> bytes:
        entry = bytearray(struct.pack(endian + "HHI", tag, entry_type, count))
        if isinstance(value, int):
            entry.extend(struct.pack(endian + "I", value))
        else:
            entry.extend(value[:4].ljust(4, b"\x00"))
        return bytes(entry)

    def append_ifd_with_entry(ifd_offset: int, entry: bytes) -> int | None:
        bounds = ifd_entry_bounds(ifd_offset)
        if bounds is None:
            return None
        count, entries_start, entries_end = bounds
        next_ifd = read_u32(entries_end)
        entries = [
            bytes(tiff[entries_start + index * 12:entries_start + (index + 1) * 12])
            for index in range(count)
        ]
        entries.append(entry)
        entries.sort(key=lambda item: struct.unpack_from(endian + "H", item, 0)[0])

        new_ifd_offset = len(tiff)
        tiff.extend(struct.pack(endian + "H", len(entries)))
        for item in entries:
            tiff.extend(item)
        tiff.extend(struct.pack(endian + "I", next_ifd))
        return new_ifd_offset

    first_ifd = read_u32(4)
    if ifd_entry_bounds(first_ifd) is None:
        return None

    value = EXIF_USER_COMMENT_ASCII_PREFIX + comment.encode("ascii")
    value_offset = len(tiff)
    tiff.extend(value)
    user_comment_entry_bytes = encode_entry(0x9286, 7, len(value), value_offset)

    exif_entry = find_ifd_entry(first_ifd, 0x8769)
    if exif_entry is None:
        exif_ifd = len(tiff)
        tiff.extend(struct.pack(endian + "H", 1))
        tiff.extend(user_comment_entry_bytes)
        tiff.extend(struct.pack(endian + "I", 0))
        exif_pointer_entry = encode_entry(0x8769, 4, 1, exif_ifd)
        new_first_ifd = append_ifd_with_entry(first_ifd, exif_pointer_entry)
        if new_first_ifd is None:
            return None
        write_u32(4, new_first_ifd)
        return bytes(tiff)

    exif_ifd = read_u32(exif_entry + 8)
    if ifd_entry_bounds(exif_ifd) is None:
        return None
    user_comment_entry = find_ifd_entry(exif_ifd, 0x9286)
    if user_comment_entry is None:
        new_exif_ifd = append_ifd_with_entry(exif_ifd, user_comment_entry_bytes)
        if new_exif_ifd is None:
            return None
        write_u32(exif_entry + 8, new_exif_ifd)
        return bytes(tiff)

    write_u16(user_comment_entry + 2, 7)  # UNDEFINED
    write_u32(user_comment_entry + 4, len(value))
    write_u32(user_comment_entry + 8, value_offset)

    return bytes(tiff)


def _merge_exif_user_comment(exif_bytes: bytes, comment: str) -> bytes:
    """Merge a UserComment string into existing EXIF bytes."""
    split = _split_exif_payload(exif_bytes)
    if split is not None:
        prefix, tiff = split
        patched_tiff = _patch_tiff_user_comment(tiff, comment)
        if patched_tiff is not None:
            return prefix + patched_tiff

    try:
        import piexif
        exif_dict = piexif.load(exif_bytes)
        exif_dict["Exif"][piexif.ExifIFD.UserComment] = EXIF_USER_COMMENT_ASCII_PREFIX + comment.encode("ascii")
        return piexif.dump(exif_dict)
    except Exception:
        print("warning: unable to patch EXIF UserComment; preserving source EXIF", file=sys.stderr)
        return exif_bytes


def _build_minimal_exif_user_comment(comment: str) -> bytes:
    value = EXIF_USER_COMMENT_ASCII_PREFIX + comment.encode("ascii")
    first_ifd_offset = 8
    exif_ifd_offset = first_ifd_offset + 2 + 12 + 4
    value_offset = exif_ifd_offset + 2 + 12 + 4

    tiff = bytearray(b"II*\x00" + struct.pack("<I", first_ifd_offset))
    tiff += struct.pack("<H", 1)
    tiff += struct.pack("<HHII", 0x8769, 4, 1, exif_ifd_offset)
    tiff += struct.pack("<I", 0)
    tiff += struct.pack("<H", 1)
    tiff += struct.pack("<HHII", 0x9286, 7, len(value), value_offset)
    tiff += struct.pack("<I", 0)
    tiff += value
    return b"Exif\x00\x00" + bytes(tiff)


def _inject_exif_user_comment(heif, comment: str) -> None:
    """Inject EXIF UserComment into a pillow-heif object before save."""
    value = EXIF_USER_COMMENT_ASCII_PREFIX + comment.encode("ascii")
    try:
        primary = heif[0] if hasattr(heif, '__getitem__') else heif
        # Build minimal EXIF with UserComment (tag 0x9286)
        import piexif
        exif_dict = {"0th": {}, "Exif": {piexif.ExifIFD.UserComment: value},
                     "GPS": {}, "1st": {}, "thumbnail": None}
        primary.info["exif"] = piexif.dump(exif_dict)
    except ImportError:
        try:
            primary = heif[0] if hasattr(heif, '__getitem__') else heif
            primary.info["exif"] = _build_minimal_exif_user_comment(comment)
        except Exception:
            pass


def _patch_passthrough_exif_user_comment(src_mdat_content: bytes,
                                         src_mdat_ds: int,
                                         parsed_iloc: list[dict],
                                         item_types: dict[int, str],
                                         comment: str) -> bytes:
    exif_ids = {iid for iid, item_type in item_types.items() if item_type == "Exif"}
    if not exif_ids:
        return src_mdat_content

    content = bytearray(src_mdat_content)
    for entry in parsed_iloc:
        if entry["iid"] not in exif_ids or entry["cm"] != 0 or len(entry["extents"]) != 1:
            continue
        abs_offset, old_length = entry["extents"][0]
        rel_offset = abs_offset - src_mdat_ds
        if rel_offset < 0 or rel_offset + old_length > len(content):
            continue

        old_exif = bytes(content[rel_offset:rel_offset + old_length])
        new_exif = _merge_exif_user_comment(old_exif, comment)
        if new_exif == old_exif:
            continue

        delta = len(new_exif) - old_length
        content[rel_offset:rel_offset + old_length] = new_exif
        entry["extents"] = [(abs_offset, len(new_exif))]

        if delta:
            for other in parsed_iloc:
                if other is entry:
                    continue
                shifted_extents = []
                for offset, length in other["extents"]:
                    shifted_extents.append((offset + delta if offset > abs_offset else offset, length))
                other["extents"] = shifted_extents
        return bytes(content)

    print("warning: unable to patch passthrough EXIF UserComment; preserving source EXIF", file=sys.stderr)
    return src_mdat_content


def _append_oppo_trailing_payload(output_path: str, iso_meta: dict,
                                   gainmap, lhdr) -> None:
    """Append OPPO private extension blocks to the HEIC tail.

    LHDR sources are kept byte-for-byte so Gallery can stay on the proven
    local.hdr.* decoder branch. UHDR sources are repacked into the OPPO UHDR
    extension shape.
    """
    if lhdr.file_data is None or lhdr.manifest_entries is None:
        return

    if lhdr.mode == "lhdr":
        with open(output_path, "ab") as f:
            f.write(lhdr.file_data[lhdr.ext_start:])
        return

    names_to_skip = {
        "local.hdr.meta.data",
        "local.hdr.linear.mask",
        "local.uhdr.gainmap.info",
        "local.uhdr.gainmap.data",
    }
    json_start_in_ext = None
    # Locate the JSON manifest in the extension region to compute physical offsets
    ext = lhdr.file_data[lhdr.ext_start:]
    manifest_result = container.parse_manifest(ext)
    if manifest_result is None:
        return
    _, json_start_in_ext, _ = manifest_result

    repacked = bytearray()
    new_entries = []

    def append_manifest_entry(name: str, payload: bytes, version: int = 1) -> None:
        start = len(repacked)
        repacked.extend(payload)
        new_entries.append({
            "name": name,
            "length": len(payload),
            "start": start,
            "version": version,
        })

    for entry in lhdr.manifest_entries:
        if entry["name"] in names_to_skip:
            continue
        # Physical offset = ext_start + (json_start_in_ext - entry.offset)
        phys = lhdr.ext_start + (json_start_in_ext - entry["offset"])
        length = entry["length"]
        if 0 <= phys and phys + length <= len(lhdr.file_data):
            chunk = lhdr.file_data[phys:phys + length]
            append_manifest_entry(entry["name"], chunk, entry.get("version", 1))

    info_bytes = iso21496.build_oppo_uhdr_info_bytes(iso_meta)
    append_manifest_entry("local.uhdr.gainmap.info", info_bytes, 1)

    # local.uhdr.gainmap.data: JPEG of gain map
    if gainmap is not None:
        gm_img = _normalize_gainmap_image(gainmap)
        buf = io.BytesIO()
        gm_img.save(buf, format="JPEG", quality=90)
        gm_jpeg = buf.getvalue()
        append_manifest_entry("local.uhdr.gainmap.data", gm_jpeg, 1)

    if not new_entries:
        return

    # Build final payload: 2168-byte container header + data + JSON manifest + footer
    # Header: 84-byte standard header + 2164-byte hdr.transform.data (zeroed)
    HEADER_SIZE = 2168
    payload_length = len(repacked)
    manifest_entries = [
        {
            "name": entry["name"],
            "length": entry["length"],
            "offset": payload_length - entry["start"],
            "version": entry["version"],
        }
        for entry in new_entries
    ]
    manifest_json = json.dumps(manifest_entries, separators=(",", ":")).encode("utf-8")

    footer_length = len(manifest_json) + 1 + 8
    total_region_size = HEADER_SIZE + payload_length + footer_length
    header = bytearray(HEADER_SIZE)
    struct.pack_into(">I", header, 0, total_region_size)
    struct.pack_into("<f", header, 4, 1.2)
    header[8] = 0xFF
    device_name = b"XDRemux\x00"
    header[9:9 + len(device_name)] = device_name
    # bytes 84-2168: hdr.transform.data (zeroed — no tone curve LUT available)

    with open(output_path, "ab") as f:
        f.write(bytes(header))
        f.write(bytes(repacked))
        f.write(manifest_json)
        f.write(b"\x00")
        f.write(OPPO_EXTENSION_TAG)
        f.write(struct.pack("<I", footer_length))
