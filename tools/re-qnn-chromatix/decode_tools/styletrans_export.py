"""Export StyleTrans HTP context binaries (.minn) to float conv weights (.npz).

All facts below were read from ROM libraries (libQnnHtpPrepare.so HMX simulator, 0x2EEE578 +
core 0x2EEDCE8; converter table 0x316D9F8), not fitted to data:

Per-conv bias/multiplier block ("Fi", 512 B per 32 output channels):
  2 groups g x { 16 x (m0, m1) , 16 x (bias_int32, 0) };  output channel c = 2*k + g.
HMX W8A16 output conversion (mode 6, two HMX columns per channel):
  acc   = sum(q * act16) / 256 + bias                  (act16 raw u16 incl. zero point)
  mant  = ((m1.b16<<10 | m1[0:10]) << 11 | m0[0:10] << 1 | m0.b31) ^ 0x200000     (22 bit)
  e     = m0[10:15]
  out16 = acc * 2^(e-7) * mant / 2^30 + zpf/16,   zpf = m1[23:31]<<12 | m0[19:31]
  (zpf/16 = zp_out + 0.5 rounding), activation clamp mode = m0.b15<<2 | m0[17:19].
=> F_c = mant * 2^(e-45) per unit (q*act16); real weights W = q * F_c * s_out / s_in,
   real bias b = 256 * F_c * s_out * (bias + zp_in * sum(q_c) / 256).
Weight tiles (int8, 1024 B, off = (ci%32//4)*128 + (co%32)*4 + ci%4):
  Xwb 3x3 : [co_blk][ci_blk][tap = ky*3 + (2-kx)]  (kx reversed: found from intra-block detail test)     Xsb/Xpb 1x1 : [ci_blk][co_blk]
"""
import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
from htpquant import Model  # noqa: E402

TILE = 1024


