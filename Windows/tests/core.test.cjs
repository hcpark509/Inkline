'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const {
  Documents,
  Scope,
  canonical,
  inside,
  encode,
  decode,
  revision,
  atomicWrite,
} = require('../src/documents.cjs');
const { tableSource, validSettings, colors } = require('../src/shared.cjs');
const { handleAutomation, validate, tools, startBridge, bridgeRequest } = require('../src/mcp.cjs');
const pause = (ms) => new Promise((r) => setTimeout(r, ms));
async function fixture(t) {
  const root = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), 'inkline-unit-')));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const store = new Documents({ userData: path.join(root, 'settings') });
  await store.init();
  t.after(() => store.dispose());
  return { root, store };
}
test('save, reopen, Unicode/BOM encodings, CRLF, and format validation', async (t) => {
  const { root, store } = await fixture(t);
  const source = '# 한글 ✓ 😀\r\n\r\nText\r\n';
  for (const [encoding, bom] of [
    ['utf8', [239, 187, 191]],
    ['utf16le', [255, 254]],
    ['utf16be', [254, 255]],
    ['utf32le', [255, 254, 0, 0]],
    ['utf32be', [0, 0, 254, 255]],
  ]) {
    const data = encode({ source, encoding, bom: Buffer.from(bom) });
    assert.equal(decode(data).source, source);
    const file = path.join(root, encoding + '.md');
    await fs.writeFile(file, data);
    const doc = await store.open(file);
    assert.equal(doc.newline, '\r\n');
    assert.equal(store.snapshot(doc).modified, false);
    store.update(doc.id, source + 'More\r\n');
    await store.save(doc.id);
    assert.deepEqual(await fs.readFile(file), encode({ ...doc }));
    store.close(doc.id);
  }
  await assert.rejects(store.open(path.join(root, 'missing.md')));
  const d = store.create('html', '<h1>Hello</h1>');
  await assert.rejects(store.save(d.id, path.join(root, 'wrong.md')), /extension/);
  assert.throws(() => decode(Buffer.from([0xff, 0x80])), /encoded|encoding/i);
});
test('autosave is opt-in, debounced, cancellable, and never names an untitled file', async (t) => {
  const { root, store } = await fixture(t);
  const doc = store.create('markdown', '# Original\n'),
    file = path.join(root, 'note.md');
  await store.save(doc.id, file);
  store.update(doc.id, '# Manual\n');
  await pause(1100);
  assert.equal(await fs.readFile(file, 'utf8'), '# Original\n');
  await store.setSettings({ autosaveEnabled: true, autosaveDelay: 1 });
  await pause(1200);
  assert.equal(await fs.readFile(file, 'utf8'), '# Manual\n');
  store.update(doc.id, '# Pending\n');
  await store.setSettings({ autosaveEnabled: false });
  await pause(1100);
  assert.equal(await fs.readFile(file, 'utf8'), '# Manual\n');
  const untitled = store.create('markdown', 'untitled');
  await store.setSettings({ autosaveEnabled: true });
  await pause(1100);
  assert.equal(untitled.path, null);
});
test('serialized saves preserve newest source and refuse external changes and collisions', async (t) => {
  const { root, store } = await fixture(t);
  const d = store.create('markdown', 'one'),
    file = path.join(root, 'note.md');
  await store.save(d.id, file);
  const operations = [];
  for (let i = 0; i < 8; i++) {
    store.update(d.id, 'revision ' + i);
    operations.push(store.save(d.id));
  }
  await Promise.all(operations);
  assert.equal(await fs.readFile(file, 'utf8'), 'revision 7');
  assert.equal(store.snapshot(d).modified, false);
  await fs.writeFile(file, 'outside edit');
  store.update(d.id, 'mine');
  await assert.rejects(store.save(d.id), /outside Inkline/);
  assert.equal(await fs.readFile(file, 'utf8'), 'outside edit');
  const other = store.create('markdown', 'other');
  await assert.rejects(store.save(other.id, file, true), /another document/);
  const exists = path.join(root, 'exists.md');
  await fs.writeFile(exists, 'original');
  await assert.rejects(store.save(other.id, exists), /already exists/);
  assert.equal(await fs.readFile(exists, 'utf8'), 'original');
});
test('project paths and scopes resolve references and reject directory/symlink escapes', async (t) => {
  const { root, store } = await fixture(t);
  const project = path.join(root, 'project'),
    chapters = path.join(project, 'chapters'),
    figures = path.join(project, 'figures');
  await fs.mkdir(chapters, { recursive: true });
  await fs.mkdir(figures);
  const image = path.join(figures, 'plot.png');
  await fs.writeFile(image, 'image');
  const file = path.join(chapters, 'note.md');
  await fs.writeFile(file, '# Note');
  const doc = await store.open(file);
  await store.project(project);
  assert.equal(await store.asset(doc.id, '../figures/plot.png'), image);
  assert.equal(await store.asset(doc.id, 'figures/plot.png'), image);
  const outside = path.join(root, 'outside.md');
  await fs.writeFile(outside, 'outside');
  await assert.rejects(store.asset(doc.id, '../../outside.md'));
  await fs.symlink(root, path.join(project, 'escape'), 'junction');
  await assert.rejects(store.asset(doc.id, 'escape/outside.md'));
  const scope = await Scope.create([project], []);
  assert.equal(scope.permits(file), true);
  assert.equal(scope.permits(file, true), false);
  await assert.rejects(scope.require(outside));
  await assert.rejects(scope.require(path.join(project, 'escape', 'outside.md')));
  const write = await Scope.create([], [project]);
  assert.equal(write.permits(file, true), true);
  assert.equal(write.permits(project), false);
  assert.equal(
    await write.require(path.join(project, 'new.md'), true, true),
    path.join(project, 'new.md'),
  );
  const tree = await store.tree();
  assert.equal(
    tree.some((n) => n.name === 'escape'),
    false,
  );
  assert.equal(tree[0].directory, true);
  assert.equal(inside(path.join(root, 'project-other', 'file.md'), project), false);
});
test('settings persist without source changes; all themes have both complete palettes', async (t) => {
  const { root, store } = await fixture(t);
  const doc = store.create('markdown', '# Stable');
  const before = revision(doc);
  for (const theme of ['Orchid', 'Ocean', 'Forest', 'Graphite']) {
    for (const appearance of ['light', 'dark', 'system']) {
      await store.setSettings({
        theme,
        appearance,
        sourceFont: 'Georgia',
        previewFont: 'Arial',
        sourceFontSize: 16,
        lineSpacing: 8,
      });
      assert.equal(revision(doc), before);
      assert.equal(Object.keys(colors(theme, appearance === 'dark')).length, 12);
    }
  }
  const reopened = new Documents({ userData: store.userData });
  await reopened.init();
  assert.equal(reopened.settings.theme, 'Graphite');
  assert.equal(reopened.settings.sourceFont, 'Georgia');
  assert.throws(() => validSettings({ autosaveDelay: 0 }));
  assert.throws(() => validSettings({ appearance: 'unknown' }));
  assert.throws(() => validSettings({ defaultLatexEngine: 'shell-command' }));
  assert.throws(() => validSettings({ mcpEnabled: 'true' }));
});
test('table escaping in Markdown, HTML and LaTeX, including headers and empty cells', () => {
  const cells = [
    ['A | B', 'Title'],
    ['<cell>&"', 'price $5_&#% \\'],
  ];
  assert.match(tableSource('markdown', cells), /A \\\| B/);
  assert.ok(tableSource('html', cells).includes('&lt;cell&gt;&amp;&quot;'));
  const tex = tableSource('latex', cells);
  assert.ok(tex.includes('price \\$5\\_\\&\\#\\% \\textbackslash{}'));
  assert.ok(tex.includes('\\textbf{Title}'));
  assert.ok(!tableSource('latex', cells, false).includes('\\textbf'));
  assert.match(tableSource('markdown', [['value']], false), /^\|  \|\n\| --- \|\n\| value \|/);
});
test('MCP revisions, unique-match edits, read-only roots, resources and saved format copies', async (t) => {
  const { root, store } = await fixture(t);
  let undo = [];
  const deps = {
    store,
    sync: async () => {},
    replace: async (d, source) => {
      undo.push(d.source);
      store.update(d.id, source);
    },
    compile: async () => ({ log: 'compiled' }),
    exportPDF: async () => {},
    show: () => {},
  };
  const request = async (name, args = {}, write = [root]) =>
    handleAutomation(
      { method: 'tools/call', params: { name, arguments: args }, read: [root], write },
      deps,
    );
  const created = (await request('create_document', { format: 'markdown', source: 'aaa' }))
    .structuredContent;
  let d = store.get(created.document_id);
  assert.equal(
    (
      await request('edit_document', {
        document_id: d.id,
        expected_revision: revision(d),
        old_text: 'aa',
        new_text: 'b',
      })
    ).isError,
    true,
  );
  const old = revision(d);
  assert.equal(
    (
      await request('replace_document', {
        document_id: d.id,
        expected_revision: old,
        source: '# Updated',
      })
    ).isError,
    undefined,
  );
  assert.equal(undo[0], 'aaa');
  assert.equal(
    (
      await request('replace_document', {
        document_id: d.id,
        expected_revision: old,
        source: 'stale',
      })
    ).isError,
    true,
  );
  const uri = 'inkline://document/' + d.id;
  assert.equal(
    (
      await handleAutomation(
        { method: 'resources/read', params: { uri }, read: [root], write: [] },
        deps,
      )
    ).contents[0].text,
    '# Updated',
  );
  assert.equal((await request('close_document', { document_id: d.id })).isError, true);
  await request('save_document', { document_id: d.id, path: path.join(root, 'note.md') });
  assert.equal(
    (
      await request(
        'replace_document',
        { document_id: d.id, expected_revision: revision(d), source: 'forbidden' },
        [],
      )
    ).isError,
    true,
  );
  const copy = (await request('set_format', { document_id: d.id, format: 'html' }))
    .structuredContent;
  assert.notEqual(copy.document_id, d.id);
  assert.equal(copy.path, undefined);
  assert.equal(await fs.readFile(d.path, 'utf8'), '# Updated');
  assert.equal(
    (await request('close_document', { document_id: d.id })).structuredContent.closed,
    true,
  );
  assert.equal(tools.length, 13);
  assert.throws(() =>
    validate('replace_document', { document_id: 'id', source: 'missing revision' }),
  );
});
test('local automation transport authenticates each request', async (t) => {
  const { root } = await fixture(t);
  const pipe =
    process.platform === 'win32'
      ? '\\\\.\\pipe\\inkline-test-' + Date.now()
      : path.join(os.tmpdir(), 'inkline-test-' + process.pid + '-' + Date.now() + '.sock');
  const server = await startBridge({
    pipe,
    token: 'test-secret',
    handle: async (input) => ({
      method: input.method,
      ...(input.source ? { source: input.source } : {}),
    }),
  });
  t.after(() => new Promise((resolve) => server.close(resolve)));
  assert.deepEqual(await bridgeRequest(pipe, { token: 'test-secret', method: 'ping' }), {
    method: 'ping',
  });
  const unicode = '한글 😀 ✓ '.repeat(100000);
  assert.equal(
    (await bridgeRequest(pipe, { token: 'test-secret', method: 'echo', source: unicode })).source,
    unicode,
  );
  await assert.rejects(bridgeRequest(pipe, { token: 'wrong', method: 'ping' }), /Invalid local/);
});
test('concurrent new-file exports cannot overwrite a destination without permission', async (t) => {
  const { root } = await fixture(t),
    file = path.join(root, 'output.pdf');
  const results = await Promise.allSettled([
    atomicWrite(file, Buffer.from('first'), false),
    atomicWrite(file, Buffer.from('second'), false),
  ]);
  assert.equal(results.filter((r) => r.status === 'fulfilled').length, 1);
  assert.equal(results.find((r) => r.status === 'rejected').reason.code, 'EEXIST');
  assert.ok(['first', 'second'].includes(await fs.readFile(file, 'utf8')));
});
test('Markdown preview escapes HTML, rejects executable links, and supplies unique heading anchors', async () => {
  const { markdownHTML } = await import('../renderer/preview.mjs');
  const output = markdownHTML(
    {
      document_id: 'test',
      source:
        '# Heading\n\n# Heading\n\n<script>alert(1)</script>\n\n[run](javascript:alert(1))\n\n![figure](../figures/plot.png)\n',
    },
    {
      settings: { theme: 'Orchid', previewFont: 'Georgia', previewFontSize: 17 },
      dark: false,
      fonts: [],
    },
  );
  assert.ok(output.includes('id="heading"'));
  assert.ok(output.includes('id="heading-2"'));
  assert.ok(output.includes('&lt;script&gt;'));
  assert.ok(!output.includes('href="javascript:'));
  assert.ok(output.includes('inkline://asset/test/'));
});

