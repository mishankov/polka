import { spawnSync } from 'node:child_process';
import { setTimeout as delay } from 'node:timers/promises';

/** Wait for this disposable app and its helpers, including Sparkle's detached relaunch. */
export async function stopUpdateFixtureProcesses(directory: string, appId: string) {
  // pgrep uses regular expressions; the fixture path and app ID must match literally.
  const pattern = [directory, appId]
    .map((marker) => marker.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'))
    .join('|');
  const deadline = Date.now() + 15000;
  let terminationStarted: number | undefined;
  const signalled = new Set<number>();
  while (true) {
    const remaining = deadline - Date.now();
    if (remaining <= 0) throw Error('Timed out waiting for updater fixture processes to exit.');
    const result = spawnSync('pgrep', ['-f', pattern], {
      encoding: 'utf8',
      timeout: Math.min(5000, remaining),
    });
    if (result.error) {
      // A busy macOS runner can take more than a second to inspect its processes.
      // Retry timed-out scans; only a successful scan can confirm cleanup is safe.
      if ((result.error as NodeJS.ErrnoException).code === 'ETIMEDOUT' && Date.now() < deadline) {
        await delay(50);
        continue;
      }
      throw result.error;
    }
    if (result.status === 1) return;
    if (result.status !== 0) throw Error('Could not inspect updater fixture processes.');
    const pids = result.stdout
      .trim()
      .split(/\s+/)
      .map(Number)
      .filter((pid) => pid > 0 && pid !== process.pid);
    if (!pids.length) return;
    const now = Date.now();
    if (now >= deadline) throw Error(`Updater fixture processes did not exit: ${pids.join(', ')}`);
    terminationStarted ??= now;
    const elapsed = now - terminationStarted;
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
