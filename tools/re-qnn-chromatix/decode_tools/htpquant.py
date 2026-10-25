"""Per-conv quantization bookkeeping: activation scales, weight Const, bias/multiplier block."""
import sys
import numpy as np
from htpgraph import HtpGraph, decrypt_minn
from htpflow import Flow
from htpctx import ConstParser, name_table


def dec_m0(m):
    m = int(m)
    mant = ((((m >> 16) & 1) << 11) | ((m & 0x3FF) << 1) | (m >> 31)) ^ 0x800
    e = (m >> 10) & 31
    return mant, e


class Model:
    def __init__(self, path, base, lo=0x10000):
        self.x = decrypt_minn(path)
        self.B = base
        self.g = HtpGraph(self.x, lo, len(self.x))
        self.fl = Flow(self.g).run()
        cp = ConstParser(name_table(self.x, 0x74438BBC))
        self.cinfo = {}
        failed = []
        for i, (off, rid, kind, f) in enumerate(self.g.recs):
            if kind == self.g.CONST:
                c = cp.parse(f)
                if c:
                    self.cinfo[i] = c
                else:
                    failed.append(i)
        # one object table is shared by Const records and tensor records: merge both ways
        fo = self.fl.obj.o
        for k, v in fo.items():
            if v[0] == "q":
                cp.objs.setdefault(k, ("quant", v[1], v[2]))
            elif v[0] == "s":
                cp.objs.setdefault(k, ("shape", v[1], [d for d in v[2] if d != 1] or [1]))
        for i in failed:
            c = cp.parse(self.g.recs[i][3])
            if c:
                self.cinfo[i] = c
        for t in self.fl.tensors.values():
            q = t.get("q")
            if isinstance(q, tuple) and q and q[0] == "ref" and cp.objs.get(q[1], ("",))[0] == "quant":
                t["q"] = cp.objs[q[1]][1:]

    def addr(self, off, extra=None):
        if off == 0x40000004 and extra:          # second form: explicit byte offset from B
            return self.B + extra[0]
        return self.B + (off & 0xFFFF) * 64

    def const_of(self, t):
        """follow tensor -> Const (through weights_to_vtcm)."""
        g = self.g
        for _ in range(4):
            r = g.tensor_owner.get(t)
            if r is None:
                return None
            if r in self.cinfo:
                return self.cinfo[r]
            ins = g.rec_inputs.get(r)
            if not ins:
                return None
            t = ins[0]
        return None

    def convs(self):
        """unique conv ops: (node, opname, s_in, zp_in, s_out, zp_out, consts...)"""
        g, seen, res = self.g, set(), []
        for i, (off, rid, kind, f) in enumerate(g.recs):
            name = g.op_name(kind)
            if not name.startswith("Conv") or ".opt@" not in name:
                continue
            node = int(f[0])
            ins = g.rec_inputs.get(i, [])
            if not ins:
                continue
            qin = self.fl.tensors.get(ins[0], {}).get("q")
            outs = [self.fl.tensors.get(t, {}).get("q") for t in g.rec_outputs.get(i, [])]
            cs = [self.const_of(t) for t in ins[1:]]
            key = (node, name, tuple(k["off"] for k in cs if k))
            if key in seen:
                continue
            seen.add(key)
            res.append(dict(node=node, name=g.names.get(node, "?"), op=name, qin=qin, qout=outs[0] if outs else None,
                            consts=cs, rec=i))
        return res
