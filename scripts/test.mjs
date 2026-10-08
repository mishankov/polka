import { readdirSync } from 'node:fs';
import { cli, run } from './lib/command.mjs';

export function testPlan(input = []) {
  const args = [...input];
  if (args.includes('--help')) return { help: true };
  const group = args[0] && !args[0].startsWith('-') ? args.shift() : 'all';
  if (!['all', 'unit', 'integration'].includes(group))
    throw Error('Choose one test group: all, unit, integration.');
  const groups = group === 'all' ? ['unit', 'integration'] : [group];
  const files = groups.flatMap((name) =>
    readdirSync(`tests/${name}`)
      .filter((file) => file.endsWith('.test.ts'))
      .sort()
      .map((file) => `tests/${name}/${file}`),
  );
  if (!files.length) throw Error(`No tests found for ${group}.`);
  return { args: ['node_modules/tsx/dist/cli.mjs', '--test', ...args, ...files], files };
}

export function main(args = process.argv.slice(2)) {
  const plan = testPlan([...args]);
  if (plan.help) {
    console.log(
      'Usage: npm test -- [all|unit|integration] [Node test options]\nDefault: all. Unit tests need no build or macOS tools; build before integration tests.',
    );
    return;
  }
  run(process.execPath, plan.args);
}

cli(import.meta.url, () => main());
