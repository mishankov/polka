import { test } from 'node:test';
import assert from 'node:assert/strict';
import { MediaMonitor } from '../../src/main/media-monitor';
import { mediaIndicatorGeometry } from '../../src/main/media-indicator-geometry';
import {
  parseMediaActivity,
  mediaIndicatorVisible,
  UNKNOWN_MEDIA,
  mediaTrackingFromSettings,
  trackedMediaActivity,
  mediaActivityLabel,
  type DeviceActivity,
} from '../../src/shared/media-indicator';

const snapshot = (camera: string, microphone: string) => ({
  camera: { state: camera },
  microphone: { state: microphone },
});
const flush = async () => {
  await Promise.resolve();
  await Promise.resolve();
};

test('independent preferences preserve defaults and migrate the combined switch', () => {
  assert.deepEqual(mediaTrackingFromSettings(), { cameraEnabled: true, microphoneEnabled: true });
  for (const enabled of [true, false]) {
    assert.deepEqual(mediaTrackingFromSettings({ mediaIndicatorEnabled: enabled }), {
      cameraEnabled: enabled,
      microphoneEnabled: enabled,
    });
  }
  for (const cameraEnabled of [true, false])
    for (const microphoneEnabled of [true, false]) {
      const tracking = { cameraEnabled, microphoneEnabled };
      assert.deepEqual(
        mediaTrackingFromSettings({
          mediaIndicatorEnabled: false,
          mediaIndicatorTracking: tracking,
        }),
        tracking,
      );
    }
});

test('disabled devices cannot show active or unavailable indicators', () => {
  const states: DeviceActivity[] = ['active', 'inactive', 'unknown'];
  for (const cameraEnabled of [true, false])
    for (const microphoneEnabled of [true, false])
      for (const camera of states)
        for (const microphone of states) {
          const activity = trackedMediaActivity(
            { camera, microphone },
            { cameraEnabled, microphoneEnabled },
          );
          assert.equal(activity.camera, cameraEnabled ? camera : 'disabled');
          assert.equal(activity.microphone, microphoneEnabled ? microphone : 'disabled');
          assert.equal(
            mediaIndicatorVisible(activity),
            (cameraEnabled && camera !== 'inactive') ||
              (microphoneEnabled && microphone !== 'inactive'),
          );
        }
  assert.match(
    mediaActivityLabel({ camera: 'disabled', microphone: 'active' }),
    /Камера: отслеживание выключено/,
  );
  assert.deepEqual(parseMediaActivity(snapshot('disabled', 'active')), {
    camera: 'disabled',
    microphone: 'active',
  });
});

test('unavailable and malformed measurements are never treated as inactive', () => {
  assert.deepEqual(parseMediaActivity(null), UNKNOWN_MEDIA);
  assert.deepEqual(parseMediaActivity({ camera: { state: 'active' } }), {
    camera: 'active',
    microphone: 'unknown',
  });
  assert.deepEqual(parseMediaActivity(snapshot('inactive', 'unsupported')), {
    camera: 'inactive',
    microphone: 'unknown',
  });
  for (const camera of ['active', 'inactive', 'unknown'])
    for (const microphone of ['active', 'inactive', 'unknown']) {
      assert.equal(
        mediaIndicatorVisible(parseMediaActivity(snapshot(camera, microphone))),
        camera !== 'inactive' || microphone !== 'inactive',
      );
    }
});

test('geometry follows an offset notch, display origins, and the no-notch fallback', () => {
  const screen = { x: -1728, y: -1117, width: 1728, height: 1117 };
  const notch = { id: 4, x: 730, width: 200, height: 32 };
  const result = mediaIndicatorGeometry(screen, notch);
  assert.deepEqual(result.bounds, { x: -1060, y: -1117, width: 324, height: 46 });
  assert.equal(result.notchWidth, 200);
  const fallback = mediaIndicatorGeometry(screen);
  assert.equal(fallback.bounds.x + fallback.bounds.width / 2, -864);
  assert.equal(fallback.notchHeight, 0);
  assert.equal(fallback.bounds.height, 46);
});

test('polling covers transitions, failure and recovery without overlapping requests', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  let resolveRead!: (value: unknown) => void;
  let rejectRead!: (reason: Error) => void;
  let reads = 0;
  const states: unknown[] = [];
  const monitor = new MediaMonitor(
    () => {
      reads++;
      return new Promise((resolve, reject) => {
        resolveRead = resolve;
        rejectRead = reject;
      });
    },
    (state) => states.push(state),
  );
  t.after(() => monitor.stop());
  monitor.start();
  t.mock.timers.tick(10000);
  assert.equal(reads, 1);
  resolveRead(snapshot('active', 'inactive'));
  await flush();
  assert.deepEqual(states.at(-1), { camera: 'active', microphone: 'inactive' });
  t.mock.timers.tick(1000);
  rejectRead(Error('Probe timed out'));
  await flush();
  assert.deepEqual(states.at(-1), UNKNOWN_MEDIA);
  t.mock.timers.tick(1000);
  resolveRead(snapshot('inactive', 'inactive'));
  await flush();
  assert.deepEqual(states.at(-1), { camera: 'inactive', microphone: 'inactive' });
});

test('disabling and resuming discards late samples from the previous session', async (t) => {
  const pending: ((value: unknown) => void)[] = [];
  const states: unknown[] = [];
  const monitor = new MediaMonitor(
    () => new Promise((resolve) => pending.push(resolve)),
    (state) => states.push(state),
  );
  t.after(() => monitor.stop());
  monitor.start();
  monitor.stop();
  monitor.start();
  pending[0](snapshot('active', 'active'));
  await flush();
  assert.equal(states.length, 0);
  pending[1](snapshot('inactive', 'active'));
  await flush();
  assert.deepEqual(states, [{ camera: 'inactive', microphone: 'active' }]);
  monitor.stop();
  assert.deepEqual(monitor.activity, UNKNOWN_MEDIA);
});
