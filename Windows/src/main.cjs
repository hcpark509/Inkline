'use strict';
const {
  app,
  BrowserWindow,
  Menu,
  dialog,
  ipcMain,
  protocol,
  nativeTheme,
  shell,
} = require('electron');
const fs = require('node:fs/promises');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { randomUUID } = require('node:crypto');
const {
  Documents,
  Scope,
  canonical,
  inside,
  atomicWrite,
  digest,
  revision,
} = require('./documents.cjs');
const { extensions, starters, validSettings } = require('./shared.cjs');
const { compileLatex } = require('./latex.cjs');
const mcp = require('./mcp.cjs');
const appRoot = path.resolve(__dirname, '..');
const argv = process.argv.slice(1),
  helperAt = argv.findIndex((a) => a === 'mcp' || a === '--mcp');
const testData = argv.find((a) => a.startsWith('--inkline-user-data='));
app.setName('Inkline');
if (testData && !app.isPackaged)
  app.setPath('userData', path.resolve(testData.split('=').slice(1).join('=')));
else
  app.setPath(
    'userData',
    path.join(
      app.getPath('appData'),
      process.platform === 'win32' ? 'Inkline' : 'Inkline-Windows-Development',
    ),
  );
protocol.registerSchemesAsPrivileged([
  {
    scheme: 'inkline',
    privileges: {
      standard: true,
      secure: true,
      supportFetchAPI: true,
      corsEnabled: true,
      stream: true,
    },
  },
]);
let mainWindow,
  settingsWindow,
  store,
  fonts = [],
  server,
  forceClose = false;
const pending = new Map(),
  compiling = new Map();
const renderer = path.join(appRoot, 'dist');
const mime = {
  '.html': 'text/html',
  '.js': 'text/javascript',
  '.mjs': 'text/javascript',
  '.css': 'text/css',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.svg': 'image/svg+xml',
  '.webp': 'image/webp',
  '.avif': 'image/avif',
  '.bmp': 'image/bmp',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.json': 'application/json',
};
const staticCSP =
  "default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; worker-src 'self' blob:; style-src 'self' 'unsafe-inline'; img-src inkline: data: https: http:; font-src inkline:; connect-src inkline:; frame-src inkline: about:; object-src 'none'; base-uri 'none'";
const documentCSP =
  "default-src 'none'; script-src 'none'; style-src inkline: 'unsafe-inline'; img-src inkline: data: https: http:; font-src inkline: data:; form-action 'none'; object-src 'none'; base-uri 'none'";
