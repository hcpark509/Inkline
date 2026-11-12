import { EditorState, Compartment, Transaction } from '@codemirror/state';
import {
  EditorView,
  keymap,
  lineNumbers,
  highlightActiveLine,
  highlightActiveLineGutter,
  drawSelection,
  dropCursor,
  rectangularSelection,
} from '@codemirror/view';
import {
  history,
  historyKeymap,
  defaultKeymap,
  indentWithTab,
  undo,
  redo,
  isolateHistory,
} from '@codemirror/commands';
import { searchKeymap, openSearchPanel, highlightSelectionMatches } from '@codemirror/search';
import {
  syntaxHighlighting,
  HighlightStyle,
  StreamLanguage,
  bracketMatching,
  foldGutter,
  foldKeymap,
} from '@codemirror/language';
import { markdown } from '@codemirror/lang-markdown';
import { html } from '@codemirror/lang-html';
import { stex } from '@codemirror/legacy-modes/mode/stex';
import { tags } from '@lezer/highlight';
import * as pdfjs from 'pdfjs-dist';
import shared from '../src/shared.cjs';
import { markdownHTML, fontRules, cssString } from './preview.mjs';
const { colors, tableSource, htmlEscape, latexEscape } = shared;
pdfjs.GlobalWorkerOptions.workerSrc = 'inkline://app/pdf.worker.min.mjs';
const api = window.inkline,
  $ = (selector) => document.querySelector(selector);
let current,
  active = null,
  view,
  renderTimer,
  compileLog = '',
  compileBusy = false,
  pdfGeneration = 0;
const records = new Map();
const language = new Compartment(),
  appearance = new Compartment(),
  numbers = new Compartment();
