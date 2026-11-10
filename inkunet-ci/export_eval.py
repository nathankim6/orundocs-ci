import sys, os, time, numpy as np, torch, onnxruntime as ort
from pathlib import Path
from PIL import Image
R=Path('hf'); sys.path.insert(0,str(R))
from src.model import build_model
from src.utils import load_config
cfg=load_config(R/'config.yaml'); m=build_model(cfg)
ck=torch.load(R/'weights/gated_unetpp_erase.pt',map_location='cpu',weights_only=False); m.load_state_dict(ck['ema'],strict=False); m.eval()
class W(torch.nn.Module):
    def __init__(s,m): super().__init__(); s.m=m
    def forward(s,x): return s.m(x,None)['pred'][-1].clamp(0,1)
w=W(m).eval(); x=torch.rand(1,3,512,512)
os.makedirs('out',exist_ok=True)
torch.onnx.export(w,x,'out/inkunet_512.onnx',input_names=['input'],output_names=['output'],opset_version=17,do_constant_folding=True,dynamo=False)
s=ort.InferenceSession('out/inkunet_512.onnx',providers=['CPUExecutionProvider'])
with torch.no_grad(): ref=w(x).numpy()
o=s.run(None,{'input':x.numpy()})[0]; print('onnx max abs diff',float(np.abs(o-ref).max()), 'size MB', os.path.getsize('out/inkunet_512.onnx')/1e6)
def tiled(img, win=512, step=300, pad=106):
    a=img.astype(np.float32)/255.; H,W,_=a.shape
    p=np.pad(a,((pad,pad+win),(pad,pad+win),(0,0)),mode='reflect')
    out=np.zeros_like(a); keep=step
    for y in range(0,H,keep):
        for x0 in range(0,W,keep):
            t=p[y:y+win,x0:x0+win]; t=np.ascontiguousarray(t.transpose(2,0,1)[None])
            r=s.run(None,{'input':t})[0][0].transpose(1,2,0)
            cy=min(keep,H-y); cx=min(keep,W-x0)
            out[y:y+cy,x0:x0+cx]=r[pad:pad+cy,pad:pad+cx]
    return (out*255+.5).clip(0,255).astype(np.uint8)
def run(name, maxside):
    im=Image.open('out/'+name).convert('RGB'); W0,H0=im.size; sc=maxside/max(W0,H0)
    im2=im.resize((round(W0*sc),round(H0*sc)),Image.LANCZOS) if sc<1 else im
    t=time.time(); r=tiled(np.array(im2)); dt=time.time()-t
    return Image.fromarray(r), dt, im2.size
for base in ['photo1','photo2','photo3']:
    for ms in [1500,1100]:
        r,dt,sz=run(base+'-normalized.png',ms); r.save(f'out/{base}-ai-{ms}.png'); print(base,'ai',ms,sz,f'{dt:.1f}s')
    r,dt,sz=run(base+'-coloronly.png',1500); r.save(f'out/{base}-hybrid-1500.png'); print(base,'hybrid',sz,f'{dt:.1f}s')
