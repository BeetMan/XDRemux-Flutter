"""ISO 21496-1 HDR metadata construction.

Builds the standardized hdrgm:* XMP metadata block from
the EDR scale projection produced by edrScaleCalculator.
"""

import math
import struct
from typing import Any


OPPO_UHDR_INFO_FLOAT_COUNT = 20


def _vector3(value: Any, default: float) -> list[float]:
    if isinstance(value, (list, tuple)):
        values = list(value)
    else:
        values = [value]

    result: list[float] = []
    for index in range(3):
        try:
            result.append(float(values[index]))
        except (IndexError, TypeError, ValueError):
            result.append(float(default))
    return result


def parse_oppo_uhdr_info(floats: tuple[float, ...]) -> dict[str, Any]:
    """Parse the confirmed 20-float OPPO UHDR info layout."""
    if len(floats) < OPPO_UHDR_INFO_FLOAT_COUNT:
        raise ValueError("local.uhdr.gainmap.info must contain at least 20 float32 values")

    return {
        "ratioMin": [floats[0], floats[1], floats[2]],
        "padding": floats[3],
        "ratioMax": [floats[4], floats[5], floats[6]],
        "gamma": [floats[7], floats[8], floats[9]],
        "epsilonSdr": [floats[10], floats[11], floats[12]],
        "epsilonHdr": [floats[13], floats[14], floats[15]],
        "displayRatioSdr": floats[16],
        "displayRatioHdr": floats[17],
        "scale": floats[18],
        "baseImageType": floats[19],
    }


def build_oppo_uhdr_info_bytes(iso_meta: dict[str, Any]) -> bytes:
    """Build OPPO's 80-byte local.uhdr.gainmap.info payload."""
    gain_map_min = _vector3(iso_meta.get("gainMapMin", [0.0, 0.0, 0.0]), 0.0)
    gain_map_max = _vector3(iso_meta.get("gainMapMax", [0.0, 0.0, 0.0]), 0.0)
    gamma = _vector3(iso_meta.get("gamma", [1.0, 1.0, 1.0]), 1.0)
    offset_sdr = _vector3(iso_meta.get("offsetSdr", [0.0, 0.0, 0.0]), 0.0)
    offset_hdr = _vector3(iso_meta.get("offsetHdr", [0.0, 0.0, 0.0]), 0.0)

    hdr_capacity_min = float(iso_meta.get("hdrCapacityMin", 0.0) or 0.0)
    hdr_capacity_max = float(iso_meta.get("hdrCapacityMax", 0.0) or 0.0)
    display_ratio_sdr = 2 ** hdr_capacity_min if hdr_capacity_min > 0.0 else 1.0
    display_ratio_hdr = 2 ** hdr_capacity_max if hdr_capacity_max > 0.0 else 1.0
    scale_val = float(iso_meta.get("scale", display_ratio_hdr) or display_ratio_hdr)

    info_floats = [
        2 ** gain_map_min[0], 2 ** gain_map_min[1], 2 ** gain_map_min[2],
        1.0,
        2 ** gain_map_max[0], 2 ** gain_map_max[1], 2 ** gain_map_max[2],
        gamma[0], gamma[1], gamma[2],
        offset_sdr[0], offset_sdr[1], offset_sdr[2],
        offset_hdr[0], offset_hdr[1], offset_hdr[2],
        display_ratio_sdr, display_ratio_hdr, scale_val,
        0.0,
    ]
    return struct.pack("<20f", *info_floats)


