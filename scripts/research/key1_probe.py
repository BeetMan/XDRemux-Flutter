#!/usr/bin/env python3
"""key1 (Photographic Styles) extraction and structure analysis.

Finds embedded bplists in a HEIC by exact-length trailer detection, pulls the
51840-byte key1 blob, and reports its structure. See
docs/research/key1-reverse-engineering.md for what this established.
"""
import plistlib, struct, numpy as np, sys

def find_bplists(d):
    out=[]; i=0
    while True:
        j=d.find(b'bplist00', i)
        if j<0: break
        out.append(j); i=j+1
    return out

def bplist_len(d, start):
    """bplist trailer is the last 32 bytes: offsetIntSize, objectRefSize,
    numObjects, topObject, offsetTableOffset. Exact-length constraint:
    offsetTableOffset + numObjects*offsetIntSize + 32 == length."""
    limit = min(len(d), start+200000)
    for end in range(start+32, limit):
        tr = d[end-32:end]
        if tr[6] not in (1,2,4,8) or tr[7] not in (1,2,4,8):
            continue
        numObjects = int.from_bytes(tr[8:16],'big')
        topObject   = int.from_bytes(tr[16:24],'big')
        oto         = int.from_bytes(tr[24:32],'big')
        if not (0 < numObjects < 200000 and topObject < numObjects):
            continue
        if oto + numObjects*tr[6] + 32 == end - start:
            return end - start
    return None

def load_plists(d):
    res=[]
    for s in find_bplists(d):
        n = bplist_len(d, s)
        if not n: continue
        try: res.append(plistlib.loads(d[s:s+n]))
        except Exception: pass
    return res

if __name__ == '__main__':
    d = open(sys.argv[1],'rb').read()
    for o in load_plists(d):
        if isinstance(o, dict) and isinstance(o.get('1'), bytes) and len(o['1'])==51840:
            k1 = np.frombuffer(o['1'], dtype='<f2').astype(np.float32)
            print(f"key1 FP16 个数 {len(k1)}  min={k1.min():.4f} max={k1.max():.4f} mean={k1.mean():.5f} std={k1.std():.5f}")
            print(f"NaN={np.isnan(k1).sum()} Inf={np.isinf(k1).sum()}")
            arr = k1.reshape(12,9,8,10,3)
            print("\n=== 12x9x8x10x3 reshape 成功 ===")
            print("各轴切片均值的离散度（越大越可能携带信息）:")
            for ax in range(5):
                others = tuple(i for i in range(5) if i!=ax)
                m = arr.mean(axis=others)
                print(f"  axis{ax} ({arr.shape[ax]} 维): 切片均值 std={m.std():.6f}  [{', '.join(f'{v:+.3f}' for v in m.ravel()[:6])}]")
            print("\n=== 最后一维是否 RGB 三通道 ===")
            A,B,C = arr[...,0], arr[...,1], arr[...,2]
            print(f"  corr(A,B)={np.corrcoef(A.ravel(),B.ravel())[0,1]:+.4f}  corr(A,C)={np.corrcoef(A.ravel(),C.ravel())[0,1]:+.4f}  corr(B,C)={np.corrcoef(B.ravel(),C.ravel())[0,1]:+.4f}")
            print(f"  均值 A={A.mean():+.5f} B={B.mean():+.5f} C={C.mean():+.5f}")
            print("\n=== axis0 (12 维) 的逐层统计 ===")
            for i in range(12):
                sl=arr[i]
                print(f"  [{i:2d}] mean={sl.mean():+.6f} std={sl.std():.6f} min={sl.min():+.5f} max={sl.max():+.5f}")
            break

# ---- 追加：自相关找真实 block 结构 ----
def autocorr_scan(path):
    d=open(path,'rb').read()
    for o in load_plists(d):
        if isinstance(o,dict) and isinstance(o.get('1'),bytes) and len(o['1'])==51840:
            k1=np.frombuffer(o['1'],dtype='<f2').astype(np.float32)
            break
    n=len(k1)
    x=k1-k1.mean()
    print("\n=== 自相关：value[i] vs value[i+k] ===")
    for k in [1,2,3,4,5,6,8,9,10,12,15,16,18,20,24,27,30,36,45,48,60,72,80,90,108,120]:
        if k>=n: continue
        a,b = x[:-k], x[k:]
        c = float(np.dot(a,b)/(np.linalg.norm(a)*np.linalg.norm(b)))
        print(f"  k={k:3d}: corr={c:+.4f} {'*' if abs(c)>0.3 else ''}")
    # 分块统计：把 25920 分成 m 块，看块间是否有周期
    print("\n=== 分块均值（找周期）===")
    for blk in [12, 36, 72, 120, 288, 2592]:
        if n%blk: continue
        m = k1.reshape(-1, blk).mean(axis=1)
        print(f"  block={blk:5d}: 块均值 std={m.std():.6f}  前8={[f'{v:+.3f}' for v in m[:8]]}")
