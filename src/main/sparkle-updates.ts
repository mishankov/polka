import { EventEmitter } from 'node:events';
import type { SparkleBridge, SparkleBridgeEvent } from 'electron-sparkle-updater';
import type { UpdateAdapter } from './updates';

export type CancellableSparkleBridge = SparkleBridge & { cancelPendingUpdate(): void };

/** Sparkle downloads automatically, but its user driver holds installation until requested. */
export class SparkleUpdateAdapter extends EventEmitter implements UpdateAdapter {
  private bridge?: CancellableSparkleBridge;
  constructor(
    private load: () => Promise<SparkleBridge | null>,
    private feedUrl: string,
    private publicKey: string,
  ) {
    super();
  }
  async start() {
    if (this.bridge) return;
    const bridge = await this.load();
    if (!bridge || typeof (bridge as CancellableSparkleBridge).cancelPendingUpdate !== 'function')
      throw Error('Sparkle is unavailable');
    bridge.setEventHandler((event: SparkleBridgeEvent) => {
      if (event.type === 'download-progress') {
        // Extraction is a separate phase; do not move the download bar backwards.
        if (event.phase !== 'apply') this.emit(event.type, { percent: event.percent });
      } else if (event.type === 'installing') {
        this.emit('before-quit-for-update');
      } else if (event.type === 'error') {
        this.emit('error', Error('Sparkle update failed'));
      } else {
        this.emit(event.type, { version: event.version });
      }
    });
    if (!bridge.init({ appcastUrl: this.feedUrl, publicEdKey: this.publicKey }))
      throw Error('Sparkle could not initialize');
    this.bridge = bridge as CancellableSparkleBridge;
    bridge.setAutomaticChecks(true);
  }
  async checkForUpdates() {
    await this.start();
    this.bridge!.checkForUpdates();
  }
  cancelPendingUpdate() {
    this.bridge?.cancelPendingUpdate();
  }
  quitAndInstall() {
    if (!this.bridge) throw Error('Sparkle is unavailable');
    this.bridge.installUpdateNow();
  }
}
