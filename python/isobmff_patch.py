"""ISOBMFF binary patcher for ISO 21496-1 + Apple ImageIO compliance.

After pillow-heif writes a HEIC file with a secondary gain map image,
this module patches the binary to:
  1. Add auxC property box in ipco with urn:iso:std:iso:ts:21496:-1 URI
    2. Create a new tmap item with 62-byte tone map config (stored in mdat)
  3. Link tmap to auxC via ipma
  4. Add iref/dimg from tmap to [primary, gain_map]
  5. Add iref/auxl from gain_map to primary (ISO 21496-1)
    6. Adjust iloc offsets for inserted bytes before mdat

Assembly strategy: parse all meta children into an ordered list, modify
each box's content in-place, then rebuild the output by walking the list
and inserting new content at the correct positions. This ensures no box
is lost regardless of ordering.
"""
import struct


# ── Low-level helpers ──────────────────────────────────────────────

def _rn(n, d, o):
    """Read n-byte big-endian unsigned int."""
    if n == 0: return 0, o
    if n == 1: return d[o], o+1
    if n == 2: return struct.unpack_from('>H', d, o)[0], o+2
    if n == 4: return struct.unpack_from('>I', d, o)[0], o+4
    if n == 8: return struct.unpack_from('>Q', d, o)[0], o+8
    return 0, o

def _wn(n, v, d, o):
    """Write n-byte big-endian unsigned int v into bytearray d at offset o."""
    if n == 1: d[o] = v & 0xFF
    elif n == 2: struct.pack_into('>H', d, o, v)
    elif n == 4: struct.pack_into('>I', d, o, v)
    elif n == 8: struct.pack_into('>Q', d, o, v)

def _pack(n, v):
    """Return n bytes big-endian encoding of v."""
    if n == 0: return b''
    if n == 1: return bytes([v & 0xFF])
    if n == 2: return struct.pack('>H', v)
    if n == 4: return struct.pack('>I', v)
    if n == 8: return struct.pack('>Q', v)
    return b''


# ── Box iterator ───────────────────────────────────────────────────

def _boxes(d, start, end):
    """Yields (type, data_start, data_end, box_start, box_size)."""
    o = start
    while o < end - 7:
        sz = struct.unpack_from('>I', d, o)[0]
        tp = d[o+4:o+8].decode('latin-1', errors='replace')
        o2 = o + 8; hs = 8
        if sz == 1: sz = struct.unpack_from('>Q', d, o2)[0]; o2 += 8; hs = 16
        elif sz == 0: sz = end - o
        be = min(o + sz, end)
        yield tp, o+hs, be, o, sz
        o = be


# ── Constants ──────────────────────────────────────────────────────

AUXC_URI = 'urn:iso:std:iso:ts:21496:-1'
AUXC_BOX = (
    b'\x00\x00\x00\x28'     # size = 40
    b'\x61\x75\x78\x43'     # type = "auxC"
    b'\x00\x00\x00\x00'     # version=0, flags=0
    b'\x75\x72\x6e\x3a\x69\x73\x6f\x3a'   # "urn:iso:"
    b'\x73\x74\x64\x3a\x69\x73\x6f\x3a'   # "std:iso:"
    b'\x74\x73\x3a\x32\x31\x34\x39\x36'   # "ts:21496"
    b'\x3a\x2d\x31\x00'                     # ":-1\0"
)

# dinf box (data information) — required by Apple ImageIO.
# Contains dref with self-referencing url entry.
DINF_BOX = (
    b'\x00\x00\x00\x24'     # size = 36
    b'\x64\x69\x6e\x66'     # type = "dinf"
    b'\x00\x00\x00\x1c'     # dref size = 28
    b'\x64\x72\x65\x66'     # type = "dref"
    b'\x00\x00\x00\x00'     # version=0, flags=0
    b'\x00\x00\x00\x01'     # entry_count = 1
    b'\x00\x00\x00\x0c'     # url size = 12
    b'\x75\x72\x6c\x20'     # type = "url "
    b'\x00\x00\x00\x01'     # version=0, flags=1 (self-contained)
)

# colr nclx for BT.2020 with PQ transfer — matches Apple ImageIO ISO gainmap encoder.
# cp=9 (BT.2020), tc=16 (SMPTE ST 2084 PQ), mc=9 (BT.2020 non-constant luminance)
COLR_NCLX_PQ_BOX = (
    b'\x00\x00\x00\x13'     # size = 19
    b'\x63\x6f\x6c\x72'     # type = "colr"
    b'\x6e\x63\x6c\x78'     # colour_type = "nclx"
    b'\x00\x09'              # colour_primaries = 9 (BT.2020)
    b'\x00\x10'              # transfer_characteristics = 16 (PQ / ST 2084)
    b'\x00\x09'              # matrix_coefficients = 9 (BT.2020 non-constant luminance)
    b'\x80'                  # full_range_flag = 1
)

# colr nclx for sRGB — matches gainmap grid's base color space in golden sample.
# cp=2 (sRGB), tc=2 (sRGB), mc=2 (sRGB)
COLR_NCLX_SRGB_BOX = (
    b'\x00\x00\x00\x13'     # size = 19
    b'\x63\x6f\x6c\x72'     # type = "colr"
    b'\x6e\x63\x6c\x78'     # colour_type = "nclx"
    b'\x00\x02'              # colour_primaries = 2 (sRGB)
    b'\x00\x02'              # transfer_characteristics = 2 (sRGB)
    b'\x00\x02'              # matrix_coefficients = 2 (sRGB)
    b'\x80'                  # full_range_flag = 1
)

# irot box (rotation=0) — Apple ImageIO requires this on primary and gainmap items.
IROT_BOX = (
    b'\x00\x00\x00\x09'     # size = 9
    b'\x69\x72\x6f\x74'     # type = "irot"
    b'\x00'                  # angle = 0 (no rotation)
)

# pixi box for the alternate HDR representation advertised by tmap.
# Fullbox + num_channels=3 + bits_per_channel=[10,10,10].
PIXI_RGB10_BOX = (
    b'\x00\x00\x00\x10'
    b'\x70\x69\x78\x69'
    b'\x00\x00\x00\x00'
    b'\x03\x0a\x0a\x0a'
)

PIXI_RGB8_BOX = (
    b'\x00\x00\x00\x10'
    b'\x70\x69\x78\x69'
    b'\x00\x00\x00\x00'
    b'\x03\x08\x08\x08'
)


def build_grid_payload(width: int, height: int, *, rows: int = 1, columns: int = 1) -> bytes:
    """Build the 8-byte HEIF grid item payload used in meta/idat."""
    if not (1 <= rows <= 0x100 and 1 <= columns <= 0x100):
        raise ValueError(f"Unsupported grid shape: {rows}x{columns}")
    if 1 <= width <= 0xFFFF and 1 <= height <= 0xFFFF:
        return struct.pack('>BBBBHH', 0, 0, rows - 1, columns - 1, width, height)
    if 1 <= width <= 0xFFFFFFFF and 1 <= height <= 0xFFFFFFFF:
        return struct.pack('>BBBBII', 0, 1, rows - 1, columns - 1, width, height)
    raise ValueError(f"Unsupported grid output size: {width}x{height}")