function state() {
  return {
    documents: [...store.docs.values()].map((d) => store.snapshot(d, true)),
    active: store.active,
    settings: store.settings,
    projectRoot: store.projectRoot,
    fonts: fonts.map(({ family, postscript, file }) => ({ family, postscript, file })),
    dark: nativeTheme.shouldUseDarkColors,
    version: app.getVersion(),
    platform: process.platform,
  };
}
function broadcast() {
  if (!store) return;
  const value = state();
  for (const win of [mainWindow, settingsWindow])
    if (win && !win.isDestroyed()) win.webContents.send('inkline:state', value);
  if (mainWindow && !mainWindow.isDestroyed()) {
    const d = store.docs.get(store.active);
    mainWindow.setTitle((d ? store.snapshot(d).title : 'Inkline') + ' — Inkline');
    mainWindow.setDocumentEdited?.(
      [...store.docs.values()].some((d) => d.source !== d.savedSource),
    );
  }
}
function applyAppearance() {
  nativeTheme.themeSource = store.settings.appearance;
  broadcast();
}
function trusted(event, settings = true) {
  const url = event.senderFrame?.url;
  return (
    !!url &&
    (url === 'inkline://app/index.html' || (settings && url === 'inkline://app/settings.html')) &&
    (event.sender === mainWindow?.webContents || event.sender === settingsWindow?.webContents)
  );
}
function rpc(action, args = {}) {
  return new Promise((resolve, reject) => {
    if (!mainWindow || mainWindow.isDestroyed()) {
      reject(Error('The editor window is closed.'));
      return;
    }
    const id = randomUUID();
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(Error('The editor did not respond.'));
    }, 15000);
    pending.set(id, { resolve, reject, timer });
    mainWindow.webContents.send('inkline:request', { id, action, args });
  });
}
async function sync() {
  if (!mainWindow || mainWindow.isDestroyed()) return;
  const snapshots = await rpc('snapshot');
  for (const value of snapshots)
    if (store.docs.has(value.documentId))
      store.update(value.documentId, value.source, value.selection);
}
async function replace(doc, source) {
  await rpc('replace', { documentId: doc.id, expectedSource: doc.source, source });
  store.update(doc.id, source);
  broadcast();
}
function previewURL(doc) {
  const root = store.projectFor(doc) || (doc.path ? path.dirname(doc.path) : null);
  const relative = doc.path && root ? path.relative(root, doc.path) : 'index.html';
  return (
    'inkline://preview/' +
    doc.id +
    '/' +
    relative.split(path.sep).map(encodeURIComponent).join('/') +
    '?revision=' +
    revision(doc)
  );
}
async function initializeProtocol() {
  protocol.handle('inkline', async (request) => {
    try {
      const url = new URL(request.url);
      let file,
        body,
        type,
        csp = staticCSP;
      if (url.hostname === 'app') {
        if (url.pathname.startsWith('/fonts/')) {
          const name = decodeURIComponent(url.pathname.slice(7));
          const font = fonts.find((f) => f.file === name);
          if (!font) throw Error('Unknown font.');
          file = path.join(store.userData, 'Fonts', font.file);
        } else {
          file = path.resolve(renderer, decodeURIComponent(url.pathname).slice(1));
          if (!inside(file, renderer)) throw Error('Invalid resource.');
        }
      } else if (url.hostname === 'asset') {
        const id = url.pathname.split('/')[1];
        file = await store.asset(id, url.searchParams.get('path'));
        if (
          !['.png', '.jpg', '.jpeg', '.gif', '.svg', '.webp', '.avif', '.bmp'].includes(
            path.extname(file).toLowerCase(),
          )
        )
          throw Error('Unsupported image type.');
      } else if (url.hostname === 'preview') {
        const parts = url.pathname.split('/').slice(1).map(decodeURIComponent),
          doc = store.get(parts.shift());
        const root = store.projectFor(doc) || (doc.path ? path.dirname(doc.path) : null);
        const relative = parts.join('/'),
          own =
            doc.path && root
              ? path.relative(root, doc.path).split(path.sep).join('/')
              : 'index.html';
        csp = documentCSP;
        if (relative === own) {
          body = Buffer.from(doc.source, 'utf8');
          type = 'text/html';
        } else file = await store.asset(doc.id, relative, true);
        if (
          file &&
          ![
            '.css',
            '.png',
            '.jpg',
            '.jpeg',
            '.gif',
            '.svg',
            '.webp',
            '.avif',
            '.bmp',
            '.ttf',
            '.otf',
            '.woff',
            '.woff2',
          ].includes(path.extname(file).toLowerCase())
        )
          throw Error('Unsupported preview asset.');
      } else throw Error('Unknown resource.');
      if (file) {
        type = mime[path.extname(file).toLowerCase()] || 'application/octet-stream';
        body = await fs.readFile(file);
      }
      return new Response(body, {
        headers: {
          'Content-Type': type,
          'Content-Security-Policy': csp,
          'X-Content-Type-Options': 'nosniff',
          'Cache-Control': 'no-store',
        },
      });
    } catch {
      return new Response('Resource unavailable', {
        status: 404,
        headers: { 'Content-Type': 'text/plain' },
      });
    }
  });
}
function secureWindow(options = {}) {
  const win = new BrowserWindow({
    icon: path.join(renderer, 'icon.png'),
    ...options,
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true,
      webviewTag: false,
      ...options.webPreferences,
    },
  });
  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  win.webContents.on('will-frame-navigate', (event) => {
    if (
      event.url.startsWith('inkline://') ||
      event.url === 'about:srcdoc' ||
      event.url === 'about:blank'
    )
      return;
    event.preventDefault();
    if (/^https?:|^mailto:/i.test(event.url)) shell.openExternal(event.url).catch(() => {});
  });
  win.webContents.session.setPermissionRequestHandler((_wc, _permission, callback) =>
    callback(false),
  );
  return win;
}
function command(name) {
  mainWindow?.webContents.send('inkline:command', name);
}
function makeMenu() {
  const cmd = process.platform === 'darwin' ? 'Command' : 'Control';
  const item = (label, name, accelerator) => ({ label, accelerator, click: () => command(name) });
  const menus = [
    {
      label: 'File',
      submenu: [
        item('New Markdown', 'new-markdown', cmd + '+N'),
        item('New LaTeX', 'new-latex', cmd + '+Alt+N'),
        item('New HTML', 'new-html'),
        item('New from Example', 'example'),
        { type: 'separator' },
        item('Open…', 'open', cmd + '+O'),
        item('Open Project Folder…', 'project', cmd + '+Alt+O'),
        item('Close Project', 'close-project'),
        { type: 'separator' },
        item('Save', 'save', cmd + '+S'),
        item('Save As…', 'save-as', cmd + '+Shift+S'),
        item('Export PDF…', 'export', cmd + '+Shift+E'),
        { type: 'separator' },
        item('Close Document', 'close', cmd + '+W'),
        { role: 'quit' },
      ],
    },
    {
      label: 'Edit',
      submenu: [
        item('Undo', 'undo', cmd + '+Z'),
        item('Redo', 'redo', cmd + '+Shift+Z'),
        item('Redo (alternate)', 'redo', cmd + '+Y'),
        { type: 'separator' },
        { role: 'cut' },
        { role: 'copy' },
        { role: 'paste' },
        { role: 'selectAll' },
        item('Find…', 'find', cmd + '+F'),
      ],
    },
    {
      label: 'Format',
      submenu: [
        item('Heading', 'heading', cmd + '+Shift+H'),
        item('Bold', 'bold', cmd + '+B'),
        item('Italic', 'italic', cmd + '+I'),
        item('Link', 'link', cmd + '+K'),
        { label: 'Source and Preview Fonts…', click: showSettings },
      ],
    },
    {
      label: 'Insert',
      submenu: [item('Table…', 'table', cmd + '+Alt+T'), item('Figure…', 'figure', cmd + '+Alt+I')],
    },
    {
      label: 'View',
      submenu: [
        item('Source', 'source', cmd + '+1'),
        item('Split', 'split', cmd + '+2'),
        item('Preview', 'preview', cmd + '+3'),
        { type: 'separator' },
        item('Recompile LaTeX', 'compile', cmd + '+Enter'),
        item('Recompile LaTeX (alternate)', 'compile', cmd + '+Shift+R'),
        item('Compile Log…', 'log'),
        { role: 'togglefullscreen' },
      ],
    },
    {
      label: 'Settings',
      submenu: [
        { label: 'Settings…', accelerator: cmd + '+,', click: showSettings },
        {
          label: 'MCP Connection Details',
          click: () =>
            dialog.showMessageBox(mainWindow, {
              type: 'info',
              title: 'Inkline MCP',
              message: 'Inkline MCP',
              detail:
                'Use this executable with the mcp subcommand and explicit read/write folder roots. MCP access is ' +
                (store.settings.mcpEnabled ? 'enabled.' : 'paused.') +
                '\n\n' +
                (app.isPackaged
                  ? path.join(path.dirname(process.execPath), 'Inkline-MCP.exe')
                  : 'npm run mcp --') +
                ' mcp\n\nSee the Windows README for configuration.',
            }),
        },
      ],
    },
  ];
  if (process.platform === 'darwin')
    menus.unshift({
      label: 'Inkline',
      submenu: [
        { role: 'about' },
        { label: 'Settings…', accelerator: 'Command+,', click: showSettings },
        { type: 'separator' },
        { role: 'quit' },
      ],
    });
  Menu.setApplicationMenu(Menu.buildFromTemplate(menus));
}
function showSettings() {
  if (settingsWindow && !settingsWindow.isDestroyed()) {
    settingsWindow.show();
    settingsWindow.focus();
    return;
  }
  settingsWindow = secureWindow({
    width: 820,
    height: 760,
    minWidth: 740,
    minHeight: 620,
    title: 'Inkline Settings',
    parent: mainWindow,
    resizable: true,
    autoHideMenuBar: true,
    show: false,
  });
  settingsWindow.loadURL('inkline://app/settings.html');
  settingsWindow.once('ready-to-show', () => settingsWindow.show());
  settingsWindow.on('closed', () => {
    settingsWindow = null;
  });
}
async function loadFonts() {
  fonts = [];
  const directory = path.join(store.userData, 'Fonts');
  await fs.mkdir(directory, { recursive: true });
  const fontkit = await import('fontkit');
  for (const file of await fs.readdir(directory))
    if (/^[a-f0-9]{64}\.(ttf|otf)$/.test(file)) {
      try {
        const font = fontkit.create(await fs.readFile(path.join(directory, file)));
        if (font.familyName)
          fonts.push({ family: font.familyName, postscript: font.postscriptName, file });
      } catch {}
    }
}
async function importFonts(files) {
  const fontkit = await import('fontkit');
  for (const file of files) {
    if (!/\.(ttf|otf)$/i.test(file)) throw Error('Choose .ttf or .otf font files.');
    const data = await fs.readFile(file);
    const font = fontkit.create(data);
    if (!font.familyName) throw Error('This font has no readable family name.');
    const name = digest(data) + path.extname(file).toLowerCase();
    await atomicWrite(path.join(store.userData, 'Fonts', name), data);
  }
  await loadFonts();
  broadcast();
  return fonts;
}
const filters = [{ name: 'Inkline documents', extensions: Object.values(extensions).flat() }];
async function openDialog() {
  const picked = await dialog.showOpenDialog(mainWindow, {
    properties: ['openFile', 'multiSelections'],
    filters,
  });
  for (const file of picked.filePaths) await store.open(file);
  broadcast();
}
async function chooseSave(doc, as = false) {
  if (doc.path && !as) {
    await store.save(doc.id);
    broadcast();
    return true;
  }
  const picked = await dialog.showSaveDialog(mainWindow, {
    defaultPath:
      doc.path ||
      path.join(
        store.projectRoot || app.getPath('documents'),
        'Untitled.' + extensions[doc.format][0],
      ),
    filters: [{ name: doc.format, extensions: extensions[doc.format] }],
  });
  if (picked.canceled) return false;
  await store.save(doc.id, picked.filePath, true);
  broadcast();
  return true;
}
async function confirmClose(doc) {
  if (doc.source === doc.savedSource) return true;
  const answer = await dialog.showMessageBox(mainWindow, {
    type: 'question',
    buttons: ['Save', 'Discard', 'Cancel'],
    defaultId: 0,
    cancelId: 2,
    message: 'Save changes to ' + store.snapshot(doc).title + '?',
  });
  if (answer.response === 2) return false;
  if (answer.response === 0) return chooseSave(doc);
  doc.savedSource = doc.source;
  return true;
}
async function compile(doc) {
  if (doc.format !== 'latex') throw Error('Only LaTeX documents can be compiled.');
  const key = revision(doc) + '\0' + doc.engine + '\0' + store.projectFor(doc) + '\0' + doc.path;
  const publish = (result) => {
    mainWindow?.webContents.send('inkline:compiled', {
      documentId: doc.id,
      pdf: result.pdf.toString('base64'),
      log: result.log,
      revision: key.split('\0')[0],
    });
    return result;
  };
  if (doc.compiled?.key === key) return publish(doc.compiled);
  if (compiling.has(doc.id)) throw Error('This document is already compiling.');
  const task = compileLatex({
    source: doc.source,
    file: doc.path,
    projectRoot: store.projectFor(doc),
    engine: doc.engine,
  });
  compiling.set(doc.id, task);
  try {
    const result = await task;
    doc.compiled = { ...result, key, revision: key.split('\0')[0] };
    return publish(doc.compiled);
  } finally {
    compiling.delete(doc.id);
  }
}
async function exportPDF(doc, file, overwrite = false, expected = revision(doc)) {
  file = await canonical(file, true);
  if (path.extname(file).toLowerCase() !== '.pdf') throw Error('Use a .pdf filename.');
  if ([...store.docs.values()].some((d) => d.path === file))
    throw Error('The export destination is open in Inkline.');
  try {
    await fs.access(file);
    if (!overwrite) throw Error('The PDF already exists. Explicitly allow overwrite.');
  } catch (e) {
    if (e.code !== 'ENOENT') throw e;
  }
  let data;
  if (doc.format === 'latex') {
    const result = await compile(doc);
    store.check(doc, expected);
    data = result.pdf;
  } else {
    const win = secureWindow({
      width: 794,
      height: 1123,
      show: false,
      webPreferences: { preload: undefined, javascript: false },
    });
    try {
      if (doc.format === 'html') await win.loadURL(previewURL(doc));
      else {
        const html = await rpc('exportHTML', { documentId: doc.id });
        await win.loadURL('data:text/html;charset=utf-8,' + encodeURIComponent(html));
      }
      await win.webContents
        .executeJavaScript(
          'Promise.race([Promise.allSettled([document.fonts.ready, ...Array.from(document.images, i => i.decode())]), new Promise(r => setTimeout(r, 6000))])',
        )
        .catch(() => {});
      data = await win.webContents.printToPDF({
        pageSize: 'A4',
        printBackground: true,
        preferCSSPageSize: true,
        margins: { top: 0.4, bottom: 0.4, left: 0.45, right: 0.45 },
      });
      store.check(doc, expected);
    } finally {
      win.destroy();
    }
  }
  await atomicWrite(file, data, overwrite);
  return file;
}
async function invoke(method, a = {}) {
  if (method === 'state') return state();
  if (method === 'settings') {
    await store.setSettings(a);
    applyAppearance();
    return state();
  }
  if (method === 'settings-window') {
    showSettings();
    return;
  }
  if (method === 'import-fonts') {
    const picked = await dialog.showOpenDialog(settingsWindow || mainWindow, {
      properties: ['openFile', 'multiSelections'],
      filters: [{ name: 'Fonts', extensions: ['ttf', 'otf'] }],
    });
    if (!picked.canceled) await importFonts(picked.filePaths);
    return state();
  }
  if (method === 'project-tree') return store.tree(a.folder);
  if (method === 'preview-url') return previewURL(store.get(a.documentId));
  if (method === 'external') {
    if (!/^(https?:|mailto:)/i.test(a.url)) throw Error('Unsupported link.');
    await shell.openExternal(a.url);
    return;
  }
  if (method === 'error') {
    await dialog.showMessageBox(mainWindow, {
      type: 'error',
      message: 'Inkline',
      detail: String(a.message),
    });
    return;
  }
  if (method === 'project') {
    if (a.close) await store.project(null);
    else {
      const picked = await dialog.showOpenDialog(mainWindow, { properties: ['openDirectory'] });
      if (!picked.canceled) await store.project(picked.filePaths[0]);
    }
    return state();
  }
  await sync();
  let doc = a.documentId ? store.get(a.documentId) : store.docs.get(store.active);
  switch (method) {
    case 'new':
      store.create(a.format, a.source);
      break;
    case 'example': {
      const file = app.isPackaged
        ? path.join(process.resourcesPath, 'Welcome.md')
        : path.join(appRoot, '..', 'Resources', 'Welcome.md');
      store.create('markdown', await fs.readFile(file, 'utf8'));
      break;
    }
    case 'open':
      if (a.path) await store.open(a.path);
      else await openDialog();
      break;
    case 'open-link':
      await store.open(await store.asset(a.documentId, a.path));
      break;
    case 'active':
      store.active = store.get(a.documentId).id;
      break;
    case 'close':
      if (doc && (await confirmClose(doc))) store.close(doc.id);
      break;
    case 'save':
      return { saved: doc ? await chooseSave(doc, a.as === true) : false };
    case 'format':
      if (!Object.hasOwn(extensions, a.format)) throw Error('Unknown document format.');
      if (doc.format !== a.format) {
        if (doc.path) store.create(a.format, doc.source);
        else {
          doc.format = a.format;
          if (!doc.source) doc.source = starters[a.format];
          doc.compiled = null;
        }
      }
      break;
    case 'view':
      if (!['source', 'split', 'preview'].includes(a.view)) throw Error('Unknown view.');
      doc.view = a.view;
      break;
    case 'engine':
      if (!['pdflatex', 'xelatex'].includes(a.engine)) throw Error('Unknown TeX engine.');
      doc.engine = a.engine;
      break;
    case 'compile': {
      try {
        const result = await compile(doc);
        return {
          success: true,
          pdf: result.pdf.toString('base64'),
          log: result.log,
          revision: result.key.split('\0')[0],
        };
      } catch (e) {
        return { success: false, message: e.message, log: e.log || e.message };
      }
    }
    case 'export': {
      const picked = await dialog.showSaveDialog(mainWindow, {
        defaultPath: doc.path ? doc.path.replace(/\.[^.]+$/, '.pdf') : 'Untitled.pdf',
        filters: [{ name: 'PDF', extensions: ['pdf'] }],
      });
      if (!picked.canceled) await exportPDF(doc, picked.filePath, true);
      return { exported: !picked.canceled };
    }
    case 'figure': {
      const base = doc.path ? path.dirname(doc.path) : store.projectFor(doc);
      if (!base) throw Error('Save the document or open a project before inserting figures.');
      const picked = await dialog.showOpenDialog(mainWindow, {
        defaultPath: base,
        properties: ['openFile'],
        filters: [
          {
            name: 'Images',
            extensions:
              doc.format === 'latex'
                ? ['png', 'jpg', 'jpeg', 'pdf']
                : ['png', 'jpg', 'jpeg', 'gif', 'svg', 'webp', 'avif', 'bmp'],
          },
        ],
      });
      if (picked.canceled) return null;
      const file = await canonical(picked.filePaths[0]),
        root = store.projectFor(doc) || base;
      if (!inside(file, root))
        throw Error('Choose a figure inside the document or project folder.');
      return path.relative(base, file).split(path.sep).join('/');
    }
    default:
      throw Error('Unknown editor command.');
  }
  broadcast();
  return state();
}
async function startGUI() {
  store = new Documents({ userData: app.getPath('userData'), changed: broadcast });
  await store.init();
  await loadFonts();
  applyAppearance();
  await initializeProtocol();
  ipcMain.handle('inkline:call', (event, method, args) => {
    if (!trusted(event)) throw Error('Untrusted caller.');
    if (
      event.sender === settingsWindow?.webContents &&
      !['state', 'settings', 'import-fonts', 'external'].includes(method)
    )
      throw Error('This command is not available from Settings.');
    return invoke(method, args);
  });
  ipcMain.on('inkline:change', (event, value) => {
    if (!trusted(event, false)) return;
    try {
      store.update(value.documentId, value.source, value.selection);
    } catch {}
  });
  ipcMain.on('inkline:reply', (event, value) => {
    if (!trusted(event, false)) return;
    const p = pending.get(value.id);
    if (!p) return;
    clearTimeout(p.timer);
    pending.delete(value.id);
    value.error ? p.reject(Error(value.error)) : p.resolve(value.value);
  });
  mainWindow = secureWindow({
    width: 1280,
    height: 840,
    minWidth: 900,
    minHeight: 540,
    title: 'Inkline',
    backgroundColor: '#f7f5fb',
    show: false,
  });
  mainWindow.on('close', (event) => {
    if (forceClose) return;
    event.preventDefault();
    sync()
      .then(async () => {
        for (const doc of store.docs.values()) if (!(await confirmClose(doc))) return;
        forceClose = true;
        settingsWindow?.destroy();
        mainWindow.close();
      })
      .catch((e) => dialog.showErrorBox('Could not close Inkline', e.message));
  });
  makeMenu();
  nativeTheme.on('updated', broadcast);
  const files = argv.filter(
    (a) =>
      path.isAbsolute(a) &&
      Object.values(extensions).flat().includes(path.extname(a).slice(1).toLowerCase()),
  );
  for (const file of files) await store.open(file);
  if (!store.docs.size) store.create();
  await mainWindow.loadURL('inkline://app/index.html');
  mainWindow.show();
  const pipe = mcp.pipeName(
    app.isPackaged ? path.dirname(process.execPath) : appRoot,
    app.getPath('userData'),
  );
  if (process.platform !== 'win32') await fs.rm(pipe, { force: true });
  server = await mcp.startBridge({
    pipe,
    token: await mcp.getToken(store.userData),
    handle: (input) =>
      mcp.handleAutomation(input, { store, sync, replace, compile, exportPDF, show: broadcast }),
  });
}
if (helperAt >= 0 && process.platform === 'win32') {
  process.stderr.write(
    'Use Inkline-MCP.exe for the Windows MCP connection. See Windows/README.md.\n',
  );
  app.exit(2);
} else if (helperAt >= 0) {
  app
    .whenReady()
    .then(() =>
      mcp.runHelper({
        app,
        args: argv.slice(helperAt + 1),
        pipe: mcp.pipeName(
          app.isPackaged ? path.dirname(process.execPath) : appRoot,
          app.getPath('userData'),
        ),
        userData: app.getPath('userData'),
        appPath: appRoot,
      }),
    )
    .catch((e) => {
      process.stderr.write('Inkline MCP: ' + e.message + '\n');
      app.exit(1);
    });
} else if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', async (_event, commandLine) => {
    mainWindow?.show();
    mainWindow?.focus();
    for (const file of commandLine.filter(
      (a) =>
        path.isAbsolute(a) &&
        Object.values(extensions).flat().includes(path.extname(a).slice(1).toLowerCase()),
    ))
      await store?.open(file).catch(() => {});
    broadcast();
  });
  app
    .whenReady()
    .then(startGUI)
    .catch((e) => {
      dialog.showErrorBox('Inkline could not start', e.stack || e.message);
      app.exit(1);
    });
  app.on('window-all-closed', () => app.quit());
  app.on('will-quit', () => {
    store?.dispose();
    server?.close();
  });
}
module.exports = { getStore: () => store, invoke, exportPDF, importFonts, previewURL };
