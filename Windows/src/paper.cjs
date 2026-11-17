'use strict';
// Inkline exports and prints on A4 unless a document states its own paper size.
// Keep these rules in step with Sources/PaperSize.swift in the macOS edition.

const fixedSizeClasses = new Set([
  'beamer',
  'standalone',
  'tikzposter',
  'a0poster',
  'sciposter',
  'baposter',
]);
const explicitPatterns = [
  /\b(?:[abc]\d{1,2}|letter|legal|executive|ansi[a-e]|b\dj|jisb\d)paper\b/i,
  /\bpaper(?:size|width|height)?\s*=/i,
  /\\setlength\s*\{?\s*\\(?:paper|pdfpage|stock)(?:width|height)\b/i,
  /\\(?:paper|pdfpage|stock)(?:width|height)\s*=/i,
  /\\setstocksize\b|\\stock(?:a\d|b\d|letter|legal|executive)\b/i,
  /\\(?:usepackage|RequirePackage)\s*(?:\[[^\]]*\])?\s*\{[^}]*\b(?:beamerposter|a0poster)\b/i,
];
// Keeps the PDF media box in step with the paper size LaTeX lays out, unless the document or a
// package such as geometry has already set the PDF page size.
const pageSync =
  '\\edef\\InklinePaperW{\\the\\pdfpagewidth}\\edef\\InklinePaperH{\\the\\pdfpageheight}' +
  '\\AtBeginDocument{\\ifdim\\pdfpagewidth=\\InklinePaperW\\relax\\ifdim\\pdfpageheight=\\InklinePaperH\\relax' +
  '\\ifdim\\paperwidth>0pt\\ifdim\\paperheight>0pt\\pdfpagewidth=\\paperwidth\\pdfpageheight=\\paperheight' +
  '\\fi\\fi\\fi\\fi}';

function preamble(source) {
  const uncommented = source.replace(/(?<!\\)%[^\n]*/g, '');
  const end = uncommented.indexOf('\\begin{document}');
  return end < 0 ? uncommented : uncommented.slice(0, end);
}
function className(source) {
  return (
    /\\documentclass\s*(?:\[[^\]]*\])?\s*\{\s*([^}\s]+)\s*\}/.exec(preamble(source))?.[1] ?? null
  );
}
function statesPaperSize(source) {
  if (fixedSizeClasses.has(className(source))) return true;
  const head = preamble(source);
  return explicitPatterns.some((pattern) => pattern.test(head));
}
// Everything is added before the first line's text, so compiler line numbers stay the same.
function prepareLatex(source) {
  const name = className(source);
  return (
    (!statesPaperSize(source) && name ? '\\PassOptionsToClass{a4paper}{' + name + '}' : '') +
    pageSync +
    source
  );
}
// Reads the first page's size, in points, from a PDF written by Chromium.
function firstPageSize(pdf) {
  const match = /\/MediaBox\s*\[\s*([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s*\]/.exec(
    Buffer.from(pdf).toString('latin1'),
  );
  if (!match) return null;
  const [x0, y0, x1, y1] = match.slice(1).map(Number);
  const width = Math.abs(x1 - x0),
    height = Math.abs(y1 - y0);
  return width > 0 && height > 0 ? { width, height } : null;
}
const A4 = { width: (210 * 72) / 25.4, height: (297 * 72) / 25.4 };
const pointsToMicrons = (points) => Math.round((points * 25400) / 72);
// Standard sheets in microns. Chromium rounds PDF page sizes, so near matches snap to these.
const standardSheets = [
  [148000, 210000],
  [210000, 297000],
  [297000, 420000],
  [176000, 250000],
  [250000, 353000],
  [215900, 279400],
  [215900, 355600],
  [279400, 431800],
];
// Converts a page size in points to the micron size webContents.print expects.
function printPageSize({ width, height }) {
  const size = { width: pointsToMicrons(width), height: pointsToMicrons(height) };
  const tolerance = 400; // about 1 pt
  for (const [short, long] of standardSheets)
    for (const [w, h] of [
      [short, long],
      [long, short],
    ])
      if (Math.abs(size.width - w) <= tolerance && Math.abs(size.height - h) <= tolerance)
        return { width: w, height: h };
  return size;
}
module.exports = {
  A4,
  statesPaperSize,
  prepareLatex,
  className,
  firstPageSize,
  pointsToMicrons,
  printPageSize,
};