test('A4 is the default paper unless a LaTeX source states its own size', () => {
  const {
    statesPaperSize,
    prepareLatex,
    firstPageSize,
    pointsToMicrons,
    A4,
  } = require('../src/paper.cjs');
  const body = '\n\\begin{document}x\\end{document}\n';
  for (const source of [
    '\\documentclass[letterpaper]{article}',
    '\\documentclass[a5paper,11pt]{article}',
    '\\documentclass{scrartcl}\\KOMAoptions{paper=letter}',
    '\\documentclass{beamer}',
    '\\documentclass{article}\n\\usepackage[margin=1in, paper=legalpaper]{geometry}',
    '\\documentclass{article}\\geometry{paperwidth=5in,paperheight=7in}',
    '\\documentclass{memoir}\\setstocksize{9in}{6in}',
  ])
    assert.ok(statesPaperSize(source + body), source);
  for (const source of [
    '\\documentclass[11pt]{article}',
    '% \\documentclass[letterpaper]{article}\n\\documentclass{report}',
    '\\documentclass{article}\n\\begin{document}\nletterpaper \\paperwidth=1in\n',
  ])
    assert.ok(!statesPaperSize(source), source);
  assert.ok(
    prepareLatex('\\documentclass{report}\nx').startsWith('\\PassOptionsToClass{a4paper}{report}'),
  );
  assert.ok(!prepareLatex('\\documentclass[letterpaper]{report}\n').includes('a4paper'));
  assert.equal(prepareLatex('\\documentclass{report}\nx').split('\n').length, 2);
  assert.deepEqual(firstPageSize(Buffer.from('<< /MediaBox [0 0 612 792] >>')), {
    width: 612,
    height: 792,
  });
  assert.equal(firstPageSize(Buffer.from('no pages')), null);
  assert.equal(pointsToMicrons(A4.width), 210000);
  assert.equal(pointsToMicrons(A4.height), 297000);
  const { printPageSize } = require('../src/paper.cjs');
  assert.deepEqual(printPageSize({ width: 594.96, height: 841.92 }), {
    width: 210000,
    height: 297000,
  });
  assert.deepEqual(printPageSize({ width: 792, height: 612 }), { width: 279400, height: 215900 });
  assert.deepEqual(printPageSize({ width: 360, height: 504 }), { width: 127000, height: 177800 });
});