const localFonts = document.createElement('style');
document.head.append(localFonts);
function error(e) {
  $('#errorMessage').textContent = e.message || String(e);
  if (!$('#errorDialog').open) $('#errorDialog').showModal();
}
function record() {
  return records.get(active);
}
function textOf(r) {
  return r?.state.sliceDoc() || '';
}
function sourceSelection(state) {
  const selection = state.selection.main;
  const offset = (position) =>
    position + (state.doc.lineAt(position).number - 1) * (state.lineBreak.length - 1);
  return {
    utf16_location: offset(selection.from),
    utf16_length: offset(selection.to) - offset(selection.from),
  };
}
function docFor(r) {
  return { ...r.meta, source: textOf(r) };
}
function languageFor(format) {
  return format === 'latex'
    ? StreamLanguage.define(stex)
    : format === 'html'
      ? html()
      : markdown({ htmlTagLanguage: html() });
}
function editorAppearance() {
  const c = colors(current.settings.theme, current.dark);
  return [
    EditorView.theme(
      {
        '&': {
          backgroundColor: c.source,
          color: c.ink,
          fontSize: current.settings.sourceFontSize + 'px',
        },
        '.cm-scroller': {
          fontFamily: cssString(current.settings.sourceFont) + ', Consolas, monospace',
          lineHeight: (
            1.4 +
            current.settings.lineSpacing / current.settings.sourceFontSize
          ).toFixed(3),
        },
        '.cm-content': { caretColor: c.purple },
        '.cm-cursor': { borderLeftColor: c.purple },
        '.cm-gutters': {
          backgroundColor: c.source,
          color: c.muted,
          borderRight: '1px solid ' + c.line,
        },
        '.cm-activeLineGutter': { backgroundColor: c.lavender },
        '.cm-activeLine': { backgroundColor: current.dark ? '#ffffff05' : '#00000003' },
        '&.cm-focused .cm-selectionBackground, .cm-selectionBackground, ::selection': {
          backgroundColor: c.lavender,
        },
        '.cm-panels': { backgroundColor: c.chrome, color: c.ink },
        '.cm-searchMatch': { backgroundColor: c.lavender, outline: '1px solid ' + c.purple },
      },
      { dark: current.dark },
    ),
    syntaxHighlighting(
      HighlightStyle.define([
        {
          tag: [tags.heading, tags.processingInstruction, tags.keyword],
          color: c.purple,
          fontWeight: '600',
        },
        { tag: [tags.link, tags.url, tags.attributeName], color: c.teal },
        { tag: [tags.monospace, tags.string, tags.special(tags.string)], color: c.orange },
        { tag: [tags.strong, tags.list, tags.tagName], color: c.blue },
        { tag: [tags.emphasis, tags.quote], color: c.rose },
        { tag: [tags.comment, tags.meta], color: c.muted },
      ]),
    ),
  ];
}
function createState(doc) {
  return EditorState.create({
    doc: doc.source,
    extensions: [
      EditorState.lineSeparator.of(doc.line_separator || '\n'),
      EditorView.contentAttributes.of({ 'aria-label': 'Source editor' }),
      history(),
      drawSelection(),
      dropCursor(),
      rectangularSelection(),
      highlightActiveLine(),
      highlightSelectionMatches(),
      highlightActiveLineGutter(),
      foldGutter(),
      bracketMatching(),
      EditorView.lineWrapping,
      language.of(languageFor(doc.format)),
      numbers.of(current.settings.showLineNumbers ? lineNumbers() : []),
      appearance.of(editorAppearance()),
      keymap.of([
        {
          key: 'Mod-Enter',
          run: () => {
            run('compile');
            return true;
          },
        },
        {
          key: 'Mod-Alt-t',
          run: () => {
            run('table');
            return true;
          },
        },
        ...defaultKeymap,
        ...historyKeymap,
        ...searchKeymap,
        ...foldKeymap,
        indentWithTab,
      ]),
      EditorView.updateListener.of((update) => {
        const r = record();
        if (!r || update.view !== view) return;
        r.state = update.state;
        if (update.docChanged || update.selectionSet) {
          const selection = update.state.selection.main;
          api.change({
            documentId: active,
            source: update.state.sliceDoc(),
            selection: sourceSelection(update.state),
          });
          updateFooter();
        }
        if (update.docChanged) {
          renderTabs();
          clearTimeout(renderTimer);
          renderTimer = setTimeout(renderPreview, 110);
          if (r.meta.format === 'latex')
            $('#notice').textContent = 'PDF out of date — press Ctrl+Enter to recompile';
        }
      }),
    ],
  });
}
function renderTabs() {
  const tabs = $('#tabs');
  tabs.replaceChildren(
    ...[...records.values()].map((r) => {
      const row = document.createElement('div');
      row.className = 'tab' + (r.meta.document_id === active ? ' active' : '');
      const title = document.createElement('button');
      title.className = 'title';
      title.textContent = (textOf(r) !== r.cleanSource ? '● ' : '') + r.meta.title;
      title.title = r.meta.path || 'Untitled';
      title.onclick = () => run('activate', r.meta.document_id);
      const close = document.createElement('button');
      close.className = 'close';
      close.textContent = '×';
      close.setAttribute('aria-label', 'Close ' + r.meta.title);
      close.onclick = () => call('close', { documentId: r.meta.document_id });
      row.append(title, close);
      return row;
    }),
  );
}
function receiveState(state) {
  current = state;
  for (const [name, value] of Object.entries(colors(state.settings.theme, state.dark)))
    document.documentElement.style.setProperty('--' + name, value);
  document.documentElement.style.colorScheme = state.dark ? 'dark' : 'light';
  localFonts.textContent = fontRules(state.fonts);
  for (const doc of state.documents) {
    let r = records.get(doc.document_id);
    if (!r) {
      r = { meta: doc, cleanSource: doc.modified ? '' : doc.source };
      r.state = createState(doc);
      records.set(doc.document_id, r);
    } else {
      if (!doc.modified && doc.source === textOf(r)) r.cleanSource = doc.source;
      const changedFormat = r.meta.format !== doc.format;
      r.meta = doc;
      if (changedFormat) {
        r.state = createState(doc);
        if (active === doc.document_id) view.setState(r.state);
      }
    }
  }
  for (const id of records.keys())
    if (!state.documents.some((d) => d.document_id === id)) records.delete(id);
  active =
    state.active && records.has(state.active) ? state.active : records.keys().next().value || null;
  if (!active) {
    const state = EditorState.create({ doc: '' });
    if (view) view.setState(state);
    renderTabs();
    return;
  }
  const r = record();
  if (!view) {
    view = new EditorView({ state: r.state, parent: $('#editor') });
  } else if (view.state !== r.state) view.setState(r.state);
  for (const value of records.values()) {
    const effects = [
      appearance.reconfigure(editorAppearance()),
      numbers.reconfigure(state.settings.showLineNumbers ? lineNumbers() : []),
      language.reconfigure(languageFor(value.meta.format)),
    ];
    if (value === r) view.dispatch({ effects });
    else value.state = value.state.update({ effects }).state;
  }
  $('#format').value = r.meta.format;
  $('#engine').value = r.meta.engine;
  $('#documentArea').dataset.view = r.meta.view;
  for (const button of document.querySelectorAll('.segmented button'))
    button.classList.toggle('selected', button.dataset.command === r.meta.view);
  $('#project').hidden = !state.projectRoot;
  $('#projectName').textContent =
    state.projectRoot?.split(/[\\/]/).filter(Boolean).pop() || 'Project';
  $('#projectName').title = state.projectRoot || '';
  if (state.projectRoot !== $('#projectFiles').dataset.root) {
    $('#projectFiles').dataset.root = state.projectRoot || '';
    refreshProject();
  }
  renderTabs();
  updateFooter();
  renderPreview();
}
function updateFooter() {
  const r = record();
  if (!r || !view) return;
  const text = view.state.doc.toString(),
    selection = view.state.selection.main,
    line = view.state.doc.lineAt(selection.head);
  $('#documentStatus').textContent =
    r.meta.format === 'latex' ? 'LaTeX' : r.meta.format === 'html' ? 'HTML' : 'Markdown';
  $('#counts').textContent = (text.match(/\S+/gu) || []).length + ' words';
  $('#position').textContent =
    `Ln ${line.number}, Col ${Array.from(text.slice(line.from, selection.head)).length + 1}`;
  $('#saveStatus').textContent = current.settings.autosaveEnabled
    ? r.meta.save_error
      ? 'Autosave failed'
      : 'Autosave on'
    : 'Manual save';
  $('#saveStatus').title = r.meta.save_error || '';
}
async function renderPreview() {
  const r = record();
  if (!r) return;
  const latex = r.meta.format === 'latex';
  $('#preview').hidden = latex;
  $('#latexPreview').hidden = !latex;
  $('#liveStatus').hidden = latex;
  $('#latexTools').hidden = !latex;
  if (latex) {
    const key = r.pdf ? active + ':' + r.pdfRevision : null;
    if (key !== $('#latexPreview').dataset.pdf) {
      $('#latexPreview').dataset.pdf = key || '';
      if (r.pdf) renderPDF(r.pdf).catch(error);
      else
        $('#latexPreview').innerHTML =
          '<div class="empty"><h1>LaTeX PDF preview</h1><p>Press Ctrl+Enter to compile your document.</p></div>';
    }
    return;
  }
  if (r.meta.view === 'source') return;
  if (r.meta.format === 'html') {
    const url = await api.call('preview-url', { documentId: active });
    if (active !== r.meta.document_id) return;
    $('#preview').removeAttribute('srcdoc');
    $('#preview').src = url;
  } else {
    $('#preview').removeAttribute('src');
    $('#preview').srcdoc = markdownHTML(docFor(r), current);
  }
}
$('#preview').addEventListener('load', () => {
  try {
    $('#preview').contentDocument?.addEventListener('click', (event) => {
      const link = event.target.closest('a');
      if (!link) return;
      const href = link.getAttribute('href');
      if (href?.startsWith('#')) {
        event.preventDefault();
        let id = href.slice(1);
        try {
          id = decodeURIComponent(id);
        } catch {}
        $('#preview').contentDocument.getElementById(id)?.scrollIntoView();
        return;
      }
      event.preventDefault();
      if (/^https?:|^mailto:/i.test(href)) call('external', { url: href });
      else if (href?.startsWith('inkline://link/')) {
        call('open-link', { documentId: active, path: new URL(href).searchParams.get('path') });
      }
    });
  } catch {}
});
async function call(method, args = {}) {
  try {
    return await api.call(method, args);
  } catch (e) {
    error(e);
    return null;
  }
}
async function run(command, id) {
  try {
    const r = record();
    switch (command) {
      case 'new-markdown':
      case 'new-latex':
      case 'new-html':
        await api.call('new', { format: command.slice(4) });
        break;
      case 'activate':
        await api.call('active', { documentId: id });
        break;
      case 'open':
      case 'example':
      case 'close':
        await api.call(command, { documentId: active });
        break;
      case 'save':
      case 'save-as': {
        const result = await api.call('save', { documentId: active, as: command === 'save-as' });
        $('#notice').textContent = result.saved ? 'Saved' : '';
        break;
      }
      case 'project':
        await api.call('project');
        break;
      case 'close-project':
        await api.call('project', { close: true });
        break;
      case 'settings':
        await api.call('settings-window');
        break;
      case 'source':
      case 'split':
      case 'preview':
        await api.call('view', { documentId: active, view: command });
        break;
      case 'find':
        openSearchPanel(view);
        break;
      case 'undo':
        undo(view);
        break;
      case 'redo':
        redo(view);
        break;
      case 'heading':
      case 'bold':
      case 'italic':
      case 'link':
        formatSelection(command);
        break;
      case 'table':
        openTable();
        break;
      case 'figure': {
        const relative = await api.call('figure', { documentId: active });
        if (relative) {
          let source;
          if (r.meta.format === 'latex') {
            if (/[{}]/.test(relative)) throw Error('LaTeX figure paths cannot contain braces.');
            source = '\\includegraphics[width=\\linewidth]{\\detokenize{' + relative + '}}';
          } else if (r.meta.format === 'html')
            source = `<img src="${htmlEscape(relative)}" alt="Figure">`;
          else
            source =
              '![Figure](' +
              relative
                .split('/')
                .map((p) =>
                  encodeURIComponent(p).replace(/[()]/g, (c) => '%' + c.charCodeAt(0).toString(16)),
                )
                .join('/') +
              ')';
          insert('\n\n' + source + '\n');
        }
        break;
      }
      case 'compile':
        await compile();
        break;
      case 'export': {
        $('#notice').textContent = 'Exporting PDF…';
        const result = await api.call('export', { documentId: active });
        $('#notice').textContent = result.exported ? 'PDF export complete' : '';
        break;
      }
      case 'log':
        $('#compileLog').textContent = compileLog || 'Compile a LaTeX document to see its log.';
        $('#logDialog').showModal();
        break;
    }
  } catch (e) {
    $('#notice').textContent = e.message;
    error(e);
  }
}
function insert(text) {
  if (!view) return;
  view.focus();
  const at = view.state.selection.main.from;
  view.dispatch({
    changes: { from: at, insert: text },
    selection: { anchor: at + text.length },
    annotations: [Transaction.userEvent.of('input.insert'), isolateHistory.of('full')],
  });
}
function formatSelection(command) {
  if (!view) return;
  const r = record(),
    selection = view.state.selection.main;
  let before, after, placeholder;
  if (command === 'heading') {
    [before, after, placeholder] =
      r.meta.format === 'latex'
        ? ['\\section{', '}', 'Section title']
        : r.meta.format === 'html'
          ? ['<h1>', '</h1>', 'Heading']
          : ['# ', '', 'Heading'];
  } else if (command === 'bold') {
    [before, after, placeholder] =
      r.meta.format === 'latex'
        ? ['\\textbf{', '}', 'bold text']
        : r.meta.format === 'html'
          ? ['<strong>', '</strong>', 'bold text']
          : ['**', '**', 'bold text'];
  } else if (command === 'italic') {
    [before, after, placeholder] =
      r.meta.format === 'latex'
        ? ['\\textit{', '}', 'italic text']
        : r.meta.format === 'html'
          ? ['<em>', '</em>', 'italic text']
          : ['*', '*', 'italic text'];
  } else {
    if (r.meta.format === 'latex') return;
    [before, after, placeholder] =
      r.meta.format === 'html'
        ? ['<a href="https://example.com">', '</a>', 'link text']
        : ['[', '](https://example.com)', 'link text'];
  }
  const selected = view.state.sliceDoc(selection.from, selection.to) || placeholder;
  view.dispatch({
    changes: { from: selection.from, to: selection.to, insert: before + selected + after },
    selection: {
      anchor: selection.from + before.length,
      head: selection.from + before.length + selected.length,
    },
    annotations: Transaction.userEvent.of('input.format'),
  });
  view.focus();
}
async function compile() {
  const r = record();
  if (!r || r.meta.format !== 'latex' || compileBusy) return;
  compileBusy = true;
  $('#compileButton').disabled = true;
  $('#notice').textContent = 'Compiling…';
  const id = active;
  try {
    const result = await api.call('compile', { documentId: id });
    compileLog = result.log;
    if (!result.success) {
      $('#notice').textContent = result.message;
      throw Error(result.message);
    }
    if (id === active) $('#notice').textContent = 'Compiled';
  } finally {
    compileBusy = false;
    $('#compileButton').disabled = false;
  }
}
async function renderPDF(base64) {
  const generation = ++pdfGeneration;
  const bytes = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
  const loading = pdfjs.getDocument({
      data: bytes,
      isEvalSupported: false,
      standardFontDataUrl: 'inkline://app/standard_fonts/',
      cMapUrl: 'inkline://app/cmaps/',
      cMapPacked: true,
      wasmUrl: 'inkline://app/wasm/',
    }),
    pdf = await loading.promise;
  if (generation !== pdfGeneration) return;
  const target = $('#latexPreview');
  target.replaceChildren();
  for (let index = 1; index <= pdf.numPages; index++) {
    const page = await pdf.getPage(index),
      viewport = page.getViewport({ scale: 1.35 }),
      canvas = document.createElement('canvas');
    canvas.width = viewport.width;
    canvas.height = viewport.height;
    canvas.setAttribute('aria-label', 'PDF page ' + index);
    target.append(canvas);
    await page.render({ canvasContext: canvas.getContext('2d'), viewport }).promise;
  }
  await loading.destroy();
}
let tableValues = new Map(),
  tableFormat = 'markdown';
