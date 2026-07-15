#!/usr/bin/env python3
"""
Tier 3: ISOBMFF structural dump for cross-implementation comparison.

Extracts a canonical JSON representation of an output HEIC file's
box structure, suitable for comparing Rust vs Python vs Swift implementations.

The dump includes:
- ftyp (major brand, compatible brands)
- meta/hdlr (handler type)
- meta/pitm (primary item ID)
- meta/iinf (item info entries)
- meta/iref (item references)
- meta/iprp/ipco (item properties with key fields extracted)
- meta/iprp/ipma (item-property associations)
- meta/iloc (item locations, construction method + extent count only)

Normalization rules:
- ipco properties sorted by (type, index)
- ipma associations sorted by (property_index, essential)
- iinf entries sorted by (type, id)
- iref entries sorted by (type, from)
- iloc entries sorted by id
"""

import json
import struct
import sys
from pathlib import Path
from typing import Any

SCHEMA_VERSION = "xdremux-conformance-dump/1"
CRATE_VERSION = "0.1.0"


def parse_boxes(data: bytes, start: int, end: int) -> list[dict]:
    """Parse ISOBMFF boxes in the given range."""
    boxes = []
    pos = start
    while pos < end:
        if pos + 8 > end:
            break
        size = struct.unpack(">I", data[pos:pos+4])[0]
        box_type = data[pos+4:pos+8].decode("ascii", errors="replace")
        
        if size == 0:
            # Box extends to end of file
            size = end - pos
        elif size == 1:
            # 64-bit extended size
            if pos + 16 > end:
                break
            size = struct.unpack(">Q", data[pos+8:pos+16])[0]
        
        if size < 8 or pos + size > end:
            break
        
        boxes.append({
            "type": box_type,
            "start": pos,
            "size": size,
            "data_start": pos + 8,
            "data_end": pos + size,
        })
        pos += size
    
    return boxes


def parse_ftyp(data: bytes) -> dict:
    """Parse the ftyp box."""
    boxes = parse_boxes(data, 0, len(data))
    ftyp = next((b for b in boxes if b["type"] == "ftyp"), None)
    if not ftyp:
        raise ValueError("ftyp box not found")
    
    payload = data[ftyp["data_start"]:ftyp["data_end"]]
    if len(payload) < 8:
        raise ValueError("ftyp payload too short")
    
    major_brand = payload[0:4].decode("ascii", errors="replace")
    minor_version = struct.unpack(">I", payload[4:8])[0]
    
    # Compatible brands (each 4 bytes)
    brands = []
    for i in range(8, len(payload), 4):
        if i + 4 <= len(payload):
            brand = payload[i:i+4].decode("ascii", errors="replace")
            brands.append(brand)
    
    return {
        "major_brand": major_brand,
        "minor_version": minor_version,
        "compatible_brands": brands,
    }