test(
  'LaTeX compiles on A4 by default and keeps stated sizes',
  { skip: !process.env.INKLINE_REQUIRE_TEX && 'set INKLINE_REQUIRE_TEX=1' },
  async () => {
    const { compileLatex } = require('../src/latex.cjs');
    const pdfjs = await import('pdfjs-dist/legacy/build/pdf.mjs');
    const pageSize = async (source, engine) => {
      const { pdf } = await compileLatex({ source, engine });
      const task = pdfjs.getDocument({ data: new Uint8Array(pdf), isEvalSupported: false });
      const page = await (await task.promise).getPage(1);
      const { width, height } = page.getViewport({ scale: 1 });
      await task.destroy();
      return [Math.round(width), Math.round(height)];
    };
    const body = '\n\\begin{document}\nPaper\n\\end{document}\n';
    for (const engine of ['pdflatex', 'xelatex']) {
      assert.deepEqual(await pageSize('\\documentclass{article}' + body, engine), [595, 842]);
      assert.deepEqual(
        await pageSize('\\documentclass[letterpaper]{article}' + body, engine),
        [612, 792],
      );
      assert.deepEqual(
        await pageSize(
          '\\documentclass{article}\\usepackage[paperwidth=5in,paperheight=7in]{geometry}' + body,
          engine,
        ),
        [360, 504],
      );
    }
    await assert.rejects(
      compileLatex({
        source: '\\documentclass{article}\n\\begin{document}\n\\undefinedmacro\n\\end{document}\n',
      }),
      /document\.tex:3:/,
    );
  },
);

