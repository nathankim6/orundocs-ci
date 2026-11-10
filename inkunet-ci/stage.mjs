// Produce rectified + illumination-normalised pages (model input) and the current engine's result.
import fs from 'node:fs';import {createRequire} from 'node:module';const require=createRequire(import.meta.url);
const {PNG}=require('pngjs');const jpeg=require('jpeg-js');
const core=await import('./exam-scan-core.mjs');
fs.mkdirSync('out',{recursive:true});
for(const f of ['photo1.png','photo2.png','photo3.jpg']){
 const buf=fs.readFileSync(f);let w,h,d;if(f.endsWith('.png')){const p=PNG.sync.read(buf);w=p.width;h=p.height;d=p.data;}else{const j=jpeg.decode(buf,{useTArray:true});w=j.width;h=j.height;d=j.data;}
 const img={width:w,height:h,data:new Uint8ClampedArray(d)};
 const det=core.detectDocument(img);
 const r=core.processPage(img,{corners:det.corners,mode:'clean'});
 const save=(im,n)=>{const p=new PNG({width:im.width,height:im.height});p.data=Buffer.from(im.data.buffer,im.data.byteOffset,im.data.length);fs.writeFileSync('out/'+n,PNG.sync.write(p));};
 const base=f.replace(/\..*/,'');save(r.normalized,base+'-normalized.png');save(r.after,base+'-current.png');
 // current engine colour removal only (keep for hybrid)
 const c=core.removeHandwriting(r.normalized,{removeColor:true,removePencil:false});save(c.image,base+'-coloronly.png');
 console.log(f,det.detected,r.normalized.width+'x'+r.normalized.height);
}
