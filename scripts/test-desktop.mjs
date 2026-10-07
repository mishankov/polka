import { parseArgs } from 'node:util';
import { cli, run, runAll } from './lib/command.mjs';

const suites = {
  core: [
    'desktop-harness-smoke',
    'shelf-smoke',
    'shelf-search-shortcuts-smoke',
    'clipboard-startup-smoke',
    'emoji-smoke',
    'image-text-smoke',
    'file-shelf-smoke',
  ],
  shelf: ['shelf-smoke', 'shelf-search-shortcuts-smoke', 'clipboard-startup-smoke'],
  'shelf-search': ['shelf-search-shortcuts-smoke'],
  'clipboard-startup': ['clipboard-startup-smoke'],
  harness: ['desktop-harness-smoke'],
  emoji: ['emoji-smoke'],
  workflows: [
    'clipboard-smoke',
    'clipboard-actions-smoke',
    'clipboard-screenshot-smoke',
    'clipboard-animation-smoke',
    'clipboard-snippets-smoke',
  ],
  clipboard: ['clipboard-smoke'],
  'clipboard-actions': ['clipboard-actions-smoke'],
  'clipboard-images': ['clipboard-screenshot-smoke'],
  'clipboard-animation': ['clipboard-animation-smoke'],
  'clipboard-storage': ['clipboard-storage-smoke'],
  'clipboard-paste': ['clipboard-paste-smoke'],
  'clipboard-sync': ['clipboard-sync-smoke'],
  'clipboard-snippets': ['clipboard-snippets-smoke'],
  'clipboard-ocr': ['image-text-smoke'],
  'file-shelf': ['file-shelf-smoke'],
  'file-shelf-native': ['file-shelf-native-smoke'],
  media: ['media-indicator-smoke'],
  updates: ['updates-smoke'],
};

export function desktopPlan(args = [], env = process.env) {
  const { values, positionals } = parseArgs({
    args,
    allowPositionals: true,
    options: Object.fromEntries([
      ...[
        'packaged',
        'prebuilt',
        'dev',
        'native',
        'finder',
        'self-signed',
        'migrate-self-signed',
        'help',
      ].map((name) => [name, { type: 'boolean' }]),
      ['case', { type: 'string' }],
    ]),
  });
  if (values.help) return { help: true };
  const suite = positionals[0] ?? (values.packaged ? 'shelf' : 'core');
  if (positionals.length > 1 || !Object.hasOwn(suites, suite))
    throw Error(`Choose one desktop suite: ${Object.keys(suites).join(', ')}.`);
  for (const [option, allowed] of Object.entries({
    packaged: [
      'shelf',
      'workflows',
      'clipboard',
      'clipboard-actions',
      'clipboard-images',
      'clipboard-animation',
      'emoji',
      'clipboard-snippets',
    ],
    finder: ['file-shelf-native'],
    prebuilt: ['updates'],
    dev: ['clipboard-paste'],
    native: ['clipboard-actions', 'clipboard-images'],
    'self-signed': ['updates'],
    'migrate-self-signed': ['updates'],
    case: ['shelf-search'],
  })) {
    if (values[option] && !allowed.includes(suite))
      throw Error(`--${option} is not supported by the ${suite} suite.`);
  }
  if (values['self-signed'] && values['migrate-self-signed'])
    throw Error('Choose --self-signed or --migrate-self-signed, not both.');
  const childEnv = Object.fromEntries(
    Object.entries(env).filter(([key]) => key !== 'ELECTRON_RUN_AS_NODE'),
  );
  if (values.packaged)
    childEnv.EVERYTHING_EXECUTABLE = 'release/mac-arm64/Polka.app/Contents/MacOS/Polka';
  // Packaged shelf coverage has always used the native shelf smoke alone.
  const tests = values.packaged && suite === 'shelf' ? ['shelf-smoke'] : suites[suite];
  const flags = ['prebuilt', 'dev', 'native', 'finder', 'self-signed', 'migrate-self-signed']
    .filter((name) => values[name])
    .map((name) => `--${name}`);
  if (values.case) flags.push('--case', values.case);
  return {
    env: childEnv,
    commands: tests.map((name) => [
      process.execPath,
      [
        'node_modules/tsx/dist/cli.mjs',
        `tests/desktop/${name}.ts`,
        ...(name === 'emoji-smoke' ? ['--empty-clipboard-item'] : []),
        ...flags,
      ],
    ]),
  };
}

export function main(args = process.argv.slice(2), env = process.env, execute = run) {
  const plan = desktopPlan(args, env);
  if (plan.help) {
    console.log(
      `Usage: npm run test:desktop -- [suite] [options]\nDefault: core; --packaged defaults to shelf. Build first, except for updates.\nSuites: ${Object.keys(suites).join(', ')}\nOptions: --packaged, --prebuilt (updates), --dev (clipboard-paste), --native (clipboard-actions or clipboard-images), --finder (file-shelf-native), --self-signed or --migrate-self-signed (updates), --case ID (shelf-search: catalog, calculations, search-actions, ranking, clipboard, emoji, restoration, updates).`,
    );
    return;
  }
  runAll(plan.commands, { env: plan.env }, execute);
}

cli(import.meta.url, () => main());
