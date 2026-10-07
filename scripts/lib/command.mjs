import { spawnSync } from 'node:child_process';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export function run(command, args, options = {}) {
  const result = spawnSync(command, args, { stdio: 'inherit', ...options });
  if (result.status !== 0) {
    const error = Error(
      `${command} failed (${result.status ?? result.signal ?? 'could not start'}).`,
    );
    error.exitCode = result.status ?? 1;
    throw error;
  }
}

export function cli(url, main) {
  if (!process.argv[1] || resolve(process.argv[1]) !== fileURLToPath(url)) return;
  Promise.resolve()
    .then(main)
    .catch((error) => {
      console.error(error.message);
      process.exitCode = error.exitCode ?? 1;
    });
}
