import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { UpdateService } from '../src/main/updates';
class Adapter extends EventEmitter {
  checks = 0;
  downloads = 0;
  installed = false;
  async checkForUpdates() {
    this.checks++;
    this.emit('update-available', { version: '0.2.0' });
  }
  async downloadUpdate() {
    this.downloads++;
    this.emit('download-progress', { percent: 42 });
    this.emit('update-downloaded', { version: '0.2.0' });
  }
  quitAndInstall() {
    this.installed = true;
  }
}
test('updates are explicit, report progress, and flush clipboard history before installing', async () => {
  const adapter = new Adapter();
  const states: string[] = [];
  let saved = false;
  const service = new UpdateService(
    adapter,
    '0.1.0',
    true,
    (s) => states.push(`${s.status}:${s.progress || 0}`),
    async () => {
      saved = true;
    },
  );
  await assert.rejects(service.handle('updates.install'), /не загружено/);
  await service.handle('updates.check');
  assert.equal(adapter.downloads, 0);
  assert.equal(service.status().version, '0.2.0');
  await service.handle('updates.download');
  assert.equal(adapter.installed, false);
  assert(states.includes('downloading:42'));
  adapter.quitAndInstall = () => {
    assert(saved);
    adapter.installed = true;
  };
  await service.handle('updates.install');
  assert(adapter.installed);
});
test('unsigned/local builds never call the update feed', async () => {
  const adapter = new Adapter();
  const service = new UpdateService(
    adapter,
    '0.1.0',
    false,
    () => {},
    async () => {},
  );
  assert.equal(service.status().status, 'unavailable');
  await assert.rejects(service.handle('updates.check'));
  assert.equal(adapter.checks, 0);
});
test('failed clipboard flush preserves a downloaded update and prevents restart', async () => {
  const adapter = new Adapter();
  const service = new UpdateService(
    adapter,
    '0.1.0',
    true,
    () => {},
    async () => {
      throw Error('disk full');
    },
  );
  await service.handle('updates.check');
  await service.handle('updates.download');
  await service.handle('updates.install');
  assert.equal(adapter.installed, false);
  assert.equal(service.status().status, 'ready');
});
test('network errors are retryable and do not expose signed URLs or credentials', async () => {
  const adapter = new Adapter();
  adapter.checkForUpdates = async () => {
    throw Error('https://secret:token@example.com');
  };
  const service = new UpdateService(
    adapter,
    '0.1.0',
    true,
    () => {},
    async () => {},
  );
  await service.handle('updates.check');
  assert.equal(service.status().status, 'error');
  assert(!service.status().message?.includes('token'));
  adapter.checkForUpdates = async () => {
    adapter.emit('update-not-available', { version: '0.1.0' });
  };
  await service.handle('updates.check');
  assert.equal(service.status().status, 'current');
});

test('native staging error restores the live app rather than stranding disabled windows', async () => {
  const adapter = new Adapter();
  let disabled = false;
  const service = new UpdateService(
    adapter,
    '0.1.0',
    true,
    () => {},
    async () => {
      disabled = true;
    },
    () => {
      disabled = false;
    },
  );
  await service.handle('updates.check');
  await service.handle('updates.download');
  adapter.quitAndInstall = () => {
    /* Squirrel staging is asynchronous; core must still be alive. */
  };
  await service.handle('updates.install');
  assert(disabled);
  assert.equal(service.status().status, 'installing');
  adapter.emit('error', Error('native staging failed'));
  assert.equal(disabled, false);
  assert.equal(service.status().status, 'error');
});

test('failed pre-install flush restores interaction without calling native quit', async () => {
  const adapter = new Adapter();
  let disabled = false;
  const service = new UpdateService(
    adapter,
    '0.1.0',
    true,
    () => {},
    async () => {
      disabled = true;
      throw Error('flush failed');
    },
    () => {
      disabled = false;
    },
  );
  await service.handle('updates.check');
  await service.handle('updates.download');
  await service.handle('updates.install');
  assert.equal(disabled, false);
  assert.equal(adapter.installed, false);
  assert.equal(service.status().status, 'ready');
});