def parse_iref_dimg(data: bytes | bytearray, iref_ds: int, iref_de: int) -> dict[int, list[int]]:
    """Parse all dimg references from an iref box data range."""
    version, _, pos = _fullbox(data, iref_ds)
    id_size = 4 if version >= 1 else 2
    refs = {}
    while pos + 8 <= iref_de:
        ref_size = struct.unpack_from('>I', data, pos)[0]
        ref_type = bytes(data[pos + 4:pos + 8])
        header_size = 8
        if ref_size == 1:
            if pos + 16 > iref_de:
                break
            ref_size = struct.unpack_from('>Q', data, pos + 8)[0]
            header_size = 16
        ref_end = pos + ref_size
        if ref_size < header_size + id_size + 2 or ref_end > iref_de:
            break
        cursor = pos + header_size
        from_id = int.from_bytes(data[cursor:cursor + id_size], 'big')
        cursor += id_size
        ref_count = struct.unpack_from('>H', data, cursor)[0]
        cursor += 2
        targets = []
        for _ in range(ref_count):
            if cursor + id_size > ref_end:
                break
            targets.append(int.from_bytes(data[cursor:cursor + id_size], 'big'))
            cursor += id_size
        if ref_type == b'dimg':
            refs[from_id] = targets
        pos = ref_end
    return refs

def _first_number(value, default=0.0):
    if isinstance(value, (list, tuple)):
        return _first_number(value[0], default) if value else default
    if value is None:
        return default
    return float(value)


def _fixed_100k(value, *, zero_as_one=False):
    encoded = int(round(float(value) * 100000.0))
    if zero_as_one and encoded == 0:
        return 1
    return encoded


def _build_tmap_config(iso_meta=None):
    """Build Apple ImageIO-compatible 62-byte tmap item payload.

    The payload mirrors the structure emitted by CGImageDestination for ISO
    gain maps: a six-byte header followed by seven signed fixed-point
    numerator/denominator pairs at scale 100000.  CoreImage derives the
    reported content headroom from the alternate headroom pair.
    """
    iso_meta = iso_meta or {}
    base_headroom = _first_number(iso_meta.get("hdrCapacityMin"), 0.0)
    alternate_headroom = _first_number(
        iso_meta.get("hdrCapacityMax"),
        _first_number(iso_meta.get("gainMapMax"), 1.0),
    )
    gain_min = _first_number(iso_meta.get("gainMapMin"), 0.0)
    gain_max = _first_number(iso_meta.get("gainMapMax"), alternate_headroom)
    gamma = _first_number(iso_meta.get("gamma"), 1.0)
    base_offset = _first_number(iso_meta.get("offsetSdr"), 0.0)
    alternate_offset = _first_number(iso_meta.get("offsetHdr"), 0.0)

    values = [
        _fixed_100k(base_headroom), 100000,
        _fixed_100k(alternate_headroom), 100000,
        _fixed_100k(gain_min), 100000,
        _fixed_100k(gain_max), 100000,
        _fixed_100k(gamma), 100000,
        _fixed_100k(base_offset, zero_as_one=True), 100000,
        _fixed_100k(alternate_offset, zero_as_one=True), 100000,
    ]
    payload = b'\x00\x00\x00\x00\x00\x40' + b''.join(
        struct.pack('>i', value) for value in values
    )
    if len(payload) != 62:
        raise ValueError(f"tmap config is {len(payload)} bytes, expected 62")
    return payload

# Primary image colr payload extracted from an Apple ImageIO ISO-gain-map HEIC.
# It is a Display P3 Linear ICC profile with a cicp tag, which CoreImage reports
# as kCGColorSpaceLinearDisplayP3 when expandToHDR succeeds.
SWIFT_PQ_ICC_PROFILE = bytes.fromhex(
    '70726f66000002306170706c040000006d6e74725247422058595a2007e30001'
    '0001000000000000616373704150504c000000004150504c0000000000000000'
    '00000000000000000000f6d6000100000000d32d6170706c5fbfd541cbee4e95'
    'e59562c4b432e80f000000000000000000000000000000000000000000000000'
    '000000000000000b64657363000001080000003e637072740000014800000050'
    '7774707400000198000000147258595a000001ac000000146758595a000001c0'
    '000000146258595a000001d40000001472545243000001e80000001063686164'
    '000001f80000002c63696370000002240000000c62545243000001e800000010'
    '67545243000001e8000000106d6c756300000000000000010000000c656e5553'
    '000000220000001c0044006900730070006c006100790020005000330020004c'
    '0069006e00650061007200006d6c756300000000000000010000000c656e5553'
    '000000340000001c0043006f0070007900720069006700680074002000410070'
    '0070006c006500200049006e0063002e002c0020003200300031003958595a20'
    '000000000000f6d6000100000000d32d58595a2000000000000083df00003dbf'
    'ffffffbb58595a200000000000004abf0000b13700000ab958595a2000000000'
    '000028380000110b0000c8b97061726100000000000000000001000073663332'
    '0000000000010c42000005defffff326000007930000fd90fffffba2fffffda3'
    '000003dc0000c06e63696370000000000c080001'
)
assert len(SWIFT_PQ_ICC_PROFILE) == 564


# ── Item detection ─────────────────────────────────────────────────

def _parse_all_items(data, iinf_ds, iinf_de):
    """Parse iinf and return dict of {item_id: item_type}.

    Pillow-heif uses v=2 with u16 item_id (non-standard).
    ISO standard uses v=2+ with u32 item_id.
    Detection: check which offset (ds+8 for u16, ds+10 for u32) contains
    a valid ASCII FourCC for item_type.
    """
    iinf_v = data[iinf_ds]
    ec_size = 4 if iinf_v >= 1 else 2
    ec_pos = iinf_ds + 4
    infe_start = ec_pos + ec_size
    item_types = {}

    def _is_valid_fourcc(b):
        """Check if 4 bytes look like a valid item type FourCC."""
        try:
            s = b.decode('ascii')
            return all(c.isalnum() or c in ' _-.!' for c in s)
        except:
            return False

    for tp, ds, de, bs, bsz in _boxes(data, infe_start, iinf_de):
        if tp == 'infe':
            v = data[ds]; f = (data[ds+1]<<16)|(data[ds+2]<<8)|data[ds+3]
            o = ds + 4  # after version+flags
            if v >= 2:
                # Detect u16 vs u32 by checking which offset has valid FourCC
                type_at_u16 = data[o+4:o+8]   # item_type if iid is u16
                type_at_u32 = data[o+6:o+10]  # item_type if iid is u32
                if _is_valid_fourcc(type_at_u16) and not _is_valid_fourcc(type_at_u32):
                    iid = struct.unpack_from('>H', data, o)[0]; o += 2
                else:
                    iid = struct.unpack_from('>I', data, o)[0]; o += 4
                o += 2  # protection_index
                itype = data[o:o+4].decode('latin-1')
                item_types[iid] = itype
    return item_types, iinf_v


