"""ISOBMFF binary patcher for ISO 21496-1 compliance.

After pillow-heif writes a HEIC file with a secondary gain map image,
this module patches the binary to add:
  1. auxC property box in ipco with urn:iso:std:iso:ts:21496:-1 URI
  2. tmap item type in iinf (replacing hvc1)
  3. ipma entry linking gain map to auxC property
  4. iref/auxl reference from gain map to primary image
  5. Adjusted iloc extent offsets for mdat shift
"""
import struct


# ── Low-level helpers ──────────────────────────────────────────────

def _u8(d, o):  return struct.unpack_from('>B', d, o)[0], o+1
def _u16(d, o): return struct.unpack_from('>H', d, o)[0], o+2
def _u32(d, o): return struct.unpack_from('>I', d, o)[0], o+4
def _u64(d, o): return struct.unpack_from('>Q', d, o)[0], o+8

def _fourcc(d, o): return d[o:o+4].decode('latin-1', errors='replace'), o+4

def _fullbox(d, o):
    v = d[o]; f = (d[o+1] << 16) | (d[o+2] << 8) | d[o+3]
    return v, f, o + 4


# ── Box iterator ───────────────────────────────────────────────────

def _boxes(d, start, end):
    """Yields (type, data_start, data_end, box_start, box_size)."""
    o = start
    while o < end - 7:
        sz, o2 = _u32(d, o)
        tp = d[o2:o2+4].decode('latin-1', errors='replace')
        o2 += 4; hs = 8
        if sz == 1: sz = struct.unpack_from('>Q', d, o2)[0]; o2 += 8; hs = 16
        elif sz == 0: sz = end - o
        be = min(o + sz, end)
        yield tp, o+hs, be, o, sz
        o = be


# ── AuxC box constant ─────────────────────────────────────────────

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


def _detect_ids(data, iinf_ds, iinf_de, iloc_ds, iloc_de, ipma_ds, ipma_de):
    """Auto-detect primary and gain map item IDs from the file structure."""
    # Parse iinf to get item types
    # Skip iinf's fullbox header (4 bytes) + entry_count (u16 for v0, u32 for v1+)
    iinf_v, iinf_f, iinf_body = _fullbox(data, iinf_ds)
    ec_size = 4 if iinf_v >= 1 else 2
    infe_start = iinf_body + ec_size
    item_types = {}
    for tp, ds, de, bs, bsz in _boxes(data, infe_start, iinf_de):
        if tp == 'infe':
            v, f, o = _fullbox(data, ds)
            if v >= 2:
                iid = struct.unpack_from('>H', data, o)[0] if v == 2 else struct.unpack_from('>I', data, o)[0]
                o += 2 if v == 2 else 4
                o += 2  # protection_index
                itype = data[o:o+4].decode('latin-1')
                item_types[iid] = itype

    # Parse ipma to find items with properties
    ipma_v, ipma_f, ipma_body = _fullbox(data, ipma_ds)
    # entry_count is always u32 per ISOBMFF spec
    ipma_entry_cnt = struct.unpack_from('>I', data, ipma_body)[0]
    ipma_item_ids = []
    pos = ipma_body + 4
    for _ in range(ipma_entry_cnt):
        if ipma_f & 1:
            iid = struct.unpack_from('>I', data, pos)[0]; pos += 4
        else:
            iid = struct.unpack_from('>H', data, pos)[0]; pos += 2
        ac = data[pos]; pos += 1
        for _ in range(ac):
            pos += 2 if (ipma_f & 1) else 1
        ipma_item_ids.append(iid)

    # Primary = first item in ipma with type hvc1
    primary_id = None
    for iid in ipma_item_ids:
        if item_types.get(iid) == 'hvc1':
            primary_id = iid
            break

    # Gain map = non-primary hvc1 or tmap in ipma
    gainmap_id = None
    for iid in ipma_item_ids:
        if iid != primary_id and item_types.get(iid) in ('hvc1', 'tmap'):
            gainmap_id = iid
            break

    return primary_id, gainmap_id


