// Drives real Safari (safaridriver) through https://orundocs.web.app/signin -> email sign-in -> 127.0.0.1 loopback,
// exactly like the OrunDocs desktop app's auth bridge. Never prints secrets.
const http=require('http'),fs=require('fs');const OUT=process.argv[2];fs.mkdirSync(OUT,{recursive:true});
const log=m=>{console.log(m);fs.appendFileSync(OUT+'/log.txt',m+'\n');};
const state='SafariCI_'+Math.random().toString(36).slice(2)+Math.random().toString(36).slice(2);
let got=null;
const page=`<!doctype html><meta charset=utf-8><body><p id=m>pending</p><script>var f=location.hash.slice(1);history.replaceState(null,'',location.pathname);fetch('/auth/token',{method:'POST',headers:{'content-type':'text/plain;charset=utf-8'},body:f}).then(r=>r.text()).then(t=>document.getElementById('m').textContent=t).catch(e=>document.getElementById('m').textContent='ERR '+e)</script>`;
const srv=http.createServer((req,res)=>{log('loopback '+req.method+' '+req.url.split('#')[0].slice(0,40)+' host='+req.headers.host);
 if(req.method==='GET'&&req.url.startsWith('/auth/callback')){res.writeHead(200,{'content-type':'text/html; charset=utf-8'});return res.end(page);}
 if(req.method==='POST'&&req.url==='/auth/token'){let b='';req.on('data',d=>b+=d).on('end',()=>{const p=new URLSearchParams(b);got={stateOk:p.get('state')===state,rtLen:(p.get('rt')||'').length,email:p.get('email')==='appreview@orundocs.web.app'};res.writeHead(200,{'content-type':'text/plain; charset=utf-8'});res.end('로그인 완료');});return;}
 res.writeHead(404);res.end();});
const W='http://127.0.0.1:4444';
async function wd(method,path,body){const r=await fetch(W+path,{method,headers:{'content-type':'application/json'},body:body?JSON.stringify(body):undefined});const j=await r.json().catch(()=>({}));if(!r.ok)throw Error(path+' '+r.status+' '+JSON.stringify(j).slice(0,300));return j.value;}
(async()=>{await new Promise(r=>srv.listen(0,'127.0.0.1',r));const port=srv.address().port;
 const sess=await wd('POST','/session',{capabilities:{alwaysMatch:{browserName:'safari'}}});const S='/session/'+(sess.sessionId);
 const shot=async n=>{try{const b=await wd('GET',S+'/screenshot');fs.writeFileSync(OUT+'/'+n+'.png',Buffer.from(b,'base64'));}catch(e){log('shot fail '+e.message)}};
 const url=`https://orundocs.web.app/signin?target=desktop&state=${state}&port=${port}`;
 await wd('POST',S+'/url',{url});await new Promise(r=>setTimeout(r,5000));await shot('01-choices');
 const txt=async()=>wd('POST',S+'/execute/sync',{script:'return document.body.innerText',args:[]});
 log('page: '+(await txt()).replace(/\s+/g,' ').slice(0,200));
 // open email form and sign in
 await wd('POST',S+'/execute/sync',{script:`document.querySelector('details.more').open=true;const f=document.querySelector('.pwform');f.querySelector('input[type=email]').value=arguments[0];f.querySelector('input[type=password]').value=arguments[1];f.requestSubmit();return true;`,args:[process.env.OD_REVIEW_EMAIL,process.env.OD_REVIEW_PASSWORD]});
 for(let i=0;i<30&&!got;i++)await new Promise(r=>setTimeout(r,1000));
 await new Promise(r=>setTimeout(r,2000));
 let cur='';try{cur=await wd('GET',S+'/url');}catch{}
 log('final url host+path: '+cur.replace(/#.*/,'').slice(0,60));try{log('final page: '+(await txt()).replace(/\s+/g,' ').slice(0,200));}catch(e){log('text fail '+e.message);}
 await shot('02-after');
 log('RESULT '+JSON.stringify(got));
 // Google button path: just confirm it reaches accounts.google.com
 await wd('POST',S+'/url',{url:`https://orundocs.web.app/signin?target=desktop&state=${state}x&port=${port}`});await new Promise(r=>setTimeout(r,4000));
 await wd('POST',S+'/execute/sync',{script:`[...document.querySelectorAll('button')].find(b=>b.textContent.includes('Google')).click();return 1`,args:[]});await new Promise(r=>setTimeout(r,7000));
 try{log('google url host: '+new URL(await wd('GET',S+'/url')).host);}catch(e){log('google step '+e.message)}await shot('03-google');
 await wd('DELETE',S);srv.close();process.exit(got&&got.stateOk&&got.rtLen>20?0:1);
})().catch(e=>{log('ERR '+e.message);process.exit(1);});
