"""HEIC I/O — cross-platform via pillow-heif.

Read: pillow-heif for base image decode.
Write: pillow-heif dual-image encode + ISOBMFF binary patch for ISO 21496-1.

After pillow-heif writes the base file, isobmff_patch.py patches the binary
to add auxC box (urn:iso:std:iso:ts:21496:-1), convert gain map to tmap type,
and insert iref/auxl reference — enabling HDR detection by macOS/iOS.
"""

import json
import io
import re
import struct
import sys

from PIL import Image
import numpy as np

from . import container
from . import iso21496


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

    # Accept both numpy arrays and PIL Images
    if isinstance(gainmap, Image.Image):
        gm_img = gainmap.convert("L")
    elif isinstance(gainmap, np.ndarray):
        gm_img = Image.fromarray(gainmap, mode="L")
    else:
        raise ValueError(f"Unsupported gainmap type: {type(gainmap)}")

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
        _append_oppo_trailing_payload(output_path, iso_meta, gainmap, lhdr)


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
        if isinstance(gainmap, np.ndarray):
            if gainmap.ndim == 2:
                gm_img = Image.fromarray(gainmap, mode="L")
            elif gainmap.ndim == 3 and gainmap.shape[2] == 3:
                gm_img = Image.fromarray(gainmap, mode="RGB")
            else:
                gm_img = Image.fromarray(gainmap, mode="L")
        elif isinstance(gainmap, Image.Image):
            gm_img = gainmap
        else:
            gm_img = None

        if gm_img is not None:
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
