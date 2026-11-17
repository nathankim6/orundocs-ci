'use strict';
// Envelope: ODQA1 (5 bytes), random nonce (12), auth tag (16), AES-256-GCM ciphertext.
// encrypt <input> <output> <key-file>: private local key; decrypt <input> <output>: Actions secret env.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const [mode,input,output,keyFile]=process.argv.slice(2); const magic=Buffer.from('ODQA1');
if(mode==='encrypt'){
 if(!keyFile)throw Error('key file required');fs.mkdirSync(path.dirname(keyFile),{recursive:true,mode:0o700});fs.chmodSync(path.dirname(keyFile),0o700);
 if(!fs.existsSync(keyFile))fs.writeFileSync(keyFile,crypto.randomBytes(32).toString('hex'),{mode:0o600,flag:'wx'});fs.chmodSync(keyFile,0o600);
 const key=Buffer.from(fs.readFileSync(keyFile,'utf8').trim(),'hex');if(key.length!==32)throw Error('bad key length');const iv=crypto.randomBytes(12),cipher=crypto.createCipheriv('aes-256-gcm',key,iv);cipher.setAAD(magic);
 const plain=fs.readFileSync(input),enc=Buffer.concat([cipher.update(plain),cipher.final()]);fs.writeFileSync(output,Buffer.concat([magic,iv,cipher.getAuthTag(),enc]));
 const decipher=crypto.createDecipheriv('aes-256-gcm',key,iv);decipher.setAAD(magic);decipher.setAuthTag(cipher.getAuthTag());if(!Buffer.concat([decipher.update(enc),decipher.final()]).equals(plain))throw Error('roundtrip mismatch');console.log('Encrypted roundtrip verified; plaintext SHA256 '+crypto.createHash('sha256').update(plain).digest('hex'));
}else if(mode==='decrypt'){
 const key=Buffer.from(process.env.DESKTOP_QA_PAYLOAD_KEY||'','hex');if(key.length!==32)throw Error('DESKTOP_QA_PAYLOAD_KEY missing');const b=fs.readFileSync(input);if(!b.subarray(0,5).equals(magic))throw Error('bad envelope');const decipher=crypto.createDecipheriv('aes-256-gcm',key,b.subarray(5,17));decipher.setAAD(magic);decipher.setAuthTag(b.subarray(17,33));const p=Buffer.concat([decipher.update(b.subarray(33)),decipher.final()]);fs.writeFileSync(output,p,{mode:0o600});console.log('Authenticated payload decrypted; SHA256 '+crypto.createHash('sha256').update(p).digest('hex'));
}else throw Error('encrypt|decrypt required');