def parse_meta(data: bytes) -> dict:
    """Parse the meta box and its children."""
    boxes = parse_boxes(data, 0, len(data))
    meta = next((b for b in boxes if b["type"] == "meta"), None)
    if not meta:
        raise ValueError("meta box not found")
    
    # meta has a 4-byte version/flags field before its children
    meta_children = parse_boxes(data, meta["data_start"] + 4, meta["data_end"])
    
    result = {}
    
    # pitm
    pitm = next((b for b in meta_children if b["type"] == "pitm"), None)
    if pitm:
        payload = data[pitm["data_start"] + 4:pitm["data_end"]]  # skip version/flags
        if len(payload) >= 2:
            result["pitm"] = struct.unpack(">H", payload[0:2])[0]
    
    # iinf
    iinf = next((b for b in meta_children if b["type"] == "iinf"), None)
    if iinf:
        payload = data[iinf["data_start"] + 4:iinf["data_end"]]  # skip version/flags
        if len(payload) >= 4:
            version = data[iinf["data_start"]]
            
            # Parse count based on version
            if version >= 1:
                entry_count = struct.unpack(">I", payload[0:4])[0]
                infe_start = iinf["data_start"] + 4 + 4
            else:
                entry_count = struct.unpack(">H", payload[0:2])[0]
                infe_start = iinf["data_start"] + 4 + 2
            
            # Parse all infe boxes in the iinf range
            infe_boxes = parse_boxes(data, infe_start, iinf["data_end"])
            
            items = []
            for infe in infe_boxes:
                if infe["type"] != "infe":
                    continue
                
                infe_payload = data[infe["data_start"] + 4:infe["data_end"]]  # skip version/flags
                
                # Parse infe (version 2 or 3)
                if len(infe_payload) >= 6:
                    # Check version (first byte of FullBox header, not in payload)
                    # For version 2: item_id is 2 bytes if type is known, else 4 bytes
                    # For version 3: item_id is 4 bytes
                    infe_version = data[infe["data_start"]]
                    
                    if infe_version >= 2 and len(infe_payload) >= 8:
                        # Check if the type at position 4 is a known type
                        type_at_u16 = infe_payload[4:8].decode("ascii", errors="replace")
                        known_types = ["hvc1", "grid", "Exif", "mime", "tmap", "jpeg"]
                        
                        if type_at_u16 in known_types:
                            # 2-byte item_id
                            item_id = struct.unpack(">H", infe_payload[0:2])[0]
                            item_protection_index = struct.unpack(">H", infe_payload[2:4])[0]
                            
                            # For mime items, read the full item_type as null-terminated string
                            # to match Rust's behavior (which reads until null byte)
                            if type_at_u16 == "mime":
                                type_start = 4
                                p = type_start
                                while p < len(infe_payload) and infe_payload[p] != 0:
                                    p += 1
                                item_type = infe_payload[type_start:p].decode("ascii", errors="replace")
                            else:
                                item_type = type_at_u16
                        else:
                            # 4-byte item_id
                            item_id = struct.unpack(">I", infe_payload[0:4])[0]
                            item_protection_index = struct.unpack(">H", infe_payload[4:6])[0]
                            item_type = infe_payload[6:10].decode("ascii", errors="replace")
                    else:
                        # Version < 2: 2-byte item_id
                        item_id = struct.unpack(">H", infe_payload[0:2])[0]
                        item_protection_index = struct.unpack(">H", infe_payload[2:4])[0]
                        item_type = infe_payload[4:8].decode("ascii", errors="replace")
                    
                    # flags field is in the FullBox header, not in payload
                    flags = 0
                    if infe_version >= 2:
                        flags = ((data[infe["data_start"] + 1] << 16) |
                                (data[infe["data_start"] + 2] << 8) |
                                data[infe["data_start"] + 3])
                    
                    items.append({
                        "id": item_id,
                        "type": item_type,
                        "hidden": (flags & 1) != 0,
                    })
            
            # Sort by (type, id)
            items.sort(key=lambda x: (x["type"], x["id"]))
            result["iinf"] = items
    
    # iref
    iref = next((b for b in meta_children if b["type"] == "iref"), None)
    if iref:
        iref_payload = data[iref["data_start"] + 4:iref["data_end"]]  # skip version/flags
        refs = []
        pos = 0
        while pos < len(iref_payload):
            if pos + 8 > len(iref_payload):
                break
            box_size = struct.unpack(">I", iref_payload[pos:pos+4])[0]
            ref_type = iref_payload[pos+4:pos+8].decode("ascii", errors="replace")
            
            if box_size < 8 or pos + box_size > len(iref_payload):
                break
            
            ref_payload = iref_payload[pos+8:pos+box_size]
            if len(ref_payload) >= 6:
                from_id = struct.unpack(">H", ref_payload[0:2])[0]
                reference_count = struct.unpack(">H", ref_payload[2:4])[0]
                to_ids = []
                for i in range(reference_count):
                    if 4 + i*2 + 2 <= len(ref_payload):
                        to_id = struct.unpack(">H", ref_payload[4+i*2:6+i*2])[0]
                        to_ids.append(to_id)
                
                refs.append({
                    "type": ref_type,
                    "from": from_id,
                    "to": to_ids,
                })
            
            pos += box_size
        
        # Sort by (type, from)
        refs.sort(key=lambda x: (x["type"], x["from"]))
        result["iref"] = refs
    
    # iprp (contains ipco and ipma)
    iprp = next((b for b in meta_children if b["type"] == "iprp"), None)
    if iprp:
        iprp_children = parse_boxes(data, iprp["data_start"], iprp["data_end"])
        
        # ipco
        ipco = next((b for b in iprp_children if b["type"] == "ipco"), None)
        if ipco:
            ipco_boxes = parse_boxes(data, ipco["data_start"], ipco["data_end"])
            props = []
            for idx, prop in enumerate(ipco_boxes, start=1):
                prop_type = prop["type"]
                prop_payload = data[prop["data_start"]:prop["data_end"]]
                
                prop_info = {
                    "index": idx,
                    "type": prop_type,
                }
                
                # Extract key fields based on property type
                if prop_type == "ispe" and len(prop_payload) >= 12:
                    # ispe has version/flags (4 bytes) + width (4) + height (4)
                    width = struct.unpack(">I", prop_payload[4:8])[0]
                    height = struct.unpack(">I", prop_payload[8:12])[0]
                    prop_info["width"] = width
                    prop_info["height"] = height
                
                elif prop_type == "colr" and len(prop_payload) >= 4:
                    # colr: version/flags (4 bytes) + colour_type (4 bytes)
                    # But Rust reads colour_type from offset 8-12 of raw (including 8-byte header)
                    # So colour_type is at offset 0-4 of payload
                    colour_type = prop_payload[0:4].decode("ascii", errors="replace")
                    prop_info["kind"] = colour_type
                    
                    if colour_type == "nclx" and len(prop_payload) >= 11:
                        # nclx: primaries (2) + transfer (2) + matrix (2) + full_range_flag (1)
                        primaries = struct.unpack(">H", prop_payload[4:6])[0]
                        transfer = struct.unpack(">H", prop_payload[6:8])[0]
                        matrix = struct.unpack(">H", prop_payload[8:10])[0]
                        full_range = (prop_payload[10] & 0x80) != 0
                        prop_info["primaries"] = primaries
                        prop_info["transfer"] = transfer
                        prop_info["matrix"] = matrix
                        prop_info["full_range"] = full_range
                
                elif prop_type == "pixi" and len(prop_payload) >= 5:
                    # pixi: version/flags (4 bytes) + num_channels (1) + bits_per_channel (N)
                    num_channels = prop_payload[4]
                    if len(prop_payload) >= 5 + num_channels:
                        bits = list(prop_payload[5:5+num_channels])
                        prop_info["num_channels"] = num_channels
                        prop_info["bits"] = bits
                    else:
                        prop_info["size"] = prop["size"]
                
                elif prop_type == "auxC" and len(prop_payload) > 4:
                    # auxC: version/flags (4 bytes) + aux_type (null-terminated string)
                    aux_type_bytes = prop_payload[4:]
                    null_pos = aux_type_bytes.find(b'\x00')
                    if null_pos >= 0:
                        aux_type = aux_type_bytes[:null_pos].decode("utf-8", errors="replace")
                    else:
                        aux_type = aux_type_bytes.decode("utf-8", errors="replace")
                    prop_info["urn"] = aux_type
                
                elif prop_type == "hvcC" and prop["size"] >= 23:
                    # hvcC: HEVCDecoderConfigurationRecord
                    # Rust reads from offsets 18, 19, 20 of the raw bytes (including 8-byte box header)
                    # So we read from offsets 10, 11, 12 of the payload
                    if len(prop_payload) >= 13:
                        chroma = prop_payload[10] & 0x03
                        luma_depth = (prop_payload[11] & 0x07) + 8
                        chroma_depth = (prop_payload[12] & 0x07) + 8
                        prop_info["chroma_format_idc"] = chroma
                        prop_info["bit_depth_luma"] = luma_depth
                        prop_info["bit_depth_chroma"] = chroma_depth
                    else:
                        prop_info["size"] = prop["size"]
                
                else:
                    # Use the full box size (including header) to match Rust
                    prop_info["size"] = prop["size"]
                
                props.append(prop_info)
            
            # Sort by (type, index)
            props.sort(key=lambda x: (x["type"], x["index"]))
            result["ipco"] = props
        
        # ipma
        ipma = next((b for b in iprp_children if b["type"] == "ipma"), None)
        if ipma:
            ipma_payload = data[ipma["data_start"] + 4:ipma["data_end"]]  # skip version/flags
            if len(ipma_payload) >= 4:
                entry_count = struct.unpack(">I", ipma_payload[0:4])[0]
                associations = []
                pos = 4
                for _ in range(entry_count):
                    if pos + 4 > len(ipma_payload):
                        break
                    item_id = struct.unpack(">H", ipma_payload[pos:pos+2])[0]
                    association_count = ipma_payload[pos+2]
                    
                    props = []
                    pos += 3
                    for _ in range(association_count):
                        if pos + 1 > len(ipma_payload):
                            break
                        # Each association is 1 byte: essential (1 bit) + property_index (7 bits)
                        byte = ipma_payload[pos]
                        essential = (byte & 0x80) != 0
                        property_index = byte & 0x7F
                        props.append({
                            "index": property_index,
                            "essential": essential,
                        })
                        pos += 1
                    
                    # Sort props by (index, essential)
                    props.sort(key=lambda x: (x["index"], x["essential"]))
                    associations.append({
                        "id": item_id,
                        "props": props,
                    })
                
                # Sort by item_id
                associations.sort(key=lambda x: x["id"])
                result["ipma"] = associations
    
    # iloc
    iloc = next((b for b in meta_children if b["type"] == "iloc"), None)
    if iloc:
        iloc_payload = data[iloc["data_start"] + 4:iloc["data_end"]]  # skip version/flags
        if len(iloc_payload) >= 6:
            # Parse iloc (version 1)
            # offset_size (4 bits) + length_size (4 bits) + base_offset_size (4 bits) + index_size (4 bits)
            sizes_byte = iloc_payload[0]
            offset_size = (sizes_byte >> 4) & 0x0F
            length_size = sizes_byte & 0x0F
            
            sizes_byte2 = iloc_payload[1]
            base_offset_size = (sizes_byte2 >> 4) & 0x0F
            index_size = sizes_byte2 & 0x0F
            
            item_count = struct.unpack(">H", iloc_payload[2:4])[0]
            
            items = []
            pos = 4
            for _ in range(item_count):
                if pos + 6 > len(iloc_payload):
                    break
                item_id = struct.unpack(">H", iloc_payload[pos:pos+2])[0]
                construction_method = struct.unpack(">H", iloc_payload[pos+2:pos+4])[0]
                data_reference_index = struct.unpack(">H", iloc_payload[pos+4:pos+6])[0]
                pos += 6
                
                # base_offset (variable size)
                if base_offset_size > 0:
                    pos += base_offset_size
                
                # extent_count
                if pos + 2 > len(iloc_payload):
                    break
                extent_count = struct.unpack(">H", iloc_payload[pos:pos+2])[0]
                pos += 2
                
                # Skip extents (we only care about count)
                for _ in range(extent_count):
                    if index_size > 0:
                        pos += index_size
                    if offset_size > 0:
                        pos += offset_size
                    if length_size > 0:
                        pos += length_size
                
                items.append({
                    "id": item_id,
                    "cm": construction_method,
                    "extents": extent_count,
                })
            
            # Sort by id
            items.sort(key=lambda x: x["id"])
            result["iloc"] = items
    
    return result


def build_json(data: bytes, input_path: Path, implementation: str) -> dict:
    """Build the canonical JSON structure for an output HEIC file."""
    ftyp = parse_ftyp(data)
    meta = parse_meta(data)
    
    return {
        "schema": SCHEMA_VERSION,
        "implementation": implementation,
        "version": CRATE_VERSION,
        "source": str(input_path),
        "ftyp": {
            "major_brand": ftyp["major_brand"],
            "compatible_brands": ftyp["compatible_brands"],
        },
        "meta": meta,
    }


def run(input_path: Path, output_path: Path, implementation: str) -> None:
    """Run the dump subcommand and write a canonical JSON document to `out`."""
    data = input_path.read_bytes()
    result = build_json(data, input_path, implementation)
    output_path.write_text(json.dumps(result, indent=2), encoding="utf-8")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <output.heic> <output.json>", file=sys.stderr)
        sys.exit(2)
    
    input_path = Path(sys.argv[1])
    output_path = Path(sys.argv[2])
    
    try:
        run(input_path, output_path, "python")
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)
