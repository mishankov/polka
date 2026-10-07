import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, rm, utimes } from 'node:fs/promises';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
// @ts-expect-error Build-time JavaScript.
import * as desktop from '../../scripts/test-desktop.mjs';
// @ts-expect-error Build-time JavaScript.
import { verificationPlan } from '../../scripts/verify.mjs';
// @ts-expect-error Build-time JavaScript.
import { packagingPlan } from '../../scripts/package.mjs';
// @ts-expect-error Build-time JavaScript.
import { run, runAll } from '../../scripts/lib/command.mjs';
// @ts-expect-error Build-time JavaScript.
import { nativeHelpers } from '../../scripts/build.mjs';
// @ts-expect-error Build-time JavaScript.
import { testPlan } from '../../scripts/test.mjs';

test('development preparation compiles only stale or missing native helpers', async () => {
  const root = await mkdtemp(join(tmpdir(), 'polka-native-preparation-'));
  const calls = join(root, 'compiler-calls');
  try {
    await Promise.all(['native', 'build', 'bin'].map((dir) => mkdir(join(root, dir))));
    for (const { source, output, dependencies = [] } of nativeHelpers) {
      for (const path of [source, ...dependencies]) {
        await writeFile(join(root, path), '// fixture');
        await utimes(join(root, path), 10, source.endsWith('ClipboardProbe.swift') ? 30 : 10);
      }
      await writeFile(join(root, output), 'previous build');
      await utimes(join(root, output), 20, 20);
    }
    await writeFile(
      join(root, 'bin', 'swiftc'),
      `#!/bin/sh
printf '%s\\n' "$*" >> "$COMPILER_CALLS"
while [ "$#" -gt 0 ]; do
  if [ "$1" = '-o' ]; then
    shift
    printf 'compiled fixture' > "$1"
    break
  fi
  shift
done
`,
      { mode: 0o755 },
    );
    const prepare = () => {
      const result = spawnSync(process.execPath, [resolve('scripts/prepare-dev.mjs')], {
        cwd: root,
        encoding: 'utf8',
        env: {
          ...process.env,
          PATH: `${join(root, 'bin')}:${process.env.PATH}`,
          COMPILER_CALLS: calls,
        },
      });
      assert.equal(result.status, 0, result.stderr);
    };
    prepare();
    prepare();
    assert.deepEqual((await readFile(calls, 'utf8')).trim().split('\n'), [
      '-O native/ClipboardProbe.swift -o build/clipboard-probe -framework AppKit',
    ]);
    assert.equal(await readFile(join(root, 'build', 'media-probe'), 'utf8'), 'previous build');
    await rm(join(root, 'build', 'sync-discovery'));
    prepare();
    assert.deepEqual((await readFile(calls, 'utf8')).trim().split('\n'), [
      '-O native/ClipboardProbe.swift -o build/clipboard-probe -framework AppKit',
      '-O native/SyncDiscovery.swift -o build/sync-discovery',
    ]);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('focused Node groups are disjoint and the default discovers their complete union', () => {
  const unit = testPlan(['unit']).files;
  const integration = testPlan(['integration']).files;
  assert(unit.length > 0);
  assert(integration.length > 0);
  assert(unit.every((file: string) => file.startsWith('tests/unit/')));
  assert(integration.every((file: string) => file.startsWith('tests/integration/')));
  assert.deepEqual(testPlan([]).files, [...unit, ...integration]);
  assert.equal(new Set(testPlan([]).files).size, unit.length + integration.length);
  const args = ['unit', '--test-name-pattern=search'];
  assert.deepEqual(testPlan(args).args.slice(0, 3), [
    'node_modules/tsx/dist/cli.mjs',
    '--test',
    '--test-name-pattern=search',
  ]);
  assert.deepEqual(args, ['unit', '--test-name-pattern=search']);
  assert.throws(() => testPlan(['typo']), /Choose one test group/);
});

const entries = (plan: any): string[] => plan.commands.map(([, args]: any) => args[1]);

test('default desktop coverage retains the harness, shelf fixtures and emoji fault case', () => {
  const plan = desktop.desktopPlan([], {});
  assert.deepEqual(entries(plan), [
    'tests/desktop/desktop-harness-smoke.ts',
    'tests/desktop/shelf-smoke.ts',
    'tests/desktop/shelf-search-shortcuts-smoke.ts',
    'tests/desktop/clipboard-startup-smoke.ts',
    'tests/desktop/emoji-smoke.ts',
    'tests/desktop/image-text-smoke.ts',
    'tests/desktop/file-shelf-smoke.ts',
  ]);
  assert.deepEqual(
    plan.commands.find(([, args]: any) => args[1].endsWith('/emoji-smoke.ts'))[1].slice(2),
    ['--empty-clipboard-item'],
  );
});

test('packaged tests retain their narrower coverage and isolate launch environment changes', () => {
  const env = { ELECTRON_RUN_AS_NODE: '1', EVERYTHING_EXECUTABLE: '/custom/Polka', EXTRA: 'kept' };
  const plan = desktop.desktopPlan(['--packaged'], env);
  assert.deepEqual(entries(plan), ['tests/desktop/shelf-smoke.ts']);
  assert.equal(plan.env.EVERYTHING_EXECUTABLE, 'release/mac-arm64/Polka.app/Contents/MacOS/Polka');
  assert.equal(plan.env.ELECTRON_RUN_AS_NODE, undefined);
  assert.equal(plan.env.EXTRA, 'kept');
  assert.equal(env.ELECTRON_RUN_AS_NODE, '1');
  assert.equal(env.EVERYTHING_EXECUTABLE, '/custom/Polka');
  assert.equal(desktop.desktopPlan(['clipboard'], env).env.EVERYTHING_EXECUTABLE, '/custom/Polka');
  assert.equal(desktop.desktopPlan(['workflows', '--packaged'], {}).commands.length, 5);
});

test('updater modes and interactive fixture options reach only their intended suite', () => {
  for (const option of ['--self-signed', '--migrate-self-signed']) {
    const plan = desktop.desktopPlan(['updates', '--prebuilt', option], {});
    assert.deepEqual(plan.commands[0][1].slice(2), ['--prebuilt', option]);
  }
  assert.deepEqual(desktop.desktopPlan(['clipboard-paste', '--dev'], {}).commands[0][1].slice(2), [
    '--dev',
  ]);
  for (const suite of ['clipboard-actions', 'clipboard-images'])
    assert.deepEqual(desktop.desktopPlan([suite, '--native'], {}).commands[0][1].slice(2), [
      '--native',
    ]);
  assert.deepEqual(
    desktop.desktopPlan(['shelf-search', '--case', 'emoji'], {}).commands[0][1].slice(2),
    ['--case', 'emoji'],
  );
  for (const args of [
    ['unknown'],
    ['shelf', 'emoji'],
    ['core', '--prebuilt'],
    ['media', '--packaged'],
    ['clipboard-paste', '--packaged'],
    ['clipboard', '--dev'],
    ['emoji', '--native'],
    ['updates', '--self-signed', '--migrate-self-signed'],
    ['updates', '--typo'],
    ['emoji', '--case', 'emoji'],
  ])
    assert.throws(() => desktop.desktopPlan(args, {}), /./, args.join(' '));
});

test('independent suites finish sequentially and retain every failure', () => {
  const calls: string[] = [];
  const failed = Error('Fixture failed');
  assert.throws(
    () =>
      desktop.main([], {}, (_command: string, args: string[]) => {
        calls.push(args[1]);
        if (calls.length === 1 || calls.length === 3) throw failed;
      }),
    (error: any) =>
      error instanceof AggregateError &&
      error.errors.length === 2 &&
      error.errors.every((item: unknown) => item === failed),
  );
  assert.deepEqual(calls, entries(desktop.desktopPlan([], {})));
  assert.throws(
    () => run(process.execPath, ['-e', 'process.exit(7)'], { stdio: 'ignore' }),
    (error: any) => error.exitCode === 7,
  );
  assert.throws(
    () =>
      runAll(
        [
          ['first', []],
          ['second', []],
        ],
        {},
        () => {
          throw failed;
        },
      ),
    (error: any) =>
      error instanceof AggregateError &&
      error.errors.length === 2 &&
      (error as { exitCode?: number }).exitCode === 1,
  );
});

test('verification builds once and preserves independently selectable CI groups', () => {
  const all = verificationPlan([]).commands;
  assert.equal(all.filter(([, args]: any) => args[0] === 'scripts/build.mjs').length, 1);
  assert.deepEqual(
    all.map(([, args]: any) => args.join(' ')),
    [
      'scripts/build.mjs',
      'run format:check',
      'run typecheck',
      'test',
      'scripts/test-desktop.mjs core',
      'scripts/test-desktop.mjs workflows',
      'scripts/test-desktop.mjs clipboard-storage',
      'scripts/test-desktop.mjs media',
    ],
  );
  assert.equal(verificationPlan(['desktop', '--prebuilt']).commands.length, 4);
  assert.deepEqual(
    verificationPlan(['workflows', '--prebuilt']).commands.map(([, args]: any) => args.at(-1)),
    ['workflows', 'clipboard-storage', 'media'],
  );
  assert.throws(() => verificationPlan(['unknown']));
});

test('packaging reuses prepared output and forwards builder arguments without losing values', () => {
  const plan = packagingPlan(['--dir', '--prebuilt', '--publish', 'never', '-c.mac.identity=-']);
  assert.equal(plan.commands.length, 1);
  assert.equal(plan.prebuilt, true);
  assert.deepEqual(plan.commands[0][1], [
    '--mac',
    'dir',
    '--arm64',
    '--publish',
    'never',
    '-c.mac.identity=-',
  ]);
  assert.equal(packagingPlan([]).commands.length, 2);
});

test('prebuilt commands fail before running checks or packaging when output is absent', async () => {
  const root = await mkdtemp(join(tmpdir(), 'polka-missing-build-'));
  try {
    for (const script of ['verify', 'package']) {
      const result = spawnSync(process.execPath, [resolve(`scripts/${script}.mjs`), '--prebuilt'], {
        cwd: root,
        encoding: 'utf8',
      });
      assert.equal(result.status, 1, result.stdout + result.stderr);
      assert.match(result.stderr, /Missing prepared app output out\/main\/index.js/);
      assert.equal(result.stdout, '');
    }
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('release source jobs support both consolidated commands and older checked-out tags', async () => {
  const yaml = createRequire(resolve('package.json'))('js-yaml');
  const workflow = yaml.load(readFileSync('.github/workflows/release.yml', 'utf8'));
  const steps = workflow.jobs.verify.steps;
  const build = steps.find((step: any) => step.name === 'Build app and native helpers once').run;
  const source = steps.find((step: any) => step.if === "matrix.suite == 'desktop'").run;
  const workflows = steps.find((step: any) => step.if === "matrix.suite == 'workflows'").run;
  for (const current of [false, true]) {
    const root = await mkdtemp(join(tmpdir(), 'polka-command-workflow-'));
    try {
      const bin = join(root, 'bin');
      const calls = join(root, 'npm-calls');
      await mkdir(bin);
      await writeFile(join(bin, 'npm'), '#!/bin/sh\nprintf "%s\\n" "$*" >> "$NPM_CALLS"\n', {
        mode: 0o755,
      });
      if (current) {
        await mkdir(join(root, 'scripts'));
        await writeFile(join(root, 'scripts/build.mjs'), '');
        await writeFile(join(root, 'scripts/verify.mjs'), '');
      }
      const result = spawnSync(
        'bash',
        ['-e', '-o', 'pipefail', '-c', [build, source, workflows].join('\n')],
        {
          cwd: root,
          encoding: 'utf8',
          env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, NPM_CALLS: calls },
        },
      );
      assert.equal(result.status, 0, result.stderr);
      assert.deepEqual(
        (await readFile(calls, 'utf8')).trim().split('\n'),
        current
          ? ['run build', 'run verify -- desktop --prebuilt', 'run verify -- workflows --prebuilt']
          : [
              'run build',
              'run native:build',
              'run typecheck',
              'test',
              'run test:desktop',
              'run test:workflows',
              'run test:media',
            ],
      );
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  }
});

test('macOS CI shares source runners and caches only exact native builds', async () => {
  const yaml = createRequire(resolve('package.json'))('js-yaml');
  const workflow = yaml.load(readFileSync('.github/workflows/build.yml', 'utf8'));
  const action = yaml.load(readFileSync('.github/actions/prepare-macos/action.yml', 'utf8'));
  assert.equal(workflow.jobs.verify.strategy, undefined);
  assert.equal(workflow.jobs.updates.strategy.matrix.include.length, 3);
  assert.deepEqual(workflow.jobs['macos-arm64'].needs, ['verify', 'package', 'updates']);
  for (const job of ['verify', 'package', 'updates'])
    assert(
      workflow.jobs[job].steps.some((step: any) => step.uses === './.github/actions/prepare-macos'),
    );
  const native = action.runs.steps.find((step: any) => step.id === 'native');
  assert.deepEqual(
    native.with.path.trim().split('\n').sort(),
    nativeHelpers.map((helper: any) => helper.output).sort(),
  );
  assert.equal(native.with['restore-keys'], undefined);
  for (const dependency of [
    'native/**/*.swift',
    'native/**/*.plist',
    'scripts/build.mjs',
    'steps.toolchain.outputs.key',
  ])
    assert(native.with.key.includes(dependency));
  const toolchain = action.runs.steps.find((step: any) => step.id === 'toolchain').run;
  for (const identity of [
    'sw_vers -productVersion',
    'xcodebuild -version',
    'xcrun swiftc --version',
    'xcrun --show-sdk-version',
  ])
    assert(toolchain.includes(identity));
  assert.equal(action.runs.steps[0].with['node-version-file'], '.node-version');
  const compile = action.runs.steps.find((step: any) => step.name === 'Build native helpers');
  assert.equal(compile.if, "steps.native.outputs.cache-hit != 'true'");
  const javascript = action.runs.steps.find((step: any) => step.name === 'Build app');
  const root = await mkdtemp(join(tmpdir(), 'polka-ci-cache-'));
  try {
    await mkdir(join(root, 'bin'));
    await writeFile(join(root, 'bin/npm'), '#!/bin/sh\nprintf "%s\\n" "$*" >> "$NPM_CALLS"\n', {
      mode: 0o755,
    });
    for (const hit of [false, true]) {
      const calls = join(root, hit ? 'warm' : 'cold');
      const result = spawnSync(
        'bash',
        ['-e', '-c', [!hit ? compile.run : '', javascript.run].join('\n')],
        {
          cwd: root,
          encoding: 'utf8',
          env: {
            ...process.env,
            PATH: `${join(root, 'bin')}:${process.env.PATH}`,
            NPM_CALLS: calls,
          },
        },
      );
      assert.equal(result.status, 0, result.stderr);
      assert.deepEqual(
        (await readFile(calls, 'utf8')).trim().split('\n'),
        hit
          ? ['run build -- --javascript']
          : ['run build -- --native', 'run build -- --javascript'],
      );
    }
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
