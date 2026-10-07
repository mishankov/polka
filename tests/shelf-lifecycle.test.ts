import test from 'node:test';
import assert from 'node:assert/strict';
import { ShelfLifecycle } from '../src/main/shelf-lifecycle';

function opened(destination: 'clipboard' | 'emoji' = 'clipboard') {
  const shelf = new ShelfLifecycle();
  const { entry } = shelf.begin(destination, 0);
  assert.equal(shelf.commit(entry.revision), true);
  return shelf;
}

test('generic reopen resumes only before the closed-minute boundary; direct navigation is fresh', () => {
  for (const destination of ['clipboard', 'emoji'] as const) {
    for (const [elapsed, expected] of [
      [59_999, destination],
      [60_000, 'apps'],
    ] as const) {
      const shelf = opened(destination);
      shelf.close(100);
      const { entry, newSession } = shelf.begin(undefined, 100 + elapsed);
      assert.equal(entry.destination, expected);
      assert.equal(entry.entryMode, elapsed < 60_000 ? 'resume' : 'fresh');
      assert.equal(newSession, true);
      assert.equal(entry.sessionId, 2);
    }
    const shelf = opened(destination);
    shelf.close(100);
    const { entry } = shelf.begin(destination, 101, 'specific query');
    assert.equal(entry.destination, destination);
    assert.equal(entry.entryMode, 'fresh');
    assert.equal(entry.searchQuery, 'specific query');
  }
});

test('navigation and open time preserve the session; returning to Apps changes the remembered destination', () => {
  const shelf = opened();
  const generic = shelf.begin(undefined, 120_000);
  assert.equal(generic.newSession, false);
  assert.equal(generic.entry.destination, 'clipboard');
  assert.equal(generic.entry.entryMode, 'resume');
  shelf.commit(generic.entry.revision);
  const apps = shelf.begin('apps', 120_001);
  assert.equal(apps.entry.sessionId, generic.entry.sessionId);
  shelf.commit(apps.entry.revision);
  const openApps = shelf.begin(undefined, 120_002);
  assert.equal(openApps.entry.destination, 'apps');
  assert.equal(openApps.entry.entryMode, 'fresh');
  shelf.commit(openApps.entry.revision);
  shelf.close(120_002);
  assert.equal(shelf.begin(undefined, 120_003).entry.destination, 'apps');
});

test('repeated close requests and cancelled preparation do not restart the resume deadline', () => {
  const shelf = opened('emoji');
  shelf.close(100);
  assert.equal(shelf.close(50_000), false);
  const cancelled = shelf.begin('clipboard', 59_000);
  shelf.close(59_100);
  assert.equal(shelf.commit(cancelled.entry.revision), false);
  assert.equal(shelf.begin(undefined, 60_100).entry.destination, 'apps');

  const retained = opened('emoji');
  retained.close(100);
  retained.begin('clipboard', 200);
  retained.close(300);
  assert.equal(retained.begin(undefined, 400).entry.destination, 'emoji');
});

test('stale show/hide completions cannot change a superseding transition', () => {
  const shelf = opened();
  shelf.close(100);
  const closing = shelf.revision;
  const first = shelf.begin('emoji', 101);
  const second = shelf.begin('apps', 102);
  assert.equal(shelf.commit(first.entry.revision), false);
  assert.equal(shelf.finishClose(closing), false);
  assert.equal(shelf.phase, 'preparing');
  assert.equal(shelf.commit(second.entry.revision), true);
  assert.equal(shelf.phase, 'open');
  shelf.close(103);
  assert.equal(shelf.finishClose(closing), false);
  assert.equal(shelf.finishClose(shelf.revision), true);
  assert.equal(shelf.phase, 'hidden');
});

test('an opening cancelled before any native reveal does not create a remembered destination', () => {
  const shelf = new ShelfLifecycle();
  const opening = shelf.begin('emoji', 0);
  shelf.close(1);
  assert.equal(shelf.commit(opening.entry.revision), false);
  assert.equal(shelf.begin(undefined, 2).entry.destination, 'apps');
});
