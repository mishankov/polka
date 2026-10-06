import type { ShelfDestination, ShelfEntry } from '../shared/shelf';

/** Native visibility and renderer preparation are different parts of an opening. */
export class ShelfLifecycle {
  phase: 'hidden' | 'preparing' | 'open' | 'closing' = 'hidden';
  revision = 0;
  sessionId = 0;
  private destination: ShelfDestination = 'apps';
  private committedOpen = false;
  private remembered?: { destination: ShelfDestination; closedAt: number };
  private preparing?: ShelfEntry;

  get requested() {
    return this.phase === 'preparing' || this.phase === 'open';
  }

  begin(destination: ShelfDestination | undefined, now: number, searchQuery = '') {
    const newSession = !this.requested;
    if (newSession) this.sessionId++;
    const remembered = this.remembered;
    const resume =
      destination === undefined &&
      ((this.committedOpen && (this.destination === 'clipboard' || this.destination === 'emoji')) ||
        (!this.committedOpen &&
          !!remembered &&
          now - remembered.closedAt < 60_000 &&
          (remembered.destination === 'clipboard' || remembered.destination === 'emoji')));
    const entry: ShelfEntry = {
      revision: ++this.revision,
      sessionId: this.sessionId,
      destination: destination ?? (resume ? this.destination : 'apps'),
      entryMode: resume ? 'resume' : 'fresh',
      searchQuery,
    };
    this.preparing = entry;
    this.phase = 'preparing';
    return { entry, newSession };
  }

  commit(revision: number) {
    if (this.phase !== 'preparing' || this.preparing?.revision !== revision) return false;
    this.destination = this.preparing.destination;
    this.committedOpen = true;
    this.phase = 'open';
    return true;
  }

  close(now: number) {
    if (!this.requested) return false;
    if (this.committedOpen) this.remembered = { destination: this.destination, closedAt: now };
    this.committedOpen = false;
    this.preparing = undefined;
    this.phase = 'closing';
    this.revision++;
    return true;
  }

  finishClose(revision: number) {
    if (this.phase !== 'closing' || revision !== this.revision) return false;
    this.phase = 'hidden';
    return true;
  }
}
