import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import type { Input, WebContents } from 'electron';
import { bindAssistantShortcut } from '../src/main/workspace-shortcuts';

test('assistant shortcut routes native input to its workspace across layouts and suppresses repeats', () => {
  const contents = new EventEmitter();
  const messages: unknown[] = [];
  let destroyed = false;
  const workspace = {
    isDestroyed: () => destroyed,
    send: (...args: unknown[]) => messages.push(args),
  } as unknown as WebContents;
  bindAssistantShortcut(contents as WebContents, workspace);
  function press(overrides: Partial<Input> = {}) {
    let prevented = false;
    contents.emit(
      'before-input-event',
      { preventDefault: () => (prevented = true) },
      {
        type: 'keyDown',
        key: 'j',
        code: 'KeyJ',
        meta: true,
        control: false,
        shift: false,
        alt: false,
        isComposing: false,
        isAutoRepeat: false,
        ...overrides,
      },
    );
    return prevented;
  }

  assert.equal(press(), true);
  assert.equal(press({ key: 'о' }), true, 'Russian layout uses the same physical key');
  assert.equal(press({ key: 'J' }), true, 'Caps Lock does not disable the shortcut');
  assert.equal(press({ meta: false, control: true }), true);
  assert.equal(messages.length, 4);
  assert(
    messages.every(
      (message) =>
        JSON.stringify(message) ===
        JSON.stringify(['platform:event', { type: 'workspace.toggleAssistant' }]),
    ),
  );
  assert.equal(press({ isAutoRepeat: true }), true);
  assert.equal(messages.length, 4, 'Holding the key must not toggle repeatedly');
  for (const input of [
    { type: 'keyUp' },
    { meta: false },
    { shift: true },
    { alt: true },
    { isComposing: true },
    { key: 'k', code: 'KeyK' },
  ])
    assert.equal(press(input), false);
  destroyed = true;
  assert.equal(press(), false);
  assert.equal(messages.length, 4);
});
