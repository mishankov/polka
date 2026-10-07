import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { mkdtemp, mkdir, readFile, writeFile, copyFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const yaml = createRequire(resolve('package.json'))('js-yaml');
const workflow = yaml.load(readFileSync('.github/workflows/release.yml', 'utf8'));
const prepare = workflow.jobs.prepare.steps.find((step: any) => step.id === 'release').run;
const tag = 'v0.2.0';
const notes = { ru: '• Из проверенного коммита.', en: '• From the verified commit.' };

/** Execute the real preparation shell against local Git and an isolated GitHub stand-in. */
async function fixture(
  options: {
    notes?: unknown;
    missing?: boolean;
    tagged?: boolean;
    existing?: 'draft' | 'published';
    legacy?: boolean;
    race?: boolean;
  } = {},
) {
  const root = await mkdtemp(join(tmpdir(), 'polka-release-workflow-'));
  const source = join(root, 'source');
  const remote = join(root, 'origin.git');
  const bin = join(root, 'bin');
  const log = join(root, 'calls.jsonl');
  const output = join(root, 'outputs');
  await Promise.all([mkdir(source), mkdir(bin), writeFile(log, ''), writeFile(output, '')]);
  const git = (...args: string[]) => {
    const result = spawnSync('git', args, { cwd: source, encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    return result.stdout.trim();
  };
  git('init', '--bare', remote);
  git('init', '-b', 'master');
  git('remote', 'add', 'origin', remote);
  await mkdir(join(source, 'scripts'));
  await mkdir(join(source, 'release-notes'));
  for (const name of ['release-notes.mjs', 'release-version.mjs'])
    await copyFile(resolve('scripts', name), join(source, 'scripts', name));
  if (!options.missing)
    await writeFile(
      join(source, 'release-notes/0.2.0.json'),
      JSON.stringify(options.notes ?? notes),
    );
  git('add', '.');
  if (options.legacy) git('rm', '--cached', 'scripts/release-notes.mjs');
  git(
    '-c',
    'user.name=Release test',
    '-c',
    'user.email=release@example.invalid',
    'commit',
    '-m',
    'Release source',
  );
  const commit = git('rev-parse', 'HEAD');
  git('push', 'origin', 'master');
  if (options.tagged) {
    git('tag', tag);
    git('push', 'origin', tag);
  }
  let racedCommit: string | undefined;
  if (options.race) {
    await writeFile(join(source, 'branch-movement.txt'), 'A different release source');
    git('add', 'branch-movement.txt');
    git(
      '-c',
      'user.name=Release test',
      '-c',
      'user.email=release@example.invalid',
      'commit',
      '-m',
      'Branch moved',
    );
    racedCommit = git('rev-parse', 'HEAD');
    git('push', 'origin', 'master');
  }
  // The workflow checkout differs from the release source; it must not supply the notes.
  await writeFile(
    join(source, 'release-notes/0.2.0.json'),
    JSON.stringify({ ru: 'Неверный текст', en: 'Wrong checkout notes' }),
  );
  await writeFile(
    join(bin, 'gh'),
    `#!/usr/bin/env node
const fs = require('node:fs');
const { spawnSync } = require('node:child_process');
const args = process.argv.slice(2);
fs.appendFileSync(process.env.RELEASE_TEST_LOG, JSON.stringify(args) + '\\n');
if (args[0] === 'release' && args[1] === 'view') {
  if (!process.env.RELEASE_TEST_EXISTING) process.exit(1);
  console.log(JSON.stringify({isDraft:process.env.RELEASE_TEST_EXISTING === 'draft',targetCommitish:'master'}));
} else if (args[0] === 'release' && args[1] === 'create') {
  const noteIndex = args.indexOf('--notes-file');
  if (noteIndex >= 0) fs.copyFileSync(args[noteIndex + 1], process.env.RELEASE_TEST_DESCRIPTION);
} else if (args[0] === 'api' && args.includes('POST')) {
  const ref = args.find(arg => arg.startsWith('ref=')).slice(4);
  const sha = process.env.RELEASE_TEST_RACE || args.find(arg => arg.startsWith('sha=')).slice(4);
  const result = spawnSync('git', ['--git-dir', process.env.RELEASE_TEST_REMOTE, 'update-ref', ref, sha]);
  if (result.status !== 0) process.exit(result.status || 1);
} else if (args[0] === 'api' && args[1].includes('/commits/')) {
  console.log(process.env.RELEASE_TEST_COMMIT);
} else {
  console.error('Unexpected GitHub operation', args);
  process.exit(2);
}
`,
    { mode: 0o755 },
  );
  const run = () =>
    spawnSync('bash', ['-e', '-o', 'pipefail', '-c', prepare], {
      cwd: source,
      encoding: 'utf8',
      env: {
        ...process.env,
        PATH: `${bin}:${process.env.PATH}`,
        GH_TOKEN: 'fixture-token',
        EVENT_NAME: 'workflow_dispatch',
        REQUESTED_TAG: tag,
        RELEASE_TAG: '',
        PRERELEASE: 'false',
        DEFAULT_BRANCH: 'master',
        GITHUB_REPOSITORY: 'fixture/polka',
        RUNNER_TEMP: root,
        GITHUB_OUTPUT: output,
        RELEASE_TEST_LOG: log,
        RELEASE_TEST_REMOTE: remote,
        RELEASE_TEST_COMMIT: commit,
        RELEASE_TEST_EXISTING: options.existing || '',
        RELEASE_TEST_RACE: racedCommit || '',
        RELEASE_TEST_DESCRIPTION: join(root, 'github-description.md'),
      },
    });
  return {
    root,
    commit,
    git,
    run,
    calls: async (): Promise<string[][]> =>
      (await readFile(log, 'utf8'))
        .trim()
        .split('\n')
        .filter(Boolean)
        .map((line) => JSON.parse(line)),
    outputs: async () =>
      Object.fromEntries(
        (await readFile(output, 'utf8'))
          .trim()
          .split('\n')
          .filter(Boolean)
          .map((line) => line.split('=')),
      ),
    cleanup: () => rm(root, { recursive: true, force: true }),
  };
}

test('new releases preflight immutable notes and pin the draft and tag to the validated source', async () => {
  const f = await fixture();
  try {
    const result = f.run();
    assert.equal(result.status, 0, result.stdout + result.stderr);
    const outputs = await f.outputs();
    assert.equal(outputs.commit, f.commit);
    assert.equal(outputs.has_notes, 'true');
    assert.equal(outputs.publish_after_upload, 'true');
    const create = (await f.calls()).find((call) => call[0] === 'release' && call[1] === 'create')!;
    assert.equal(create[create.indexOf('--target') + 1], f.commit);
    assert(!create.includes('--generate-notes'));
    const description = await readFile(join(f.root, 'github-description.md'), 'utf8');
    assert.ok(description.startsWith('# Polka 0.2.0\n'));
    assert.ok(description.includes('- Из проверенного коммита.'));
    assert.ok(description.includes('- From the verified commit.'));
    assert.ok(!description.includes('Wrong checkout notes'));
    assert.ok(description.includes('### Установка'));
    assert.ok(description.includes('### Installation'));
    assert.ok(
      description.includes(
        'https://github.com/fixture/polka/releases/download/v0.2.0/polka-0.2.0-arm64.dmg',
      ),
    );
    assert.equal(
      f.git('--git-dir', join(f.root, 'origin.git'), 'rev-parse', `refs/tags/${tag}`),
      f.commit,
    );
  } finally {
    await f.cleanup();
  }
});

test('missing or invalid translations stop preparation before creating a draft or tag', async () => {
  for (const options of [
    { missing: true },
    { notes: { ru: 'Нет английского' } },
    { notes: { ru: ' ', en: 'English' } },
  ]) {
    const f = await fixture(options);
    try {
      assert.notEqual(f.run().status, 0);
      const calls = await f.calls();
      assert(!calls.some((call) => call[1] === 'create' || call.includes('POST')));
      assert.deepEqual(await f.outputs(), {});
      assert.equal(f.git('ls-remote', '--refs', 'origin', `refs/tags/${tag}`), '');
    } finally {
      await f.cleanup();
    }
  }
});

test('existing published tags are reused without changing source or recreating the release', async () => {
  const f = await fixture({ tagged: true, existing: 'published' });
  try {
    const result = f.run();
    assert.equal(result.status, 0, result.stdout + result.stderr);
    const outputs = await f.outputs();
    assert.equal(outputs.commit, f.commit);
    assert.equal(outputs.publish_after_upload, 'false');
    assert.equal(outputs.has_notes, 'true');
    assert(!(await f.calls()).some((call) => call[0] === 'api' || call[1] === 'create'));
  } finally {
    await f.cleanup();
  }
});

test('an existing draft without a tag resumes the same source instead of creating a duplicate', async () => {
  const f = await fixture({ existing: 'draft' });
  try {
    const result = f.run();
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.equal((await f.outputs()).publish_after_upload, 'true');
    assert(!(await f.calls()).some((call) => call[1] === 'create'));
    assert.equal((await f.calls()).filter((call) => call.includes('POST')).length, 1);
  } finally {
    await f.cleanup();
  }
});

test('legacy source is permitted only for an existing release retry', async () => {
  for (const existing of ['published', undefined] as const) {
    const f = await fixture({ legacy: true, tagged: true, existing });
    try {
      const result = f.run();
      if (existing) {
        assert.equal(result.status, 0, result.stdout + result.stderr);
        assert.equal((await f.outputs()).has_notes, 'false');
      } else assert.notEqual(result.status, 0);
      assert(!(await f.calls()).some((call) => call[1] === 'create' || call.includes('POST')));
    } finally {
      await f.cleanup();
    }
  }
});

test('a tag race aborts instead of building a source that was not preflighted', async () => {
  const f = await fixture({ race: true });
  try {
    const result = f.run();
    assert.notEqual(result.status, 0);
    assert.match(result.stdout, /Release tag changed/);
    assert.deepEqual(await f.outputs(), {});
    const create = (await f.calls()).find((call) => call[1] === 'create')!;
    assert.equal(create[create.indexOf('--target') + 1], f.commit);
  } finally {
    await f.cleanup();
  }
});
