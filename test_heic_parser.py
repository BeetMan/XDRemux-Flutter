#!/usr/bin/env python3
"""HEIC ISO 21496-1 structure validator.

Parses a HEIC file and checks for proper auxC box, tmap item type,
iref/auxl reference, and structural consistency. Used to verify that
the ISOBMFF binary patcher produced correct output.
"""
import struct
import sys


# ── Low-level helpers ──────────────────────────────────────────────

def _u8(d, o):  return struct.unpack_from('>B', d, o)[0], o+1
def _u16(d, o): return struct.unpack_from('>H', d, o)[0], o+2
def _u32(d, o): return struct.unpack_from('>I', d, o)[0], o+4
def _u64(d, o): return struct.unpack_from('>Q', d, o)[0], o+8

def _fourcc(d, o): return d[o:o+4].decode('latin-1', errors='replace'), o+4

def _fullbox(d, o):
    v, o = _u8(d, o)
    f = (d[o] << 16) | (d[o+1] << 8) | d[o+2]
    return v, f, o+3


# ── Box iterator ───────────────────────────────────────────────────

def _boxes(d, start, end):
    o = start
    while o < end - 7:
        sz, o2 = _u32(d, o)
        tp, o2 = _fourcc(d, o2)
        hs = 8
        if sz == 1: sz, o2 = _u64(d, o2); hs = 16
        elif sz == 0: sz = end - o
        be = o + sz
        if be > end: be = end
        yield tp, o+hs, be, o, sz
        o = be


# ── Box-specific parsers ──────────────────────────────────────────

def _parse_iinf(d, start, end):
    v, f, o = _fullbox(d, start)
    if v >= 1:
        cnt, o = _u32(d, o)
    else:
        cnt, o = _u16(d, o)
    items = []
    for tp, ds, de, bs, bsz in _boxes(d, o, end):
        if tp == 'infe':
            items.append(_parse_infe(d, ds, de))
    return {'version': v, 'entry_count': cnt, 'items': items}

def _parse_infe(d, start, end):
    v, f, o = _fullbox(d, start)
    if v >= 2:
        iid = _u16(d, o)[0] if v == 2 else _u32(d, o)[0]
        o += 2 if v == 2 else 4
        o += 2  # protection_index
        itype = d[o:o+4].decode('latin-1'); o += 4
    else:
        iid = _u16(d, o)[0]; o += 2
        o += 2  # protection_index
        itype = '????'
    return {'item_id': iid, 'item_type': itype, 'version': v,
            'flags': f, 'infe_offset': start, 'type_field_offset': o}

def _parse_ipco(d, start, end):
    props = []
    idx = 1
    for tp, ds, de, bs, bsz in _boxes(d, start, end):
        info = {'index': idx, 'type': tp, 'offset': bs, 'size': bsz}
        if tp == 'auxC':
            _, _, ao = _fullbox(d, ds)
            nul = d.find(b'\x00', ao, de)
            info['uri'] = d[ao:nul].decode('utf-8', errors='replace') if nul >= 0 else d[ao:de].decode('utf-8', errors='replace')
        props.append(info)
        idx += 1
    return props

def _parse_ipma(d, start, end):
    v, f, o = _fullbox(d, start)
    # entry_count is always u32 per ISOBMFF spec
    cnt, o = _u32(d, o)
    entries = []
    for _ in range(cnt):
        # flags & 1: item_ID is u32, else u16
        if f & 1:
            iid, o = _u32(d, o)
        else:
            iid, o = _u16(d, o)
        ac, o = _u8(d, o)
        assocs = []
        for _ in range(ac):
            if f & 1:
                val, o = _u16(d, o)
                essential = bool(val & 0x8000)
                pidx = val & 0x7FFF
            else:
                val, o = _u8(d, o)
                essential = bool(val & 0x80)
                pidx = val & 0x7F
            assocs.append({'property_index': pidx, 'essential': essential})
        entries.append({'item_id': iid, 'associations': assocs})
    return {'version': v, 'flags': f, 'entries': entries}

def _parse_iref(d, start, end):
    v, f, o = _fullbox(d, start)
    refs = []
    while o < end - 7:
        rsz, o2 = _u32(d, o)
        rtp, o2 = _fourcc(d, o2)
        rhs = 8
        if rsz == 1: rsz, o2 = _u64(d, o2); rhs = 16
        re = o + rsz
        if re > end: break
        if v == 0:
            fid, o3 = _u16(d, o2)
            rc, o3 = _u16(d, o3)
            tids = [_u16(d, o3)[0] for _ in range(rc)]
        else:
            fid, o3 = _u32(d, o2)
            rc, o3 = _u16(d, o3)
            tids = [_u32(d, o3)[0] for _ in range(rc)]
        refs.append({'type': rtp, 'from_item': fid, 'to_items': tids})
        o = re
    return {'version': v, 'flags': f, 'references': refs}

