'use strict';
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const { spawn } = require('node:child_process');
const { prepareLatex } = require('./paper.cjs');
async function findEngine(engine, environment = process.env) {
  if (!['pdflatex', 'xelatex'].includes(engine)) throw Error('Choose pdfLaTeX or XeLaTeX.');
  const extra =
    process.platform === 'win32'
      ? [
          path.join(os.homedir(), 'AppData', 'Local', 'Programs', 'MiKTeX', 'miktex', 'bin', 'x64'),
          path.join(
            environment.ProgramFiles || 'C:\\Program Files',
            'MiKTeX',
            'miktex',
            'bin',
            'x64',
          ),
          path.join(environment.APPDATA || os.homedir(), 'TinyTeX', 'bin', 'windows'),
          path.join(os.homedir(), 'TinyTeX', 'bin', 'windows'),
        ]
      : [
          '/Library/TeX/texbin',
          '/usr/local/bin',
          '/opt/homebrew/bin',
          path.join(os.homedir(), 'Library', 'TinyTeX', 'bin', 'universal-darwin'),
        ];
  if (process.platform === 'win32') {
    for (const base of ['C:\\texlive', path.join(os.homedir(), 'AppData', 'Roaming', 'TinyTeX')]) {
      try {
        for (const entry of await fs.readdir(base))
          if (/^\d{4}$/.test(entry)) extra.push(path.join(base, entry, 'bin', 'windows'));
      } catch {}
    }
  }
  for (const folder of [...(environment.PATH || '').split(path.delimiter), ...extra]) {
    if (!folder || !path.isAbsolute(folder)) continue;
    const file = path.join(folder, engine + (process.platform === 'win32' ? '.exe' : ''));
    try {
      await fs.access(file);
      return file;
    } catch {}
  }
  return null;
}
// Recreates the document folder's subfolders so TeX can write auxiliary files for \include{dir/file}.
async function mirrorFolders(folder, work) {
  const skipped = new Set(['node_modules', 'build', '.git', '.next']);
  let created = 0;
  async function walk(from, depth) {
    if (depth > 4 || created >= 500) return;
    let entries = [];
    try {
      entries = await fs.readdir(from, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      if (!entry.isDirectory() || entry.name.startsWith('.') || skipped.has(entry.name)) continue;
      const child = path.join(from, entry.name);
      await fs.mkdir(path.join(work, path.relative(folder, child)), { recursive: true });
      if (++created >= 500) return;
      await walk(child, depth + 1);
    }
  }
  await walk(folder, 0);
}
// Compiler errors in file-line-error form, with the temporary folder removed from the main file's path.
function diagnostics(log, work) {
  const prefixes = [work + path.sep, work + '/', './', '.\\'];
  const found = [];
  for (let line of log.split(/\r?\n/)) {
    if (line.startsWith('! ')) {
      if (!found.length) found.push({ message: line.slice(2) });
      continue;
    }
    const prefix = prefixes.find((p) => line.startsWith(p));
    if (!prefix) continue;
    line = line.slice(prefix.length);
    const match = /^([^:]*):(\d+):\s*(.*)$/.exec(line);
    if (!match || match[3].startsWith('==>')) continue;
    if (found.length === 1 && !found[0].file) found.length = 0;
    found.push({
      file: match[1].split(path.sep).join('/'),
      line: Number(match[2]),
      message: match[3],
    });
  }
  return found;
}
const describe = (error) =>
  error.file
    ? `${error.file}${error.line ? ':' + error.line : ''}: ${error.message}`
    : error.message;
// TeX points are 1/72.27 in; PDF points are 1/72 in.
function pageInfo(log) {
  const written = /Output written on .*?\((\d+) pages?/.exec(log.replace(/\r?\n/g, ''));
  const size = /Inkline page size: ([\d.]+)pt x ([\d.]+)pt/.exec(log);
  return {
    pages: written ? Number(written[1]) : null,
    size: size
      ? { width: (Number(size[1]) * 72) / 72.27, height: (Number(size[2]) * 72) / 72.27 }
      : null,
  };
}
async function compileLatex({ source, file, projectRoot, engine = 'pdflatex' }) {
  const executable = await findEngine(engine);
  if (!executable)
    throw Error(engine + ' is unavailable. Install MiKTeX or TeX Live, then recompile.');
  const work = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), 'inkline-tex-')));
  try {
    const name = file ? path.basename(file) : 'document.tex';
    const main = path.join(work, name);
    await fs.writeFile(main, prepareLatex(source), 'utf8');
    // TeX runs in the document's folder, as on Overleaf, so ../ and subfolder paths resolve from the
    // document. Output goes to the temporary folder, which mirrors the subfolders \include writes into.
    const folder = file ? path.dirname(file) : projectRoot || null;
    if (folder) await mirrorFolders(folder, work);
    const env = {
      ...process.env,
      PATH: path.dirname(executable) + path.delimiter + (process.env.PATH || ''),
      TEXINPUTS: ['.', folder, projectRoot, process.env.TEXINPUTS || '']
        .filter((v) => v !== null && v !== undefined)
        .join(path.delimiter),
      openout_any: 'p',
      // Long temporary paths would otherwise wrap at 79 columns and split file:line errors.
      max_print_line: '10000',
    };
    const miktex = /miktex/i.test(executable);
    const deadline = Date.now() + 45000;
    let log = '',
      finalLog = '';
    for (let pass = 1; pass <= 2; pass++) {
      const result = await run(
        executable,
        [
          '-no-shell-escape',
          '-no-parse-first-line',
          '-interaction=nonstopmode',
          '-halt-on-error',
          '-file-line-error',
          ...(miktex ? ['-max-print-line=10000'] : []),
          '-output-directory=' + work,
          main,
        ],
        { cwd: folder || work, env, timeout: Math.max(1, deadline - Date.now()) },
      );
      log += `Pass ${pass}\n${result.log}\n`;
      finalLog = result.log;
      if (result.code !== 0) {
        const errors = diagnostics(result.log, work);
        const error = Error(
          result.timeout
            ? 'Compilation exceeded 45 seconds.'
            : errors.length
              ? describe(errors[0])
              : 'Compilation failed. Open the compile log.',
        );
        Object.assign(error, { log, finalLog, errors });
        throw error;
      }
    }
    const pdf = await fs.readFile(path.join(work, name.replace(/\.[^.]*$/, '') + '.pdf'));
    return { pdf, log, finalLog, ...pageInfo(finalLog) };
  } finally {
    await fs.rm(work, { recursive: true, force: true });
  }
}
function run(executable, args, options) {
  return new Promise((resolve, reject) => {
    let log = '',
      timedOut = false;
    const child = spawn(executable, args, {
      cwd: options.cwd,
      env: options.env,
      shell: false,
      windowsHide: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill('SIGKILL');
    }, options.timeout);
    const collect = (data) => {
      log = (log + data.toString()).slice(-98304);
    };
    child.stdout.on('data', collect);
    child.stderr.on('data', collect);
    child.once('error', (e) => {
      clearTimeout(timer);
      reject(e);
    });
    child.once('close', (code) => {
      clearTimeout(timer);
      resolve({ code, log, timeout: timedOut });
    });
  });
}
module.exports = { findEngine, compileLatex, diagnostics };
