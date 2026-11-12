'use strict';
const fs=require('node:fs/promises');
const path=require('node:path');
const os=require('node:os');
const net=require('node:net');
const readline=require('node:readline');
const {spawn}=require('node:child_process');
const {randomBytes}=require('node:crypto');
const {Scope,digest,atomicWrite}=require('./documents.cjs');
const version=require('../package.json').version;
const protocols=['2025-11-25','2025-06-18','2025-03-26','2024-11-05'];
const str={type:'string'},bool={type:'boolean'},doc={type:'string',description:'Document ID from list_documents.'},rev={type:'string',description:'Revision from read_document. Stale revisions are rejected.'},format={type:'string',enum:['markdown','latex','html']};
function tool(name,description,properties={},required=[],readOnly=false,destructive=false) {return {name,description,inputSchema:{type:'object',properties,required,additionalProperties:false},annotations:{readOnlyHint:readOnly,destructiveHint:destructive,openWorldHint:false}};}
const tools=[
  tool('list_documents','List accessible saved documents and untitled documents.',{},[],true),
  tool('read_document','Read current source, revision, selection, and unsaved changes.',{document_id:doc},['document_id'],true),
  tool('create_document','Create an untitled Markdown, LaTeX, or HTML document.',{format,source:str},['format']),
  tool('open_document','Open a file within a configured read root.',{path:str},['path']),
  tool('close_document','Close a clean document. Save modified documents first.',{document_id:doc},['document_id']),
  tool('replace_document','Replace source with one undoable edit. Read first.',{document_id:doc,expected_revision:rev,source:str},['document_id','expected_revision','source'],false,true),
  tool('edit_document','Replace one unique exact occurrence as one undoable edit.',{document_id:doc,expected_revision:rev,old_text:str,new_text:str},['document_id','expected_revision','old_text','new_text'],false,true),
  tool('save_document','Save within a write root. New documents need an absolute path.',{document_id:doc,path:str,overwrite:bool},['document_id'],false,true),
  tool('set_view','Switch source, split, or preview layout.',{document_id:doc,view:{type:'string',enum:['source','split','preview']}},['document_id','view']),
  tool('set_format','Change untitled format; saved documents open as untitled copies.',{document_id:doc,format},['document_id','format']),
  tool('compile_latex','Compile with an installed pdfLaTeX or XeLaTeX engine.',{document_id:doc,engine:{type:'string',enum:['pdflatex','xelatex']}},['document_id']),
  tool('export_pdf','Export current revision to a PDF within a write root.',{document_id:doc,expected_revision:rev,path:str,overwrite:bool},['document_id','expected_revision','path'],false,true)
];
function validate(name,args) {const schema=tools.find(t=>t.name===name)?.inputSchema;if(!schema) throw Error('Unknown Inkline tool.');for(const key of schema.required) if(!(key in args)) throw Error('Missing argument: '+key);for(const [key,value] of Object.entries(args)) {const p=schema.properties[key];if(!p || typeof value!==p.type || (p.enum&&!p.enum.includes(value))) throw Error('Invalid argument: '+key);}}
function pipeName(identity) {const hash=digest(os.homedir()+'\0'+identity).slice(0,28);return process.platform==='win32'?'\\\\.\\pipe\\inkline-'+hash:path.join(os.tmpdir(),'inkline-'+hash+'.sock');}
function startBridge({pipe,token,handle}) {
  const server=net.createServer(socket=>{let buffer='';socket.setTimeout(90000,()=>socket.destroy());socket.on('data',data=>{buffer+=data.toString('utf8');if(Buffer.byteLength(buffer)>16*1024*1024) {socket.destroy();return;}let split;while((split=buffer.indexOf('\n'))>=0) {const line=buffer.slice(0,split);buffer=buffer.slice(split+1);Promise.resolve().then(async()=>{const input=JSON.parse(line);if(input.token!==token) throw Error('Invalid local automation token.');return await handle(input);}).then(result=>socket.write(JSON.stringify({result})+'\n')).catch(error=>socket.write(JSON.stringify({error:error.message})+'\n'));}});socket.on('error',()=>{});});
  return new Promise((resolve,reject)=>{server.once('error',reject);server.listen(pipe,async()=>{if(process.platform!=='win32') await fs.chmod(pipe,0o600).catch(()=>{});resolve(server);});});
}
async function bridgeRequest(pipe,input) {
  return new Promise((resolve,reject)=>{const socket=net.connect(pipe);let buffer='';const timer=setTimeout(()=>{socket.destroy();reject(Error('Inkline timed out. Read the document before retrying.'));},85000);socket.once('connect',()=>socket.write(JSON.stringify(input)+'\n'));socket.on('data',data=>{buffer+=data.toString('utf8');if(Buffer.byteLength(buffer)>20*1024*1024) {socket.destroy(Error('Automation response is too large.'));return;}if(buffer.includes('\n')) {clearTimeout(timer);socket.end();try {const value=JSON.parse(buffer.split('\n')[0]);if(value.error) reject(Error(value.error));else resolve(value.result);} catch(e){reject(e);}}});socket.once('error',e=>{clearTimeout(timer);reject(e);});socket.once('end',()=>{clearTimeout(timer);if(!buffer) reject(Error('Inkline closed the automation connection.'));});});
}
async function getToken(userData) {const file=path.join(userData,'mcp-token');try{return await fs.readFile(file,'utf8');}catch{const token=randomBytes(32).toString('hex');await fs.mkdir(userData,{recursive:true});try {await fs.writeFile(file,token,{flag:'wx',mode:0o600});return token;} catch(e) {if(e.code==='EEXIST')return fs.readFile(file,'utf8');throw e;}}}
function rootsFromArgs(args) {const read=[],write=[];for(let i=0;i<args.length;i+=2) {if(!args[i+1] || !['--automation-read-root','--automation-write-root'].includes(args[i])) throw Error('Use --automation-read-root or --automation-write-root followed by an absolute folder path.');(args[i]==='--automation-read-root'?read:write).push(args[i+1]);}return {read,write};}
async function runHelper({app,args,pipe,userData,appPath}) {
  const roots=rootsFromArgs(args);await Scope.create(roots.read,roots.write);let initialized=false;
  async function request(method,params) {
    let token=await getToken(userData);
    try {return await bridgeRequest(pipe,{token,method,params,...roots});}
    catch(e) {if(!['ENOENT','ECONNREFUSED'].includes(e.code)) throw e;}
    const command=app.isPackaged?[]:[appPath,'--inkline-user-data='+userData];const environment={...process.env};delete environment.ELECTRON_RUN_AS_NODE;const child=spawn(process.execPath,[...command,'--automation-gui'],{detached:true,stdio:'ignore',env:environment});child.unref();
    for(let i=0;i<100;i++){await new Promise(r=>setTimeout(r,100));try{return await bridgeRequest(pipe,{token,method,params,...roots});}catch(e){if(!['ENOENT','ECONNREFUSED'].includes(e.code))throw e;}}
    throw Error('Could not start Inkline. Open the app and try again.');
  }
  const lines=readline.createInterface({input:process.stdin,crlfDelay:Infinity});
  for await(const line of lines) {
    if(!line.trim())continue;let id=null;
    try {if(Buffer.byteLength(line)>16*1024*1024)throw Error('Request exceeds 16 MB.');const input=JSON.parse(line);id=input.id;if(id===undefined)continue;if(input.jsonrpc!=='2.0'||typeof input.method!=='string'||!(typeof id==='string'||typeof id==='number'))throw Error('Invalid JSON-RPC request.');const params=input.params||{};let result;
      if(input.method==='initialize'){initialized=true;result={protocolVersion:protocols.includes(params.protocolVersion)?params.protocolVersion:protocols[0],capabilities:{tools:{},resources:{}},serverInfo:{name:'Inkline Windows',version}};}
      else if(input.method==='ping')result={};
      else {if(!initialized)throw Error('Initialize the MCP connection first.');if(input.method==='tools/list')result={tools};else if(['tools/call','resources/list','resources/read'].includes(input.method)){if(input.method==='tools/call')validate(params.name,params.arguments||{});result=await request(input.method,params);}else throw Error('Unsupported MCP method.');}
      process.stdout.write(JSON.stringify({jsonrpc:'2.0',id,result})+'\n');
    }catch(e){process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:id??null,error:{code:-32603,message:e.message}})+'\n');}
  }
  app.exit(0);
}
function toolResult(value) {return {content:[{type:'text',text:JSON.stringify(value)}],structuredContent:value};}
async function handleAutomation(input,{store,sync,replace,compile,exportPDF,show}) {
  if(!store.settings.mcpEnabled)throw Error('MCP access is paused in Inkline Settings.');await sync();
  const scope=await Scope.create(input.read,input.write);
  const docs=()=>[...store.docs.values()].filter(d=>!d.path||scope.permits(d.path));
  const find=(id,write=false)=>{const d=docs().find(d=>d.id===id);if(!d)throw Error('Document is closed or outside configured roots.');if(write&&d.path&&!scope.permits(d.path,true))throw Error('Document is outside configured write roots.');return d;};
  if(input.method==='resources/list')return {resources:docs().map(d=>({uri:'inkline://document/'+d.id,name:store.snapshot(d).title,mimeType:'text/plain'}))};
  if(input.method==='resources/read'){const uri=input.params.uri;if(typeof uri!=='string'||!uri.startsWith('inkline://document/'))throw Error('Unknown resource.');return {contents:[{uri,mimeType:'text/plain',text:find(uri.slice(19)).source}]};}
  try {
    const {name,arguments:a={}}=input.params;validate(name,a);let d,result;
    switch(name) {
      case 'list_documents':result={documents:docs().map(d=>store.snapshot(d)),read_roots:scope.read,write_roots:scope.write,app_version:version,platform:process.platform};break;
      case 'create_document':d=store.create(a.format,a.source);break;
      case 'open_document':d=await store.open(await scope.require(a.path));break;
      case 'read_document':result=store.snapshot(find(a.document_id),true);break;
      case 'close_document':store.close(a.document_id&&find(a.document_id).id);result={closed:true,document_id:a.document_id};break;
      case 'replace_document':case 'edit_document':{d=find(a.document_id,true);store.check(d,a.expected_revision);let source=a.source;if(name==='edit_document'){const at=d.source.indexOf(a.old_text);if(!a.old_text||at<0||d.source.indexOf(a.old_text,at+1)>=0)throw Error('old_text must match exactly one occurrence.');source=d.source.slice(0,at)+a.new_text+d.source.slice(at+a.old_text.length);}await replace(d,source);break;}
      case 'save_document':d=find(a.document_id,true);await store.save(d.id,await scope.require(a.path||d.path,true,true),a.overwrite===true);break;
      case 'set_view':d=find(a.document_id);d.view=a.view;break;
      case 'set_format':d=find(a.document_id);if(d.format!==a.format){if(d.path)d=store.create(a.format,d.source);else {d.format=a.format;d.compiled=null;}}break;
      case 'compile_latex':d=find(a.document_id);if(a.engine)d.engine=a.engine;try {const compiled=await compile(d);result={success:true,message:'Compiled',log:compiled.log};}catch(e){result={success:false,message:e.message,log:e.log||e.message};}break;
      case 'export_pdf':{d=find(a.document_id);store.check(d,a.expected_revision);const file=await scope.require(a.path,true,true);if(path.extname(file).toLowerCase()!=='.pdf')throw Error('Export path must end in .pdf.');await exportPDF(d,file,a.overwrite===true,a.expected_revision);result={path:file,document:store.snapshot(d)};break;}
    }
    show();return toolResult(result||store.snapshot(d));
  } catch(e) {return {isError:true,content:[{type:'text',text:e.message}]};}
}
module.exports={tools,validate,pipeName,startBridge,bridgeRequest,getToken,rootsFromArgs,runHelper,handleAutomation,toolResult};
