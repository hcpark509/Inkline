'use strict';
const fs = require('node:fs/promises');
const path = require('node:path');
const { createHash, randomUUID } = require('node:crypto');
const { extensions, starters, defaults, validSettings } = require('./shared.cjs');
const digest = (value) => createHash('sha256').update(value).digest('hex');
const revision = (doc) => digest(doc.format + '\0' + doc.source);
function inside(file, root) {
  const relative = path.relative(root, file);
  return (
    relative !== '' &&
    relative !== '..' &&
    !relative.startsWith('..' + path.sep) &&
    !path.isAbsolute(relative)
  );
}
async function canonical(file, allowNew = false) {
  if (typeof file !== 'string' || !path.isAbsolute(file) || file.includes('\0'))
    throw Error('Use an absolute file path.');
  try {
    return await fs.realpath(file);
  } catch (e) {
    if (!allowNew || e.code !== 'ENOENT') throw e;
    try {
      await fs.lstat(file);
      throw Error('Broken symbolic links are not valid destinations.');
    } catch (link) {
      if (link.code !== 'ENOENT') throw link;
    }
    return path.join(await fs.realpath(path.dirname(file)), path.basename(file));
  }
}
function decode(data) {
  const marks = [
    ['utf32be', [0, 0, 254, 255]],
    ['utf32le', [255, 254, 0, 0]],
    ['utf8', [239, 187, 191]],
    ['utf16be', [254, 255]],
    ['utf16le', [255, 254]],
  ];
  const mark = marks.find(([, bytes]) => data.subarray(0, bytes.length).equals(Buffer.from(bytes)));
  const encoding = mark?.[0] || 'utf8',
    bom = Buffer.from(mark?.[1] || []),
    body = data.subarray(bom.length);
  let source;
  if (encoding.startsWith('utf32')) {
    if (body.length % 4) throw Error('Invalid UTF-32 file.');
    const chars = [];
    for (let i = 0; i < body.length; i += 4) {
      const cp = encoding === 'utf32le' ? body.readUInt32LE(i) : body.readUInt32BE(i);
      if (cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff)) throw Error('Invalid UTF-32 character.');
      chars.push(String.fromCodePoint(cp));
    }
    source = chars.join('');
  } else source = new TextDecoder(encoding.replace('utf', 'utf-'), { fatal: true }).decode(body);
  return { source, encoding, bom };
}
function encode(doc) {
  let body;
  if (doc.encoding.startsWith('utf32')) {
    const chars = Array.from(doc.source);
    body = Buffer.alloc(chars.length * 4);
    chars.forEach((c, i) =>
      doc.encoding === 'utf32le'
        ? body.writeUInt32LE(c.codePointAt(0), i * 4)
        : body.writeUInt32BE(c.codePointAt(0), i * 4),
    );
  } else if (doc.encoding === 'utf16be') {
    body = Buffer.from(doc.source, 'utf16le');
    body.swap16();
  } else body = Buffer.from(doc.source, doc.encoding);
  return Buffer.concat([doc.bom, body]);
}
async function atomicWrite(file, data, overwrite = true) {
  const temporary = path.join(
    path.dirname(file),
    '.' + path.basename(file) + '.inkline-' + randomUUID() + '.tmp',
  );
  try {
    await fs.writeFile(temporary, data, { flag: 'wx' });
    if (overwrite) await fs.rename(temporary, file);
    else {
      try {
        await fs.link(temporary, file);
      } catch (error) {
        if (!['EPERM', 'ENOTSUP', 'EXDEV'].includes(error.code)) throw error;
        await fs.copyFile(temporary, file, require('node:fs').constants.COPYFILE_EXCL);
      }
    }
  } finally {
    await fs.rm(temporary, { force: true }).catch(() => {});
  }
}
class Documents {
  constructor({ userData, changed = () => {} }) {
    this.userData = userData;
    this.changed = changed;
    this.docs = new Map();
    this.settings = { ...defaults };
    this.projectRoot = null;
    this.timers = new Map();
    this.saves = new Map();
    this.active = null;
  }
  async init() {
    await fs.mkdir(this.userData, { recursive: true });
    try {
      const value = JSON.parse(
        await fs.readFile(path.join(this.userData, 'settings.json'), 'utf8'),
      );
      this.settings = { ...defaults, ...validSettings(value.settings || {}) };
      if (value.projectRoot && (await fs.stat(value.projectRoot)).isDirectory())
        this.projectRoot = await canonical(value.projectRoot);
    } catch {}
  }
  async persist() {
    await atomicWrite(
      path.join(this.userData, 'settings.json'),
      JSON.stringify({ settings: this.settings, projectRoot: this.projectRoot }, null, 2),
    );
  }
  async setSettings(values) {
    this.settings = { ...this.settings, ...validSettings(values) };
    await this.persist();
    for (const doc of this.docs.values()) this.schedule(doc);
    this.changed();
    return this.settings;
  }
  async project(folder) {
    this.projectRoot = folder ? await canonical(folder) : null;
    if (this.projectRoot && !(await fs.stat(this.projectRoot)).isDirectory())
      throw Error('Choose a project folder.');
    await this.persist();
    this.changed();
    return this.projectRoot;
  }
  projectFor(doc) {
    return this.projectRoot && (!doc.path || inside(doc.path, this.projectRoot))
      ? this.projectRoot
      : null;
  }
  create(format = 'markdown', source) {
    if (!Object.hasOwn(extensions, format)) throw Error('Unknown document format.');
    const content = source ?? starters[format];
    const doc = {
      id: randomUUID(),
      format,
      source: content,
      savedSource: '',
      path: null,
      encoding: 'utf8',
      bom: Buffer.alloc(0),
      newline: content.includes('\r\n') ? '\r\n' : content.includes('\r') ? '\r' : '\n',
      selection: { utf16_location: 0, utf16_length: 0 },
      view: 'split',
      engine: this.settings.defaultLatexEngine,
      saveError: null,
      compiled: null,
    };
    this.docs.set(doc.id, doc);
    this.active = doc.id;
    this.changed();
    return doc;
  }
  get(id) {
    const doc = this.docs.get(id);
    if (!doc) throw Error('Document is closed. Run list_documents again.');
    return doc;
  }
  async open(file) {
    file = await canonical(file);
    const existing = [...this.docs.values()].find((d) => d.path === file);
    if (existing) {
      this.active = existing.id;
      this.changed();
      return existing;
    }
    const ext = path.extname(file).slice(1).toLowerCase(),
      format = Object.keys(extensions).find((k) => extensions[k].includes(ext));
    if (!format) throw Error('Open a Markdown, LaTeX, or HTML file.');
    const data = await fs.readFile(file);
    const decoded = decode(data);
    const doc = this.create(format, decoded.source);
    Object.assign(doc, decoded, {
      path: file,
      savedSource: decoded.source,
      diskHash: digest(data),
    });
    this.changed();
    return doc;
  }
  update(id, source, selection) {
    const doc = this.get(id);
    if (typeof source !== 'string') throw Error('Source must be text.');
    if (doc.source !== source) {
      doc.source = source;
      this.schedule(doc);
    }
    if (selection) doc.selection = selection;
    return doc;
  }
  snapshot(doc, includeSource = false) {
    return {
      document_id: doc.id,
      title: doc.path ? path.basename(doc.path) : 'Untitled',
      format: doc.format,
      revision: revision(doc),
      modified: doc.source !== doc.savedSource,
      path: doc.path || undefined,
      resource_uri: 'inkline://document/' + doc.id,
      active: doc.id === this.active,
      selection: doc.selection,
      line_separator: doc.newline,
      view: doc.view,
      engine: doc.engine,
      project_root: this.projectFor(doc) || undefined,
      autosave_enabled: this.settings.autosaveEnabled,
      save_error: doc.saveError,
      ...(includeSource ? { source: doc.source } : {}),
    };
  }
  check(doc, expected) {
    if (revision(doc) !== expected)
      throw Error(
        'The document changed since it was read. Read it again before editing or exporting.',
      );
  }
  schedule(doc) {
    clearTimeout(this.timers.get(doc.id));
    this.timers.delete(doc.id);
    if (!this.settings.autosaveEnabled || !doc.path || doc.source === doc.savedSource) return;
    this.timers.set(
      doc.id,
      setTimeout(
        () =>
          this.save(doc.id).catch((e) => {
            doc.saveError = e.message;
            this.changed();
          }),
        this.settings.autosaveDelay * 1000,
      ),
    );
  }
  async save(id, file, overwrite = false) {
    const previous = this.saves.get(id) || Promise.resolve();
    const operation = previous.catch(() => {}).then(() => this.write(id, file, overwrite));
    this.saves.set(id, operation);
    try {
      return await operation;
    } finally {
      if (this.saves.get(id) === operation) this.saves.delete(id);
    }
  }
  async write(id, file, overwrite) {
    const doc = this.get(id);
    file = await canonical(file || doc.path, true);
    if (!extensions[doc.format].includes(path.extname(file).slice(1).toLowerCase()))
      throw Error('The filename extension must match the document format.');
    if ([...this.docs.values()].some((d) => d.id !== id && d.path === file))
      throw Error('The destination is open in another document.');
    let previous;
    try {
      previous = await fs.readFile(file);
    } catch (e) {
      if (e.code !== 'ENOENT') throw e;
    }
    if (previous && file !== doc.path && !overwrite)
      throw Error(
        'The destination already exists. Explicitly allow overwrite or choose another path.',
      );
    if (previous && file === doc.path && doc.diskHash && digest(previous) !== doc.diskHash)
      throw Error(
        'This file changed outside Inkline. Save As to a new file before replacing the external changes.',
      );
    const source = doc.source,
      data = encode({ ...doc, source });
    await atomicWrite(file, data, file === doc.path || overwrite);
    Object.assign(doc, {
      path: file,
      savedSource: source,
      diskHash: digest(data),
      saveError: null,
    });
    this.schedule(doc);
    this.changed();
    return doc;
  }
  close(id) {
    const doc = this.get(id);
    if (doc.source !== doc.savedSource)
      throw Error('The document has unsaved changes. Save it before closing.');
    clearTimeout(this.timers.get(id));
    this.docs.delete(id);
    if (this.active === id) this.active = this.docs.keys().next().value || null;
    this.changed();
  }
  dispose() {
    for (const timer of this.timers.values()) clearTimeout(timer);
  }
  async asset(id, relative, rootRelative = false) {
    const doc = this.get(id),
      root = this.projectFor(doc) || (doc.path ? path.dirname(doc.path) : null);
    if (
      !root ||
      typeof relative !== 'string' ||
      path.isAbsolute(relative) ||
      /^[a-z][\w+.-]*:/i.test(relative)
    )
      throw Error('Asset is outside the document/project folder.');
    const base = doc.path ? path.dirname(doc.path) : root;
    for (const directory of rootRelative ? [root] : [base, root]) {
      try {
        const file = await canonical(path.resolve(directory, relative));
        if (inside(file, root) && (await fs.stat(file)).isFile()) return file;
      } catch {}
    }
    throw Error('Asset is missing or outside the document/project folder.');
  }
  async tree(folder = this.projectRoot) {
    if (!folder || !this.projectRoot) return [];
    folder = await canonical(folder);
    if (folder !== this.projectRoot && !inside(folder, this.projectRoot))
      throw Error('Folder is outside the project.');
    const entries = await fs.readdir(folder, { withFileTypes: true });
    const out = [];
    for (const e of entries) {
      if (
        e.name.startsWith('.') ||
        ['node_modules', 'build', 'dist', 'dist-packages'].includes(e.name)
      )
        continue;
      if (e.isSymbolicLink()) continue;
      out.push({
        name: e.name,
        path: path.join(folder, e.name),
        directory: e.isDirectory(),
        supported: Object.values(extensions)
          .flat()
          .includes(path.extname(e.name).slice(1).toLowerCase()),
      });
    }
    return out.sort(
      (a, b) => Number(b.directory) - Number(a.directory) || a.name.localeCompare(b.name),
    );
  }
}
class Scope {
  static async create(read = [], write = []) {
    const value = new Scope();
    value.write = await Promise.all(write.map(canonicalRoot));
    value.read = [...new Set([...(await Promise.all(read.map(canonicalRoot))), ...value.write])];
    return value;
  }
  permits(file, write = false) {
    return (write ? this.write : this.read).some((root) => inside(file, root));
  }
  async require(file, write = false, newFile = false) {
    file = await canonical(file, newFile);
    if (!this.permits(file, write))
      throw Error(
        'Path is outside the configured automation ' + (write ? 'write' : 'read') + ' roots.',
      );
    return file;
  }
}
async function canonicalRoot(folder) {
  folder = await canonical(folder);
  if (!(await fs.stat(folder)).isDirectory()) throw Error('Automation root is not a directory.');
  return folder;
}
module.exports = {
  Documents,
  Scope,
  canonical,
  inside,
  decode,
  encode,
  atomicWrite,
  digest,
  revision,
};
