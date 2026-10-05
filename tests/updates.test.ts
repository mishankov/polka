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
    await this.downloadUpdate();
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
test('updates download automatically, report progress, and flush documents before explicit installation', async () => {
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
  assert.equal(adapter.downloads, 1);
  assert.equal(service.status().version, '0.2.0');
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
test('failed document flush preserves a downloaded update and prevents restart', async () => {
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
  adapter.quitAndInstall = () => {
    /* Sparkle staging is asynchronous; core must still be alive. */
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
  await service.handle('updates.install');
  assert.equal(disabled, false);
  assert.equal(adapter.installed, false);
  assert.equal(service.status().status, 'ready');
});

test('scheduled update events download without restarting, and repeated checks cannot interrupt download', async () => {
  const adapter = new Adapter();
  const service = new UpdateService(
    adapter,
    '0.1.0',
    true,
    () => {},
    async () => {},
  );
  adapter.emit('update-available', { version: '0.2.0' });
  assert.equal(service.status().status, 'downloading');
  await assert.rejects(service.handle('updates.check'), /завершите/);
  await assert.rejects(service.handle('updates.install'), /не загружено/);
  adapter.emit('update-downloaded', { version: '0.2.0' });
  assert.equal(service.status().status, 'ready');
  assert.equal(adapter.installed, false);
});

test('asynchronous native check blocks duplicate checks until a result arrives', async () => {
  const adapter = new Adapter();
  adapter.checkForUpdates = async () => {};
  const service = new UpdateService(
    adapter,
    '0.1.0',
    true,
    () => {},
    async () => {},
  );
  await service.handle('updates.check');
  await assert.rejects(service.handle('updates.check'), /завершите/);
  adapter.emit('update-not-available');
  assert.equal(service.status().status, 'current');
});

test('Sparkle adapter registers events before initialization and never installs on download', async () => {
  const { SparkleUpdateAdapter } = await import('../src/main/sparkle-updates');
  let listener: (event: any) => void = () => {};
  let installs = 0;
  let checks = 0;
  let automatic = false;
  const bridge = {
    cancelPendingUpdate() {},
    setEventHandler(handler: typeof listener) {
      listener = handler;
    },
    init() {
      listener({ type: 'update-available', version: '0.2.0' });
      return true;
    },
    setAutomaticChecks(enabled: boolean) {
      automatic = enabled;
    },
    checkForUpdates() {
      checks++;
    },
    installUpdateNow() {
      installs++;
    },
    installUpdateOnQuit() {
      throw Error('Must not schedule installation on ordinary quit');
    },
  };
  const adapter = new SparkleUpdateAdapter(
    async () => bridge,
    'https://example.com/appcast.xml',
    'key',
  );
  const service = new UpdateService(
    adapter,
    '0.1.0',
    true,
    () => {},
    async () => {},
  );
  await service.handle('updates.check');
  assert(automatic);
  assert.equal(checks, 1);
  assert.equal(service.status().status, 'downloading');
  listener({ type: 'download-progress', percent: 70 });
  listener({ type: 'download-progress', phase: 'apply', percent: 10 });
  assert.equal(service.status().progress, 70);
  listener({ type: 'update-downloaded', version: '0.2.0' });
  assert.equal(installs, 0);
  await service.handle('updates.install');
  assert.equal(installs, 1);
});

test('ordinary quit cancels staging, explicit update quit retains staging', async () => {
  const adapter = new Adapter();
  let cancellations = 0;
  Object.assign(adapter, {
    cancelPendingUpdate() {
      cancellations++;
    },
  });
  const service = new UpdateService(
    adapter,
    '0.1.0',
    true,
    () => {},
    async () => {},
  );
  await service.handle('updates.check');
  service.cancelForQuit();
  assert.equal(cancellations, 1);
  await service.handle('updates.check');
  await service.handle('updates.install');
  service.cancelForQuit(true);
  assert.equal(cancellations, 1);
});

test('ordinary quit during document saving prevents a late native install request', async () => {
  const adapter = new Adapter();
  let saved!: () => void;
  const service = new UpdateService(
    adapter,
    '0.1.0',
    true,
    () => {},
    () =>
      new Promise<void>((done) => {
        saved = done;
      }),
  );
  await service.handle('updates.check');
  const install = service.handle('updates.install');
  service.cancelForQuit();
  saved();
  await install;
  assert.equal(adapter.installed, false);
});
