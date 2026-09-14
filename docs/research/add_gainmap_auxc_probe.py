def boxes(d,s,e):
    p=s; out=[]
    while p+8<=e:
        size=int.from_bytes(d[p:p+4],'big'); t=d[p+4:p+8]
        h=8
        if size==1: size=int.from_bytes(d[p+8:p+16],'big'); h=16
        if size==0: size=e-p
        out.append((t,p,size,h))
        if size<8: break
        p+=size
    return out

data=bytearray(open('/tmp/ps3-ab/E-mdat-ident.heic','rb').read())
native=open("/Users/beet/Desktop/iPhone 18 Pro/IMG_0004/IMG_0004.HEIC",'rb').read()

def find_ipco(d):
    meta=next(b for b in boxes(d,0,len(d)) if b[0]==b'meta'); _,mp,ms,mh=meta
    iprp=next(b for b in boxes(d,mp+mh+4,mp+ms) if b[0]==b'iprp')
    ipco=next(b for b in boxes(d,iprp[1]+iprp[3],iprp[1]+iprp[2]) if b[0]==b'ipco')
    return meta,iprp,ipco

meta_n,iprp_n,ipco_n=find_ipco(native)
auxc=next(native[p:p+s] for t,p,s,h in boxes(native,ipco_n[1]+ipco_n[3],ipco_n[1]+ipco_n[2])
          if t==b'auxC' and b'hdrgainmap' in native[p:p+s])

meta,iprp,ipco=find_ipco(data)
_,mp,ms,mh=meta; _,pI,sI,hI=iprp; _,pC,sC,hC=ipco
kids=boxes(data,mp+mh+4,mp+ms)
ipma=next(b for b in boxes(data,pI+hI,pI+sI) if b[0]==b'ipma'); _,pM,sM,hM=ipma
iloc=next(b for b in kids if b[0]==b'iloc'); pL,sL,hL=iloc[1],iloc[2],iloc[3]
nchild=len(boxes(data,pC+hC,pC+sC)); new_index=nchild+1

# rebuild ipma (ver0: u32 count, u16 ids, 1-byte assocs)
cnt_off=pM+12
count=int.from_bytes(data[cnt_off:cnt_off+4],'big')
q=cnt_off+4
body=bytearray()
GAIN=10242
for i in range(count):
    id_start=q
    iid=int.from_bytes(data[q:q+2],'big'); q+=2
    n=data[q]; q+=1
    assocs=bytes(data[q:q+n]); q+=n
    if iid==GAIN:
        body+=iid.to_bytes(2,'big')+bytes([n+1])+assocs+bytes([new_index])
    else:
        body+=data[id_start:q]
new_ipma=bytearray((0).to_bytes(4,'big')+b'ipma'+data[pM+8:cnt_off+4]+body)
new_ipma[:4]=len(new_ipma).to_bytes(4,'big')
new_ipco=bytearray((8+(sC-8)+len(auxc)).to_bytes(4,'big')+b'ipco'+data[pC+hC:pC+sC]+auxc)
new_iprp=bytearray((8).to_bytes(4,'big')+b'iprp')
for t,p,s,h in boxes(data,pI+hI,pI+sI):
    if t==b'ipco': new_iprp+=new_ipco
    elif t==b'ipma': new_iprp+=new_ipma
    else: new_iprp+=data[p:p+s]
new_iprp[:4]=len(new_iprp).to_bytes(4,'big')
delta=len(new_iprp)-sI
print("delta",delta)
new_meta=bytearray()
for t,p,s,h in kids:
    if t==b'iprp': new_meta+=new_iprp
    else: new_meta+=data[p:p+s]
out=bytearray(data[:mp])
out+=(12+len(new_meta)).to_bytes(4,'big')+b'meta'+data[mp+8:mp+12]+new_meta
out+=data[mp+ms:]
# in-place patch of iloc cm0 offsets (iloc before iprp -> position unchanged)
p,h,s=pL,hL,sL
ver2=data[p+h]; flags2=int.from_bytes(data[p+h+1:p+h+4],'big')
b1,b2=data[p+h+4],data[p+h+5]
offsz,lensz,baseoffsz=b1>>4,b1&0xf,b2>>4
idxsz=(b2&0xf) if (flags2&1) else 0
q=p+h+6
cnt=int.from_bytes(out[q:q+(4 if ver2>=2 else 2)],'big'); q+=4 if ver2>=2 else 2
patched=0
for i in range(cnt):
    iid=int.from_bytes(out[q:q+(4 if ver2>=2 else 2)],'big'); q+=4 if ver2>=2 else 2
    cm=int.from_bytes(out[q:q+2],'big')&0xf; q+=2
    q+=2
    # base_offset_size=0 in this file
    ec=int.from_bytes(out[q:q+2],'big'); q+=2
    for j in range(ec):
        if ver2>=1 and (flags2&1): q+=idxsz
        if cm==0:
            o=int.from_bytes(out[q:q+offsz],'big')+delta
            out[q:q+offsz]=o.to_bytes(offsz,'big')
            patched+=1
        q+=offsz+lensz
print("patched cm0 offsets:",patched,"final q",q,"iloc end",pL+sL)
open('/tmp/ps3-ab/U-gainmap-auxc.heic','wb').write(out)
print("written",len(out))
