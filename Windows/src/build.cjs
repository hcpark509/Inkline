'use strict';
// Headless LaTeX → PDF builds for MCP clients. It runs inside the MCP helper, so no Inkline window opens,
// and returns a short summary instead of the whole compiler log. Keep in step with Sources/LatexBuild.swift.
const fs = require('node:fs/promises');
const path = require('node:path');
const { canonical, atomicWrite, decode } = require('./documents.cjs');
const { compileLatex } = require('./latex.cjs');

const name = 'build_latex_pdf';
const definition = {
  name,
  description:
    'Compile a .tex file on disk to PDF without opening a window, like a deliverable build. ' +
    "Paths resolve from the file's folder (../ and subfolders work) and from project_root. A4 unless the preamble states a size. " +
    'Returns pages, paper, errors with line numbers, and warning counts; set include_log for the log tail.',
  inputSchema: {
    type: 'object',
    properties: {
      path: { type: 'string', description: 'Absolute path of the .tex file within a read root.' },
      output: {
        type: 'string',
        description: 'Absolute .pdf path within a write root. Defaults to the .tex path with .pdf.',
      },
      engine: { type: 'string', enum: ['pdflatex', 'xelatex'] },
      project_root: {
        type: 'string',
        description: 'Optional folder within a read root searched for inputs and figures.',
      },
      overwrite: { type: 'boolean', description: 'Required to replace an existing PDF.' },
      include_log: {
        type: 'boolean',
        description: 'Also return the last 6,000 characters of the final pass log.',
      },
    },
    required: ['path'],
    additionalProperties: false,
  },
  annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
};

function summarize(log, errors = []) {
  const lines = log.split(/\r?\n/);
  const count = (test) => lines.filter(test).length;
  const warnings = Object.fromEntries(
    Object.entries({
      undefined_references: count(
        (l) => l.includes('LaTeX Warning: Reference') || l.includes('LaTeX Warning: Citation'),
      ),
      missing_files: count((l) => l.includes('not found') && l.includes('Warning')),
      overfull_boxes: count((l) => l.startsWith('Overfull \\')),
      underfull_boxes: count((l) => l.startsWith('Underfull \\')),
      other: count(
        (l) =>
          l.includes('Warning:') &&
          !l.includes('Reference') &&
          !l.includes('Citation') &&
          !l.includes('not found'),
      ),
    }).filter(([, value]) => value > 0),
  );
  const summary = {};
  if (errors.length)
    summary.errors = errors.slice(0, 5).map((e) => {
      const value = { message: e.message };
      if (e.file) value.file = e.file;
      if (e.line) value.line = e.line;
      return value;
    });
  if (Object.keys(warnings).length) summary.warnings = warnings;
  const examples = [
    ...new Set(lines.filter((l) => l.includes('Warning:')).map((l) => l.trim().slice(0, 140))),
  ].slice(0, 3);
  if (examples.length) summary.warning_examples = examples;
  if (/Rerun to get|Rerun LaTeX/.test(log)) summary.needs_rerun = true;
  return summary;
}

function paperName({ width, height }) {
  const named = [
    ['A4', 595.28, 841.89],
    ['Letter', 612, 792],
    ['Legal', 612, 1008],
    ['A5', 419.53, 595.28],
    ['A3', 841.89, 1190.55],
    ['B5', 498.9, 708.66],
  ];
  const short = Math.min(width, height),
    long = Math.max(width, height);
  const match = named.find(([, w, h]) => Math.abs(w - short) < 1.5 && Math.abs(h - long) < 1.5);
  const orientation = width > height ? ' landscape' : '';
  return match
    ? match[0] + orientation
    : `${Math.round((width * 25.4) / 72)}×${Math.round((height * 25.4) / 72)} mm`;
}

async function buildLatexPdf(args, scope) {
  const file = await scope.require(args.path, false);
  if (path.extname(file).toLowerCase() !== '.tex') throw Error('path must end in .tex.');
  if (!(await fs.stat(file)).isFile()) throw Error('The .tex file does not exist.');
  const output = await scope.require(args.output || file.replace(/\.tex$/i, '.pdf'), true, true);
  if (path.extname(output).toLowerCase() !== '.pdf') throw Error('output must end in .pdf.');
  let exists = true;
  try {
    await fs.access(output);
  } catch {
    exists = false;
  }
  if (exists && args.overwrite !== true)
    throw Error('The PDF already exists. Pass overwrite=true to replace it.');
  let projectRoot = null;
  if (args.project_root) {
    const folder = await canonical(args.project_root);
    // A configured root is itself a valid project folder.
    projectRoot = scope.read.includes(folder) ? folder : await scope.require(folder, false);
    if (!(await fs.stat(projectRoot)).isDirectory()) throw Error('project_root must be a folder.');
  }
  const engine = args.engine || 'pdflatex';
  const { source: text } = decode(await fs.readFile(file));
  const started = Date.now();
  let result,
    failure = null;
  try {
    result = await compileLatex({ source: text, file, projectRoot, engine });
  } catch (e) {
    if (!e.log && !e.errors) throw e;
    failure = e;
  }
  const seconds = Math.round((Date.now() - started) / 100) / 10;
  const summary = {
    ...summarize(failure ? failure.finalLog || '' : result.finalLog, failure?.errors),
    engine,
    seconds,
  };
  const log = failure ? failure.finalLog || failure.log || '' : result.finalLog;
  if (args.include_log) summary.log = log.slice(-6000);
  if (failure) {
    summary.success = false;
    if (!failure.errors?.length) summary.message = failure.message;
    return summary;
  }
  await atomicWrite(output, result.pdf, true);
  summary.success = true;
  summary.pdf = output;
  if (result.pages) summary.pages = result.pages;
  if (result.size) summary.paper = paperName(result.size);
  return summary;
}

module.exports = { name, definition, buildLatexPdf, summarize, paperName };
