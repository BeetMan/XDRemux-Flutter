"""Recover the tensor-level dataflow graph of a decrypted QNN HTP context.

Rules (from hnnx::Op::Op(Deserz&), TypicalOpUtil::do_deserialize, deserialize_tensor
in libQnnHtpPrepare.so):
  record = u32 id | u32 kind(mode<<28 | op_type) | u64(node_id, hash)
           | extra u32 x {mode1:0, mode2:1, mode3:1, mode0:2}
           | n_in u32 input tensor indices (1-based) | outputs...
  tensor indices are handed out sequentially: Const = 1, regular op = 1 per output,
  @DummyOpN = N, scheduling ops (@Fill/@Spill/@SyncOp/@DmaCheckpoint*) = 0.
"""
import re
import sys
from collections import defaultdict

from htpctx import decrypt_minn, name_table, node_names, records

NHDR = {1: 0, 2: 1, 3: 1, 0: 2}
NOREG = {"@SyncOp", "@DmaCheckpointSet", "@DmaCheckpointWait", "@Spill", "@Fill"}


def signature(s):
    if "@" not in s:
        return None
    lst = []
    for q in [q for q in s.split("@", 1)[1].split(".") if q]:
        m = re.match(r"(\w+)\*(\d+)$", q)
        lst += [m.group(1)] * int(m.group(2)) if m else [q]
    return lst


class HtpGraph:
    def __init__(self, x: bytes, lo=0x10000, hi=None):
        self.x = x
        self.ops = name_table(x, 0x6F4390BC)
        self.names = node_names(x)
        self.recs = records(x, lo, hi or len(x))
        self.CONST = 0x10000000 | self.ops.index("Const")      # op type numbering differs per model
        self.tensor_owner = {}      # tensor index -> record index
        self.rec_inputs = {}        # record index -> [tensor indices]
        self.rec_outputs = defaultdict(list)
        self.resyncs = []
        self._build()

    def op_name(self, kind):
        t = kind & 0xFF
        return self.ops[t] if t < len(self.ops) else f"?{t}"

    def _build(self):
        # find a sync anchor: first Const directly referenced by the following vtcm op
        cnt = None
        for i, (off, rid, kind, f) in enumerate(self.recs):
            name = self.op_name(kind)
            node = int(f[0])
            sig = signature(name)
            n_in = len(sig) - 1 if sig else 0
            k = 2 + NHDR[(kind >> 28) & 3]
            if sig and not name.startswith("@"):
                if name.startswith("Concat@"):
                    n_in = 1 + (int(f[k]) & 0xFFFF)
                self.rec_inputs[i] = [int(v) for v in f[k:k + n_in]]
            if cnt is None:
                # anchor on "Const ; weights/acts_to_vtcm(input = that Const)"
                if (name.startswith("ConvLayer.opt.weights_to_vtcm") and i > 0 and self.recs[i - 1][2] == self.CONST
                        and int(self.recs[i - 1][3][0]) == node):
                    cnt = self.rec_inputs[i][0]
                    self._assign(i - 1, 1, cnt)
                else:
                    continue
            if kind == self.CONST:
                if i in self.rec_outputs:
                    continue
                cnt += 1
                # resync on "Const ; same-node weights_to_vtcm(input = this Const)"
                if i + 1 < len(self.recs):
                    _, _, k2, f2 = self.recs[i + 1]
                    n2 = self.op_name(k2)
                    if n2.startswith("ConvLayer.opt.weights_to_vtcm") and int(f2[0]) == node:
                        ref = int(f2[2 + NHDR[(k2 >> 28) & 3]])
                        if ref != cnt:
                            self.resyncs.append((i, ref - cnt))
                            cnt = ref
                self._assign(i, 1, cnt)
            elif name in NOREG or name == "Shape":
                pass
            elif name.startswith("@DummyOp"):
                n = int(name[len("@DummyOp"):])
                self._assign(i, n, cnt + 1)
                cnt += n
            else:
                cnt += 1
                self._assign(i, 1, cnt)

    def _assign(self, i, n, first):
        for j in range(n):
            self.tensor_owner[first + j] = i
            self.rec_outputs[i].append(first + j)

    def check(self):
        """Fraction of vtcm ops whose input is exactly the preceding Const's index."""
        ok = tot = 0
        for i, ins in self.rec_inputs.items():
            name = self.op_name(self.recs[i][2])
            if name.startswith("ConvLayer.opt.") and self.recs[i - 1][2] == self.CONST:
                tot += 1
                ok += self.rec_outputs.get(i - 1, [None])[0] == ins[0]
        return ok, tot

    def node_of_tensor(self, t):
        r = self.tensor_owner.get(t)
        return None if r is None else int(self.recs[r][3][0])


if __name__ == "__main__":
    g = HtpGraph(decrypt_minn(sys.argv[1]), 0x10000, 0x560000)
    print("vtcm/const consistency:", g.check(), "resyncs:", g.resyncs)


def node_graph(g: "HtpGraph"):
    """node id -> set of producer node ids (activation edges only)."""
    from collections import defaultdict
    skip_prefix = ("ConvLayer.opt.weights_to_vtcm",)
    edges = defaultdict(set)
    kinds = defaultdict(set)
    for i, ins in g.rec_inputs.items():
        off, rid, kind, f = g.recs[i]
        node = int(f[0])
        name = g.op_name(kind)
        kinds[node].add(name.split("@")[0])
        for t in ins:
            r = g.tensor_owner.get(t)
            if r is None:
                continue
            pk = g.recs[r][2]
            pn = g.op_name(pk)
            if pk == g.CONST or pn.startswith(skip_prefix):
                continue
            src = int(g.recs[r][3][0])
            if src != node:
                edges[node].add(src)
    return edges, kinds