test('LaTeX errors are located when TeX prints the temporary path with forward slashes', () => {
  const { diagnostics } = require('../src/latex.cjs');
  const work = 'C:\\Users\\runner\\AppData\\Local\\Temp\\inkline-tex-abc';
  const log = [
    '! Undefined control sequence.',
    'C:/Users/runner/AppData/Local/Temp/inkline-tex-abc/document.tex:3: Undefined control sequence.',
    'C:/Users/runner/AppData/Local/Temp/inkline-tex-abc/document.tex:3:  ==> Fatal error occurred, no output PDF file produced!',
    './chapters/intro.tex:7: Missing $ inserted.',
  ].join('\r\n');
  assert.deepEqual(diagnostics(log, work), [
    { file: 'document.tex', line: 3, message: 'Undefined control sequence.' },
    { file: 'chapters/intro.tex', line: 7, message: 'Missing $ inserted.' },
  ]);
  assert.deepEqual(diagnostics('! Emergency stop.', work), [{ message: 'Emergency stop.' }]);
});

test('path suggestions follow the Overleaf-style rules shared with macOS', async () => {
  const { pathContext, rankPaths } = await import('../renderer/paths.mjs');
  const files = [
    '../figures/plot.png',
    '../figures/results/chart one.png',
    'intro.tex',
    '../refs.bib',
    '../notes.md',
  ];
  const graphic = pathContext('\\includegraphics[width=2cm]{../fig', 'latex');
  assert.equal(graphic.partial, '../fig');
  assert.deepEqual(rankPaths(graphic, files), [
    '../figures/plot.png',
    '../figures/results/chart one.png',
  ]);
  assert.deepEqual(rankPaths(pathContext('\\include{in', 'latex'), files), ['intro']);
  assert.deepEqual(rankPaths(pathContext('\\bibliography{a,../re', 'latex'), files), ['../refs']);
  assert.deepEqual(rankPaths(pathContext('![Chart](../figures/res', 'markdown'), files), [
    '../figures/results/chart%20one.png',
  ]);
  assert.equal(pathContext('<img src="https://x', 'html'), null);
  assert.equal(pathContext('Plain {text', 'latex'), null);
  assert.equal(pathContext('<a href="../no', 'html').kind, 'any');
});