def _parse_pitm(d, start, end):
    v, f, o = _fullbox(d, start)
    iid = _u16(d, o)[0] if v == 0 else _u32(d, o)[0]
    return {'primary_item_id': iid}

def _parse_iloc(d, start, end):
    v, f, o = _fullbox(d, start)
    b0 = d[o]; o += 1
    osz = (b0 >> 4) & 0xF; lsz = b0 & 0xF
    b1 = d[o]; o += 1
    bosz = (b1 >> 4) & 0xF
    isz = (b1 & 0xF) if v in (1,2) else 0
    cnt = _u32(d, o)[0] if v >= 2 else _u16(d, o)[0]
    o += 4 if v >= 2 else 2
    items = []
    def _rn(n, d, o):
        if n == 0: return 0, o
        if n == 2: return _u16(d, o)
        if n == 4: return _u32(d, o)
        if n == 8: return _u64(d, o)
        return 0, o
    for _ in range(cnt):
        iid = _u32(d, o)[0] if v >= 2 else _u16(d, o)[0]
        o += 4 if v >= 2 else 2
        cm = 0
        if v in (1, 2):
            cm = _u16(d, o)[0] & 0xF; o += 2
        dri, o = _u16(d, o)
        bo, o = _rn(bosz, d, o)
        ec, o = _u16(d, o)
        exts = []
        for _ in range(ec):
            if v in (1,2) and isz: _, o = _rn(isz, d, o)
            eo, o = _rn(osz, d, o)
            el, o = _rn(lsz, d, o)
            exts.append({'offset': eo, 'length': el})
        items.append({'item_id': iid, 'cm': cm, 'base_offset': bo, 'extents': exts})
    return {'items': items, 'offset_size': osz, 'length_size': lsz}


# ── Main validator ─────────────────────────────────────────────────

