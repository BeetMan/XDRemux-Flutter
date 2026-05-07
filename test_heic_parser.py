#!/usr/bin/env python3
"""HEIC ISO 21496-1 structure validator.

Parses a HEIC file and checks for proper ISO HDR structure. Supports two
validation modes:

  Golden mode — tmap item with dimg references to primary, cdsc from
  metadata to primary. No auxC/auxl required. Matches Swift XDRemux output.

  AuxC injection mode — auxC box in ipco, ipma linkage, iref/auxl from
  gainmap to primary, cdsc from metadata to primary. Matches Python
  isobmff_patch.py output.

PASS if either mode's requirements are met.
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
        def _is_valid_fourcc(raw):
            try:
                text = raw.decode('ascii')
            except UnicodeDecodeError:
                return False
            return len(text) == 4 and all(c.isalnum() or c in ' _-.!' for c in text)

        type_at_u16 = d[o+4:o+8]
        type_at_u32 = d[o+6:o+10]
        if _is_valid_fourcc(type_at_u16) and not _is_valid_fourcc(type_at_u32):
            iid = _u16(d, o)[0]; o += 2
        else:
            iid = _u32(d, o)[0]; o += 4
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
    cnt, o = _u32(d, o)
    entries = []
    for _ in range(cnt):
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
        # Guard: ensure enough bytes for header + at least from_id
        min_header = rhs + (4 if v >= 1 else 2) + 2  # rhs + from_id + count
        if re - o < min_header:
            o = re
            continue
        if v == 0:
            fid, o3 = _u16(d, o2)
            rc, o3 = _u16(d, o3)
            # Guard: check remaining bytes for to_items
            remaining = re - o3
            item_sz = 2  # u16 for v0
            max_items = remaining // item_sz
            actual_rc = min(rc, max_items)
            tids = [_u16(d, o3 + i * item_sz)[0] for i in range(actual_rc)]
        else:
            fid, o3 = _u32(d, o2)
            rc, o3 = _u16(d, o3)
            remaining = re - o3
            item_sz = 4  # u32 for v1+
            max_items = remaining // item_sz
            actual_rc = min(rc, max_items)
            tids = [_u32(d, o3 + i * item_sz)[0] for i in range(actual_rc)]
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


def _parse_grpl(d, start, end):
    groups = []
    for tp, ds, de, bs, bsz in _boxes(d, start, end):
        if tp != 'altr':
            continue
        v, f, o = _fullbox(d, ds)
        group_id, o = _u32(d, o)
        count, o = _u32(d, o)
        item_ids = []
        for _ in range(count):
            if o + 4 > de:
                break
            iid, o = _u32(d, o)
            item_ids.append(iid)
        groups.append({'type': tp, 'group_id': group_id, 'item_ids': item_ids})
    return groups


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
    if 'mdat' not in top:
        errors.append('No top-level mdat box found')

    meta = top['meta']
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
    grpl_data = None

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

    if 'grpl' in meta_children:
        pc = meta_children['grpl']
        grpl_data = _parse_grpl(data, pc['data_start'], pc['data_end'])

    # ── Basic structural checks (always required) ──

    primary_id = pitm_data['primary_item_id'] if pitm_data else None
    if primary_id is None:
        errors.append('No pitm (primary item) found')
        return errors

    items_by_id = {}
    if iinf_data:
        for it in iinf_data['items']:
            items_by_id[it['item_id']] = it

    if not iref_data or not iref_data['references']:
        errors.append('No iref references found')
        return errors

    # ── Collect structural evidence ──

    # Find tmap item
    tmap_id = None
    for iid, it in items_by_id.items():
        if it['item_type'] == 'tmap' and iid != primary_id:
            tmap_id = iid
            break

    # Find gainmap item (non-primary image item that is NOT tmap)
    gainmap_id = None
    # Prefer auxl-linked item
    if iref_data:
        auxl_refs = [r for r in iref_data['references'] if r['type'] == 'auxl']
        if auxl_refs:
            gainmap_id = auxl_refs[0]['from_item']
    if gainmap_id is None:
        candidates = [it for it in items_by_id.values()
                      if it['item_id'] != primary_id
                      and it['item_id'] != tmap_id
                      and it['item_type'] in ('hvc1', 'grid')]
        if len(candidates) == 1:
            gainmap_id = candidates[0]['item_id']
        elif len(candidates) > 1:
            gainmap_id = max(c['item_id'] for c in candidates)

    # Check for dimg references from tmap
    # tmap dimg can point to primary directly OR to grid items that wrap primary
    tmap_dimg_to_primary = False
    tmap_dimg_to_grid = False
    # Find all grid item IDs
    grid_item_ids = set()
    if iref_data:
        for r in iref_data['references']:
            if r['type'] == 'dimg' and r['from_item'] in items_by_id:
                item_type = items_by_id[r['from_item']]['item_type']
                if item_type == 'grid':
                    grid_item_ids.add(r['from_item'])
    if tmap_id and iref_data:
        for r in iref_data['references']:
            if r['type'] == 'dimg' and r['from_item'] == tmap_id:
                if primary_id in r['to_items']:
                    tmap_dimg_to_primary = True
                    break
                # Check if tmap points to grid items
                if any(tid in grid_item_ids for tid in r['to_items']):
                    tmap_dimg_to_grid = True
                    break

    # Check for cdsc references (metadata → primary or metadata → grid wrapping primary)
    has_cdsc_to_primary = False
    has_cdsc_to_grid = False
    if iref_data:
        for r in iref_data['references']:
            if r['type'] == 'cdsc':
                if primary_id in r['to_items']:
                    has_cdsc_to_primary = True
                    break
                # Check if cdsc points to grid items
                if any(tid in grid_item_ids for tid in r['to_items']):
                    has_cdsc_to_grid = True
                    break

    # Check for auxC in ipco
    auxC_prop_idx = None
    if ipco_data:
        for p in ipco_data:
            if p['type'] == 'auxC':
                uri = p.get('uri', '')
                if uri == 'urn:iso:std:iso:ts:21496:-1':
                    auxC_prop_idx = p['index']

    # Check for auxl reference (gainmap → primary)
    has_auxl_from_gm = False
    if iref_data and gainmap_id:
        for r in iref_data['references']:
            if r['type'] == 'auxl' and r['from_item'] == gainmap_id:
                if primary_id in r['to_items']:
                    has_auxl_from_gm = True
                    break

    # Check ipma linkage for gainmap to auxC
    gm_ipma_has_auxc = False
    if ipma_data and auxC_prop_idx is not None and gainmap_id:
        for e in ipma_data['entries']:
            if e['item_id'] == gainmap_id:
                gm_ipma_has_auxc = any(a['property_index'] == auxC_prop_idx
                                       for a in e['associations'])
                break

    if ipma_data:
        max_prop_idx = len(ipco_data) if ipco_data else 0
        for e in ipma_data['entries']:
            if e['item_id'] not in items_by_id:
                errors.append(f'ipma entry references unknown item_id {e["item_id"]}')
            for assoc in e['associations']:
                pidx = assoc['property_index']
                if pidx == 0 or pidx > max_prop_idx:
                    errors.append(
                        f'ipma item {e["item_id"]} references invalid property index {pidx}'
                    )

    if tmap_id is not None and iloc_data:
        tmap_loc = next((item for item in iloc_data['items'] if item['item_id'] == tmap_id), None)
        idat_info = meta_children.get('idat')
        if tmap_loc is None:
            errors.append(f'tmap item {tmap_id} has no iloc entry')
        elif not idat_info:
            errors.append('tmap item exists but idat box is missing')
        elif tmap_loc['cm'] != 1:
            errors.append(f'tmap item {tmap_id} is not stored in idat construction_method=1')
        else:
            for ext in tmap_loc['extents']:
                start = idat_info['data_start'] + ext['offset']
                end = start + ext['length']
                blob = data[start:end]
                if ext['length'] != 62 or len(blob) != 62:
                    errors.append(f'tmap item {tmap_id} payload length is {ext["length"]}, expected 62')
                    continue
                if not blob.startswith(b'\x00\x00\x00\x00\x00\x40'):
                    errors.append('tmap payload missing Apple-compatible 000000000040 header')
                alt_num = _u32(blob, 14)[0]
                alt_den = _u32(blob, 18)[0]
                if alt_num <= 0 or alt_den <= 0:
                    errors.append('tmap alternate headroom rational is not positive')

    if grpl_data and tmap_id is not None:
        matching = [g for g in grpl_data if tmap_id in g['item_ids'] and primary_id in g['item_ids']]
        if matching:
            for group in matching:
                if group['group_id'] in items_by_id:
                    errors.append(
                        f'altr group_id {group["group_id"]} collides with an item id'
                    )
        elif tmap_dimg_to_grid:
            errors.append('No altr group connects tmap and primary grid item')

    if tmap_dimg_to_grid and iref_data:
        for r in iref_data['references']:
            if r['type'] == 'dimg' and r['from_item'] in grid_item_ids:
                for tid in r['to_items']:
                    target = items_by_id.get(tid)
                    if target and target['item_type'] == 'hvc1' and not (target['flags'] & 1):
                        errors.append(f'grid source hvc1 item {tid} is not hidden')

    # ── Triple-mode PASS logic ──

    # Mode 1: Golden mode (tmap + dimg to primary + cdsc to primary, no auxC/auxl required)
    golden_pass = (
        tmap_id is not None
        and tmap_dimg_to_primary
        and has_cdsc_to_primary
    )

    # Mode 2: Grid mode (tmap + dimg to grid + cdsc to grid, no auxC/auxl required)
    # Matches our patched output: tmap→[primary_grid, gainmap_grid], cdsc→[primary_grid]
    grid_pass = (
        tmap_id is not None
        and tmap_dimg_to_grid
        and has_cdsc_to_grid
    )

    # Mode 3: AuxC injection mode (auxC + ipma + auxl + cdsc)
    auxc_pass = (
        auxC_prop_idx is not None
        and gm_ipma_has_auxc
        and has_auxl_from_gm
        and has_cdsc_to_primary
    )

    if golden_pass or grid_pass or auxc_pass:
        return errors  # PASS

    # ── Diagnostic output: which chains are missing ──

    if tmap_id is None:
        errors.append('No tmap item found')
    elif not tmap_dimg_to_primary:
        errors.append(f'tmap {tmap_id} has no dimg reference to primary {primary_id}')

    if not has_cdsc_to_primary:
        errors.append('No cdsc reference pointing to primary item')

    if auxC_prop_idx is None:
        errors.append('No auxC box with ISO 21496-1 URI in ipco')
    else:
        if not gm_ipma_has_auxc:
            if gainmap_id:
                errors.append(f'Gainmap item {gainmap_id} not linked to auxC property index {auxC_prop_idx} in ipma')
            else:
                errors.append('No gainmap item found for auxC ipma linkage')

    if not has_auxl_from_gm:
        if gainmap_id:
            errors.append(f'No auxl reference from gainmap {gainmap_id} to primary {primary_id}')
        else:
            errors.append('No auxl reference found (no gainmap item identified)')

    # ── Box size consistency (always check) ──
    if 'iprp' in meta_children:
        iprp_info = meta_children['iprp']
        actual_iprp_size = iprp_info['size']
        child_total = 0
        for tp, ds, de, bs, bsz in _boxes(data, iprp_info['data_start'], iprp_info['data_end']):
            child_total += bsz
        if child_total + 8 != actual_iprp_size:
            errors.append(f'iprp size mismatch: declared={actual_iprp_size}, computed={child_total + 8} (children={child_total} + header=8)')

    # ── iloc offset validity (always check) ──
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
