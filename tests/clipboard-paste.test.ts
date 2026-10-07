import test from 'node:test';
import assert from 'node:assert/strict';
import { ClipboardPaste } from '../src/main/clipboard-paste';

function fixture() {
  const messages: { id: string; method: string; token?: string }[] = [];
  const paste = new ClipboardPaste((line) => {
    messages.push(JSON.parse(line));
    return true;
  });
  const reply = (index: number, result: Parameters<ClipboardPaste['receive']>[0]['result']) =>
    paste.receive({ id: messages[index].id, result });
  return { paste, messages, reply };
}

test('paste targets are one-shot and never reused after a new capture', async () => {
  const { paste, messages, reply } = fixture();
  const capture = paste.capture();
  reply(0, { trusted: true, token: 'field-one' });
  await capture;
  assert.equal(paste.ready, true);
  const sending = paste.paste();
  assert.equal(messages[1].token, 'field-one');
  assert.equal(paste.ready, false);
  reply(1, { sent: true });
  assert.equal(await sending, true);
  assert.equal(await paste.paste(), false);
  const next = paste.capture();
  reply(2, { trusted: true });
  await next;
  assert.equal(await paste.paste(), false);
  paste.stop();
});

test('late capture replies cannot restore a cancelled or superseded destination', async () => {
  const { paste, messages, reply } = fixture();
  const first = paste.capture();
  const second = paste.capture();
  reply(1, { trusted: true, token: 'new-field' });
  await second;
  reply(0, { trusted: true, token: 'old-field' });
  await first;
  const sending = paste.paste();
  assert.equal(messages[2].token, 'new-field');
  reply(2, { sent: false, reason: 'field-changed' });
  assert.equal(await sending, false);
  assert.equal(paste.failureReason, 'field-changed');
  const third = paste.capture();
  assert.equal(paste.failureReason, undefined);
  paste.cancel();
  reply(3, { trusted: true, token: 'cancelled' });
  reply(4, {});
  await third;
  assert.equal(paste.ready, false);
  paste.stop();
});

test('missing permission and unavailable helper fall back without prompting or emitting paste', async () => {
  const { paste, messages, reply } = fixture();
  const capture = paste.capture();
  reply(0, { trusted: false });
  await capture;
  assert.equal(paste.access, 'required');
  assert.equal(await paste.paste(), false);
  assert.deepEqual(
    messages.map((m) => m.method),
    ['capture'],
  );
  const permission = paste.status(true);
  reply(1, { trusted: false });
  assert.equal(await permission, 'required');
  paste.stop();
  const unavailable = new ClipboardPaste(() => false);
  await unavailable.capture();
  assert.equal(await unavailable.status(), 'unavailable');
  assert.equal(await unavailable.paste(), false);
  unavailable.stop();
});

test('helper exit resolves pending requests and invalidates the saved destination', async () => {
  const { paste } = fixture();
  const capture = paste.capture();
  paste.stop();
  await capture;
  assert.equal(paste.ready, false);
  assert.equal(paste.access, 'unavailable');
});

test('paste consumes the target before native dismissal and ignores replies from a previous session', async () => {
  const { paste, messages, reply } = fixture();
  const capture = paste.capture();
  reply(0, { trusted: true, token: 'previous-field' });
  await capture;
  let dismissed = false;
  const sending = paste.paste(() => {
    assert.equal(paste.ready, false);
    assert.equal(messages.length, 1, 'hide precedes the native paste command');
    dismissed = true;
  });
  assert.equal(dismissed, true);
  paste.cancel();
  const next = paste.capture();
  reply(3, { trusted: true, token: 'next-field' });
  await next;
  reply(1, { sent: false, reason: 'field-changed' });
  assert.equal(await sending, false);
  assert.equal(paste.ready, true);
  assert.equal(paste.failureReason, undefined);
  paste.stop();
});

test('a permission reply queued before helper exit cannot restore granted access', async () => {
  const { paste, reply } = fixture();
  const status = paste.status();
  reply(0, { trusted: true });
  paste.stop();
  assert.equal(await status, 'unavailable');
  assert.equal(paste.ready, false);
});

test('a target token cannot make paste ready without granted permission', async () => {
  const { paste, reply } = fixture();
  const capture = paste.capture();
  reply(0, { trusted: false, token: 'invalid-target' });
  await capture;
  assert.equal(paste.access, 'required');
  assert.equal(paste.ready, false);
  assert.equal(await paste.paste(), false);
  paste.stop();
});