test(
  'LaTeX resolves ../ and subfolder paths, and build_latex_pdf summarizes',
  { skip: !process.env.INKLINE_REQUIRE_TEX && 'set INKLINE_REQUIRE_TEX=1' },
  async () => {
    const { compileLatex } = require('../src/latex.cjs');
    const { buildLatexPdf } = require('../src/build.cjs');
    const root = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), 'inkline-paths-')));
    await fs.mkdir(path.join(root, 'chapters'));
    await fs.mkdir(path.join(root, 'figures', 'results'), { recursive: true });
    const png = Buffer.from(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==',
      'base64',
    );
    await fs.writeFile(path.join(root, 'figures', 'plot.png'), png);
    await fs.writeFile(path.join(root, 'figures', 'results', 'chart.png'), png);
    await fs.writeFile(path.join(root, 'shared.tex'), 'Shared text.\n');
    await fs.writeFile(path.join(root, 'chapters', 'intro.tex'), 'Intro.\n');
    const tex = path.join(root, 'chapters', 'main.tex');
    const source =
      '\\documentclass{article}\\usepackage{graphicx}\\begin{document}\\input{../shared}\\include{intro}' +
      '\\includegraphics[width=1cm]{../figures/plot.png}\\includegraphics[width=1cm]{figures/results/chart.png}\\end{document}\n';
    const compiled = await compileLatex({ source, file: tex, projectRoot: root });
    assert.equal(compiled.pdf.subarray(0, 4).toString(), '%PDF');
    assert.ok(compiled.pages >= 1);
    assert.ok(Math.abs(compiled.size.width - 595.28) < 1.5);
    await assert.rejects(fs.access(path.join(root, 'chapters', 'main.aux')));
    await assert.rejects(
      compileLatex({
        source:
          '\\documentclass{article}\n\\usepackage{graphicx}\n\\begin{document}\n\\includegraphics{../nope.png}\n\\end{document}\n',
        file: tex,
        projectRoot: root,
      }),
      (e) => e.errors[0].file === 'main.tex' && e.errors[0].line === 4,
    );

    await fs.writeFile(tex, source);
    const scope = await Scope.create([root], [root]);
    const built = await buildLatexPdf({ path: tex, project_root: root }, scope);
    assert.equal(built.success, true, JSON.stringify(built));
    assert.equal(built.paper, 'A4');
    assert.ok(built.pages >= 1);
    assert.ok(JSON.stringify(built).length < 600);
    await assert.rejects(buildLatexPdf({ path: tex }, scope), /overwrite=true/);
    await fs.writeFile(
      path.join(root, 'broken.tex'),
      '\\documentclass{article}\n\\begin{document}\n\\oops\n\\end{document}\n',
    );
    const broken = await buildLatexPdf({ path: path.join(root, 'broken.tex') }, scope);
    assert.equal(broken.success, false);
    assert.deepEqual(broken.errors[0], {
      message: 'Undefined control sequence.',
      file: 'broken.tex',
      line: 3,
    });
    const narrow = await Scope.create([path.join(root, 'figures')], []);
    await assert.rejects(
      buildLatexPdf({ path: tex, overwrite: true }, narrow),
      /outside the configured/,
    );
    await fs.rm(root, { recursive: true, force: true });
  },
);
