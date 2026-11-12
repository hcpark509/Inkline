'use strict';
const {contextBridge,ipcRenderer}=require('electron');
contextBridge.exposeInMainWorld('inkline',{
  call:(method,args={})=>ipcRenderer.invoke('inkline:call',method,args),
  change:value=>ipcRenderer.send('inkline:change',value),
  onState:callback=>{ipcRenderer.on('inkline:state',(_event,value)=>callback(value));},
  onCommand:callback=>{ipcRenderer.on('inkline:command',(_event,value)=>callback(value));},
  onCompiled:callback=>{ipcRenderer.on('inkline:compiled',(_event,value)=>callback(value));},
  onRequest:callback=>{ipcRenderer.on('inkline:request',async(_event,{id,action,args})=>{try{ipcRenderer.send('inkline:reply',{id,value:await callback(action,args)});}catch(e){ipcRenderer.send('inkline:reply',{id,error:e.message});}});}
});