function tableData() {
  const rows = Math.min(100, Math.max(1, Number($('#tableRows').value) || 1)),
    cols = Math.min(20, Math.max(1, Number($('#tableColumns').value) || 1));
  $('#tableRows').value = rows;
  $('#tableColumns').value = cols;
  return Array.from({ length: rows }, (_, r) =>
    Array.from({ length: cols }, (_, c) => tableValues.get(r + ',' + c) || ''),
  );
}
function updateTableSource() {
  $('#tableSource').textContent = tableSource(tableFormat, tableData(), $('#tableHeader').checked);
}
function rebuildTable() {
  const data = tableData(),
    table = document.createElement('table'),
    head = document.createElement('thead'),
    headRow = document.createElement('tr');
  for (let c = 0; c < data[0].length; c++) {
    const th = document.createElement('th');
    th.textContent = 'Column ' + (c + 1);
    headRow.append(th);
  }
  head.append(headRow);
  table.append(head);
  const body = document.createElement('tbody');
  for (let r = 0; r < data.length; r++) {
    const tr = document.createElement('tr');
    for (let c = 0; c < data[r].length; c++) {
      const td = document.createElement('td'),
        input = document.createElement('input');
      input.value = data[r][c];
      input.setAttribute('aria-label', `Row ${r + 1}, column ${c + 1}`);
      input.addEventListener('input', () => {
        tableValues.set(r + ',' + c, input.value);
        updateTableSource();
      });
      td.append(input);
      tr.append(td);
    }
    body.append(tr);
  }
  table.append(body);
  $('#tableGrid').replaceChildren(table);
  updateTableSource();
}
function openTable() {
  tableValues = new Map();
  tableFormat = record().meta.format;
  $('#tableRows').value = 3;
  $('#tableColumns').value = 3;
  $('#tableHeader').checked = true;
  rebuildTable();
  $('#tableDialog').showModal();
  $('#tableGrid input')?.focus();
}
$('#tableRows').onchange = rebuildTable;
$('#tableColumns').onchange = rebuildTable;
$('#tableHeader').onchange = updateTableSource;
$('#cancelTable').onclick = () => $('#tableDialog').close();
$('#insertTable').onclick = () => {
  const source = tableSource(tableFormat, tableData(), $('#tableHeader').checked);
  $('#tableDialog').close();
  insert((view.state.selection.main.from ? '\n\n' : '') + source + '\n');
};
$('#closeLog').onclick = () => $('#logDialog').close();
$('#closeError').onclick = () => $('#errorDialog').close();
$('#format').onchange = () => call('format', { documentId: active, format: $('#format').value });
$('#engine').onchange = () => call('engine', { documentId: active, engine: $('#engine').value });
for (const button of document.querySelectorAll('[data-command]'))
  button.onclick = () => run(button.dataset.command);