def tile_index():
    o = np.arange(TILE)
    return (o // 128) * 4 + o % 4, (o % 128) // 4      # ci, co


CI_T, CO_T = tile_index()


def weights(x, addr, kind, cin, cout, k):
    ncb, nob = -(-cin // 32), -(-cout // 32)
    taps = k * k
    raw = np.frombuffer(x, np.int8, ncb * nob * taps * TILE, addr).reshape(-1, TILE)
    W = np.zeros((nob * 32, ncb * 32, k, k), np.int32)
    for ob in range(nob):
        for cb in range(ncb):
            for t in range(taps):
                if kind == "Xwb":
                    i = (ob * ncb + cb) * taps + t
                else:
                    i = (cb * nob + ob) * taps + t
                W[ob * 32 + CO_T, cb * 32 + CI_T, t // k, k - 1 - t % k] = raw[i]   # kx stored reversed
    return W[:cout, :cin]


def fi_block(x, addr, cout):
    nb = -(-cout // 32)
    w = np.frombuffer(x, np.uint32, nb * 128, addr).reshape(nb, 2, 2, 16, 2)   # blk, g, (mm|bb), k, pair
    order = lambda v: v.transpose(0, 2, 1).reshape(-1)                       # [blk,g,k] -> c = 32blk+2k+g
    m0 = order(w[:, :, 0, :, 0]).astype(np.int64)
    m1 = order(w[:, :, 0, :, 1]).astype(np.int64)
    bias = order(w[:, :, 1, :, 0]).view(np.int32).astype(np.int64)
    pad = order(w[:, :, 1, :, 1])
    return m0[:cout], m1[:cout], bias[:cout], pad[:cout]


def decode_mult(m0, m1):
    mant = ((((m1 >> 16) & 1) << 10 | (m1 & 0x3FF)) << 11 | (m0 & 0x3FF) << 1 | (m0 >> 31) & 1) ^ 0x200000
    e = (m0 >> 10) & 31
    F = mant.astype(np.float64) * np.exp2(e.astype(np.float64) - 45)
    zpf = ((m1 >> 23) & 0xFF) << 12 | ((m0 >> 19) & 0xFFF)
    mode = ((m0 >> 15) & 1) << 2 | ((m0 >> 17) & 3)
    return F, zpf, mode


# tail input encodings taken from the topological producer (the dataflow decoder
# mis-resolves some tail inputs; high model tail_conv_1 got its own output encoding)
UP_SRC = {"tail_up1_conv_transpose": "tail_conv_0", "tail_conv_1": "tail_up1_conv_transpose",
          "tail_up2_conv_transpose": "tail_conv_1", "tail_conv_2": "tail_up2_conv_transpose",
          "tail_conv_last": "tail_conv_2", "tail_conv_0": "fixed_conv_conv"}


def isq(q):
    return isinstance(q, tuple) and len(q) == 2 and not isinstance(q[0], str)


def name_in(c, M):
    """Input encoding for convs whose input tensor is not decoded: the network input
    (u8, scale 2/255, offset -128) widened to u16 -> (32768, 2/255/256)."""
    if c["name"] == "conv_first":
        return (32768, 3.0637256713816896e-05)
    return None


def export(path, base, out):
    M = Model(path, base)
    res, log, dups, qouts = {}, [], [], {}
    for c in M.convs():
        cs = [k for k in c["consts"] if k]
        wc = [k for k in cs if k["fmt"] in ("xwb", "xpb", "xsb")]
        bc = [k for k in cs if k["fmt"] == "fi"]
        if not wc or not bc:
            continue
        wc, bc = wc[0], bc[0]
        kind = c["op"].split("@")[1].split(".")[1]           # Xwb / Xpb / Xsb
        d = wc["dims"]
        if len(d) == 4:
            k, cin, cout = d[0], d[2], d[3]
        else:
            k, cin, cout = 1, d[0], d[1]
        if cout > 4096:                                    # packed rank flags (tail_conv_last): count channels from Fi
            cout = None
        nbias = bc["dims"][0] * bc["dims"][1] // 4 if len(bc["dims"]) == 2 else bc["dims"][0] // 4
        if cout is None:
            cout = nbias
        m0, m1, bias, pad = fi_block(M.x, M.addr(bc["off"]), max(cout, 1))
        F, zpf, mode = decode_mult(m0, m1)
        if kind == "Xpb" and k == 3:
            W = None                                       # transposed conv: handled separately
        else:
            W = weights(M.x, M.addr(wc["off"]), kind, cin, cout, k)
        qin, qout = c["qin"], c["qout"]
        if name_in(c, M):
            qin = name_in(c, M)
        if c["name"] in UP_SRC and UP_SRC[c["name"]] in qouts:
            src = qouts[UP_SRC[c["name"]]]
            if isq(qin) and qin != src:
                log.append(f"  {c['name']}: input encoding {qin} -> producer's {src}")
            qin = src
        if isq(qout):
            qouts.setdefault(c["name"], qout)
        name = c["name"]
        ent = dict(F=F, zpf=zpf, mode=mode, bias_int=bias, q=W, kind=kind, k=k)
        if W is None and isq(qin) and isq(qout):
            # fixed nearest-x2 "conv_transpose": identity tap q=126, gain = 126*F*s_out/s_in
            ent.update(s_in_up=qin[1], s_out_up=qout[1], gain=126 * F * qout[1] / qin[1])
            log.append(f"{c['name']:36s} up x2 gain={ent['gain'][:3]}")
        if isq(qin) and isq(qout) and W is not None:
            zin, sin = qin
            zout, sout = qout
            sq = W.reshape(cout, -1).sum(1)
            ent["W"] = (W * (F * sout / sin)[:, None, None, None]).astype(np.float32)
            ent["b"] = (256 * F * sout * (bias + zin * sq / 256.0)).astype(np.float32)
            ent.update(s_in=sin, zp_in=zin, s_out=sout, zp_out=zout)
            zerr = np.abs(zpf / 16.0 - 0.5 - zout).max()
            log.append(f"{name:36s} {kind} k{k} {cin:3d}->{cout:3d} mode={sorted(set(mode.tolist()))} zp_err={zerr:.3f} "
                       f"|W|max={np.abs(ent['W']).max():.4f}")
        else:
            log.append(f"{name:36s} {kind} k{k} {cin}->{cout} (incomplete: qin={qin} qout={qout})")
        if name in res:                                    # duplicated node (other output encoding)
            prev = res[name]
            if "W" in prev and "W" in ent:
                dw = np.abs(prev["W"] - ent["W"]).max() / np.abs(prev["W"]).max()
                db = np.abs(prev["b"] - ent["b"]).max() / max(np.abs(prev["b"]).max(), 1e-12)
                log.append(f"  duplicate {name}: rel dW={dw:.2e} db={db:.2e}")
                dups.append((name, dw, db))
            continue
        res[name] = ent
    flat = {}
    for n, e in res.items():
        for kk, v in e.items():
            if v is None:
                continue
            flat[f"{n}/{kk}"] = np.asarray(v)
    np.savez_compressed(out, **flat)
    return res, log


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("minn")
    ap.add_argument("--base", type=lambda s: int(s, 0), default=0x58AAD0)
    ap.add_argument("-o", "--out", required=True)
    a = ap.parse_args()
    _, log = export(a.minn, a.base, a.out)
    print("\n".join(log))


# ----------------------------------------------------------------------------------------------
# colorfix: 12-layer U-Net (544x544x6 -> 3).  Its dataflow decode is unreliable (tensor index
# desync), so consts are taken per node and encodings per node (Fi zp field is exact).
UNET_IN = {   # node -> producer whose output encoding is this node's input encoding
    "layer1_net_0": None, "layer1_net_3": "layer1_net_0",
    "layer2_net_1_net_0": "layer1_net_3", "layer2_net_1_net_3": "layer2_net_1_net_0",
    "layer3_net_1_net_0": "layer2_net_1_net_3", "layer3_net_1_net_3": "layer3_net_1_net_0",
    "layer4_net_1_net_0": "layer3_net_1_net_3", "layer4_net_1_net_3": "layer4_net_1_net_0",
    "layer5_net_1_net_0": "layer4_net_1_net_3", "layer5_net_1_net_3": "layer5_net_1_net_0",
    "layer6_upsample": "layer5_net_1_net_3", "layer6_conv_net_0": "layer6_upsample",
    "layer6_conv_net_3": "layer6_conv_net_0", "layer7_upsample": "layer6_conv_net_3",
    "layer7_conv_net_0": "layer7_upsample", "layer7_conv_net_3": "layer7_conv_net_0",
    "layer8_upsample": "layer7_conv_net_3", "layer8_conv_net_0": "layer8_upsample",
    "layer8_conv_net_3": "layer8_conv_net_0", "layer9_upsample": "layer8_conv_net_3",
    "layer9_conv_net_0": "layer9_upsample", "layer9_conv_net_3": "layer9_conv_net_0",
    "layer10": "layer9_conv_net_3", "layer11": "layer10", "layer12": "layer11",
}


def weights_xpb3(x, addr, cin, cout):
    """Xpb 3x3 (cout <= 32): per tap ceil(cin/4) x 128 B, off = (ci//4)*128 + co*4 + ci%4."""
    ng = -(-cin // 4)
    raw = np.frombuffer(x, np.int8, 9 * ng * 128, addr).reshape(9, ng * 128)
    o = np.arange(ng * 128)
    ci, co = (o // 128) * 4 + o % 4, (o % 128) // 4
    W = np.zeros((32, ng * 4, 3, 3), np.int32)
    for t in range(9):
        W[co, ci, t // 3, 2 - t % 3] = raw[t]
    return W[:cout, :cin]


def export_unet(path, base, out, lo=0x5000):
    from collections import Counter, defaultdict
    M = Model(path, base, lo=lo)
    g, fl = M.g, M.fl
    isq_ = lambda q: isinstance(q, tuple) and len(q) == 2 and not isinstance(q[0], str)
    qo = defaultdict(Counter)
    for i, (o, r, k, f) in enumerate(g.recs):
        if g.op_name(k).startswith("ConvLayer_s1"):
            for t in g.rec_outputs.get(i, []):
                q = fl.tensors.get(t, {}).get("q")
                if isq_(q):
                    qo[g.names.get(int(f[0]))][q] += 1
    consts = defaultdict(list)
    for i, c in sorted(M.cinfo.items()):
        if c["fmt"] in ("xwb", "xpb", "xsb", "fi") and c["dims"] and (c["fmt"] != "fi" or c["dims"][-1] == 128):
            consts[g.names.get(c["node"])].append(c)
    res, log, sout = {}, [], {}
    for name, prod in UNET_IN.items():
        cs = consts[name]
        ws = [c for c in cs if c["fmt"] != "fi"]
        fs = [c for c in cs if c["fmt"] == "fi"]
        parts = []
        for w in ws:
            d, fmt = w["dims"], w["fmt"]
            a = M.addr(w["off"], w["extra"])
            if len(d) == 4:
                cin, cout = d[2], d[3]
                q = weights_xpb3(M.x, a, cin, cout) if fmt == "xpb" else weights(M.x, a, "Xwb", cin, cout, 3)
            else:
                cin, cout = d
                q = weights(M.x, a, "Xpb" if fmt == "xpb" else "Xsb", cin, cout, 1)
            parts.append(q)
        q = np.concatenate(parts, 0)                     # split-cout consts / up-conv phases stacked
        cout = q.shape[0]
        m0s, m1s, bs = [], [], []
        for fc in fs:
            n = fc["dims"][0] * 128 // 128 * 32 if len(fc["dims"]) == 2 else 32
            m0, m1, b, _ = fi_block(M.x, M.addr(fc["off"], fc["extra"]), n)
            m0s.append(m0); m1s.append(m1); bs.append(b)
        m0, m1, bias = np.concatenate(m0s), np.concatenate(m1s), np.concatenate(bs)
        F, zpf, mode = decode_mult(m0, m1)
        zout = int(round(zpf[0] / 16 - 0.5))
        cand = [qq for qq, _ in qo[name].most_common() if qq[0] == zout]
        s_out = cand[0][1]
        sout[name] = (zout, s_out)
        zin, sin = (32768, 3.0637256713816896e-05) if prod is None else sout[prod]
        if name.endswith("_upsample"):
            zin, sin = sout[prod]
        if cout < len(F):                                  # Fi padded to 32 channels
            F, zpf, bias = F[:cout], zpf[:cout], bias[:cout]
        nb = len(F)
        rep = cout // nb                                   # up-conv: 4 phases share one Fi
        Fr, br = np.tile(F, rep), np.tile(bias, rep)
        sq = q.reshape(cout, -1).sum(1)
        W = (q * (Fr * s_out / sin)[:, None, None, None]).astype(np.float32)
        b = (256 * Fr * s_out * (br + zin * sq / 256.0)).astype(np.float32)
        res[name] = dict(W=W, b=b, s_in=sin, zp_in=zin, s_out=s_out, zp_out=zout, F=F, zpf=zpf, q=q, nfi=nb)
        zerr = np.abs(zpf / 16 - 0.5 - zout).max()
        log.append(f"{name:22s} W{list(W.shape)} parts={len(parts)} fi={nb} in=({zin},{sin:.4g}) out=({zout},{s_out:.4g}) "
                   f"zp_spread={zerr:.2f} cand={len(cand)} |W|max={np.abs(W).max():.3f}")
    flat = {f"{n}/{k}": np.asarray(v) for n, e in res.items() for k, v in e.items()}
    np.savez_compressed(out, **flat)
    return res, log
