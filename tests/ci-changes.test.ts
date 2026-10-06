import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, rename, rm } from 'node:fs/promises';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
// @ts-expect-error Dependency-free CI script.
import { requiresMacos } from '../scripts/ci-changes.mjs';

test('real Git diffs skip docs but retain earlier source changes, renames, and packaged data', async () => {
  const root = await mkdtemp(join(tmpdir(), 'polka-ci-changes-'));
  const git = (...args: string[]) => {
    const result = spawnSync('git', args, { cwd: root, encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    return result.stdout.trim();
  };
  const write = async (path: string, value: string) => {
    await mkdir(dirname(join(root, path)), { recursive: true });
    await writeFile(join(root, path), value);
  };
  const commit = () => {
    git('add', '.');
    git(
      '-c',
      'user.name=CI test',
      '-c',
      'user.email=ci@example.invalid',
      'commit',
      '-m',
      'Fixture',
    );
    return git('rev-parse', 'HEAD');
  };
  const check = (base: string, head: string, event = 'push') =>
    requiresMacos(
      { EVENT_NAME: event, BEFORE_SHA: base, HEAD_SHA: head, PR_BASE_SHA: base, PR_HEAD_SHA: head },
      root,
    );
  try {
    git('init', '-b', 'master');
    await write('README.md', 'Before');
    await write('src/main.ts', 'Before');
    await write('docs/unicode-license.txt', 'Packaged license');
    const base = commit();
    await write('README.md', 'Updated');
    await write('docs/macos.md', 'Instructions');
    await write('release-notes/0.3.0.json', '{}');
    await write('.agents/skills/release-project/SKILL.md', 'Instructions');
    const docs = commit();
    assert.equal(check(base, docs), false);
    assert.equal(check(base, docs, 'pull_request'), false);
    await write('src/main.ts', 'Changed app');
    commit();
    await write('README.md', 'Latest commit is docs only');
    const mixed = commit();
    assert.equal(check(docs, mixed), true, 'inspect the whole push, not just its last commit');
    assert.equal(check(base, mixed, 'pull_request'), true);
    await rename(join(root, 'src/main.ts'), join(root, 'docs/main.md'));
    const moved = commit();
    assert.equal(check(mixed, moved), true, 'source renamed into docs still changes app inputs');
    await rm(join(root, 'docs/unicode-license.txt'));
    const removed = commit();
    assert.equal(check(moved, removed), true, 'packaged docs data is a build input');
    assert.equal(check(base, docs, 'workflow_dispatch'), true);
    assert.equal(check('0'.repeat(40), docs), true);
    assert.equal(check('f'.repeat(40), docs), true, 'unresolvable history must run full checks');
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('the real aggregate command accepts only successful builds or intentional docs skips', () => {
  const yaml = createRequire(resolve('package.json'))('js-yaml');
  const workflow = yaml.load(readFileSync('.github/workflows/build.yml', 'utf8'));
  const command = workflow.jobs['macos-arm64'].steps[0].run;
  for (const [macos, changeResult, results, success] of [
    ['true', 'success', ['success', 'success', 'success'], true],
    ['false', 'success', ['skipped', 'skipped', 'skipped'], true],
    ['true', 'success', ['success', 'failure', 'success'], false],
    ['true', 'success', ['success', 'cancelled', 'success'], false],
    ['true', 'success', ['skipped', 'skipped', 'skipped'], false],
    ['false', 'failure', ['skipped', 'skipped', 'skipped'], false],
    ['', 'success', ['skipped', 'skipped', 'skipped'], false],
    ['false', 'success', ['success', 'skipped', 'skipped'], false],
  ] as const) {
    const result = spawnSync('bash', ['-e', '-o', 'pipefail', '-c', command], {
      encoding: 'utf8',
      env: {
        ...process.env,
        RESULTS: JSON.stringify({
          changes: { result: changeResult, outputs: { macos } },
          verify: { result: results[0] },
          package: { result: results[1] },
          updates: { result: results[2] },
        }),
      },
    });
    assert.equal(result.status === 0, success, result.stderr || result.stdout);
  }
});
