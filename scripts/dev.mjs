import { spawn } from 'node:child_process';
import { resolve } from 'node:path';

// T3's Node transport sets this flag; the development Electron process needs GUI mode.
const env = Object.fromEntries(
  Object.entries(process.env).filter(([key]) => key !== 'ELECTRON_RUN_AS_NODE'),
);
const child = spawn(
  process.execPath,
  [resolve('node_modules/electron-vite/bin/electron-vite.js'), 'dev', ...process.argv.slice(2)],
  { stdio: 'inherit', env },
);
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => child.kill(signal));
child.on('error', (error) => {
  console.error(error);
  process.exitCode = 1;
});
child.on('exit', (code, signal) => {
  process.exitCode = code ?? (signal === 'SIGINT' ? 130 : 1);
});
