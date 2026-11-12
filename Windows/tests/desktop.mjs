import {_electron} from 'playwright';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
import {spawn} from 'node:child_process';
import readline from 'node:readline';
const require=createRequire(import.meta.url),root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const temporary=await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(),'inkline-desktop-'))),data=path.join(temporary,'user-data');
const executable=process.env.INKLINE_EXECUTABLE||require('electron'),packaged=!!process.env.INKLINE_EXECUTABLE;
const environment={...process.env};delete environment.ELECTRON_RUN_AS_NODE;
const output=path.join(root,'test-results');await fs.mkdir(output,{recursive:true});
const electronApp=await _electron.launch({executablePath:executable,args:[...(packaged?[]:[root]),'--inkline-user-data='+data],env:environment,timeout:45000});
const page=await electronApp.firstWindow();const errors=[];page.on('pageerror',e=>errors.push(e.message));page.on('console',message=>{if(message.type()==='error')console.error('renderer:',message.text());});
const helper=spawn(executable,[...(packaged?[]:[root]),'--inkline-user-data='+data,'mcp','--automation-read-root',temporary,'--automation-write-root',temporary],{env:environment,stdio:['pipe','pipe','pipe'],windowsHide:true});
helper.stderr.on('data',chunk=>process.stderr.write(chunk));const requests=new Map();let next=0;
readline.createInterface({input:helper.stdout}).on('line',line=>{let value;try{value=JSON.parse(line);}catch{console.error('Non-JSON MCP output:',line);return;}const pending=requests.get(value.id);if(!pending)return;requests.delete(value.id);clearTimeout(pending.timer);value.error?pending.reject(Error(value.error.message)):pending.resolve(value.result);});
function request(method,params={}){return new Promise((resolve,reject)=>{const id=++next,timer=setTimeout(()=>{requests.delete(id);reject(Error('MCP timed out: '+method));},90000);requests.set(id,{resolve,reject,timer});helper.stdin.write(JSON.stringify({jsonrpc:'2.0',id,method,params})+'\n');});}
async function tool(name,args={},expectError=false){const result=await request('tools/call',{name,arguments:args});assert.equal(!!result.isError,expectError,JSON.stringify(result));return expectError?result:result.structuredContent;}
async function waitFor(predicate,label,timeout=15000){const start=Date.now();while(Date.now()-start<timeout){if(await predicate())return;await new Promise(r=>setTimeout(r,75));}throw Error('Timed out waiting for '+label);}
async function core(method,args){
  if(method==='state')return (await page.evaluate(()=>window.inkline.call('state'))).settings;
  await electronApp.evaluate(({dialog},file)=>{const original=dialog.showOpenDialog;dialog.showOpenDialog=async()=>{dialog.showOpenDialog=original;return {canceled:false,filePaths:[file]};};},method==='fonts'?args[0]:args);
  if(method==='project'){await page.evaluate(()=>window.inkline.call('project'));return;}
  if(method==='fonts'){const settings=electronApp.windows().find(w=>w.url().endsWith('/settings.html'));await settings.locator('[data-section=fonts]').click();await settings.locator('#importFonts').click();await waitFor(async()=>(await page.evaluate(()=>window.inkline.call('state'))).fonts.length>0,'font import');return (await page.evaluate(()=>window.inkline.call('state'))).fonts;}
  throw Error('Unknown test method.');
}
async function source(text){await page.locator('.cm-content').click();await page.keyboard.press('ControlOrMeta+A');await page.keyboard.insertText(text);}
let current;
try {
  await page.locator('.cm-content').waitFor();
  const initialized=await request('initialize',{protocolVersion:'2025-11-25',capabilities:{},clientInfo:{name:'inkline-desktop-regression',version:'1'}});assert.equal(initialized.serverInfo.version,'1.4.0');
  assert.equal((await request('tools/list')).tools.length,12);
  const original='# Windows edition\n\n한글 ✓ **Bold** and a [link](https://example.com).\n';await source(original);
  await waitFor(async()=>await page.frameLocator('#preview').locator('h1').textContent()==='Windows edition','Markdown render');
  current=(await tool('list_documents')).documents.find(d=>d.active);assert.equal((await tool('read_document',{document_id:current.document_id})).source,original);
  const first=await tool('read_document',{document_id:current.document_id});
  await tool('replace_document',{document_id:first.document_id,expected_revision:first.revision,source:'# MCP changed\n'});
  await tool('replace_document',{document_id:first.document_id,expected_revision:first.revision,source:'stale'},true);
  await page.locator('.cm-content').click();await page.keyboard.press('ControlOrMeta+z');await waitFor(async()=>(await tool('read_document',{document_id:first.document_id})).source===original,'native Undo of MCP edit');
  const file=path.join(temporary,'note.md');await tool('save_document',{document_id:first.document_id,path:file});assert.equal(await fs.readFile(file,'utf8'),original);
  await page.locator('[data-command=table]').click();await page.locator('#tableDialog[open]').waitFor();
  await page.locator('#tableRows').fill('2');await page.locator('#tableRows').press('Tab');await page.locator('#tableColumns').fill('2');await page.locator('#tableColumns').press('Tab');
  await page.getByRole('textbox',{name:'Row 1, column 1',exact:true}).fill('Item');await page.getByRole('textbox',{name:'Row 1, column 2',exact:true}).fill('Value');await page.getByRole('textbox',{name:'Row 2, column 1',exact:true}).fill('Example');await page.getByRole('textbox',{name:'Row 2, column 2',exact:true}).fill('42');
  assert.ok((await page.locator('#tableSource').textContent()).includes('| Example | 42 |'));await page.screenshot({path:path.join(output,(packaged?'packaged-':'')+'table.png')});await page.locator('#insertTable').click();
  assert.ok((await tool('read_document',{document_id:first.document_id})).source.includes('| Item | Value |'));
  await page.locator('.cm-content').click();await page.keyboard.press('ControlOrMeta+z');await waitFor(async()=>(await tool('read_document',{document_id:first.document_id})).source===original,'table Undo');
  const settingsPromise=electronApp.waitForEvent('window');await page.locator('[data-command=settings]').click();const settings=await settingsPromise;await settings.locator('[data-section=appearance]').click();await settings.locator('[data-setting=theme]').selectOption('Ocean');await settings.locator('[data-setting=appearance]').selectOption('dark');
  await page.waitForFunction(()=>getComputedStyle(document.documentElement).getPropertyValue('--source').trim()==='#14212a');await page.screenshot({path:path.join(output,(packaged?'packaged-':'')+'dark.png')});
  await settings.locator('[data-setting=appearance]').selectOption('light');await page.waitForFunction(()=>getComputedStyle(document.documentElement).getPropertyValue('--source').trim()==='#f6fafc');
  const font=process.platform==='win32'?'C:\\Windows\\Fonts\\arial.ttf':'/System/Library/Fonts/Supplemental/Georgia.ttf';const imported=await core('fonts',[font]);assert.ok(imported.length);const family=imported[0].family;
  await settings.locator('[data-section=fonts]').click();await settings.locator('[data-setting=sourceFont]').fill(family);await settings.locator('[data-setting=sourceFont]').press('Tab');await settings.locator('[data-setting=previewFont]').fill(family);await settings.locator('[data-setting=previewFont]').press('Tab');
  await waitFor(async()=>(await core('state')).sourceFont===family&&(await core('state')).previewFont===family,'font preferences');await settings.screenshot({path:path.join(output,(packaged?'packaged-':'')+'fonts.png')});
  await settings.locator('[data-section=general]').click();await settings.locator('[data-setting=autosaveDelay]').fill('1');await settings.locator('[data-setting=autosaveDelay]').press('Tab');await settings.locator('[data-setting=autosaveEnabled]').check();await waitFor(async()=>(await core('state')).autosaveEnabled,'autosave setting');await settings.close();
  await source('# Autosaved\n\nLatest text.\n');await waitFor(async()=>await fs.readFile(file,'utf8')==='# Autosaved\n\nLatest text.\n','autosave');
  const project=path.join(temporary,'project');await fs.mkdir(path.join(project,'chapters'),{recursive:true});await fs.mkdir(path.join(project,'figures'));await fs.copyFile(path.join(root,'dist/icon.png'),path.join(project,'figures','plot.png'));await core('project',project);
  const chapter=path.join(project,'chapters','note.md');await fs.writeFile(chapter,'# Project figure\n\n![A figure](../figures/plot.png)\n');const imageDoc=await tool('open_document',{path:chapter});await waitFor(async()=>await page.frameLocator('#preview').locator('img').evaluate(img=>img.complete&&img.naturalWidth>0),'project image');
  assert.equal(imageDoc.project_root,project);await page.locator('#project').waitFor();await page.screenshot({path:path.join(output,(packaged?'packaged-':'')+'project.png')});
  await tool('export_pdf',{document_id:imageDoc.document_id,expected_revision:imageDoc.revision,path:path.join(temporary,'markdown.pdf')});const mdPDF=await fs.readFile(path.join(temporary,'markdown.pdf'));assert.equal(mdPDF.subarray(0,4).toString(),'%PDF');assert.match(mdPDF.toString('latin1'),/\/Subtype\s*\/Image/);assert.match(mdPDF.toString('latin1'),/Arial|Georgia/);
  const htmlDoc=await tool('create_document',{format:'html',source:'<!doctype html><h1>Static HTML</h1><img src="figures/plot.png"><script>window.scriptExecuted=true</script>'});await waitFor(async()=>await page.frameLocator('#preview').locator('h1').textContent()==='Static HTML','HTML render');
  const frame=page.frames().find(f=>f.url().startsWith('inkline://preview/'));assert.equal(await frame.evaluate(()=>window.scriptExecuted),undefined);await tool('export_pdf',{document_id:htmlDoc.document_id,expected_revision:htmlDoc.revision,path:path.join(temporary,'html.pdf')});assert.equal((await fs.readFile(path.join(temporary,'html.pdf'))).subarray(0,4).toString(),'%PDF');
  const readResources=await request('resources/list');assert.ok(readResources.resources.some(r=>r.uri===htmlDoc.resource_uri));assert.ok((await request('resources/read',{uri:htmlDoc.resource_uri})).contents[0].text.includes('Static HTML'));
  const tex='\\documentclass{article}\n\\usepackage{amsmath}\n\\usepackage{graphicx}\n\\begin{document}\nWindows compile: $x^2$\n\\includegraphics[width=2cm]{figures/plot.png}\n\\end{document}\n';const latex=await tool('create_document',{format:'latex',source:tex});
  const result=await tool('compile_latex',{document_id:latex.document_id});if(process.env.INKLINE_REQUIRE_TEX==='1')assert.equal(result.success,true,result.log);if(result.success){await page.locator('#latexPreview canvas').first().waitFor({timeout:30000});await page.screenshot({path:path.join(output,(packaged?'packaged-':'')+'latex.png')});const changed=await tool('replace_document',{document_id:latex.document_id,expected_revision:latex.revision,source:tex.replace('x^2','x^3')});await page.locator('.cm-content').click();await page.keyboard.press('ControlOrMeta+Enter');await waitFor(async()=>await page.locator('#notice').textContent()==='Compiled','Ctrl+Enter compile',45000);await tool('export_pdf',{document_id:changed.document_id,expected_revision:changed.revision,path:path.join(temporary,'latex.pdf')});assert.equal((await fs.readFile(path.join(temporary,'latex.pdf'))).subarray(0,4).toString(),'%PDF');}
  assert.deepEqual(errors,[]);console.log('DESKTOP TESTS PASSED: editing, Markdown/HTML, tables, Undo, settings/themes, imported fonts, autosave, projects/images, all PDF exports, LaTeX shortcuts, and MCP.');console.log('Fixtures:',temporary);
}catch(e){await page.screenshot({path:path.join(output,'failure.png')}).catch(()=>{});console.error('DESKTOP TESTS FAILED:',e);throw e;}
finally{helper.stdin.end();for(const pending of requests.values())clearTimeout(pending.timer);await electronApp.evaluate(({BrowserWindow,app})=>{for(const win of BrowserWindow.getAllWindows())win.destroy();app.exit(0);}).catch(()=>{});await electronApp.close().catch(()=>{});helper.kill();}
