import { spawnSync } from 'node:child_process';
import { setTimeout as delay } from 'node:timers/promises';

/** Wait for this disposable app and its helpers, including Sparkle's detached relaunch. */
export async function stopUpdateFixtureProcesses(directory: string, appId: string) {
  // pgrep uses regular expressions; the fixture path and app ID must match literally.
  const pattern = [directory, appId]
    .map((marker) => marker.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'))
    .join('|');
  const started = Date.now();
  const signalled = new Set<number>();
  while (true) {
    const result = spawnSync('pgrep', ['-f', pattern], { encoding: 'utf8', timeout: 1000 });
    if (result.error) throw result.error;
    if (result.status === 1) return;
    if (result.status !== 0) throw Error('Could not inspect updater fixture processes.');
    const pids = result.stdout
      .trim()
      .split(/\s+/)
      .map(Number)
      .filter((pid) => pid > 0 && pid !== process.pid);
    if (!pids.length) return;
    const elapsed = Date.now() - started;
    if (elapsed >= 5000) throw Error(`Updater fixture processes did not exit: ${pids.join(', ')}`);
    const signal = elapsed >= 2000 ? 'SIGKILL' : 'SIGTERM';
    for (const pid of pids) {
      if (signal === 'SIGTERM' && signalled.has(pid)) continue;
      try {
        process.kill(pid, signal);
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== 'ESRCH') throw error;
      }
      signalled.add(pid);
    }
    await delay(50);
  }
}
