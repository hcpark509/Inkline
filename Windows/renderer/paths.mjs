// Suggests project file paths while typing a path argument, such as \includegraphics{ or ![alt](.
// Keep these rules in step with Sources/PathCompletion.swift in the macOS edition.

const latex =
  /\\(includegraphics|includesvg|includepdf|input|include|subfile|subfileinclude|lstinputlisting|verbatiminput|bibliography|addbibresource|addglobalbib)\*?(?:\[[^\]\n]*\])*\{([^{}\n]*)$/;
const markdown = /(!?)\[[^\]\n]*\]\(([^()\s]*)$/;
const html = /\b(src|href|poster)\s*=\s*["']([^"'\n]*)$/i;
const cssURL = /url\(\s*["']?([^"')\n]*)$/i;

export const extensions = {
  graphic: ['png', 'jpg', 'jpeg', 'pdf', 'eps'],
  image: ['png', 'apng', 'jpg', 'jpeg', 'gif', 'svg', 'webp', 'avif', 'bmp'],
  tex: ['tex'],
  bib: ['bib'],
};

// The path typed just before the caret, given the text of the current line up to the caret.
export function pathContext(before, format) {
  before = before.slice(-400);
  const make = (partial, kind, dropsExtension = false, percentEncodes = false) => ({
    from: before.length - partial.length,
    partial,
    kind,
    dropsExtension,
    percentEncodes,
  });
  if (format === 'latex') {
    const match = latex.exec(before);
    if (!match) return null;
    const [, command] = match;
    let partial = match[2];
    if (['includegraphics', 'includesvg', 'includepdf'].includes(command))
      return make(partial, command === 'includesvg' ? 'image' : 'graphic');
    if (['bibliography', 'addglobalbib', 'addbibresource'].includes(command)) {
      if (command === 'bibliography') partial = partial.slice(partial.lastIndexOf(',') + 1);
      return make(partial, 'bib', command === 'bibliography');
    }
    if (['input', 'include', 'subfile', 'subfileinclude'].includes(command))
      return make(partial, 'tex', command === 'include');
    return make(partial, 'any');
  }
  if (format === 'markdown') {
    const match = markdown.exec(before);
    return match ? make(match[2], match[1] === '!' ? 'image' : 'any', false, true) : null;
  }
  const css = cssURL.exec(before);
  if (css) return make(css[1], 'any', false, true);
  const match = html.exec(before);
  if (!match) return null;
  const partial = match[2];
  if (partial.includes('://') || partial.startsWith('#') || partial.startsWith('mailto:'))
    return null;
  return make(partial, match[1].toLowerCase() === 'href' ? 'any' : 'image', false, true);
}

const encodePath = (value) => value.split('/').map(encodeURIComponent).join('/');

// Ranks document-relative paths: path prefix, then file-name prefix, then any substring match.
export function rankPaths(context, files, limit = 30) {
  const allowed = extensions[context.kind];
  let typed = context.partial;
  try {
    typed = decodeURIComponent(typed);
  } catch {}
  typed = typed.toLowerCase();
  const scored = [];
  for (const file of files) {
    const dot = file.lastIndexOf('.');
    const ext = dot > file.lastIndexOf('/') ? file.slice(dot + 1).toLowerCase() : '';
    if (allowed && !allowed.includes(ext)) continue;
    let value = context.dropsExtension && ext ? file.slice(0, dot) : file;
    const lower = value.toLowerCase();
    const name = lower.slice(lower.lastIndexOf('/') + 1);
    let score;
    if (lower.startsWith(typed)) score = 0;
    else if (name.startsWith(typed)) score = 1;
    else if (!typed || lower.includes(typed)) score = 2;
    else continue;
    if (context.percentEncodes) value = encodePath(value);
    scored.push([score, value]);
  }
  return scored
    .sort((a, b) => a[0] - b[0] || a[1].length - b[1].length || a[1].localeCompare(b[1]))
    .slice(0, limit)
    .map(([, value]) => value);
}
