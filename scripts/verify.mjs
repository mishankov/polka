import { parseArgs } from 'node:util';
import { assertPreparedApp } from './release/prepared-app.mjs';
import { cli, run } from './lib/command.mjs';

export function verificationPlan(args = []) {
  const { values, positionals } = parseArgs({
    args,
    allowPositionals: true,
    options: { prebuilt: { type: 'boolean' }, help: { type: 'boolean' } },
  });
  if (values.help) return { help: true };
  const group = positionals[0] ?? 'all';
  if (positionals.length > 1 || !['all', 'desktop', 'workflows'].includes(group))
    throw Error('Choose one verification group: all, desktop, workflows.');
  const commands = values.prebuilt ? [] : [[process.execPath, ['scripts/build.mjs']]];
  if (group !== 'workflows')
    commands.push(
      ['npm', ['run', 'format:check']],
      ['npm', ['run', 'typecheck']],
      ['npm', ['test']],
      [process.execPath, ['scripts/test-desktop.mjs', 'core']],
    );
  if (group !== 'desktop')
    commands.push(
      [process.execPath, ['scripts/test-desktop.mjs', 'workflows']],
      [process.execPath, ['scripts/test-desktop.mjs', 'clipboard-storage']],
      [process.execPath, ['scripts/test-desktop.mjs', 'media']],
    );
  return { prebuilt: values.prebuilt, commands };
}

export async function main(args = process.argv.slice(2)) {
  const plan = verificationPlan(args);
  if (plan.help) {
    console.log(
      'Usage: npm run verify -- [all|desktop|workflows] [--prebuilt]\nBuild once and run the selected checks; --prebuilt reuses prepared output.',
    );
    return;
  }
  if (plan.prebuilt) await assertPreparedApp();
  for (const [command, commandArgs] of plan.commands) run(command, commandArgs);
}

cli(import.meta.url, () => main());
