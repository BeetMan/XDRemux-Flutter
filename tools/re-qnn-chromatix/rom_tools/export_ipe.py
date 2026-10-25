"""Export M9 (Feature0=7) and normal-photo IPE tables from chromatix dumps to m9/assets/ipe_tables.json.

Each module -> list of leaves {"path": [[trigger_type, start, end], ...], "data": [floats]}.
Trigger semantics are resolved in m9/tuning.py.
"""
import json
import sys

import numpy as np

from cxtree import Mem, roots, tree

D = "../re/chromatix/modes/wide_i"
SETS = {"m9": "0=0,1=1,2=1,3=7", "normal": "0=0,1=1,2=1"}
MODS = ["gamma152_ipe_v2", "cc15_ipe_v2", "cv122_ipe_v2", "tdl13_ipe_v2", "ltm21_ipe_v2", "tmc202_sw_v2"]


def leaves(path):
    m = Mem(path)
    best = []
    for o, r in roots(m):
        ls = [(p, b) for p, _, b in tree(m, r) if len(b) >= 16]
        if len(ls) > len(best):
            best = ls
    return [{"path": [[int(t), float(s), float(e)] for t, s, e in p],
             "data": np.frombuffer(b[:len(b) // 4 * 4], "<f4").astype(float).round(6).tolist()} for p, b in best]


out = {}
for tag, spec in SETS.items():
    out[tag] = {m: leaves(f"{D}/{spec}/{m}@{spec}.mem") for m in MODS}
    print(tag, {m: len(v) for m, v in out[tag].items()})
json.dump(out, open(sys.argv[1], "w"), separators=(",", ":"))