def validate(path: str) -> list[str]:
    errors = []
    with open(path, 'rb') as f:
        data = f.read()
    file_size = len(data)

    # Parse top-level boxes
    top = {}
    for tp, ds, de, bs, bsz in _boxes(data, 0, file_size):
        top[tp] = {'offset': bs, 'size': bsz, 'data_start': ds, 'data_end': de}

    if 'meta' not in top:
        return ['No meta box found']

    meta = top['meta']
    meta_d = data[meta['data_start']:meta['data_end']]
    # Skip fullbox header of meta
    meta_body_start = meta['data_start'] + 4  # version(1) + flags(3)

    # Parse meta children
    meta_children = {}
    for tp, ds, de, bs, bsz in _boxes(data, meta_body_start, meta['data_end']):
        meta_children[tp] = {'offset': bs, 'size': bsz, 'data_start': ds, 'data_end': de}

    pitm_data = None
    iinf_data = None
    ipco_data = None
    ipma_data = None
    iref_data = None
    iloc_data = None

    if 'pitm' in meta_children:
        pc = meta_children['pitm']
        pitm_data = _parse_pitm(data, pc['data_start'], pc['data_end'])

    if 'iinf' in meta_children:
        pc = meta_children['iinf']
        iinf_data = _parse_iinf(data, pc['data_start'], pc['data_end'])

    if 'iprp' in meta_children:
        iprp = meta_children['iprp']
        for tp, ds, de, bs, bsz in _boxes(data, iprp['data_start'], iprp['data_end']):
            if tp == 'ipco':
                ipco_data = _parse_ipco(data, ds, de)
            elif tp == 'ipma':
                ipma_data = _parse_ipma(data, ds, de)

    if 'iref' in meta_children:
        pc = meta_children['iref']
        iref_data = _parse_iref(data, pc['data_start'], pc['data_end'])

    if 'iloc' in meta_children:
        pc = meta_children['iloc']
        iloc_data = _parse_iloc(data, pc['data_start'], pc['data_end'])

    # ── Check 1: Find primary and gain map items ──
    primary_id = pitm_data['primary_item_id'] if pitm_data else None
    if primary_id is None:
        errors.append('No pitm (primary item) found')
        return errors

    items_by_id = {}
    if iinf_data:
        for it in iinf_data['items']:
            items_by_id[it['item_id']] = it

    # Gain map = non-primary item (prefer tmap > hvc1, prefer auxl-linked > highest ID)
    # Strategy: if there's an auxl reference, use its from_item as gain map.
    # Otherwise for 2-item files, the only non-primary item is the gain map.
    gainmap_id = None
    if iref_data:
        auxl_refs = [r for r in iref_data['references'] if r['type'] == 'auxl']
        if auxl_refs:
            gainmap_id = auxl_refs[0]['from_item']
    if gainmap_id is None:
        # For simple files: gain map is the non-primary hvc1/tmap
        candidates = [it for it in items_by_id.values()
                      if it['item_id'] != primary_id and it['item_type'] in ('hvc1', 'tmap')]
        if len(candidates) == 1:
            gainmap_id = candidates[0]['item_id']
        elif len(candidates) > 1:
            # Pick highest ID (convention: gain map is added last)
            gainmap_id = max(c['item_id'] for c in candidates)

    if gainmap_id is None:
        errors.append('No gain map item found (no non-primary hvc1/tmap)')
        return errors

    gm_item = items_by_id[gainmap_id]

    # ── Check 2: Gain map item type ──
    # Accept both hvc1 (pillow-heif native) and tmap (ISO 21496-1 standard)
    if gm_item['item_type'] not in ('hvc1', 'tmap'):
        errors.append(f'Gain map item type is "{gm_item["item_type"]}", expected hvc1 or tmap')

    # ── Check 3: auxC box in ipco ──
    auxC_uri = 'urn:iso:std:iso:ts:21496:-1'
    auxC_prop_idx = None
    if ipco_data:
        for p in ipco_data:
            if p['type'] == 'auxC':
                if p.get('uri') == auxC_uri:
                    auxC_prop_idx = p['index']
                elif 'iso' in p.get('uri', '').lower() or '21496' in p.get('uri', ''):
                    # Found an ISO auxC but maybe different URI format
                    auxC_prop_idx = p['index']
        if auxC_prop_idx is None:
            # Check for any auxC at all
            any_auxc = [p for p in ipco_data if p['type'] == 'auxC']
            if any_auxc:
                errors.append(f'auxC found but URI is "{any_auxc[0].get("uri")}", expected "{auxC_uri}"')
            else:
                errors.append('No auxC box found in ipco')
    else:
        errors.append('No ipco found')

    # ── Check 4: ipma linkage ──
    if ipma_data and auxC_prop_idx is not None:
        gm_ipma = None
        for e in ipma_data['entries']:
            if e['item_id'] == gainmap_id:
                gm_ipma = e
                break
        if gm_ipma is None:
            errors.append(f'No ipma entry for gain map item {gainmap_id}')
        else:
            linked = any(a['property_index'] == auxC_prop_idx for a in gm_ipma['associations'])
            if not linked:
                errors.append(f'Gain map item {gainmap_id} not linked to auxC property index {auxC_prop_idx}')

    # ── Check 5: iref/auxl reference ──
    if iref_data:
        auxl_refs = [r for r in iref_data['references'] if r['type'] == 'auxl']
        if not auxl_refs:
            errors.append('No auxl reference found in iref')
        else:
            gm_auxl = [r for r in auxl_refs if r['from_item'] == gainmap_id]
            if not gm_auxl:
                errors.append(f'No auxl reference from gain map {gainmap_id}')
            elif primary_id not in gm_auxl[0]['to_items']:
                errors.append(f'auxl from {gainmap_id} does not point to primary {primary_id}')
    else:
        errors.append('No iref box found')

    # ── Check 6: Box size consistency ──
    if 'iprp' in meta_children:
        iprp_info = meta_children['iprp']
        actual_iprp_size = iprp_info['size']
        # Sum children sizes + 8 for iprp box header
        child_total = 0
        for tp, ds, de, bs, bsz in _boxes(data, iprp_info['data_start'], iprp_info['data_end']):
            child_total += bsz
        if child_total + 8 != actual_iprp_size:
            errors.append(f'iprp size mismatch: declared={actual_iprp_size}, computed={child_total + 8} (children={child_total} + header=8)')

    # ── Check 7: iloc offset validity ──
    if iloc_data:
        for item in iloc_data['items']:
            if item['cm'] == 0:  # data in mdat
                for ext in item['extents']:
                    end_offset = ext['offset'] + ext['length']
                    if end_offset > file_size:
                        errors.append(f'iloc item {item["item_id"]}: extent end {end_offset} > file_size {file_size}')

    return errors


def main():
    if len(sys.argv) < 2:
        print("Usage: test_heic_parser.py <file.heic>")
        sys.exit(1)

    path = sys.argv[1]
    errors = validate(path)

    if not errors:
        print(f"PASS: {path}")
        sys.exit(0)
    else:
        print(f"FAIL: {path}")
        for e in errors:
            print(f"  - {e}")
        sys.exit(1)


if __name__ == '__main__':
    main()
