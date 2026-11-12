'use strict';
const path = require('node:path');
const os = require('node:os');
const { isSea } = require('node:sea');
const { runHelper, pipeName } = require('./mcp.cjs');

const standalone = isSea();
const args = process.argv.slice(2);
function option(name, fallback) {
  if (standalone) return fallback;
  const index = args.findIndex((value) => value.startsWith(name + '='));
  return index < 0 ? fallback : args.splice(index, 1)[0].slice(name.length + 1);
}
const appPath = standalone ? null : option('--dev-app', path.resolve(__dirname, '..'));
const userData = option(
  '--inkline-user-data',
  path.join(
    process.env.APPDATA || path.join(os.homedir(), 'Library', 'Application Support'),
    process.platform === 'win32' ? 'Inkline' : 'Inkline-Windows-Development',
  ),
);
const guiExecutable = option(
  '--gui-executable',
  standalone ? path.join(path.dirname(process.execPath), 'Inkline.exe') : require('electron'),
);
const command = args.indexOf('mcp');
if (command >= 0) args.splice(command, 1);
runHelper({
  app: { isPackaged: standalone, exit: (code) => process.exit(code) },
  args,
  pipe: pipeName(standalone ? path.dirname(guiExecutable) : appPath, userData),
  userData,
  appPath,
  guiExecutable,
}).catch((error) => {
  process.stderr.write('Inkline MCP: ' + error.message + '\n');
  process.exit(1);
});