$('#refreshProject').onclick = refreshProject;
async function refreshProject() {
  const root = current?.projectRoot,
    target = $('#projectFiles');
  target.replaceChildren();
  if (!root) return;
  try {
    await projectChildren(target, root);
  } catch (e) {
    target.textContent = e.message;
  }
}
async function projectChildren(parent, folder) {
  for (const entry of await api.call('project-tree', { folder })) {
    if (entry.directory) {
      const details = document.createElement('details'),
        summary = document.createElement('summary');
      summary.textContent = '▸ ' + entry.name;
      details.append(summary);
      let loaded = false;
      details.addEventListener('toggle', async () => {
        if (details.open && !loaded) {
          loaded = true;
          try {
            await projectChildren(details, entry.path);
          } catch (e) {
            details.append(document.createTextNode(e.message));
          }
        }
      });
      parent.append(details);
    } else {
      const button = document.createElement('button');
      button.textContent = entry.name;
      button.title = entry.path;
      button.disabled = !entry.supported;
      button.ondblclick = () => call('open', { path: entry.path });
      parent.append(button);
    }
  }
}
$('#divider').onpointerdown = (event) => {
  event.preventDefault();
  const bounds = $('#documentArea').getBoundingClientRect(),
    divider = $('#divider');
  divider.setPointerCapture(event.pointerId);
  divider.onpointermove = (e) =>
    $('#documentArea').style.setProperty(
      '--source-width',
      Math.max(280, Math.min(bounds.width - 285, e.clientX - bounds.left)) + 'px',
    );
  divider.onpointerup = () => {
    divider.onpointermove = null;
  };
};
api.onRequest(async (action, args) => {
  if (action === 'snapshot')
    return [...records.values()].map((r) => {
      const selection = r.state.selection.main;
      return {
        documentId: r.meta.document_id,
        source: textOf(r),
        selection: sourceSelection(r.state),
      };
    });
  const r = records.get(args.documentId);
  if (!r) throw Error('The document is not available in the editor.');
  if (action === 'replace') {
    if (textOf(r) !== args.expectedSource)
      throw Error('The document changed in the editor. Read it again before editing.');
    const transaction = {
      changes: { from: 0, to: r.state.doc.length, insert: args.source },
      annotations: [Transaction.userEvent.of('input.mcp'), isolateHistory.of('full')],
    };
    if (r.meta.document_id === active) view.dispatch(transaction);
    else r.state = r.state.update(transaction).state;
    return true;
  }
  if (action === 'exportHTML') return markdownHTML(docFor(r), current, true);
  throw Error('Unknown editor request.');
});
api.onCompiled((result) => {
  const r = records.get(result.documentId);
  if (!r) return;
  r.pdf = result.pdf;
  r.pdfRevision = result.revision;
  compileLog = result.log;
  if (active === result.documentId) {
    $('#latexPreview').dataset.pdf = active + ':' + result.revision;
    renderPDF(result.pdf).catch(error);
  }
});
api.onState(receiveState);
api.onCommand((command) => run(command));
receiveState(await api.call('state'));
view.focus();
