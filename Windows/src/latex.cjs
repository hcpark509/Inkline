'use strict';
const fs=require('node:fs/promises');
const path=require('node:path');
const os=require('node:os');
const {spawn}=require('node:child_process');
async function findEngine(engine,environment=process.env) {
  if(!['pdflatex','xelatex'].includes(engine)) throw Error('Choose pdfLaTeX or XeLaTeX.');
  const extra=process.platform==='win32' ? [path.join(os.homedir(),'AppData','Local','Programs','MiKTeX','miktex','bin','x64'),path.join(environment.ProgramFiles||'C:\\Program Files','MiKTeX','miktex','bin','x64'),path.join(environment.APPDATA||os.homedir(),'TinyTeX','bin','windows'),path.join(os.homedir(),'TinyTeX','bin','windows')] : ['/Library/TeX/texbin','/usr/local/bin','/opt/homebrew/bin',path.join(os.homedir(),'Library','TinyTeX','bin','universal-darwin')];
  if(process.platform==='win32') {for(const base of ['C:\\texlive',path.join(os.homedir(),'AppData','Roaming','TinyTeX')]) {try {for(const entry of await fs.readdir(base)) if(/^\d{4}$/.test(entry)) extra.push(path.join(base,entry,'bin','windows'));} catch {}}}
  for(const folder of [...(environment.PATH||'').split(path.delimiter),...extra]) {if(!folder || !path.isAbsolute(folder)) continue; const file=path.join(folder,engine+(process.platform==='win32'?'.exe':'')); try {await fs.access(file);return file;} catch {}}
  return null;
}
async function compileLatex({source,file,projectRoot,engine='pdflatex'}) {
  const executable=await findEngine(engine); if(!executable) throw Error(engine+' is unavailable. Install MiKTeX or TeX Live, then recompile.');
  const work=await fs.mkdtemp(path.join(os.tmpdir(),'inkline-tex-'));
  try {
    await fs.writeFile(path.join(work,'document.tex'),source,'utf8');
    const env={...process.env,PATH:path.dirname(executable)+path.delimiter+(process.env.PATH||''),TEXINPUTS:['.',file?path.dirname(file):null,projectRoot,process.env.TEXINPUTS||''].filter(v=>v!==null&&v!==undefined).join(path.delimiter),openout_any:'p'};
    const deadline=Date.now()+45000; let log='';
    for(let pass=1;pass<=2;pass++) {
      const result=await run(executable,['-no-shell-escape','-no-parse-first-line','-interaction=nonstopmode','-halt-on-error','-file-line-error','./document.tex'],{cwd:work,env,timeout:Math.max(1,deadline-Date.now())});
      log+=`Pass ${pass}\n${result.log}\n`; if(result.code!==0) {const error=Error(result.timeout?'Compilation exceeded 45 seconds.':result.log.split(/\r?\n/).find(l=>/^! |^\.\/document\.tex:/.test(l))||'Compilation failed. Open the compile log.');error.log=log;throw error;}
    }
    return {pdf:await fs.readFile(path.join(work,'document.pdf')),log};
  } finally {await fs.rm(work,{recursive:true,force:true});}
}
function run(executable,args,options) {
  return new Promise((resolve,reject)=>{let log='',timedOut=false;const child=spawn(executable,args,{cwd:options.cwd,env:options.env,shell:false,windowsHide:true,stdio:['ignore','pipe','pipe']});const timer=setTimeout(()=>{timedOut=true;child.kill('SIGKILL');},options.timeout);const collect=data=>{log=(log+data.toString()).slice(-98304);};child.stdout.on('data',collect);child.stderr.on('data',collect);child.once('error',e=>{clearTimeout(timer);reject(e);});child.once('close',code=>{clearTimeout(timer);resolve({code,log,timeout:timedOut});});});
}
module.exports={findEngine,compileLatex};
