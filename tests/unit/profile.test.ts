import test from 'node:test';
import assert from 'node:assert/strict';
import { profilePathFor } from '../../src/main/profile';

test('development profiles persist per checkout and separate identically named worktrees', () => {
  const options = { appData: '/profiles', packaged: false, checkout: '/one/worktree' };
  const first = profilePathFor(options);
  assert.equal(profilePathFor({ ...options, checkout: '/one/./worktree' }), first);
  assert.notEqual(profilePathFor({ ...options, checkout: '/two/worktree' }), first);
  assert.match(first, /^\/profiles\/polka-development\/worktree-[a-f0-9]{12}$/);
});

test('packaged profiles preserve existing data and explicit test/development overrides win', () => {
  const options = { appData: '/profiles', packaged: true, checkout: '/checkout' };
  assert.equal(profilePathFor(options), '/profiles/Everything App');
  assert.equal(profilePathFor({ ...options, override: '/test-profile' }), '/test-profile');
  assert.equal(
    profilePathFor({ ...options, packaged: false, override: '/test-profile' }),
    '/test-profile',
  );
});
