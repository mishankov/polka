import { execFileSync } from 'node:child_process';

execFileSync('npm', ['ci'], { stdio: 'inherit' });
execFileSync(process.execPath, ['scripts/prepare-dev.mjs'], { stdio: 'inherit' });
console.log(
  'Worktree ready. Run npm run dev; its checkout and isolated profile are printed at startup.',
);