def _parse_infe_item_id(raw_box):
    """Return item_id from a raw infe box, supporting Pillow's v2/u16 variant."""
    if len(raw_box) < 18 or raw_box[4:8] != b'infe':
        return None
    version = raw_box[8]
    if version < 2:
        return struct.unpack_from('>H', raw_box, 12)[0]

    def _is_valid_fourcc(raw):
        try:
            text = raw.decode('ascii')
            return len(text) == 4 and all(c.isalnum() or c in ' _-.!' for c in text)
        except Exception:
            return False

    o = 12
    type_at_u16 = raw_box[o+4:o+8]
    type_at_u32 = raw_box[o+6:o+10]
    if _is_valid_fourcc(type_at_u16) and not _is_valid_fourcc(type_at_u32):
        return struct.unpack_from('>H', raw_box, o)[0]
    return struct.unpack_from('>I', raw_box, o)[0]


def _detect_ids(data, iinf_ds, iinf_de, pitm_primary_id=None):
    """Auto-detect primary and gain map item IDs."""
    item_types, _ = _parse_all_items(data, iinf_ds, iinf_de)
    primary_id = pitm_primary_id
    if primary_id is None:
        for iid, itype in item_types.items():
            if itype == 'hvc1':
                primary_id = iid
                break
    gainmap_id = None
    for iid, itype in item_types.items():
        if iid != primary_id and itype == 'hvc1':
            gainmap_id = iid
            break
    return primary_id, gainmap_id


# ── Main patcher ───────────────────────────────────────────────────