def build_iso21496_metadata_from_uhdr(floats: tuple) -> dict[str, Any]:
    """Build ISO 21496-1 metadata from UHDR 20-float info block."""
    info = parse_oppo_uhdr_info(floats)
    gm_min = [max(math.log2(info["ratioMin"][0]), 0.0),
              max(math.log2(info["ratioMin"][1]), 0.0),
              max(math.log2(info["ratioMin"][2]), 0.0)]
    gm_max = [math.log2(info["ratioMax"][0]),
              math.log2(info["ratioMax"][1]),
              math.log2(info["ratioMax"][2])]
    cap_min = max(math.log2(info["displayRatioSdr"]), 0.0)
    cap_max = math.log2(info["displayRatioHdr"])
    base_hdr = info["baseImageType"] > 0.5
    return {
        "gainMapMin": gm_min,
        "gainMapMax": gm_max,
        "gamma": info["gamma"],
        "offsetSdr": info["epsilonSdr"],
        "offsetHdr": info["epsilonHdr"],
        "hdrCapacityMin": cap_min,
        "hdrCapacityMax": cap_max,
        "baseRenditionIsHDR": base_hdr,
        "scale": info["scale"],
    }


def build_iso21496_metadata(edr_scale: float) -> dict[str, Any]:
    """Build ISO 21496-1 gain map metadata from EDR scale.

    Returns a dict with all hdrgm:* fields in linear domain.
    Caller applies log2 for the XMP serialization.
    """
    ratio_max = max(edr_scale, 1.0)
    return {
        "gainMapMin": [0.0, 0.0, 0.0],
        "gainMapMax": [round(math.log2(ratio_max), 7)] * 3,
        "gamma": [1.0, 1.0, 1.0],
        "offsetSdr": [0.0, 0.0, 0.0],
        "offsetHdr": [0.0, 0.0, 0.0],
        "hdrCapacityMin": 0.0,
        "hdrCapacityMax": round(math.log2(ratio_max), 7),
        "baseRenditionIsHDR": False,
    }


def format_hdrgm_xmp(meta: dict[str, Any]) -> str:
    """Format ISO 21496 metadata as hdrgm XMP string.

    Produces a full XMP document with <x:xmpmeta> wrapper and xmlns
    declarations matching Apple CGImageDestination output, which is
    required for CIImage expandToHDR Headroom detection.
    """
    def fmt(v):
        if isinstance(v, list):
            return " ".join(str(x) for x in v)
        if isinstance(v, bool):
            return "True" if v else "False"
        return str(v)

    return (
        '<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>\n'
        '<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="XMP Core 6.0.0">\n'
        '   <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n'
        '      <rdf:Description rdf:about=""\n'
        '            xmlns:hdrgm="http://ns.adobe.com/hdr-gain-map/1.0/"\n'
        '            xmlns:xmp="http://ns.adobe.com/xap/1.0/"\n'
        '            xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">\n'
        f'         <hdrgm:Version>1.0</hdrgm:Version>\n'
        f'         <hdrgm:GainMapMin>{fmt(meta["gainMapMin"])}</hdrgm:GainMapMin>\n'
        f'         <hdrgm:GainMapMax>{fmt(meta["gainMapMax"])}</hdrgm:GainMapMax>\n'
        f'         <hdrgm:Gamma>{fmt(meta["gamma"])}</hdrgm:Gamma>\n'
        f'         <hdrgm:OffsetSDR>{fmt(meta["offsetSdr"])}</hdrgm:OffsetSDR>\n'
        f'         <hdrgm:OffsetHDR>{fmt(meta["offsetHdr"])}</hdrgm:OffsetHDR>\n'
        f'         <hdrgm:HDRCapacityMin>{fmt(meta["hdrCapacityMin"])}</hdrgm:HDRCapacityMin>\n'
        f'         <hdrgm:HDRCapacityMax>{fmt(meta["hdrCapacityMax"])}</hdrgm:HDRCapacityMax>\n'
        f'         <hdrgm:BaseRenditionIsHDR>{fmt(meta["baseRenditionIsHDR"])}</hdrgm:BaseRenditionIsHDR>\n'
        '      </rdf:Description>\n'
        '   </rdf:RDF>\n'
        '</x:xmpmeta>\n'
        '<?xpacket end="w"?>'
    )
