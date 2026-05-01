"""ISO 21496-1 HDR metadata construction.

Builds the standardized hdrgm:* XMP metadata block from
the EDR scale projection produced by edrScaleCalculator.
"""

import math
from typing import Any


def build_iso21496_metadata_from_uhdr(floats: tuple) -> dict[str, Any]:
    """Build ISO 21496-1 metadata from UHDR 20-float info block.

    OPPO UHDR stores gainMap values as linear multipliers (e.g. 4.9261 = ~2.3 stops).
    ISO 21496-1 XMP uses log2 domain. Also OPPO gainMapMin=1.0 means no gain (ISO: 0.0).
    """
    gm_min = [max(math.log2(floats[1]), 0.0),
              max(math.log2(floats[2]), 0.0),
              max(math.log2(floats[3]), 0.0)]
    gm_max = [math.log2(floats[4]), math.log2(floats[5]), math.log2(floats[6])]
    gamma = [floats[7], floats[8], floats[9]]
    off_sdr = [floats[10], floats[11], floats[12]]
    off_hdr = [floats[13], floats[14], floats[15]]
    cap_min = max(math.log2(floats[16]), 0.0)
    cap_max = math.log2(floats[17])
    base_hdr = floats[19] > 0.5
    return {
        "gainMapMin": gm_min,
        "gainMapMax": gm_max,
        "gamma": gamma,
        "offsetSdr": off_sdr,
        "offsetHdr": off_hdr,
        "hdrCapacityMin": cap_min,
        "hdrCapacityMax": cap_max,
        "baseRenditionIsHDR": base_hdr,
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
    """Format ISO 21496 metadata as hdrgm XMP string."""
    def fmt(v):
        if isinstance(v, list):
            return " ".join(str(x) for x in v)
        if isinstance(v, bool):
            return "True" if v else "False"
        return str(v)

    return (
        '<rdf:Description rdf:about="" xmlns:hdrgm="http://ns.adobe.com/hdr-gain-map/1.0/">\n'
        f'  <hdrgm:Version>1.0</hdrgm:Version>\n'
        f'  <hdrgm:GainMapMin>{fmt(meta["gainMapMin"])}</hdrgm:GainMapMin>\n'
        f'  <hdrgm:GainMapMax>{fmt(meta["gainMapMax"])}</hdrgm:GainMapMax>\n'
        f'  <hdrgm:Gamma>{fmt(meta["gamma"])}</hdrgm:Gamma>\n'
        f'  <hdrgm:OffsetSDR>{fmt(meta["offsetSdr"])}</hdrgm:OffsetSDR>\n'
        f'  <hdrgm:OffsetHDR>{fmt(meta["offsetHdr"])}</hdrgm:OffsetHDR>\n'
        f'  <hdrgm:HDRCapacityMin>{fmt(meta["hdrCapacityMin"])}</hdrgm:HDRCapacityMin>\n'
        f'  <hdrgm:HDRCapacityMax>{fmt(meta["hdrCapacityMax"])}</hdrgm:HDRCapacityMax>\n'
        f'  <hdrgm:BaseRenditionIsHDR>{fmt(meta["baseRenditionIsHDR"])}</hdrgm:BaseRenditionIsHDR>\n'
        f'</rdf:Description>'
    )
