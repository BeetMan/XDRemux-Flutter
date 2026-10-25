"""Trace real dataflow through the HTP schedule by simulating memory.

Every op output / view tensor is decoded to its storage blocks (pool, offset);
@Spill/@Fill copy TCM segments <-> DDR ranges.  A per-2KiB "last writer" map
carries producer identity through copies so each op input resolves to the
record(s) that actually produced the data.
"""
import sys
from collections import defaultdict

from htpblocks import BlockTables, Objs, Stream, read_block_pointer
from htpgraph import NHDR, HtpGraph, decrypt_minn, signature
from htpctx import name_table

CROUTON = {4, 5, 7, 9}      # cB, CB, CH, cH
FLAT = {0, 3}               # fB, FB
GRAN = 0x800


class Flow:
    def __init__(self, g: HtpGraph):
        self.g = g
        self.obj = Objs()
        self.bt = BlockTables()
        self.tensors = {}           # index -> dict(type, q, shape, blocks)
        self.writer = {}            # (space, addr//GRAN) -> record index
        self.edges = defaultdict(set)   # record -> set(producer records)
        self.errors = []
        fmt = name_table(g.x, 0x74438BBC)          # tensor format numbering differs per model
        self.CROUTON = {i for i, n in enumerate(fmt) if n in ("cB", "CB", "CH", "cH")}
        self.FLAT = {i for i, n in enumerate(fmt) if n in ("fB", "FB")}
        self.H16 = {i for i, n in enumerate(fmt) if n in ("CH", "cH")}

    # ----------------------------------------------------------- decoding
    def _tensor(self, s, t):
        info = {"type": t}
        if t in self.CROUTON or t in self.FLAT:
            info["q"] = self.obj.interface(s)
            info["shape"] = self.obj.shape(s)
            info["alloc"], info["offs"] = getattr(self.obj, "last_alloc", None), getattr(self.obj, "last_offs", None)
            if t in self.CROUTON:
                blocks, link = self.bt.read(s)
                if link is not None and isinstance(info.get("alloc"), list):
                    import math
                    n, h, w, c = info["alloc"]
                    bw = 4 if t in self.H16 else 8
                    nb = n * math.ceil(h / 8) * math.ceil(w / bw) * math.ceil(c / 32)
                    tab = self.bt.slots.get(link[0])
                    if tab is not None:
                        blocks = tab[link[1]:link[1] + nb]
                info["blocks"], info["link"] = blocks, link
            else:
                info["blocks"] = [read_block_pointer(s)]
        return info

    def _outputs(self, i, s, n):
        outs = []
        for _ in range(n):
            t = s.next() & 0x7FFFFFFF
            outs.append(self._tensor(s, t))
        return outs

    def _addr_list(self, info):
        """Byte ranges (space, start, size) touched by a tensor."""
        bl = info.get("blocks") or []
        res = []
        if info["type"] in self.CROUTON:
            for b in bl:
                if isinstance(b, tuple) and b[0] not in ("fill",) and isinstance(b[1], int):
                    space = 1 if b[0] in ("T", 1) else b[0]
                    res.append((space, b[1], GRAN))
        elif bl and bl[0]:
            sh = info.get("shape")
            n = 1
            if isinstance(sh, list):
                for d in sh:
                    n *= d
            pool, off = bl[0]
            res.append((pool, off, max(n * 2, GRAN)))
        return res

    # ----------------------------------------------------------- simulate
    def run(self):
        g = self.g
        out_idx = g.rec_outputs
        for i, (off, rid, kind, f) in enumerate(g.recs):
            name = g.op_name(kind)
            node = int(f[0])
            k = 2 + NHDR[(kind >> 28) & 3]
            try:
                if kind == g.CONST:
                    continue
                if name in ("@Spill", "@Fill"):
                    self._dma(name, f)
                    continue
                if name.startswith("@DummyOp"):
                    n = int(name[len("@DummyOp"):])
                    s = Stream(f, 2)
                    outs = self._outputs(i, s, n)
                    for idx, info in zip(out_idx.get(i, []), outs):
                        info["rec"] = i
                        self.tensors[idx] = info
                    continue
                sig = signature(name)
                if not sig or name.startswith("@"):
                    continue
                ins = g.rec_inputs.get(i, [])
                s = Stream(f, k + len(ins))
                outs = self._outputs(i, s, 1)
                # reads
                for t in ins:
                    info = self.tensors.get(t)
                    if not info:
                        continue
                    for space, a, sz in self._addr_list(info):
                        for b in range(a // GRAN, (a + sz + GRAN - 1) // GRAN):
                            w = self.writer.get((space, b))
                            if w is not None and w != i:
                                self.edges[i].add(w)
                # writes
                for idx, info in zip(out_idx.get(i, []), outs):
                    info["rec"] = i
                    self.tensors[idx] = info
                    for space, a, sz in self._addr_list(info):
                        for b in range(a // GRAN, (a + sz + GRAN - 1) // GRAN):
                            self.writer[(space, b)] = i
            except Exception as e:      # keep going, collect diagnostics
                self.errors.append((i, hex(off), name, repr(e)))
        return self

    def _dma(self, name, f):
        # [node][hash][len][seq][ddr_pool][n][ddr_off] n x (tcm|1, size)
        ddr_pool, n, ddr = int(f[4]), int(f[5]), int(f[6])
        segs = [(int(f[7 + 2 * j]) & ~0x7FF, int(f[8 + 2 * j])) for j in range(n)]
        dspace = ("ddr", ddr_pool)
        cur = ddr
        for tcm, size in segs:
            for b in range(size // GRAN):
                tk = (1, tcm // GRAN + b)
                dk = (dspace, cur // GRAN + b)
                if name == "@Spill":
                    if tk in self.writer:
                        self.writer[dk] = self.writer[tk]
                else:
                    if dk in self.writer:
                        self.writer[tk] = self.writer[dk]
            cur += size


def node_edges(flow: Flow):
    g = flow.g
    E = defaultdict(set)
    for i, ps in flow.edges.items():
        n = int(g.recs[i][3][0])
        for p in ps:
            pn = int(g.recs[p][3][0])
            if pn != n:
                E[n].add(pn)
    return E


if __name__ == "__main__":
    g = HtpGraph(decrypt_minn(sys.argv[1]), 0x10000, 0x560000)
    fl = Flow(g).run()
    print("errors:", len(fl.errors), fl.errors[:5])
    E = node_edges(fl)
    nm = g.names
    for n in sorted(nm):
        if n <= 420 or n >= 5440:
            print(f"{n:5d} {nm[n]:34s} <- {sorted(nm.get(p, str(p)) for p in E.get(n, []))}")