def patch_heic_for_iso21496(path: str, gainmap_item_id: int = None,
                             primary_item_id: int = None) -> bool:
    """Patch a HEIC file to add ISO 21496-1 auxC + tmap + auxl.

    If gainmap_item_id/primary_item_id are None, auto-detect from file structure.
    Returns True if patching was applied, False if already patched or skipped.
    Raises on errors.
    """
    with open(path, 'rb') as f:
        data = bytearray(f.read())

    file_size = len(data)

    # ── Phase 1: Parse box tree and find all offsets ──

    # Top-level boxes
    meta_offset = None
    for tp, ds, de, bs, bsz in _boxes(data, 0, file_size):
        if tp == 'meta':
            meta_offset = bs
            meta_ds = ds
            meta_de = de
            meta_sz = bsz

    if meta_offset is None:
        raise ValueError("No meta box found")

    # meta children
    _, _, meta_body = _fullbox(data, meta_ds)
    ipco_off = ipco_ds = ipco_de = ipco_sz = None
    ipma_off = ipma_ds = ipma_de = ipma_sz = None
    iref_off = iref_ds = iref_de = iref_sz = None
    iinf_off = iinf_ds = iinf_de = iinf_sz = None
    iloc_off = iloc_ds = iloc_de = iloc_sz = None

    for tp, ds, de, bs, bsz in _boxes(data, meta_body, meta_de):
        if tp == 'iprp':
            iprp_off = bs; iprp_ds = ds; iprp_de = de; iprp_sz = bsz
            for tp2, ds2, de2, bs2, bsz2 in _boxes(data, ds, de):
                if tp2 == 'ipco':
                    ipco_off = bs2; ipco_ds = ds2; ipco_de = de2; ipco_sz = bsz2
                elif tp2 == 'ipma':
                    ipma_off = bs2; ipma_ds = ds2; ipma_de = de2; ipma_sz = bsz2
        elif tp == 'iref':
            iref_off = bs; iref_ds = ds; iref_de = de; iref_sz = bsz
        elif tp == 'iinf':
            iinf_off = bs; iinf_ds = ds; iinf_de = de; iinf_sz = bsz
        elif tp == 'iloc':
            iloc_off = bs; iloc_ds = ds; iloc_de = de; iloc_sz = bsz

    if ipco_off is None:
        raise ValueError("No ipco found in iprp")
    if ipma_off is None:
        raise ValueError("No ipma found in iprp")
    if iinf_off is None:
        raise ValueError("No iinf found in meta")
    if iloc_off is None:
        raise ValueError("No iloc found in meta")

    # Auto-detect IDs if not provided
    if gainmap_item_id is None or primary_item_id is None:
        primary_item_id, gainmap_item_id = _detect_ids(
            data, iinf_ds, iinf_de, iloc_ds, iloc_de, ipma_ds, ipma_de)
        if primary_item_id is None:
            raise ValueError("Cannot detect primary item ID")
        if gainmap_item_id is None:
            raise ValueError("Cannot detect gain map item ID")

    # ── Phase 2: Parse ipco, check for existing auxC ──

    auxC_prop_idx = None
    prop_count = 0
    for tp, ds, de, bs, bsz in _boxes(data, ipco_ds, ipco_de):
        prop_count += 1
        if tp == 'auxC':
            # Check URI
            _, _, ao = _fullbox(data, ds)
            nul = data.find(b'\x00', ao, de)
            uri = data[ao:nul].decode('utf-8', errors='replace') if nul >= 0 else ''
            if '21496' in uri or 'iso' in uri.lower():
                auxC_prop_idx = prop_count
                break

    if auxC_prop_idx is not None:
        # Already patched
        return False

    new_prop_idx = prop_count + 1  # auxC will be the last property

    # ── Phase 3: Check gain map item type in iinf ──
    # Keep as hvc1 — libheif doesn't recognize tmap, and auxC+ipma+iref
    # provide sufficient ISO 21496-1 metadata for HDR detection.

    iinf_v3, _, iinf_body3 = _fullbox(data, iinf_ds)
    ec_size3 = 4 if iinf_v3 >= 1 else 2
    infe_start3 = iinf_body3 + ec_size3
    for tp, ds, de, bs, bsz in _boxes(data, infe_start3, iinf_de):
        if tp == 'infe':
            v, f, o = _fullbox(data, ds)
            if v >= 2:
                iid = struct.unpack_from('>H', data, o)[0] if v == 2 else struct.unpack_from('>I', data, o)[0]
                o += 2 if v == 2 else 4
                o += 2  # protection_index
                item_type = data[o:o+4].decode('latin-1')
                if iid == gainmap_item_id:
                    break

    # ── Phase 4: Parse ipma to compute new entry ──

    ipma_v, ipma_f, ipma_body = _fullbox(data, ipma_ds)
    # entry_count is always u32 per ISOBMFF spec; flags & 1 controls item_ID size
    ipma_entry_cnt = struct.unpack_from('>I', data, ipma_body)[0]

    # Find gain map entry and parse all entries
    gm_entry_idx = -1
    entries = []  # list of (item_id, assoc_count, associations_bytes)
    pos = ipma_body + 4
    for i in range(ipma_entry_cnt):
        # flags & 1: item_ID is u32, else u16
        if ipma_f & 1:
            iid = struct.unpack_from('>I', data, pos)[0]; pos += 4
        else:
            iid = struct.unpack_from('>H', data, pos)[0]; pos += 2
        ac = data[pos]; pos += 1
        assocs_start = pos
        for _ in range(ac):
            if ipma_f & 1:
                pos += 2  # 16-bit
            else:
                pos += 1  # 8-bit
        assocs_bytes = data[assocs_start:pos]
        entries.append((iid, ac, assocs_bytes))
        if iid == gainmap_item_id:
            gm_entry_idx = i

    if gm_entry_idx == -1:
        raise ValueError(f"Gain map item {gainmap_item_id} not found in ipma")

    # ── Phase 5: Build new ipma content and compute deltas ──
    #
    # ipma box layout: [size:4][type:4][version:1][flags:3][entries...]
    # ipma_off      = offset of size field
    # ipma_ds       = offset of version byte (= ipma_off + 8)
    # ipma_body     = offset of entries (= ipma_ds + 4 = ipma_off + 12)
    # ipma_sz       = total box size
    # old content   = ipma_sz - 8 bytes (from ipma_ds to ipma_off + ipma_sz)

    auxc_delta = len(AUXC_BOX)  # 40 bytes
    old_ipma_content_sz = ipma_sz - 8  # includes version+flags+entries

    need_16bit = (new_prop_idx > 127) or (ipma_f & 1)
    _new_content = bytearray()
    _new_content += bytes([ipma_v])                    # version
    _flags = bytes([(ipma_f >> 16) & 0xFF, (ipma_f >> 8) & 0xFF, ipma_f & 0xFF])
    if need_16bit and not (ipma_f & 1):
        _flags = bytes([_flags[0] | 0x01, _flags[1], _flags[2]])
    _new_content += _flags                              # flags
    _new_content += struct.pack('>I', ipma_entry_cnt)   # entry_count
    for i, (iid, ac, assocs_bytes) in enumerate(entries):
        if ipma_f & 1:
            _new_content += struct.pack('>I', iid)
        else:
            _new_content += struct.pack('>H', iid)
        extra = 1 if i == gm_entry_idx else 0
        _new_content += bytes([ac + extra])
        _new_content += assocs_bytes
        if i == gm_entry_idx:
            if need_16bit:
                _new_content += struct.pack('>H', 0x8000 | new_prop_idx)
            else:
                _new_content += bytes([0x80 | new_prop_idx])
    ipma_content_delta = len(_new_content) - old_ipma_content_sz

    if iref_off is not None:
        iref_delta = 14  # append one auxl sub-box
    else:
        iref_delta = 26  # new iref box: 8 box header + 4 fullbox + 14 auxl

    total_delta = auxc_delta + ipma_content_delta + iref_delta

    # ── Phase 6: In-place size updates (fixed-length, no offset shift) ──
    #
    # pack_into overwrites 4 bytes in-place — the bytearray length
    # does not change, so all original offsets remain valid.

    # ipco
    struct.pack_into('>I', data, ipco_off, ipco_sz + auxc_delta)
    # ipma
    struct.pack_into('>I', data, ipma_off, 8 + len(_new_content))
    # iprp
    struct.pack_into('>I', data, iprp_off,
                     iprp_sz + auxc_delta + ipma_content_delta)
    # iref
    if iref_off is not None:
        struct.pack_into('>I', data, iref_off, iref_sz + iref_delta)
    # meta
    struct.pack_into('>I', data, meta_offset, meta_sz + total_delta)

    # ── Phase 7: In-place iloc extent offset adjustment ──
    #
    # iloc construction_method=0 offsets are absolute from file start.
    # Inserting bytes inside meta (before mdat) shifts mdat forward.

    if iloc_sz > 0:
        iloc_v, iloc_f, iloc_body = _fullbox(data, iloc_ds)
        b0 = data[iloc_body]; osz = (b0 >> 4) & 0xF; lsz = b0 & 0xF
        b1 = data[iloc_body+1]; bosz = (b1 >> 4) & 0xF
        isz = (b1 & 0xF) if iloc_v in (1,2) else 0
        cnt_off = iloc_body + 2
        iloc_cnt = struct.unpack_from('>I', data, cnt_off)[0] if iloc_v >= 2 else struct.unpack_from('>H', data, cnt_off)[0]
        cnt_size = 4 if iloc_v >= 2 else 2
        pos = cnt_off + cnt_size

        def _rn(n, p):
            if n == 0: return 0, p
            if n == 2: return struct.unpack_from('>H', data, p)[0], p+2
            if n == 4: return struct.unpack_from('>I', data, p)[0], p+4
            if n == 8: return struct.unpack_from('>Q', data, p)[0], p+8
            return 0, p

        for _ in range(iloc_cnt):
            pos += 4 if iloc_v >= 2 else 2  # item_ID
            # construction_method is in upper 4 bits of the next u16
            cm_dri = struct.unpack_from('>H', data, pos)[0]
            construction_method = (cm_dri >> 12) & 0xF
            pos += 2  # construction_method + data_reference_index
            bo_pos = pos  # remember where base_offset is
            bo_val, pos = _rn(bosz, pos)
            ec = struct.unpack_from('>H', data, pos)[0]; pos += 2
            # Adjust base_offset for construction_method=0 (data in mdat)
            if construction_method == 0 and bosz > 0 and bo_val > 0:
                new_bo = bo_val + total_delta
                if bosz == 2: struct.pack_into('>H', data, bo_pos, new_bo)
                elif bosz == 4: struct.pack_into('>I', data, bo_pos, new_bo)
                elif bosz == 8: struct.pack_into('>Q', data, bo_pos, new_bo)
            for _ in range(ec):
                if iloc_v in (1,2) and isz:
                    pos += isz
                if osz > 0:
                    old_off = struct.unpack_from('>Q' if osz==8 else '>I' if osz==4 else '>H', data, pos)[0]
                    if old_off > 0:
                        new_off = old_off + total_delta
                        if osz == 2: struct.pack_into('>H', data, pos, new_off)
                        elif osz == 4: struct.pack_into('>I', data, pos, new_off)
                        elif osz == 8: struct.pack_into('>Q', data, pos, new_off)
                pos += osz
                pos += lsz

    # ── Phase 8: Section-by-section assembly ──
    #
    # All offsets below are ORIGINAL file positions (unchanged because
    # phases 6-7 used pack_into which doesn't alter bytearray length).
    # We slice from the updated `data` so size fields already carry
    # their new values.

    iprp_end = iprp_off + iprp_sz
    ipma_content_end = ipma_ds + old_ipma_content_sz  # end of ipma content (incl version+flags)

    # Prepare iref auxl / new iref box
    if iref_off is not None:
        auxl_sub = struct.pack('>I', 14) + b'auxl'
        auxl_sub += struct.pack('>H', gainmap_item_id)
        auxl_sub += struct.pack('>H', 1)
        auxl_sub += struct.pack('>H', primary_item_id)
    else:
        iref_new = bytearray()
        iref_new += struct.pack('>I', 26)
        iref_new += b'iref'
        iref_new += bytes([0, 0, 0, 0])
        iref_new += struct.pack('>I', 14) + b'auxl'
        iref_new += struct.pack('>H', gainmap_item_id)
        iref_new += struct.pack('>H', 1)
        iref_new += struct.pack('>H', primary_item_id)

    out = bytearray()

    # ipma box header (size + type) = 8 bytes, already has updated size
    ipma_hdr = data[ipma_off:ipma_off + 8]

    if iref_off is not None and iref_off >= iprp_off:
        # iref is AFTER iprp (typical pillow-heif layout)
        out += data[:ipco_de]           # ftyp + meta hdr + pitm + iinf + iprp hdr + ipco
        out += AUXC_BOX                 # insert auxC
        out += ipma_hdr                 # ipma box header (size already updated)
        out += bytes(_new_content)       # new ipma content (version+flags+entries)
        out += data[ipma_content_end:iref_de]  # between ipma and iref
        out += auxl_sub                  # insert auxl
        out += data[iref_de:]            # rest of file

    elif iref_off is not None and iref_off < iprp_off:
        # iref is BEFORE iprp
        out += data[:iref_de]            # everything up to iref content end
        out += auxl_sub                  # insert auxl inside iref
        out += data[iref_de:ipco_de]     # rest of iref + gap before ipco
        out += AUXC_BOX                  # insert auxC
        out += ipma_hdr                  # ipma box header
        out += bytes(_new_content)        # new ipma content
        out += data[ipma_content_end:]    # rest of file

    else:
        # No iref — create new one after iprp
        out += data[:ipco_de]
        out += AUXC_BOX
        out += ipma_hdr
        out += bytes(_new_content)
        out += data[ipma_content_end:iprp_end]
        out += bytes(iref_new)           # new iref box
        out += data[iprp_end:]

    with open(path, 'wb') as f:
        f.write(out)

    return True