def patch_heic_for_iso21496(path: str, gainmap_item_id: int = None,
                             primary_item_id: int = None,
                             iso_meta: dict = None,
                             *,
                             replace_primary_colr: bool = False) -> bool:
    """Patch a HEIC file for ISO 21496-1 compliance.

    Three-phase approach:
      Phase A: Compute sizes, update counts/sizes in-place in data[]
      Phase B: Adjust mdat-relative iloc offsets
      Phase C: Walk meta children in order, insert new content, rebuild file
    """
    with open(path, 'rb') as f:
        data = bytearray(f.read())

    file_size = len(data)

    # ════════════════════════════════════════════════════════════════
    # Phase 0: Parse box tree — collect ALL meta children in order
    # ════════════════════════════════════════════════════════════════

    meta_offset = meta_sz = meta_ds = meta_de = None
    mdat_sz_orig = None
    for tp, ds, de, bs, bsz in _boxes(data, 0, file_size):
        if tp == 'meta':
            meta_offset = bs; meta_sz = bsz; meta_ds = ds; meta_de = de
        elif tp == 'mdat':
            mdat_sz_orig = bsz  # capture before any modifications

    if meta_offset is None:
        raise ValueError("No meta box found")

    _, _, meta_body = _fullbox(data, meta_ds)

    # Ordered list of meta children: [(type, box_off, data_start, data_end, box_size)]
    meta_children = []
    for tp, ds, de, bs, bsz in _boxes(data, meta_body, meta_de):
        meta_children.append((tp, bs, ds, de, bsz))

    child = {}
    for tp, bs, ds, de, bsz in meta_children:
        child[tp] = {'off': bs, 'ds': ds, 'de': de, 'sz': bsz}

    for name in ['iprp', 'iinf', 'iloc']:
        if name not in child:
            raise ValueError(f"No {name} found in meta")

    has_idat = 'idat' in child

    # pitm
    pitm_primary_id = None
    if 'pitm' in child:
        pitm_v = data[child['pitm']['ds']]
        pitm_body = child['pitm']['ds'] + 4
        pitm_primary_id = struct.unpack_from('>H', data, pitm_body)[0] if pitm_v == 0 else struct.unpack_from('>I', data, pitm_body)[0]

    # iprp children (pre-compute positions BEFORE any modifications)
    ipco = ipma = None
    iprp_children = []
    for tp, ds, de, bs, bsz in _boxes(data, child['iprp']['ds'], child['iprp']['de']):
        iprp_children.append((tp, bs, ds, de, bsz))
        if tp == 'ipco':
            ipco = {'off': bs, 'ds': ds, 'de': de, 'sz': bsz}
        elif tp == 'ipma':
            ipma = {'off': bs, 'ds': ds, 'de': de, 'sz': bsz}

    if ipco is None or ipma is None:
        raise ValueError("iprp missing ipco or ipma")

    # Detect items
    if gainmap_item_id is None or primary_item_id is None:
        primary_item_id, gainmap_item_id = _detect_ids(
            data, child['iinf']['ds'], child['iinf']['de'],
            pitm_primary_id=pitm_primary_id)
        if primary_item_id is None:
            raise ValueError("Cannot detect primary item ID")
        if gainmap_item_id is None:
            raise ValueError("Cannot detect gain map item ID")

    # Check for existing auxC (golden sample approach doesn't use auxC)
    auxC_prop_idx = None
    prop_count = 0
    for tp, ds, de, bs, bsz in _boxes(data, ipco['ds'], ipco['de']):
        prop_count += 1

    item_types, iinf_v = _parse_all_items(data, child['iinf']['ds'], child['iinf']['de'])
    if any(v == 'tmap' for v in item_types.values()):
        return False  # Already patched

    new_prop_idx = prop_count + 1
    next_item_id = max(item_types.keys()) + 1
    new_primary_grid_item_id = next_item_id
    new_gainmap_grid_item_id = next_item_id + 1
    new_tmap_item_id = next_item_id + 2

    # iloc geometry — upgrade v0 to v1 for Apple ImageIO compatibility.
    # Pillow-heif writes iloc v=0 with bosz=4. Apple ImageIO requires v=1
    # with bosz=0 (no base offset) and per-entry construction_method fields.
    iloc_v_orig, iloc_f, iloc_body = _fullbox(data, child['iloc']['ds'])
    b0 = data[iloc_body]; osz = (b0 >> 4) & 0xF; lsz = b0 & 0xF
    b1 = data[iloc_body+1]; bosz_orig = (b1 >> 4) & 0xF
    isz_orig = (b1 & 0xF) if iloc_v_orig in (1, 2) else 0
    iloc_cnt_pos = iloc_body + 2
    item_id_size_orig = 2 if iloc_v_orig < 2 else 4
    iloc_cnt_size_orig = 2 if iloc_v_orig < 2 else 4

    # Parse all existing iloc entries to convert from v0 to v1 format
    old_iloc_cnt = struct.unpack_from('>H' if iloc_cnt_size_orig == 2 else '>I',
                                      data, iloc_cnt_pos)[0]

    # Read all entries in original format
    parsed_entries = []
    pos = iloc_body + 2 + iloc_cnt_size_orig
    for _ in range(old_iloc_cnt):
        if iloc_v_orig >= 2:
            iid = struct.unpack_from('>I', data, pos)[0]; pos += 4
        else:
            iid = struct.unpack_from('>H', data, pos)[0]; pos += 2
        cm = 0
        if iloc_v_orig in (1, 2):
            cm = struct.unpack_from('>H', data, pos)[0] & 0xF; pos += 2
        dri = struct.unpack_from('>H', data, pos)[0]; pos += 2
        bo = _rn(bosz_orig, data, pos)[0]; pos += bosz_orig
        ec = struct.unpack_from('>H', data, pos)[0]; pos += 2
        extents = []
        for _ in range(ec):
            if iloc_v_orig in (1, 2) and isz_orig:
                pos += isz_orig
            eo = _rn(osz, data, pos)[0]; pos += osz
            el = _rn(lsz, data, pos)[0]; pos += lsz
            extents.append((eo, el))
        parsed_entries.append({'iid': iid, 'cm': cm, 'dri': dri,
                               'bo': bo, 'extents': extents})

    # Target format: v1, osz=4, lsz=4, bosz=0, isz=0
    iloc_v = 1
    target_osz = 4
    target_lsz = 4
    target_bosz = 0
    target_isz = 0
    item_id_size = 2  # v1 with flag=0 uses u16 item_id
    iloc_cnt_size = 2

    # Compute new iloc content size
    # v1 entry: item_id(2) + cm(2) + dri(2) + bosz(0) + count(2) + ec * (osz(4) + lsz(4))
    entry_size_v1 = 2 + 2 + 2 + 0 + 2 + (target_osz + target_lsz)  # per extent
    # We'll compute actual size when building entries

    # ipma geometry
    ipma_v, ipma_f, ipma_body = _fullbox(data, ipma['ds'])
    ipma_entry_cnt = struct.unpack_from('>I', data, ipma_body)[0]
    ipma_pos = ipma_body + 4
    for _ in range(ipma_entry_cnt):
        if ipma_f & 1: ipma_pos += 4
        else: ipma_pos += 2
        ac = data[ipma_pos]; ipma_pos += 1
        for _ in range(ac):
            ipma_pos += 2 if (ipma_f & 1) else 1
    old_ipma_content_end = ipma_pos

    # Precompute ispe property indices and build ipco property type map
    ispe_indices = set()
    ipco_prop_types = {}  # {property_index: type}
    colr_sizes = {}      # {property_index: box_size} — for ICC replacement delta
    ispe_sizes = {}      # {property_index: (width, height)}
    ipco_idx = 1
    for tp_i, ds_i, de_i, bs_i, bsz_i in _boxes(data, ipco['ds'], ipco['de']):
        ipco_prop_types[ipco_idx] = tp_i
        if tp_i == 'ispe':
            ispe_indices.add(ipco_idx)
            if de_i - ds_i >= 12:
                ispe_sizes[ipco_idx] = (
                    struct.unpack_from('>I', data, ds_i + 4)[0],
                    struct.unpack_from('>I', data, ds_i + 8)[0],
                )
        if tp_i == 'colr':
            colr_sizes[ipco_idx] = bsz_i
        ipco_idx += 1

    # Pre-scan ipma entries to find primary's colr index (needed for rebuild)
    primary_colr_idx_pre = None
    scan_pos = ipma_body + 4
    for _ in range(ipma_entry_cnt):
        if ipma_f & 1:
            scan_iid = struct.unpack_from('>I', data, scan_pos)[0]; scan_pos += 4
        else:
            scan_iid = struct.unpack_from('>H', data, scan_pos)[0]; scan_pos += 2
        scan_ac = data[scan_pos]; scan_pos += 1
        if scan_iid == primary_item_id:
            for _ in range(scan_ac):
                if ipma_f & 1:
                    scan_val = struct.unpack_from('>H', data, scan_pos)[0]; scan_pos += 2
                else:
                    scan_val = data[scan_pos]; scan_pos += 1
                scan_pidx = scan_val & 0x7FFF
                if ipco_prop_types.get(scan_pidx) == 'colr':
                    primary_colr_idx_pre = scan_pidx
                    break
            break
        for _ in range(scan_ac):
            scan_pos += 2 if (ipma_f & 1) else 1

    # New properties appended to ipco: irot, PQ nclx, sRGB nclx, HDR pixi
    irot_prop_idx = prop_count + 1
    pq_nclx_prop_idx_early = prop_count + 2  # PQ nclx for tmap AND primary
    srgb_nclx_prop_idx = prop_count + 3  # after irot + PQ nclx
    hdr_pixi_prop_idx = prop_count + 4

    # Parse all ipma entries to modify gain map entry (add auxC)
    gainmap_ispe_idx = None
    primary_ispe_idx = None
    ipma_entries_list = []  # Store parsed entries for later reference
    ipma_entry_bytes = []   # List of raw entry bytes (without count header)
    orig_ipma_entry_cnt = ipma_entry_cnt  # capture before Phase A modifies data
    ipma_pos2 = ipma_body + 4
    for _ in range(orig_ipma_entry_cnt):
        if ipma_f & 1:
            iid = struct.unpack_from('>I', data, ipma_pos2)[0]; ipma_pos2 += 4
        else:
            iid = struct.unpack_from('>H', data, ipma_pos2)[0]; ipma_pos2 += 2
        ac = data[ipma_pos2]; ipma_pos2 += 1
        assocs = []
        for _ in range(ac):
            if ipma_f & 1:
                val = struct.unpack_from('>H', data, ipma_pos2)[0]; ipma_pos2 += 2
            else:
                val = data[ipma_pos2]; ipma_pos2 += 1
            assocs.append(val)
        # Store parsed entry for later reference
        ipma_entries_list.append({'item_id': iid, 'assocs': list(assocs)})
        # Track gainmap's ispe index for tmap ipma entry
        if iid == gainmap_item_id and gainmap_ispe_idx is None:
            for v in assocs:
                pidx = v & 0x7FFF
                if pidx in ispe_indices:
                    gainmap_ispe_idx = pidx
                    break
        # Track primary's ispe index for grid ipma entries
        if iid == primary_item_id and primary_ispe_idx is None:
            for v in assocs:
                pidx = v & 0x7FFF
                if pidx in ispe_indices:
                    primary_ispe_idx = pidx
                    break
        # Rebuild entry bytes
        entry = bytearray()
        if ipma_f & 1:
            entry += struct.pack('>I', iid)
        else:
            entry += struct.pack('>H', iid)
        # Add irot for primary and gainmap
        extra_assocs = 0
        if iid in (primary_item_id, gainmap_item_id):
            extra_assocs = 1  # irot
        entry_ac = ac + extra_assocs
        entry += bytes([entry_ac])
        for val in assocs:
            pidx = val & 0x7FFF
            # Make colr essential on primary (Apple ImageIO needs this for PQ detection)
            if iid == primary_item_id and pidx == primary_colr_idx_pre:
                if ipma_f & 1:
                    val = val | 0x8000
                else:
                    val = val | 0x80
            if ipma_f & 1:
                entry += struct.pack('>H', val)
            else:
                entry += bytes([val & 0xFF])
        # Append irot for primary and gainmap
        if iid in (primary_item_id, gainmap_item_id):
            irot_val = irot_prop_idx | (0x8000 if ipma_f & 1 else 0x80)
            if ipma_f & 1:
                entry += struct.pack('>H', irot_val)
            else:
                entry += bytes([irot_val & 0xFF])
        ipma_entry_bytes.append(bytes(entry))
    def _encode_ipma_entry(iid, assocs):
        entry = bytearray()
        if ipma_f & 1:
            entry += struct.pack('>I', iid)
        else:
            entry += struct.pack('>H', iid)
        entry += bytes([len(assocs)])
        for pidx, essential in assocs:
            if ipma_f & 1:
                entry += struct.pack('>H', (0x8000 if essential else 0) | pidx)
            else:
                entry += bytes([(0x80 if essential else 0) | pidx])
        return bytes(entry)

    # Find colr/pixi property indices from source image entries.
    primary_colr_idx = None
    primary_pixi_idx = None
    gainmap_pixi_idx = None
    for e in ipma_entries_list:
        if e['item_id'] == primary_item_id:
            for v in e['assocs']:
                pidx = v & 0x7FFF
                prop_type = ipco_prop_types.get(pidx)
                if prop_type == 'colr' and primary_colr_idx is None:
                    primary_colr_idx = pidx
                elif prop_type == 'pixi' and primary_pixi_idx is None:
                    primary_pixi_idx = pidx
        elif e['item_id'] == gainmap_item_id:
            for v in e['assocs']:
                pidx = v & 0x7FFF
                if ipco_prop_types.get(pidx) == 'pixi' and gainmap_pixi_idx is None:
                    gainmap_pixi_idx = pidx

    # Compute ICC profile replacement delta: source colr -> Apple linear Display P3 colr.
    # Only apply the delta if we are actually going to replace the colr box; otherwise
    # any non-zero delta would corrupt offsets/sizes.
    if replace_primary_colr and primary_colr_idx is not None and primary_colr_idx in colr_sizes:
        original_colr_sz = colr_sizes[primary_colr_idx]
        new_colr_sz = 8 + len(SWIFT_PQ_ICC_PROFILE)
        icc_colr_delta = new_colr_sz - original_colr_sz
    else:
        icc_colr_delta = 0

    # PQ nclx colr for tmap — Apple ImageIO needs PQ transfer for HDR detection.
    pq_nclx_prop_idx = prop_count + 2  # after irot at prop_count + 1

    # Add 1x1 grid wrappers for base and gain-map images. Apple ImageIO's ISO
    # gain-map writer exposes tmap over two grid-derived items, even when the
    # source is conceptually a single image.
    primary_grid_assocs = []
    if primary_colr_idx is not None:
        primary_grid_assocs.append((primary_colr_idx, True))
    if primary_ispe_idx is not None:
        primary_grid_assocs.append((primary_ispe_idx, False))
    if primary_pixi_idx is not None:
        primary_grid_assocs.append((primary_pixi_idx, False))
    primary_grid_assocs.append((irot_prop_idx, True))
    ipma_entry_bytes.append(_encode_ipma_entry(new_primary_grid_item_id, primary_grid_assocs))

    gainmap_grid_assocs = []
    if gainmap_ispe_idx is not None:
        gainmap_grid_assocs.append((gainmap_ispe_idx, False))
    if gainmap_pixi_idx is not None:
        gainmap_grid_assocs.append((gainmap_pixi_idx, False))
    gainmap_grid_assocs.append((srgb_nclx_prop_idx, True))
    gainmap_grid_assocs.append((irot_prop_idx, True))
    ipma_entry_bytes.append(_encode_ipma_entry(new_gainmap_grid_item_id, gainmap_grid_assocs))

    tmap_assocs = [(pq_nclx_prop_idx, True)]
    if primary_ispe_idx is not None:
        tmap_assocs.append((primary_ispe_idx, False))
    tmap_assocs.append((hdr_pixi_prop_idx, False))
    tmap_assocs.append((irot_prop_idx, True))
    ipma_entry_bytes.append(_encode_ipma_entry(new_tmap_item_id, tmap_assocs))

    # Construct final ipma_entries_raw with correct count
    ipma_entries_raw = struct.pack('>I', len(ipma_entry_bytes))
    for entry in ipma_entry_bytes:
        ipma_entries_raw += entry

    # iinf geometry
    iinf_ec_pos = child['iinf']['ds'] + 4
    iinf_ec_size = 4 if iinf_v >= 1 else 2
    iinf_insert_pos = child['iinf']['de']

    # Parse iref for existing auxl and cdsc (skip fullbox header!)
    has_auxl_from_gm = False
    existing_cdsc_refs = []  # [(from_id, [to_ids])]
    if 'iref' in child:
        iref_v = data[child['iref']['ds']]
        iref_body = child['iref']['ds'] + 4  # skip version(1)+flags(3)
        rpos = iref_body
        while rpos < child['iref']['de'] - 7:
            rsz = struct.unpack_from('>I', data, rpos)[0]
            if rsz < 8: break
            rtp = data[rpos+4:rpos+8].decode('latin-1', errors='replace')
            rhs = 8
            if rsz == 1:
                rsz = struct.unpack_from('>Q', data, rpos+8)[0]; rhs = 16
            re = rpos + rsz
            if re > child['iref']['de']: break
            if rtp == 'auxl':
                from_id = struct.unpack_from('>H', data, rpos+rhs)[0]
                if from_id == gainmap_item_id:
                    has_auxl_from_gm = True
            elif rtp == 'cdsc':
                fid = struct.unpack_from('>H', data, rpos+rhs)[0]
                rc = struct.unpack_from('>H', data, rpos+rhs+2)[0]
                tids = [struct.unpack_from('>H', data, rpos+rhs+4+i*2)[0] for i in range(rc)]
                existing_cdsc_refs.append((fid, tids))
            rpos = re

    # iloc count is read earlier in the iloc geometry section

    # ════════════════════════════════════════════════════════════════
    # Build new content pieces
    # ════════════════════════════════════════════════════════════════

    tmap_config = _build_tmap_config(iso_meta)

    def _grid_payload_for_ispe(prop_idx):
        width, height = ispe_sizes.get(prop_idx, (0, 0))
        return build_grid_payload(width, height)

    primary_grid_config = _grid_payload_for_ispe(primary_ispe_idx)
    gainmap_grid_config = _grid_payload_for_ispe(gainmap_ispe_idx)
    idat_payload = primary_grid_config + gainmap_grid_config + tmap_config

    def _infe_box(item_id, item_type, flags=0):
        # infe v=2 with u16 item_ID + empty item_name.
        return (
            struct.pack('>I', 21) + b'infe'
            + bytes([2, (flags >> 16) & 0xFF, (flags >> 8) & 0xFF, flags & 0xFF])
            + struct.pack('>H', item_id)
            + struct.pack('>H', 0)
            + item_type.encode('ascii')
            + b'\x00'
        )

    def _with_hidden_infe_flag(raw_box):
        raw = bytearray(raw_box)
        if len(raw) >= 12 and raw[4:8] == b'infe':
            flags = int.from_bytes(raw[9:12], 'big') | 1
            raw[9:12] = flags.to_bytes(3, 'big')
        return bytes(raw)

    new_infe = (
        _infe_box(new_primary_grid_item_id, 'grid', flags=0)
        + _infe_box(new_gainmap_grid_item_id, 'grid', flags=1)
        + _infe_box(new_tmap_item_id, 'tmap', flags=0)
    )

    def _single_dimg(from_id, to_id):
        return (
            struct.pack('>I', 14) + b'dimg'
            + struct.pack('>H', from_id)
            + struct.pack('>H', 1)
            + struct.pack('>H', to_id)
        )

    dimg_tmap_sub = (
        struct.pack('>I', 16) + b'dimg'
        + struct.pack('>H', new_tmap_item_id)
        + struct.pack('>H', 2)
        + struct.pack('>H', new_primary_grid_item_id)
        + struct.pack('>H', new_gainmap_grid_item_id)
    )
    dimg_subs = (
        _single_dimg(new_primary_grid_item_id, primary_item_id)
        + _single_dimg(new_gainmap_grid_item_id, gainmap_item_id)
        + dimg_tmap_sub
    )

    # Build replacement cdsc sub-boxes that point to primary grid + tmap.
    # Apple ImageIO requires metadata to describe both the displayed grid item and tmap.
    cdsc_replacements = {}  # {from_id: new_cdsc_bytes}
    cdsc_old_size = 0
    cdsc_new_size = 0
    for fid, tids in existing_cdsc_refs:
        old_sz = 4 + 4 + 2 + 2 + len(tids) * 2
        cdsc_old_size += old_sz
        # Remove existing derived references, then ensure primary grid + tmap are in list.
        new_tids = []
        for tid in tids:
            if tid in (new_primary_grid_item_id, new_gainmap_grid_item_id, new_tmap_item_id):
                pass  # remove old tmap reference (will re-add at end)
            else:
                new_tids.append(tid)
        if primary_item_id in new_tids:
            new_tids.remove(primary_item_id)
        if new_primary_grid_item_id not in new_tids:
            new_tids.append(new_primary_grid_item_id)
        if new_tmap_item_id not in new_tids:
            new_tids.append(new_tmap_item_id)
        new_sz = 4 + 4 + 2 + 2 + len(new_tids) * 2
        cdsc_new_size += new_sz
        cdsc_replacements[fid] = (
            struct.pack('>I', new_sz) + b'cdsc'
            + struct.pack('>H', fid)
            + struct.pack('>H', len(new_tids))
            + b''.join(struct.pack('>H', tid) for tid in new_tids)
        )
    cdsc_delta = cdsc_new_size - cdsc_old_size

    # Build grpl/altr box — Apple ImageIO requires this to find the tmap
    # as an "alternate representation" of the primary image.
    # grpl(36) = header(8) + altr(28) = header(8) + altr_header(8) + v(4) + gid(4) + n(4) + ids(8)
    new_altr_group_id = new_tmap_item_id + 1
    GRPL_BOX = (
        struct.pack('>I', 36) + b'grpl'
        + struct.pack('>I', 28) + b'altr'
        + struct.pack('>I', 0)   # version=0, flags=0
        + struct.pack('>I', new_altr_group_id)  # group_id is separate from item IDs
        + struct.pack('>I', 2)   # num_items
        + struct.pack('>I', new_tmap_item_id)  # item 1 = tmap
        + struct.pack('>I', new_primary_grid_item_id)   # item 2 = primary grid
    )
    grpl_delta = len(GRPL_BOX)

    # ════════════════════════════════════════════════════════════════
    # Phase A: Compute deltas and update sizes/counts in-place
    # ════════════════════════════════════════════════════════════════

    # Update iinf entry_count BEFORE snapshot (Phase C reads from orig_data)
    old_iinf_cnt = struct.unpack_from('>H' if iinf_ec_size == 2 else '>I',
                                      data, iinf_ec_pos)[0]
    _wn(iinf_ec_size, old_iinf_cnt + 3, data, iinf_ec_pos)  # primary grid + gainmap grid + tmap

    # Snapshot original data AFTER count update but BEFORE size field modifications
    orig_data = bytearray(data)
    orig_de_map = {tp: de for tp, bs, ds, de, bsz in meta_children}

    # PQ/sRGB nclx colr, irot, and HDR pixi injection add bytes to ipco.
    colr_pq_delta = (
        len(COLR_NCLX_PQ_BOX)
        + len(COLR_NCLX_SRGB_BOX)
        + len(IROT_BOX)
        + len(PIXI_RGB10_BOX)
    )
    # Grid configs and tmap config are stored in idat (cm=1), matching Apple output.
    if has_idat:
        idat_delta = len(idat_payload)
    else:
        idat_delta = 8 + len(idat_payload)  # new idat box: header + payload

    iinf_delta = len(new_infe)
    # iloc delta: v0->v1 conversion changes entry size, plus three derived entries
    old_entry_size_v0 = item_id_size_orig + 2 + bosz_orig + 2 + osz + lsz
    new_entry_size_v1 = 2 + 2 + 2 + 2 + 4 + 4  # id, cm, dri, ec, offset, length
    iloc_entry_delta = (new_entry_size_v1 - old_entry_size_v0) * old_iloc_cnt + (new_entry_size_v1 * 3)
    ipma_entry_delta = len(ipma_entries_raw) - (old_ipma_content_end - ipma_body)
    # Existing pillow-heif output only has cdsc references. The new tmap dimg
    # sub-box is additional content and must be included in the enclosing sizes
    # and iloc mdat offset shift.
    iref_delta = cdsc_delta + len(dimg_subs)

    total_delta = (iinf_delta + iloc_entry_delta +
                   ipma_entry_delta + iref_delta + grpl_delta + len(DINF_BOX) + colr_pq_delta + idat_delta + icc_colr_delta)

    # NOTE: iloc count is NOT updated here — it's updated in the assembly output
    # to avoid mismatch with the entry walking (which uses old_iloc_cnt)

    # Update box sizes
    struct.pack_into('>I', data, ipma['off'], ipma['sz'] + ipma_entry_delta)
    struct.pack_into('>I', data, child['iinf']['off'], child['iinf']['sz'] + iinf_delta)
    struct.pack_into('>I', data, child['iloc']['off'], child['iloc']['sz'] + iloc_entry_delta)
    if 'iref' in child:
        struct.pack_into('>I', data, child['iref']['off'], child['iref']['sz'] + iref_delta)
    struct.pack_into('>I', data, child['iprp']['off'],
                     child['iprp']['sz'] + ipma_entry_delta + colr_pq_delta)
    if 'idat' in child:
        struct.pack_into('>I', data, child['idat']['off'], child['idat']['sz'] + idat_delta)
    else:
        # No idat in source — total_delta already accounts for new idat box (8 header + 62 data)
        pass
    struct.pack_into('>I', data, meta_offset, meta_sz + total_delta)

    # Phase B removed — iloc offset adjustment is handled in Phase C
    # (base_offset from v0 is folded into extent_offset, then delta applied)

    # ════════════════════════════════════════════════════════════════
    # Phase C: Walk meta children in order, insert new content
    # ════════════════════════════════════════════════════════════════

    out = bytearray()
    # Patch ftyp to add 'tmap', 'MiHE', 'MiHB' brands (+12 bytes) — matches golden sample
    ftyp_sz = struct.unpack_from('>I', data, 0)[0]
    out += struct.pack('>I', ftyp_sz + 12)  # updated ftyp size (+3 brands × 4 bytes)
    out += data[4:ftyp_sz]              # ftyp content after size field
    out += b'tmap'                       # add tmap brand
    out += b'MiHE'                       # add MiHE brand (HEIF main)
    out += b'MiHB'                       # add MiHB brand (HEIF HDR)
    out += data[ftyp_sz:meta_offset]    # anything between ftyp and meta
    out += data[meta_offset:meta_offset + 12]  # meta header + fullbox

    prev_end = meta_body
    iloc_tmap_entry_pos = None  # tracks where tmap iloc entry starts in output

    for tp, bs, ds, de, bsz in meta_children:
        # Use original de from snapshot (Phase A modified size fields in data[])
        orig_de = orig_de_map[tp]
        # Gap between previous child and this one (in original file positions)
        out += orig_data[prev_end:bs]
        # Track output position corresponding to orig_de
        out_pos_after = len(out) + (orig_de - bs)

        if tp == 'hdlr':
            out += orig_data[bs:orig_de]  # hdlr as-is
            out += DINF_BOX     # insert dinf after hdlr
            prev_end = orig_de

        elif tp == 'pitm':
            out += orig_data[bs:ds + 4]  # box header + fullbox header
            if data[ds] == 0:
                out += struct.pack('>H', new_primary_grid_item_id)
            else:
                out += struct.pack('>I', new_primary_grid_item_id)
            prev_end = orig_de

        elif tp == 'iprp':
            # iprp: write placeholder header, fix size after content
            iprp_out_start = len(out)
            out += b'\x00\x00\x00\x00'  # placeholder size
            out += b'iprp'

            # Walk iprp children using pre-computed positions
            iprp_prev = child['iprp']['ds']
            for tp2, bs2, ds2, de2, bsz2 in iprp_children:
                out += orig_data[iprp_prev:bs2]

                if tp2 == 'ipco':
                    ipco_out_start = len(out)
                    # Write ipco box header (placeholder, fixed after children)
                    out += struct.pack('>I', 0)  # placeholder size
                    out += b'ipco'
                    # Walk ipco children, optionally replacing primary's colr with Apple ICC profile
                    prop_idx = 1
                    ipco_child_prev = ds2  # data_start (after ipco header)
                    replaced_colr = False
                    for tp3, ds3, de3, bs3, bsz3 in _boxes(orig_data, ds2, de2):
                        # Copy gap before this child
                        out += orig_data[ipco_child_prev:bs3]
                        if (replace_primary_colr
                                and primary_colr_idx is not None
                                and tp3 == 'colr'
                                and not replaced_colr
                                and prop_idx == primary_colr_idx):
                            # Replace primary's ICC profile with Apple linear Display P3.
                            out += struct.pack('>I', 8 + len(SWIFT_PQ_ICC_PROFILE))
                            out += b'colr'
                            out += SWIFT_PQ_ICC_PROFILE
                            replaced_colr = True
                        else:
                            out += orig_data[bs3:de3]
                        ipco_child_prev = de3
                        prop_idx += 1
                    out += orig_data[ipco_child_prev:de2]
                    # Append irot (rotation=0) — Apple ImageIO requires this
                    irot_prop_idx = prop_idx
                    out += IROT_BOX
                    # Append PQ nclx colr for tmap
                    pq_nclx_prop_idx_local = prop_idx + 1
                    out += COLR_NCLX_PQ_BOX
                    # Append sRGB nclx colr for gainmap (Apple ImageIO needs this)
                    srgb_nclx_prop_idx_local = prop_idx + 2
                    out += COLR_NCLX_SRGB_BOX
                    # Append RGB10 pixi for the alternate HDR representation.
                    hdr_pixi_prop_idx_local = prop_idx + 3
                    out += PIXI_RGB10_BOX
                    # Fix ipco size
                    ipco_new_sz = len(out) - ipco_out_start
                    struct.pack_into('>I', out, ipco_out_start, ipco_new_sz)
                elif tp2 == 'ipma':
                    ipma_out_start = len(out)  # track ipma position in output
                    out += orig_data[bs2:ipma_body]  # box header + fullbox header
                    out += ipma_entries_raw  # modified entries (gain map + tmap)
                    # Fix ipma size (Phase A updated it in data[], but we read from orig_data)
                    ipma_new_sz = len(out) - ipma_out_start
                    struct.pack_into('>I', out, ipma_out_start, ipma_new_sz)
                else:
                    out += orig_data[bs2:de2]

                iprp_prev = de2

            out += orig_data[iprp_prev:orig_de]
            # Fix iprp size
            iprp_new_sz = len(out) - iprp_out_start
            struct.pack_into('>I', out, iprp_out_start, iprp_new_sz)
            prev_end = orig_de

        elif tp == 'iinf':
            # iinf: write placeholder header, fix size after content
            iinf_out_start = len(out)
            out += b'\x00\x00\x00\x00'  # placeholder size
            out += b'iinf'
            iinf_entries_start = child['iinf']['ds'] + 4 + iinf_ec_size
            out += orig_data[ds:iinf_entries_start]  # fullbox header + entry count
            for tp2, ds2, de2, bs2, bsz2 in _boxes(orig_data, iinf_entries_start, iinf_insert_pos):
                raw = bytes(orig_data[bs2:de2])
                if tp2 == 'infe':
                    item_id = _parse_infe_item_id(raw)
                    if item_id in (primary_item_id, gainmap_item_id):
                        raw = _with_hidden_infe_flag(raw)
                out += raw
            out += new_infe
            out += orig_data[iinf_insert_pos:orig_de]
            # Fix iinf size
            iinf_new_sz = len(out) - iinf_out_start
            struct.pack_into('>I', out, iinf_out_start, iinf_new_sz)
            prev_end = orig_de

        elif tp == 'iloc':
            # iloc: write placeholder header, fix size after content
            iloc_out_start = len(out)
            out += b'\x00\x00\x00\x00'  # placeholder size
            out += b'iloc'
            # v1 format: version=1, flags=0, b0=osz|lsz, b1=0 (bosz=0, isz=0)
            out += bytes([1, 0, 0, 0])  # version=1, flags=0
            out += bytes([0x44, 0x00])  # b0=0x44 (osz=4, lsz=4), b1=0x00 (bosz=0, isz=0)
            out += struct.pack('>H', old_iloc_cnt + 3)

            # Convert existing entries from v0 to v1 format
            pos = iloc_body + 2 + iloc_cnt_size_orig
            for _ in range(old_iloc_cnt):
                # Read in original format
                if iloc_v_orig >= 2:
                    iid = struct.unpack_from('>I', orig_data, pos)[0]; pos += 4
                else:
                    iid = struct.unpack_from('>H', orig_data, pos)[0]; pos += 2
                cm = 0
                if iloc_v_orig in (1, 2):
                    cm = struct.unpack_from('>H', orig_data, pos)[0] & 0xF; pos += 2
                dri = struct.unpack_from('>H', orig_data, pos)[0]; pos += 2
                bo = _rn(bosz_orig, orig_data, pos)[0]; pos += bosz_orig
                ec = struct.unpack_from('>H', orig_data, pos)[0]; pos += 2
                extents = []
                for _ in range(ec):
                    if iloc_v_orig in (1, 2) and isz_orig:
                        pos += isz_orig
                    eo = _rn(osz, orig_data, pos)[0]; pos += osz
                    el = _rn(lsz, orig_data, pos)[0]; pos += lsz
                    extents.append((eo, el))

                # Write in v1 format: item_id(2) + cm(2) + dri(2) + count(2) + extents
                out += struct.pack('>H', iid)
                out += struct.pack('>H', cm)  # construction_method
                out += struct.pack('>H', dri)
                out += struct.pack('>H', ec)
                ftyp_delta = 12  # ftyp grew by 12 bytes (tmap + MiHE + MiHB brands)
                for eo, el in extents:
                    if cm == 0:
                        # base_offset is absolute file position; fold into extent_offset.
                        # In v0: data at (base_offset + extent_offset). In v1: data at (new_extent_offset).
                        # After patching, everything before mdat shifted by total_delta + ftyp_delta.
                        new_off = bo + eo + total_delta + ftyp_delta
                    else:
                        new_off = eo  # idat: no adjustment
                    out += struct.pack('>I', new_off)
                    out += struct.pack('>I', el)

            # Add new grid/tmap entries in v1 format. Payloads are stored in idat (cm=1).
            if has_idat:
                # Offset = existing idat data size (e.g. 8 bytes in source)
                existing_idat_data_size = child['idat']['sz'] - 8  # subtract idat box header
            else:
                existing_idat_data_size = 0

            for iid, offset, length in (
                (new_primary_grid_item_id, existing_idat_data_size, len(primary_grid_config)),
                (new_gainmap_grid_item_id, existing_idat_data_size + len(primary_grid_config), len(gainmap_grid_config)),
                (new_tmap_item_id, existing_idat_data_size + len(primary_grid_config) + len(gainmap_grid_config), len(tmap_config)),
            ):
                out += struct.pack('>H', iid)
                out += struct.pack('>H', 1)  # construction_method=1 (idat)
                out += struct.pack('>H', 0)  # data_reference_index
                out += struct.pack('>H', 1)  # extent_count=1
                out += struct.pack('>I', offset)
                out += struct.pack('>I', length)
            # Fix iloc size
            iloc_new_sz = len(out) - iloc_out_start
            struct.pack_into('>I', out, iloc_out_start, iloc_new_sz)
            prev_end = orig_de

        elif tp == 'iref':
            # iref: write placeholder header, fix size after content
            iref_out_start = len(out)
            out += b'\x00\x00\x00\x00'  # placeholder size
            out += b'iref'
            out += orig_data[ds:ds + 4]  # fullbox header (version+flags)
            # Walk existing sub-boxes, replacing cdsc with updated versions
            # and skipping old tmap dimg (will be replaced with grid dimg refs)
            rpos = ds + 4
            while rpos < orig_de - 7:
                rsz = struct.unpack_from('>I', orig_data, rpos)[0]
                if rsz < 8: break
                rtp = orig_data[rpos+4:rpos+8].decode('latin-1', errors='replace')
                re = rpos + rsz
                if re > orig_de: break
                if rtp == 'cdsc':
                    fid = struct.unpack_from('>H', orig_data, rpos+8)[0]
                    if fid in cdsc_replacements:
                        out += cdsc_replacements[fid]
                    else:
                        out += orig_data[rpos:re]
                else:
                    out += orig_data[rpos:re]
                rpos = re
            out += dimg_subs
            # Fix iref size
            iref_new_sz = len(out) - iref_out_start
            struct.pack_into('>I', out, iref_out_start, iref_new_sz)
            prev_end = orig_de

        elif tp == 'idat':
            # idat: append grid configs + tmap config to existing idat data
            idat_out_start = len(out)
            out += orig_data[bs:orig_de]  # idat header + existing content
            out += idat_payload
            # Fix idat size
            idat_new_sz = len(out) - idat_out_start
            struct.pack_into('>I', out, idat_out_start, idat_new_sz)
            prev_end = orig_de

        else:
            # pitm, etc. — output as-is
            out += orig_data[bs:orig_de]
            prev_end = orig_de

    # Insert new idat box with grid configs + tmap config (if no existing idat)
    if not has_idat:
        new_idat_sz = 8 + len(idat_payload)
        out += struct.pack('>I', new_idat_sz)
        out += b'idat'
        out += idat_payload

    # Insert grpl/altr box (Apple ImageIO alternate representation)
    out += GRPL_BOX

    # Gap after last child to end of meta
    # Use original meta_de (from Phase 0) since Phase A modified the meta size in data[]
    out += data[prev_end:meta_de]

    # Everything after meta — copy as-is (tmap config is in idat, not mdat)
    out += data[meta_de:]

    with open(path, 'wb') as f:
        f.write(out)

    return True


