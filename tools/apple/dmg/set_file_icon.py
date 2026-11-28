#!/usr/bin/env python3
"""Give a file a custom Finder icon.

    set_file_icon.py <file> <icon.icns>

Finder shows a custom icon for a plain file when the file carries the
kHasCustomIcon flag in its com.apple.FinderInfo extended attribute and an
'icns' resource in its com.apple.ResourceFork one. Used for the Privacy &
Security .inetloc shortcut in the DMG, which would otherwise show the
generic document icon. Run it on a volume that keeps extended attributes
(APFS), never on exFAT or SMB: the attributes are silently dropped there.
"""

import ctypes
import ctypes.util
import struct
import sys

ICNS_TYPE = b"icns"
ICNS_ID = -16455  # kCustomIconResource


def resource_fork(icns: bytes) -> bytes:
    """Wrap raw bytes into a classic single-'icns' resource fork."""
    data = struct.pack(">I", len(icns)) + icns
    type_list = struct.pack(">H", 0) + ICNS_TYPE + struct.pack(">HH", 0, 10)
    # Reference entry: id, name offset, 1 attribute byte + 3 data offset bytes, handle.
    ref_list = struct.pack(">hH", ICNS_ID, 0xFFFF) + b"\x00\x00\x00\x00" + b"\x01\x00\x00\x00"
    # Same layout Rez writes: data offset, map offset and data length are
    # 32-bit, so the fork may exceed 64 KB.
    map_length = 28 + len(type_list) + len(ref_list)
    resource_map = struct.pack(
        ">IIIHHHHHHHH",
        256,  # offset of the resource data
        256 + len(data),  # offset of the map
        len(data),
        0,  # file reference number
        map_length,
        0,  # next resource map
        0,  # file reference number
        0x0900,  # fork attributes, as written by Rez
        0,  # reserved
        28,  # type list, right after this 28-byte map header
        map_length,  # name list (empty, ends the map)
    ) + type_list + ref_list
    # 16-byte header, zero padding up to the data offset of 256, data, map.
    header = struct.pack(">IIII", 256, 256 + len(data), len(data), map_length)
    return header + bytes(256 - len(header)) + data + resource_map


def set_xattr(path: str, name: str, value: bytes) -> None:
    """Write a macOS extended attribute directly via setxattr(2) to avoid argv limits."""
    libc = ctypes.CDLL(ctypes.util.find_library("c") or "libSystem.B.dylib", use_errno=True)
    rc = libc.setxattr(
        path.encode("utf-8"),
        name.encode("utf-8"),
        value,
        ctypes.c_size_t(len(value)),
        ctypes.c_uint32(0),
        ctypes.c_int(0),
    )
    if rc != 0:
        err = ctypes.get_errno()
        raise OSError(err, f"setxattr({name}) failed on {path}: errno {err}")


def set_file_icon(path: str, icns_path: str) -> None:
    with open(icns_path, "rb") as f:
        icns = f.read()
    if icns[:4] != ICNS_TYPE:
        raise SystemExit(f"{icns_path} is not an .icns file")
    finder_info = bytearray(32)
    struct.pack_into(">H", finder_info, 8, 0x0400)  # kHasCustomIcon
    set_xattr(path, "com.apple.FinderInfo", bytes(finder_info))
    set_xattr(path, "com.apple.ResourceFork", resource_fork(icns))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(f"usage: {sys.argv[0]} <file> <icon.icns>")
    set_file_icon(sys.argv[1], sys.argv[2])
