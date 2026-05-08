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
import re
import struct
import sys
import tempfile

from PIL import Image
import numpy as np

from . import container
from . import iso21496


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


def read_heic(path: str) -> dict:
    """Read a ProXDR HEIC file."""
    from .edr import edr_scale_calculator

    lhdr = container.extract_lhdr(path)
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


def write_heic(output_path: str, base_image: Image.Image,
               gainmap, iso_meta: dict,
               oppo_compat: bool = False, lhdr=None,
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
                            lhdr=None, oppo_compat: bool = False,
                            replace_primary_colr: bool = False,
                            exif_data: bytes | None = None) -> None:
    """Passthrough mode: copy source base image HEVC data without re-encoding.

    Only the gain map is encoded fresh. Base image compressed data is copied
    byte-for-byte from the source mdat, preserving original quality.
    """
    from .isobmff_patch import (
        _boxes, _build_tmap_config, _fullbox, _parse_all_items,
        AUXC_BOX, DINF_BOX, COLR_NCLX_PQ_BOX, COLR_NCLX_SRGB_BOX,
        IROT_BOX, PIXI_RGB10_BOX, SWIFT_PQ_ICC_PROFILE,
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

    # Parse pitm
    pitm_v = src[child['pitm']['ds']]
    pitm_body = child['pitm']['ds'] + 4
    pitm_id = struct.unpack_from('>H' if pitm_v == 0 else '>I',
                                   src, pitm_body)[0]

    # Parse ipco properties
    ipco_prop_types = {}
    ipco_idx = 1
    for tp, ds, de, bs, bsz in _boxes(src, ipco['ds'], ipco['de']):
        ipco_prop_types[ipco_idx] = tp
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
    from pillow_heif import from_pillow
    gm_img = _normalize_gainmap_image(gainmap)

    gm_width, gm_height = gm_img.size
    gm_tmp_path = None
    try:
        fd, gm_tmp_path = tempfile.mkstemp(
            prefix="proxdr_gainmap_", suffix=".heic",
            dir=os.path.dirname(os.path.abspath(output_path)) or None,
        )
        os.close(fd)
        from_pillow(gm_img).save(gm_tmp_path, quality=90)
        with open(gm_tmp_path, 'rb') as f:
            gm_data = f.read()
        gm_mdat_data, gm_hvcC = _extract_heif_hvc_payload_and_config(gm_data)
    finally:
        if gm_tmp_path:
            try:
                os.remove(gm_tmp_path)
            except OSError:
                pass

    # ── 4. Prepare building blocks ─────────────────────────────────
    next_id = max(item_types.keys()) + 1
    gm_item_id = next_id
    gm_grid_id = next_id + 1
    tmap_item_id = next_id + 2
    if tmap_item_id > 0xFFFF:
        raise ValueError("Passthrough mode currently requires 16-bit HEIF item IDs")

    auxc_prop_idx = prop_count + 1
    irot_prop_idx = prop_count + 2
    pq_nclx_prop_idx = prop_count + 3
    srgb_nclx_prop_idx = prop_count + 4
    hdr_pixi_prop_idx = prop_count + 5
    gm_hvcC_prop_idx = prop_count + 6
    gm_ispe_prop_idx = prop_count + 7
    if not (ipma_f & 1) and gm_ispe_prop_idx > 0x7F:
        raise ValueError("Passthrough mode cannot encode more than 127 properties in ipma flags=0")
    if primary_ispe_idx is None:
        raise ValueError(f"Primary item {pitm_id} has no ispe property association")

    tmap_config = _build_tmap_config(iso_meta)

    gm_grid_config = b'\x00\x00\x00\x00' + struct.pack('>HH', gm_width, gm_height)
    idat_payload = gm_grid_config + tmap_config

    new_infe = (
        _infe_box(gm_item_id, 'hvc1', flags=0)
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

    # Primary grid: colr + ispe + pixi + irot (matching normal mode)
    primary_assocs = []
    if first_colr_idx is not None:
        primary_assocs.append((first_colr_idx, True))
    if primary_ispe_idx is not None:
        primary_assocs.append((primary_ispe_idx, False))
    primary_assocs.append((hdr_pixi_prop_idx, False))
    primary_assocs.append((irot_prop_idx, True))
    new_ipma_entries = [_encode_ipma_entry(pitm_id, primary_assocs)]

    gm_assocs = [(gm_hvcC_prop_idx, True), (gm_ispe_prop_idx, True),
                 (auxc_prop_idx, True), (irot_prop_idx, True)]
    new_ipma_entries.append(_encode_ipma_entry(gm_item_id, gm_assocs))

    gm_grid_assocs = []
    if first_colr_idx is not None:
        gm_grid_assocs.append((first_colr_idx, True))
    gm_grid_assocs.append((gm_ispe_prop_idx, False))
    gm_grid_assocs.append((irot_prop_idx, True))
    new_ipma_entries.append(_encode_ipma_entry(gm_grid_id, gm_grid_assocs))

    tmap_assocs = [(pq_nclx_prop_idx, True), (primary_ispe_idx, False),
                   (hdr_pixi_prop_idx, False), (irot_prop_idx, True)]
    new_ipma_entries.append(_encode_ipma_entry(tmap_item_id, tmap_assocs))

    # New iref references
    iref_new_content = (
        _iref_box(b'dimg', gm_grid_id, [gm_item_id], version=iref_v)
        + _iref_box(b'dimg', tmap_item_id, [pitm_id, gm_grid_id], version=iref_v)
        + _iref_box(b'auxl', gm_item_id, [pitm_id], version=iref_v)
    )

    # cdsc: EXIF references both primary grid and tmap (matches normal mode)
    if exif_item_id is not None:
        iref_new_content += _iref_box(b'cdsc', exif_item_id, [pitm_id, tmap_item_id], version=iref_v)

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
                + struct.pack('>I', 0) + struct.pack('>H', pitm_id)
            ))

        elif tp == 'iinf':
            part = bytearray()
            part += b'\x00\x00\x00\x00' + b'iinf'
            ec_pos = child['iinf']['ds'] + 4
            ec_size = 4 if iinf_v >= 1 else 2
            part += src[ds:ec_pos + ec_size]
            for tp2, ds2, de2, bs2, bsz2 in _boxes(src, ec_pos + ec_size, child['iinf']['de']):
                if tp2 == 'infe':
                    part += src[bs2:de2]
            old_cnt = struct.unpack_from('>H' if ec_size == 2 else '>I', src, ec_pos)[0]
            new_cnt = old_cnt + 3
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
            part += struct.pack('>H', old_iloc_cnt + 3)
            for entry in parsed_iloc:
                part += struct.pack('>H', entry['iid'])
                part += struct.pack('>H', entry['cm'])
                part += struct.pack('>H', entry['dri'])
                part += struct.pack('>H', len(entry['extents']))
                for eo, el in entry['extents']:
                    # cm=0 offsets will be patched in step 6 after we know iloc_delta
                    part += struct.pack('>I', eo)
                    part += struct.pack('>I', el)
            # gm hvc1 (cm=0, in mdat) — offset patched later
            part += struct.pack('>H', gm_item_id) + struct.pack('>H', 0)
            part += struct.pack('>H', 0) + struct.pack('>H', 1)
            part += struct.pack('>I', 0) + struct.pack('>I', len(gm_mdat_data))  # placeholder offset
            # gm grid (cm=1, in idat)
            old_idat_data_sz = child['idat']['sz'] - 8 if 'idat' in child else 0
            part += struct.pack('>H', gm_grid_id) + struct.pack('>H', 1)
            part += struct.pack('>H', 0) + struct.pack('>H', 1)
            part += struct.pack('>I', old_idat_data_sz) + struct.pack('>I', len(gm_grid_config))
            # tmap (cm=1, in idat)
            part += struct.pack('>H', tmap_item_id) + struct.pack('>H', 1)
            part += struct.pack('>H', 0) + struct.pack('>H', 1)
            part += struct.pack('>I', old_idat_data_sz + len(gm_grid_config))
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
            ipco_part += gm_hvcC
            ipco_part += struct.pack('>I', 20) + b'ispe' + struct.pack('>I', 0)
            ipco_part += struct.pack('>II', gm_width, gm_height)
            struct.pack_into('>I', ipco_part, 0, len(ipco_part))

            # Build ipma — re-serialize existing entries, skipping pitm_id
            # (we replace it with our new entry that adds colr/pixi/irot)
            ipma_part = bytearray()
            ipma_part += b'\x00\x00\x00\x00' + b'ipma'
            ipma_part += src[ipma['ds']:ipma['ds'] + 4]  # fullbox header
            # Count: existing entries minus pitm_id duplicate, plus 4 new
            existing_count = sum(1 for e in ipma_entries if e['iid'] != pitm_id)
            ipma_part += struct.pack('>I', existing_count + 4)
            for entry in ipma_entries:
                if entry['iid'] == pitm_id:
                    continue
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
        [*item_types.keys(), gm_item_id, gm_grid_id, tmap_item_id, *existing_group_ids],
        default=tmap_item_id,
    ) + 1
    meta_parts.append(bytearray(
        struct.pack('>I', 36) + b'grpl'
        + struct.pack('>I', 28) + b'altr'
        + struct.pack('>I', 0)
        + struct.pack('>I', new_altr_group_id)
        + struct.pack('>I', 2)
        + struct.pack('>I', tmap_item_id)
        + struct.pack('>I', pitm_id)
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
    gm_mdat_offset_in_file = new_mdat_file_off + 8 + len(src_mdat_content)

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
    for i in range(old_iloc_cnt + 3):
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
            elif i == old_iloc_cnt:
                # gm hvc1 item — set offset
                struct.pack_into('>I', iloc_part, el_off - 4, gm_mdat_offset_in_file)

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

    # mdat: source tiles + gain map HEVC
    new_mdat_content_sz = len(src_mdat_content) + len(gm_mdat_data)
    out += struct.pack('>I', new_mdat_content_sz + 8)  # 8-byte box header
    out += b'mdat'
    out += src_mdat_content
    out += gm_mdat_data

    with open(output_path, 'wb') as f:
        f.write(out)

    if oppo_compat and lhdr is not None:
        _append_oppo_trailing_payload(output_path, iso_meta, gm_img, lhdr)


def _get_patched_oppo_user_comment(lhdr) -> str | None:
    """Extract and patch oplus_<digits> to add OPLUS_ULTRA_HDR flag (0x20000000)."""
    if lhdr.file_data is None:
        return None
    m = re.search(b"oplus_(\\d+)", lhdr.file_data)
    if not m:
        return None
    original_flags = int(m.group(1))
    patched_flags = original_flags | 0x20000000
    return f"oplus_{patched_flags}"


def _merge_exif_user_comment(exif_bytes: bytes, comment: str) -> bytes:
    """Merge a UserComment string into existing EXIF bytes."""
    try:
        import piexif
        exif_dict = piexif.load(exif_bytes)
        exif_dict["Exif"][piexif.ExifIFD.UserComment] = comment.encode("utf-8")
        return piexif.dump(exif_dict)
    except Exception:
        return exif_bytes


def _inject_exif_user_comment(heif, comment: str) -> None:
    """Inject EXIF UserComment into a pillow-heif object before save."""
    try:
        primary = heif[0] if hasattr(heif, '__getitem__') else heif
        # Build minimal EXIF with UserComment (tag 0x9286)
        import piexif
        exif_dict = {"0th": {}, "Exif": {piexif.ExifIFD.UserComment: comment.encode("utf-8")},
                     "GPS": {}, "1st": {}, "thumbnail": None}
        primary.info["exif"] = piexif.dump(exif_dict)
    except ImportError:
        # piexif not available — try PIL-based approach
        try:
            primary = heif[0] if hasattr(heif, '__getitem__') else heif
            pil = primary.to_pillow()
            exif = pil.getexif()
            exif[0x9286] = comment.encode("utf-8")
            primary.info["exif"] = exif.tobytes()
        except Exception:
            pass


def _append_oppo_trailing_payload(output_path: str, iso_meta: dict,
                                   gainmap, lhdr) -> None:
    """Append OPPO UHDR extension blocks to the HEIC tail.

    Replaces LHDR blocks (local.hdr.meta.data, local.hdr.linear.mask)
    with UHDR blocks (local.uhdr.gainmap.info, local.uhdr.gainmap.data)
    so OPPO Gallery can read the gain map via OPLUS_ULTRA_HDR decoder path.
    """
    if lhdr.file_data is None or lhdr.manifest_entries is None:
        return

    names_to_skip = {"local.hdr.meta.data", "local.hdr.linear.mask"}
    json_start_in_ext = None
    # Locate the JSON manifest in the extension region to compute physical offsets
    ext = lhdr.file_data[lhdr.ext_start:]
    manifest_result = container.parse_manifest(ext)
    if manifest_result is None:
        return
    _, json_start_in_ext, _ = manifest_result

    repacked = bytearray()
    new_entries = []
    current_offset = 0

    for entry in lhdr.manifest_entries:
        if entry["name"] in names_to_skip:
            continue
        # Physical offset = ext_start + (json_start_in_ext - entry.offset)
        phys = lhdr.ext_start + (json_start_in_ext - entry["offset"])
        length = entry["length"]
        if 0 <= phys and phys + length <= len(lhdr.file_data):
            chunk = lhdr.file_data[phys:phys + length]
            repacked.extend(chunk)
            current_offset += length
            new_entries.append({
                "name": entry["name"], "length": length,
                "offset": current_offset, "version": entry.get("version", 1),
            })

    # local.uhdr.gainmap.info: 80 bytes = 20 float32 LE
    ratio_max = iso_meta["gainMapMax"][0] if isinstance(iso_meta["gainMapMax"], list) else iso_meta["gainMapMax"]
    # Convert from log2 domain back to linear multiplier for OPPO UHDR format
    ratio_max_linear = 2 ** ratio_max if ratio_max > 0 else 1.0
    display_ratio_sdr = 2 ** iso_meta["hdrCapacityMin"] if iso_meta["hdrCapacityMin"] > 0 else 1.0
    display_ratio_hdr = 2 ** iso_meta["hdrCapacityMax"] if iso_meta["hdrCapacityMax"] > 0 else 1.0
    scale_val = display_ratio_hdr

    gamma_val = iso_meta["gamma"][0] if isinstance(iso_meta["gamma"], list) else iso_meta["gamma"]
    off_sdr = iso_meta["offsetSdr"][0] if isinstance(iso_meta["offsetSdr"], list) else iso_meta["offsetSdr"]
    off_hdr = iso_meta["offsetHdr"][0] if isinstance(iso_meta["offsetHdr"], list) else iso_meta["offsetHdr"]

    info_floats = [
        0, 0, 1, 1, 1,
        ratio_max_linear, ratio_max_linear, ratio_max_linear,
        gamma_val, gamma_val, gamma_val,
        off_sdr, off_sdr, off_sdr,
        off_hdr, off_hdr, off_hdr,
        display_ratio_sdr, display_ratio_hdr, scale_val,
    ]
    info_bytes = struct.pack("<20f", *info_floats)
    repacked.extend(info_bytes)
    current_offset += len(info_bytes)
    new_entries.append({
        "name": "local.uhdr.gainmap.info", "length": len(info_bytes),
        "offset": current_offset, "version": 1,
    })

    # local.uhdr.gainmap.data: JPEG of gain map
    if gainmap is not None:
        gm_img = _normalize_gainmap_image(gainmap)
        buf = io.BytesIO()
        gm_img.save(buf, format="JPEG", quality=90)
        gm_jpeg = buf.getvalue()
        repacked.extend(gm_jpeg)
        current_offset += len(gm_jpeg)
        new_entries.append({
            "name": "local.uhdr.gainmap.data", "length": len(gm_jpeg),
            "offset": current_offset, "version": 1,
        })

    if not new_entries:
        return

    # Build final payload: data + JSON manifest
    manifest_json = json.dumps(new_entries, separators=(",", ":")).encode("utf-8")
    repacked.extend(manifest_json)

    with open(output_path, "ab") as f:
        f.write(bytes(repacked))
