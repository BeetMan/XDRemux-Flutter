"""Xiaomi mi_tuning container decoder (AE/AF/AWB tuning, protobuf).

Record stream (after a u32 header): pairs of
  Header {1: module enum (EnumTuningDataLable_Module), 2: index, 3..8: link indices}
  Payload: for even module -> module data message (e.g. MI_TUNING_AEC.AEC_DrcConfig)
           for odd  module -> LinkKey {mode, scenario, feature0, function, sub_function, scene, filter}
Header of a LinkKey: 2 = index of the data entry of module (m-1) it selects  (verified below).
"""
import sys
from collections import defaultdict

from google.protobuf import descriptor_pb2, descriptor_pool, message_factory

from mipb import parse, records

MODULES = {}


def load_pool(*sets):
    pool = descriptor_pool.DescriptorPool()
    files = []
    for s in sets:
        fs = descriptor_pb2.FileDescriptorSet()
        fs.ParseFromString(open(s, "rb").read())
        files += list(fs.file)
    done, left = set(), files
    while left:
        nxt = []
        for f in left:
            if all(d in done for d in f.dependency):
                pool.Add(f); done.add(f.name)
            else:
                nxt.append(f)
        if len(nxt) == len(left):
            raise RuntimeError([f.name for f in nxt])
        left = nxt
    return pool


def header(b):
    m = parse(b)
    if not m or any(wt != 0 for _, wt, _ in m):
        return None
    d = {f: (v if v < 1 << 63 else v - (1 << 64)) for f, _, v in m}
    return d if 1 in d else None


def entries(path):
    data = open(path, "rb").read()
    recs = list(records(data))
    out, i = [], 3  # first three: version strings
    while i + 1 < len(recs):
        h = header(recs[i][1])
        if h is None:
            i += 1
            continue
        out.append((h, recs[i + 1][1]))
        i += 2
    return out


def linkkey(b):
    m = parse(b)
    d = {}
    for f, wt, v in m:
        if wt == 2 and f >= 2:
            d[f] = v.decode(errors="replace")
        elif wt == 2 and f == 1:
            sub = parse(v)
            d[1] = sub[0][2] if sub else None
    names = {1: "mode", 2: "scenario", 3: "feature0", 4: "function", 5: "sub_function", 6: "scene", 7: "filter"}
    return {names[k]: v for k, v in d.items()}


if __name__ == "__main__":
    ents = entries(sys.argv[1])
    cnt = defaultdict(int)
    for h, b in ents:
        cnt[h[1]] += 1
    print({k: v for k, v in sorted(cnt.items())})
    for h, b in ents[:12]:
        print(h, linkkey(b) if h[1] % 2 else len(b))


AEC_NAMES = {512: "AEC_AddedLight", 514: "AEC_Arbitration", 516: "AEC_Arrangement", 518: "AEC_AsdEnhance",
             520: "AEC_Convergence", 522: "AEC_Deflicker", 524: "AEC_DrcConfig", 526: "AEC_EVConfig",
             528: "AEC_Extend", 530: "AEC_FaceMetering", 532: "AEC_LLS", 534: "AEC_LumaCalculation",
             536: "AEC_Metering", 538: "AEC_Multicam", 540: "AEC_ReAEFace", 542: "AEC_SemanticAssist",
             544: "AEC_Startup", 546: "AEC_StatsConfig", 548: "AEC_StatsMon", 550: "AEC_Stylization",
             552: "AEC_WhiteBlack"}
KEYF = ("mode", "scenario", "feature0", "function", "sub_function", "scene", "filter")


def key_of(h):
    return tuple(h.get(k, -1) for k in range(2, 9))


def decoder(pool):
    from google.protobuf import message_factory
    def dec(mod, b):
        name = AEC_NAMES.get(mod)
        if not name:
            return None
        cls = message_factory.GetMessageClass(pool.FindMessageTypeByName("MI_TUNING_AEC." + name)) \
            if hasattr(message_factory, "GetMessageClass") else \
            message_factory.MessageFactory(pool).GetPrototype(pool.FindMessageTypeByName("MI_TUNING_AEC." + name))
        m = cls(); m.ParseFromString(b)
        return m
    return dec


def flat(m, pref="", out=None):
    """Flatten a decoded tuning message into {dotted.name: python value}."""
    out = {} if out is None else out
    for fd, v in m.ListFields():
        n = pref + fd.name
        t = fd.message_type.name if fd.message_type else None
        if fd.label == fd.LABEL_REPEATED and t:
            for i, x in enumerate(v):
                flat(x, f"{n}[{i}].", out)
        elif t in ("FloatArrayData", "IntArrayData", "Int32ArrayData", "UintArrayData", "BoolArrayData"):
            out[n] = list(v.arr)
        elif t and t.startswith("FloatArrayData_2D") or t in ("IntArrayData_2D",):
            out[n] = [list(r.arr) for r in v.arr_2d]
        elif t and hasattr(v, "value") and len(fd.message_type.fields) == 1:
            out[n] = v.value
        elif t:
            flat(v, n + ".", out)
        else:
            out[n] = list(v) if fd.label == fd.LABEL_REPEATED else v
    return out


def module_table(path, mod, pool=None):
    pool = pool or load_pool(__file__.replace("mituning.py", "../re/miaec/aec.pb"))
    dec = decoder(pool)
    return {key_of(h): flat(dec(mod, b)) for h, b in entries(path) if h[1] == mod}


def diff(a, b, width=600):
    for n in sorted(set(a) | set(b)):
        if a.get(n) != b.get(n):
            print(n, "\n   def:", str(a.get(n))[:width], "\n   new:", str(b.get(n))[:width])