def _fullbox(d, o):
    v = d[o]; f = (d[o+1] << 16) | (d[o+2] << 8) | d[o+3]
    return v, f, o + 4


def _adjust_iloc_offsets(data, iloc_ds, total_delta):
    """Adjust iloc mdat-relative offsets (cm=0) after insertion."""
    iloc_v, iloc_f, iloc_body = _fullbox(data, iloc_ds)
    b0 = data[iloc_body]; osz = (b0 >> 4) & 0xF; lsz = b0 & 0xF
    b1 = data[iloc_body+1]; bosz = (b1 >> 4) & 0xF
    isz = (b1 & 0xF) if iloc_v in (1,2) else 0

    if iloc_v == 0:
        iloc_cnt = struct.unpack_from('>H', data, iloc_body + 2)[0]
        cnt_size = 2; item_id_size = 2; has_cm = False
    elif iloc_v == 1 and not (iloc_f & 1):
        iloc_cnt = struct.unpack_from('>H', data, iloc_body + 2)[0]
        cnt_size = 2; item_id_size = 2; has_cm = True
    else:
        iloc_cnt = struct.unpack_from('>I', data, iloc_body + 2)[0]
        cnt_size = 4; item_id_size = 4; has_cm = True

    pos = iloc_body + 2 + cnt_size

    for _ in range(iloc_cnt):
        pos += item_id_size
        if has_cm:
            cm_val = struct.unpack_from('>H', data, pos)[0]
            construction_method = cm_val & 0xF
            pos += 2  # cm+reserved is always a u16 (2 bytes)
        else:
            construction_method = 0
            pos += 2
        bo_pos = pos
        bo_val, pos = _rn(bosz, data, pos)
        ec = struct.unpack_from('>H', data, pos)[0]; pos += 2
        if construction_method == 0 and bosz > 0 and bo_val > 0:
            _wn(bosz, bo_val + total_delta, data, bo_pos)
        for _ in range(ec):
            if iloc_v in (1,2) and isz:
                pos += isz
            if osz > 0 and construction_method == 0:
                old_off_val, _ = _rn(osz, data, pos)
                if old_off_val > 0:
                    _wn(osz, old_off_val + total_delta, data, pos)
            pos += osz
            pos += lsz


# Backward-compatible alias
patch_heic_for_iso21496_simple = patch_heic_for_iso21496
