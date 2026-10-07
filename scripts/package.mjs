import { assertPreparedApp } from './release/prepared-app.mjs';
import { cli, run } from './lib/command.mjs';

export function packagingPlan(args = []) {
  const prebuilt = args.includes('--prebuilt');
  const directory = args.includes('--dir');
  return {
    help: args.includes('--help'),
    prebuilt,
    commands: [
      ...(prebuilt ? [] : [[process.execPath, ['scripts/build.mjs']]]),
      [
        'node_modules/.bin/electron-builder',
        [
          '--mac',
          ...(directory ? ['dir'] : ['dmg', 'zip']),
          '--arm64',
          ...args.filter((arg) => !['--prebuilt', '--dir'].includes(arg)),
        ],
      ],
    ],
  };
}

export async function main(args = process.argv.slice(2)) {
  const plan = packagingPlan(args);
  if (plan.help) {
    console.log(
      'Usage: npm run package -- [--dir] [--prebuilt] [electron-builder options]\nBuild and package arm64 DMG/ZIP; --dir creates an unpacked app, --prebuilt reuses prepared output.',
    );
    return;
  }
  if (plan.prebuilt) await assertPreparedApp();
  for (const [command, commandArgs] of plan.commands) run(command, commandArgs);
}

cli(import.meta.url, () => main());
