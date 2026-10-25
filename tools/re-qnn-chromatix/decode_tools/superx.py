"""Extract logical partitions from an Android (sparse) super.img without
expanding the whole image.

usage: python superx.py super.img list
       python superx.py super.img extract <partition> <out.img>
"""
import struct
import sys

SPARSE_MAGIC = 0xED26FF3A
CHUNK_RAW, CHUNK_FILL, CHUNK_DONTCARE, CHUNK_CRC = 0xCAC1, 0xCAC2, 0xCAC3, 0xCAC4


class SparseReader:
    """Random access over a sparse image (falls back to raw files)."""

    def __init__(self, path):
        self.f = open(path, "rb")
        hdr = self.f.read(28)
        magic, _maj, _min, fhs, chs, blk, nblk, nchunk, _crc = struct.unpack("<IHHHHIIII", hdr)
        self.chunks = []  # (out_off, out_len, kind, file_off_or_fill)
        if magic != SPARSE_MAGIC:
            self.f.seek(0, 2)
            self.chunks.append((0, self.f.tell(), CHUNK_RAW, 0))
            self.size = self.f.tell()
            return
        self.f.seek(fhs)
        out = 0
        for _ in range(nchunk):
            ctype, _r, csz, tsz = struct.unpack("<HHII", self.f.read(chs))
            data_off = self.f.tell()
            n = csz * blk
            if ctype == CHUNK_RAW:
                self.chunks.append((out, n, CHUNK_RAW, data_off))
            elif ctype == CHUNK_FILL:
                self.chunks.append((out, n, CHUNK_FILL, self.f.read(4)))
            elif ctype == CHUNK_DONTCARE:
                self.chunks.append((out, n, CHUNK_DONTCARE, None))
            out += n if ctype != CHUNK_CRC else 0
            self.f.seek(data_off + tsz - chs)
        self.size = out
        self.starts = [c[0] for c in self.chunks]

    def read(self, off, n):
        import bisect
        res = bytearray()
        starts = getattr(self, "starts", [0])
        i = bisect.bisect_right(starts, off) - 1
        while n > 0 and i < len(self.chunks):
            c_off, c_len, kind, extra = self.chunks[i]
            rel = off - c_off
            take = min(n, c_len - rel)
            if kind == CHUNK_RAW:
                self.f.seek(extra + rel)
                res += self.f.read(take)
            elif kind == CHUNK_FILL:
                pat = extra * ((take + rel) // 4 + 2)
                res += pat[rel % 4: rel % 4 + take]
            else:
                res += bytes(take)
            off += take
            n -= take
            i += 1
        return bytes(res)


def parse_lp(r):
    geo = r.read(4096, 4096)
    magic, struct_sz, _cs, meta_max, slots, _lbs = struct.unpack_from("<II32sIII", geo)
    assert magic == 0x616C4467, "bad LP geometry magic"
    meta = r.read(4096 + 4096 * 2, meta_max)  # primary metadata slot 0
    hmagic, maj, mnr, hsz = struct.unpack_from("<IHHI", meta)
    assert hmagic == 0x414C5030, "bad LP header magic"
    # header: magic,maj,min,header_size,header_checksum[32],tables_size,tables_checksum[32],
    # then 4 table descriptors (offset,num_entries,entry_size)
    tables_off = hsz
    descs = struct.unpack_from("<12I", meta, 4 + 2 + 2 + 4 + 32 + 4 + 32)
    part_d, ext_d = descs[0:3], descs[3:6]
    tb = meta[tables_off:]
    extents = []
    for i in range(ext_d[1]):
        nsec, ttype, tdata, tdev = struct.unpack_from("<QIQI", tb, ext_d[0] + i * ext_d[2])
        extents.append((nsec, ttype, tdata))
    parts = {}
    for i in range(part_d[1]):
        name, attrs, first, num, grp = struct.unpack_from("<36sIIII", tb, part_d[0] + i * part_d[2])
        name = name.rstrip(b"\0").decode()
        parts[name] = extents[first:first + num]
    return parts


def main():
    r = SparseReader(sys.argv[1])
    parts = parse_lp(r)
    if sys.argv[2] == "list":
        for k, v in parts.items():
            print(f"{k:24s} {sum(e[0] for e in v) * 512 / 2**20:10.1f} MiB  {len(v)} extents")
        return
    name, outp = sys.argv[3], sys.argv[4]
    with open(outp, "wb") as o:
        for nsec, ttype, tdata in parts[name]:
            if ttype == 0:  # linear
                off, left = tdata * 512, nsec * 512
                while left:
                    n = min(left, 64 << 20)
                    o.write(r.read(off, n))
                    off += n
                    left -= n
            else:
                o.write(bytes(nsec * 512))
    print("wrote", outp)


if __name__ == "__main__":
    main()
