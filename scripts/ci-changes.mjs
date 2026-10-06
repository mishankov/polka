import { spawnSync } from 'node:child_process';
import { appendFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

/** Only known non-build inputs may bypass the macOS suites. */
export function requiresMacos(env = process.env, cwd = process.cwd()) {
  const event = env.EVENT_NAME;
  if (!['pull_request', 'push'].includes(event)) return true;
  const base = event === 'pull_request' ? env.PR_BASE_SHA : env.BEFORE_SHA;
  const head = event === 'pull_request' ? env.PR_HEAD_SHA : env.HEAD_SHA;
  if (!base || !head || /^0+$/.test(base)) return true;
  const range = event === 'pull_request' ? `${base}...${head}` : `${base}..${head}`;
  // Renames must include the old path: moving source into docs still changes the app.
  const diff = spawnSync('git', ['diff', '--name-only', '--no-renames', '-z', range, '--'], {
    cwd,
    encoding: 'utf8',
  });
  if (diff.status !== 0) return true;
  return diff.stdout
    .split('\0')
    .filter(Boolean)
    .some(
      (path) =>
        path !== 'README.md' &&
        path !== 'AGENTS.md' &&
        !/^docs\/.*\.md$/.test(path) &&
        !path.startsWith('.agents/') &&
        !/^release-notes\/[^/]+\.json$/.test(path),
    );
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const macos = requiresMacos();
  appendFileSync(process.env.GITHUB_OUTPUT, `macos=${macos}\n`);
  console.log(
    macos
      ? 'App or build inputs changed: run macOS checks.'
      : 'Only documentation, notes, or agent instructions changed: skip macOS checks.',
  );
}
