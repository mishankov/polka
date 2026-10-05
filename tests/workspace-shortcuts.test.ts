import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import type { Input, WebContents } from 'electron';
import { bindSettingsShortcut } from '../src/main/workspace-shortcuts';

test('settings shortcut handles native input across layouts and consumes repeats without reopening', () => {
  const contents = new EventEmitter();
  let opened = 0;
  bindSettingsShortcut(contents as WebContents, () => opened++);
  const mac = process.platform === 'darwin';
  function press(overrides: Partial<Input> = {}) {
    let prevented = false;
    contents.emit(
      'before-input-event',
      {
        preventDefault: () => {
          prevented = true;
        },
      },
      {
        type: 'keyDown',
        key: ',',
        code: 'Comma',
        meta: mac,
        control: !mac,
        alt: false,
        shift: false,
        isComposing: false,
        isAutoRepeat: false,
        ...overrides,
      },
    );
    return prevented;
  }
  assert.equal(press(), true);
  assert.equal(press({ key: 'б' }), true);
  assert.equal(opened, 2);
  assert.equal(press({ isAutoRepeat: true }), true);
  assert.equal(opened, 2);
  for (const input of [
    { type: 'keyUp' },
    { alt: true },
    { shift: true },
    { isComposing: true },
    { meta: false, control: false },
    { key: '.', code: 'Period' },
  ])
    assert.equal(press(input), false);
  assert.equal(opened, 2);
});
