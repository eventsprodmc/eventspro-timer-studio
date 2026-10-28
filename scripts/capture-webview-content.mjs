import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
const [portText,output]=process.argv.slice(2),port=Number(portText);
if(process.platform!=='win32'||!process.env.GITHUB_ACTIONS||!Number.isInteger(port)||port<1||port>65535)throw Error('Ephemeral Windows CI with verified local port required');
const provenance=JSON.parse((await fs.readFile(path.join(output,'native-provenance.json'),'utf8')).replace(/^\uFEFF/,''));
if(provenance.cdpPort!==port||provenance.expectedTargetUrl!=='http://127.0.0.1:9140/timer.html')throw Error('Provenance mismatch');
let target;
for(let n=0;n<60;n++){
 try{const response=await fetch(`http://127.0.0.1:${port}/json/list`,{signal:AbortSignal.timeout(2000)});const list=await response.json();const hits=list.filter(t=>t.type==='page'&&t.url===provenance.expectedTargetUrl);if(hits.length===1){target=hits[0];break;}if(hits.length>1)throw Error('Ambiguous real WebView2 page');}catch(e){if(String(e).includes('Ambiguous'))throw e;}
 await new Promise(r=>setTimeout(r,500));
}
if(!target)throw Error('The exact native app did not expose its expected WebView2 target');
const url=new URL(target.webSocketDebuggerUrl);
if(url.protocol!=='ws:'||!['127.0.0.1','localhost','[::1]'].includes(url.hostname)||Number(url.port)!==port)throw Error('Non-loopback or unexpected WebView2 target socket');
const socket=new WebSocket(url);await new Promise((resolve,reject)=>{socket.addEventListener('open',resolve,{once:true});socket.addEventListener('error',reject,{once:true});setTimeout(()=>reject(Error('WebView2 socket timeout')),10000).unref();});
let next=0;const pending=new Map();socket.addEventListener('message',event=>{const m=JSON.parse(event.data);if(!m.id)return;const p=pending.get(m.id);if(!p)return;pending.delete(m.id);clearTimeout(p.timeout);m.error?p.reject(Error(JSON.stringify(m.error))):p.resolve(m.result);});
function command(method,params={}){if(!['Page.getLayoutMetrics','Page.captureScreenshot'].includes(method))throw Error('Command forbidden');return new Promise((resolve,reject)=>{const id=++next,timeout=setTimeout(()=>{pending.delete(id);reject(Error('CDP timeout '+method));},15000);pending.set(id,{resolve,reject,timeout});socket.send(JSON.stringify({id,method,params}));});}
try{
 await new Promise(r=>setTimeout(r,5000));
 const metrics=await command('Page.getLayoutMetrics');const viewport=metrics.cssLayoutViewport||metrics.layoutViewport;
 if(viewport.clientWidth<1366||viewport.clientHeight<768)throw Error(`Actual WebView2 viewport too small: ${viewport.clientWidth}x${viewport.clientHeight}`);
 const result=await command('Page.captureScreenshot',{format:'png',fromSurface:true,captureBeyondViewport:false});const png=Buffer.from(result.data,'base64');
 if(png.subarray(0,8).toString('hex')!=='89504e470d0a1a0a'||png.length<15000)throw Error('Missing or suspiciously empty actual renderer PNG');
 const width=png.readUInt32BE(16),height=png.readUInt32BE(20);if(width<1366||height<768)throw Error('Captured image smaller than accepted native viewport');
 const image=path.join(output,'Timer-PRO-Windows-WebView2-content.png');await fs.writeFile(image,png,{flag:'wx'});
 await fs.writeFile(path.join(output,'capture-receipt.json'),JSON.stringify({...provenance,targetId:target.id,targetTitle:target.title,targetUrl:target.url,commands:['Page.getLayoutMetrics','Page.captureScreenshot'],viewport,width,height,pngSha256:crypto.createHash('sha256').update(png).digest('hex'),pngBytes:png.length,domModified:false,emulated:false,physicalDesktopCaptured:false,contentSource:'WebView2 renderer created by the exact Windows Timer EXE, without Win32 frame'},null,2)+'\n',{flag:'wx'});
 console.log('Captured the actual Windows Timer WebView2 content surface without DOM changes');
}finally{socket.close();}
