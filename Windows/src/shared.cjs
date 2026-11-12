'use strict';

const formats = ['markdown', 'latex', 'html'];
const extensions = {
  markdown: ['md', 'markdown', 'mdown', 'mkd', 'mkdn'],
  latex: ['tex'],
  html: ['html', 'htm'],
};
const starters = {
  markdown: '',
  latex:
    '\\documentclass[11pt]{article}\n\\usepackage{amsmath}\n\\usepackage{graphicx}\n\\title{A LaTeX document}\n\\author{}\n\\date{}\n\\begin{document}\n\\maketitle\n\\section{Introduction}\nWrite your document here.\n\\[\\int_0^1 x^2\\,dx = \\frac{1}{3}\\]\n\\end{document}\n',
  html: '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n<title>A new page</title>\n<style>body { font: 18px Georgia, serif; max-width: 760px; margin: 48px auto; padding: 0 24px; line-height: 1.7; } h1 { color: #6741a5; } table { border-collapse: collapse; } td, th { border: 1px solid #ccc; padding: 8px 14px; }</style>\n</head>\n<body>\n<h1>A new page</h1>\n<p>Edit the HTML and CSS to update the preview.</p>\n</body>\n</html>\n',
};
const defaults = {
  autosaveEnabled: false,
  autosaveDelay: 2,
  appearance: 'system',
  theme: 'Orchid',
  sourceFont: 'Consolas',
  sourceFontSize: 14,
  previewFont: 'Georgia',
  previewFontSize: 17,
  showLineNumbers: true,
  lineSpacing: 5,
  defaultLatexEngine: 'pdflatex',
  mcpEnabled: true,
};
const palettes = {
  Orchid: {
    light: [
      '#f7f5fb',
      '#fbf9fd',
      '#ffffff',
      '#29253b',
      '#625b75',
      '#e4dced',
      '#6741a5',
      '#ece4fa',
      '#126e66',
      '#314e9d',
      '#9b4425',
      '#963c67',
    ],
    dark: [
      '#25202e',
      '#24202c',
      '#211e28',
      '#eee6f6',
      '#bdb1cc',
      '#42374f',
      '#c9a8fd',
      '#382c48',
      '#8bdcca',
      '#aabfff',
      '#ffb991',
      '#ffa9d3',
    ],
  },
  Ocean: {
    light: [
      '#f0f6fa',
      '#f6fafc',
      '#ffffff',
      '#203647',
      '#526d80',
      '#d5e3ec',
      '#175f9e',
      '#dcecf9',
      '#087767',
      '#554ba5',
      '#99521e',
      '#9b386d',
    ],
    dark: [
      '#172630',
      '#14212a',
      '#15232c',
      '#e0edf5',
      '#a2bac9',
      '#334c5a',
      '#80c5fb',
      '#253d50',
      '#81dccc',
      '#b3b8ff',
      '#ffc18e',
      '#f3a6cb',
    ],
  },
  Forest: {
    light: [
      '#f1f7f2',
      '#f7faf7',
      '#ffffff',
      '#263d2d',
      '#526d59',
      '#d4e4d8',
      '#27673b',
      '#ddeee1',
      '#126b78',
      '#414f9d',
      '#98501d',
      '#913b67',
    ],
    dark: [
      '#202b25',
      '#1b2720',
      '#1c2821',
      '#e1efe4',
      '#adc4b3',
      '#3b5143',
      '#9cdaad',
      '#304b38',
      '#81d5df',
      '#a9bdff',
      '#f8c08b',
      '#efa6c2',
    ],
  },
  Graphite: {
    light: [
      '#f3f4f6',
      '#f9fafb',
      '#ffffff',
      '#2b303a',
      '#5b6577',
      '#dce0e6',
      '#465d8e',
      '#e2e8f5',
      '#17766b',
      '#3d56a0',
      '#985522',
      '#923d6a',
    ],
    dark: [
      '#25272c',
      '#1f2126',
      '#222429',
      '#e8e9ed',
      '#b3b8c4',
      '#42464f',
      '#b8c9f5',
      '#343f56',
      '#89d6c9',
      '#acbcfa',
      '#f0bd92',
      '#eaa8c8',
    ],
  },
};
const roles = [
  'chrome',
  'source',
  'paper',
  'ink',
  'muted',
  'line',
  'purple',
  'lavender',
  'teal',
  'blue',
  'orange',
  'rose',
];
function colors(theme, dark) {
  return Object.fromEntries(
    roles.map((r, i) => [r, (palettes[theme] || palettes.Orchid)[dark ? 'dark' : 'light'][i]]),
  );
}
function htmlEscape(value) {
  return String(value).replace(
    /[&<>"']/g,
    (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c],
  );
}
function latexEscape(value) {
  const map = {
    '\\': '\\textbackslash{}',
    '{': '\\{',
    '}': '\\}',
    $: '\\$',
    '&': '\\&',
    '#': '\\#',
    _: '\\_',
    '%': '\\%',
    '~': '\\textasciitilde{}',
    '^': '\\textasciicircum{}',
  };
  return String(value).replace(/[\\{}$&#_%~^]/g, (c) => map[c]);
}
function tableSource(format, cells, header = true) {
  if (!cells.length || !cells[0].length) throw Error('A table needs at least one cell.');
  if (format === 'html')
    return (
      '<table>\n' +
      cells
        .map(
          (row, r) =>
            '  <tr>' +
            row
              .map(
                (v) =>
                  `<${header && r === 0 ? 'th' : 'td'}>${htmlEscape(v)}</${header && r === 0 ? 'th' : 'td'}>`,
              )
              .join('') +
            '</tr>',
        )
        .join('\n') +
      '\n</table>\n'
    );
  if (format === 'latex')
    return (
      '\\begin{tabular}{|' +
      'l|'.repeat(cells[0].length) +
      '}\n\\hline\n' +
      cells
        .map(
          (row, r) =>
            row
              .map((v) => (header && r === 0 ? `\\textbf{${latexEscape(v)}}` : latexEscape(v)))
              .join(' & ') + ' \\\\ \\hline',
        )
        .join('\n') +
      '\n\\end{tabular}\n'
    );
  const line = (row) =>
    '| ' +
    row
      .map((v) =>
        String(v)
          .replace(/\\/g, '\\\\')
          .replace(/\|/g, '\\|')
          .replace(/[\r\n]+/g, ' '),
      )
      .join(' | ') +
    ' |';
  return (
    [
      line(header ? cells[0] : cells[0].map(() => '')),
      line(cells[0].map(() => '---')),
      ...cells.slice(header ? 1 : 0).map(line),
    ].join('\n') + '\n'
  );
}
function validSettings(input) {
  const out = {};
  for (const key of Object.keys(defaults)) {
    if (!(key in input)) continue;
    const value = input[key];
    if (typeof defaults[key] === 'boolean') {
      if (typeof value !== 'boolean') throw Error('Invalid setting: ' + key);
      out[key] = value;
    } else if (typeof defaults[key] === 'number') {
      const ranges = {
        autosaveDelay: [1, 60],
        sourceFontSize: [9, 48],
        previewFontSize: [9, 48],
        lineSpacing: [0, 16],
      };
      const [min, max] = ranges[key];
      if (!Number.isFinite(value) || value < min || value > max)
        throw Error('Invalid setting: ' + key);
      out[key] = value;
    } else {
      if (typeof value !== 'string' || value.length > 200) throw Error('Invalid setting: ' + key);
      if (key === 'appearance' && !['system', 'light', 'dark'].includes(value))
        throw Error('Invalid appearance.');
      if (key === 'theme' && !Object.hasOwn(palettes, value)) throw Error('Unknown color theme.');
      if (key === 'defaultLatexEngine' && !['pdflatex', 'xelatex'].includes(value))
        throw Error('Unknown TeX engine.');
      out[key] = value;
    }
  }
  return out;
}
module.exports = {
  formats,
  extensions,
  starters,
  defaults,
  palettes,
  roles,
  colors,
  htmlEscape,
  latexEscape,
  tableSource,
  validSettings,
};
