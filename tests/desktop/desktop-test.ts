import {
  _electron as electron,
  expect,
  type ElectronApplication,
  type Page,
} from '@playwright/test';
import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { randomUUID } from 'node:crypto';
import { execFileSync, type ChildProcess } from 'node:child_process';
import { setTimeout as delay } from 'node:timers/promises';
import { stopUpdateFixtureProcesses } from './update-fixture-cleanup';
import type { ClipboardState } from '../../src/shared/clipboard';

type LaunchOptions = NonNullable<Parameters<typeof electron.launch>[0]>;
type ClipboardBackup = { type: string; bytes?: string; bookmark?: unknown }[][];

/** Electron inherited from the T3 Node transport otherwise starts as a CLI. */
export function desktopEnvironment(env: NodeJS.ProcessEnv = process.env) {
  return Object.fromEntries(
    Object.entries(env).filter(
      (entry): entry is [string, string] =>
        entry[0] !== 'ELECTRON_RUN_AS_NODE' && entry[1] !== undefined,
    ),
  );
}

/** All native GUI suites on this Mac share focus, clipboard and global shortcuts. */
export async function acquireDesktopLock(
  path = join(tmpdir(), 'polka-desktop-tests.lock'),
  timeout = 120000,
) {
  const token = randomUUID();
  const deadline = Date.now() + timeout;
  while (true) {
    if (Date.now() > deadline)
      throw Error(`Another desktop suite owns ${path}. Run GUI tests sequentially.`);
    try {
      await mkdir(path);
      try {
        await writeFile(join(path, 'owner.json'), JSON.stringify({ pid: process.pid, token }));
      } catch (error) {
        await rm(path, { recursive: true, force: true });
        throw error;
      }
      return async () => {
        const owner = JSON.parse(await readFile(join(path, 'owner.json'), 'utf8'));
        if (owner.token === token) await rm(path, { recursive: true, force: true });
      };
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error;
    }
    let stale = false;
    let observedOwner: string | undefined;
    try {
      observedOwner = await readFile(join(path, 'owner.json'), 'utf8');
      const owner = JSON.parse(observedOwner);
      if (!Number.isInteger(owner.pid) || owner.pid <= 0) throw Error('Invalid desktop test owner');
      try {
        process.kill(owner.pid, 0);
      } catch (error) {
        stale = (error as NodeJS.ErrnoException).code === 'ESRCH';
      }
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
        // Allow the process which created the directory to write its owner file.
        stale = await stat(path)
          .then((s) => Date.now() - s.mtimeMs > 30000)
          .catch(() => false);
      } else throw error;
    }
    if (stale) {
      try {
        // Only one contender may reclaim a dead owner's directory.
        await mkdir(join(path, 'reclaim'));
        // A different contender may already have reclaimed it and acquired a
        // new lock between our stale check and this guard. Never evict that owner.
        const currentOwner = await readFile(join(path, 'owner.json'), 'utf8').catch((error) => {
          if ((error as NodeJS.ErrnoException).code === 'ENOENT') return undefined;
          throw error;
        });
        if (currentOwner === observedOwner) await rm(path, { recursive: true, force: true });
        else await rm(join(path, 'reclaim'), { recursive: true, force: true });
      } catch (error) {
        if (!['ENOENT', 'EEXIST'].includes((error as NodeJS.ErrnoException).code ?? ''))
          throw error;
        await delay(50);
      }
      continue;
    }
    if (Date.now() >= deadline)
      throw Error(`Another desktop suite owns ${path}. Run GUI tests sequentially.`);
    await delay(Math.min(100, Math.max(1, deadline - Date.now())));
  }
}

async function within<T>(operation: Promise<T>, timeout: number, label: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout>;
  try {
    return await Promise.race([
      operation,
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(Error(`${label} timed out`)), timeout);
      }),
    ]);
  } finally {
    clearTimeout(timer!);
  }
}

/** Bound both Playwright's quit acknowledgement and the actual child exit. */
export async function closeDesktopApp(
  app: Pick<ElectronApplication, 'close' | 'process'>,
  timeout = 10000,
  requireGraceful = false,
) {
  const child = app.process();
  const exited = () => child.exitCode !== null || child.signalCode !== null;
  if (exited()) {
    if (requireGraceful && child.exitCode !== 0)
      throw Error('Electron exited abnormally before orderly quit.');
    return;
  }
  let closeError: unknown;
  let forced = false;
  try {
    await within(app.close(), timeout, 'Electron quit');
  } catch (error) {
    closeError = error;
    if (!exited()) console.warn(String(error));
  }
  const acknowledgedExitDeadline = Date.now() + 1000;
  while (!exited() && Date.now() < acknowledgedExitDeadline) await delay(20);
  if (!exited()) {
    closeError ??= Error('Electron did not exit after its quit acknowledgement.');
    forced = true;
    child.kill('SIGTERM');
  }
  const deadline = Date.now() + 2000;
  while (!exited() && Date.now() < deadline) await delay(20);
  if (!exited()) {
    child.kill('SIGKILL');
    await within(
      new Promise<void>((done) => {
        if (exited()) done();
        else child.once('exit', () => done());
      }),
      5000,
      'Electron process exit',
    );
  }
  if (requireGraceful && (forced || child.exitCode !== 0))
    throw closeError ?? Error('Electron did not quit successfully.');
}

export async function snapshotClipboard(app: ElectronApplication): Promise<ClipboardBackup> {
  // Materialize lazy native data in Node memory so restart does not lose the backup.
  return app.evaluate(async ({ clipboard }) =>
    Promise.all(
      (await clipboard.read())
        .filter((item) => item.types.length > 0)
        .map((item) =>
          Promise.all(
            item.types.map(async (type) => {
              const data = await item.getType(type);
              return data instanceof Blob
                ? { type, bytes: Buffer.from(await data.arrayBuffer()).toString('base64') }
                : { type, bookmark: data };
            }),
          ),
        ),
    ),
  );
}

export async function restoreClipboard(live: ElectronApplication, items: ClipboardBackup) {
  return live.evaluate(async ({ clipboard, ClipboardItem }, items) => {
    if (!items.length) return clipboard.clear();
    await clipboard.write(
      items.map(
        (item) =>
          new ClipboardItem(
            Object.fromEntries(
              item.map((entry) => {
                if (entry.bytes === undefined) return [entry.type, entry.bookmark as any];
                let bytes = Buffer.from(entry.bytes, 'base64');
                // Electron's macOS writer adds this transport header. Remove one
                // copy from HTML snapshots so a round trip restores the same bytes.
                if (
                  process.platform === 'darwin' &&
                  (entry.type === 'text/html' ||
                    entry.type ===
                      'electron application/osclipboard;format="Apple HTML pasteboard type"')
                ) {
                  const prefix = Buffer.from("<meta charset='utf-8'>");
                  if (bytes.subarray(0, prefix.length).equals(prefix))
                    bytes = bytes.subarray(prefix.length);
                }
                return [entry.type, new Blob([bytes])];
              }),
            ),
          ),
      ),
    );
  }, items);
}

export class DesktopTest {
  readonly artifacts: string;
  private apps = new Set<ElectronApplication>();
  private processes = new WeakMap<ElectronApplication, ChildProcess>();
  private errors: string[] = [];
  private details: Record<string, unknown> = {};
  private clipboard?: ClipboardBackup;
  private cleanup: (() => Promise<void>)[] = [];
  constructor(
    readonly name: string,
    readonly profile: string,
  ) {
    this.artifacts = resolve('artifacts/desktop', name);
  }
  async launch(options: LaunchOptions) {
    if (
      process.platform === 'darwin' &&
      options.executablePath?.endsWith('/Contents/MacOS/Polka')
    ) {
      // Packaged workflow suites exercise storage, not acknowledgement of the
      // informational dialog. Remember it in the disposable profile before startup.
      const version = execFileSync(
        '/usr/libexec/PlistBuddy',
        [
          '-c',
          'Print :CFBundleShortVersionString',
          join(dirname(options.executablePath), '../Info.plist'),
        ],
        { encoding: 'utf8' },
      ).trim();
      await writeFile(
        join(options.env?.EVERYTHING_PROFILE || this.profile, 'keychain-notice-version'),
        version,
      );
    }
    const app = await electron.launch({
      timeout: 30000,
      ...options,
      env: desktopEnvironment({
        ...process.env,
        EVERYTHING_PROFILE: this.profile,
        ...options.env,
      }),
    });
    this.apps.add(app);
    // Playwright drops its process mapping when Sparkle quits the original app.
    this.processes.set(app, app.process());
    const context = app.context();
    context.setDefaultTimeout(10000);
    context.setDefaultNavigationTimeout(30000);
    await context.tracing.start({ screenshots: true, snapshots: true });
    const observe = (page: Page) =>
      page.on('pageerror', (error) => this.errors.push(error.message));
    context.on('page', observe);
    context.pages().forEach(observe);
    await app.evaluate(({ app, BrowserWindow }) => {
      const events: { time: number; window: number; event: string }[] = [];
      (globalThis as any).__polkaDesktopTestEvents = events;
      // Keep serialized callbacks anonymous: tsx's inferred-name helper is not
      // available in Electron's separate evaluation context.
      app.on('browser-window-created', (_, window) => {
        for (const event of ['focus', 'blur', 'show', 'hide'])
          window.on(event as any, () => {
            events.push({ time: Date.now(), window: window.id, event });
            if (events.length > 100) events.shift();
          });
      });
      BrowserWindow.getAllWindows().forEach((window) => {
        for (const event of ['focus', 'blur', 'show', 'hide'])
          window.on(event as any, () => {
            events.push({ time: Date.now(), window: window.id, event });
            if (events.length > 100) events.shift();
          });
      });
    });
    return app;
  }
  async backupClipboard(app: ElectronApplication) {
    if (this.clipboard !== undefined) return;
    this.clipboard = await snapshotClipboard(app);
  }
  private process(app: ElectronApplication) {
    return this.processes.get(app)!;
  }
  async close(app: ElectronApplication, requireGraceful = false) {
    await within(app.context().tracing.stop(), 5000, 'Trace shutdown').catch(() => {});
    await closeDesktopApp(
      { close: () => app.close(), process: () => this.process(app) } as Pick<
        ElectronApplication,
        'close' | 'process'
      >,
      10000,
      requireGraceful,
    );
    this.apps.delete(app);
  }
  deferCleanup(cleanup: () => Promise<void>) {
    this.cleanup.push(cleanup);
  }
  recordDiagnostic(label: string, value: unknown) {
    this.details[label] = value;
  }
  async step(name: string, run: () => Promise<void>) {
    this.recordDiagnostic('activeCase', name);
    const started = Date.now();
    console.log(`[${this.name}] START ${name}`);
    try {
      await run();
      this.assertNoRendererErrors();
      console.log(`[${this.name}] PASS ${name} (${Date.now() - started}ms)`);
    } catch (cause) {
      throw Error(`[${this.name}] ${name} failed: ${String(cause)}`, { cause });
    }
  }
  assertNoRendererErrors() {
    if (this.errors.length) throw Error(`Renderer errors: ${this.errors.join('; ')}`);
  }
  async shelfReady(app: ElectronApplication, page: Page, searchName: string) {
    await expect(page.locator('.clipboard-shelf')).toHaveClass(/is-open/);
    await expect(page.getByRole('combobox', { name: searchName, exact: true })).toBeFocused();
    // DOM focus can survive hiding. Wait for the actual native reveal/focus too.
    await expect
      .poll(() =>
        app.evaluate(({ BrowserWindow }) =>
          BrowserWindow.getAllWindows().some(
            (win) =>
              win.webContents.getURL().includes('mode=shelf') && win.isVisible() && win.isFocused(),
          ),
        ),
      )
      .toBe(true);
  }
  async shelfHidden(app: ElectronApplication, page: Page) {
    await expect(page.locator('.clipboard-shelf')).toHaveClass(/is-closed/);
    await expect
      .poll(() =>
        app.evaluate(({ BrowserWindow }) =>
          BrowserWindow.getAllWindows()
            .filter((win) => win.webContents.getURL().includes('mode=shelf'))
            .every((win) => !win.isVisible()),
        ),
      )
      .toBe(true);
  }
  async clipboardReady(page: Page) {
    await expect
      .poll(
        () =>
          page.evaluate(() =>
            window.platform
              .call<ClipboardState>('clipboardHistory.state')
              .then(
                (state) => state.registered && state.pasteAccess !== 'unavailable' && !state.error,
              ),
          ),
        { timeout: 15000 },
      )
      .toBe(true);
  }
  async keepClipboardFixture(page: Page, id: string) {
    // A ready helper can still be finishing its initial capture. Match our
    // fixture, then remove startup entries from this disposable history only.
    await expect
      .poll(() =>
        page.evaluate(
          (id) =>
            window.platform
              .call<ClipboardState>('clipboardHistory.state')
              .then((state) => state.clips.some((clip) => clip.id === id)),
          id,
        ),
      )
      .toBe(true);
    await page.evaluate(async (id) => {
      const state = await window.platform.call<ClipboardState>('clipboardHistory.state');
      for (const clip of state.clips)
        if (clip.id !== id) await window.platform.call('clipboardHistory.remove', { id: clip.id });
    }, id);
    await expect
      .poll(() =>
        page.evaluate(() =>
          window.platform
            .call<ClipboardState>('clipboardHistory.state')
            .then((state) => state.clips.map((clip) => clip.id)),
        ),
      )
      .toEqual([id]);
  }
  async diagnostics(error: unknown) {
    await mkdir(this.artifacts, { recursive: true });
    const state: unknown[] = [];
    let index = 0;
    for (const app of this.apps) {
      const id = index++;
      state.push({
        id,
        pid: this.process(app).pid,
        exit: this.process(app).exitCode,
        signal: this.process(app).signalCode,
      });
      state.push(
        await within(
          app.evaluate(() => ({ nativeEvents: (globalThis as any).__polkaDesktopTestEvents })),
          2000,
          'Native focus events',
        ).catch(() => ({ nativeEvents: 'unavailable' })),
      );
      for (const [pageIndex, page] of app.windows().entries()) {
        await within(
          page.screenshot({ path: join(this.artifacts, `${id}-${pageIndex}.png`), timeout: 3000 }),
          4000,
          'Failure screenshot',
        ).catch(() => {});
        state.push(
          await within(
            page.evaluate(() => ({
              focused: document.hasFocus(),
              shelf: document.querySelector('.clipboard-shelf')?.className,
              busy: [...document.querySelectorAll('[aria-busy]')].map((e) =>
                e.getAttribute('aria-busy'),
              ),
            })),
            3000,
            'Failure state',
          ).catch(() => ({ renderer: 'unavailable' })),
        );
      }
      await within(
        app.context().tracing.stop({ path: join(this.artifacts, `${id}-trace.zip`) }),
        5000,
        'Failure trace',
      ).catch(() => {});
    }
    await writeFile(
      join(this.artifacts, 'failure.json'),
      JSON.stringify(
        { error: String(error), errors: this.errors, details: this.details, state },
        null,
        2,
      ),
    );
    console.error(`Desktop diagnostics: ${this.artifacts}`);
  }
  async dispose() {
    let failure: unknown;
    if (this.clipboard !== undefined) {
      let live = [...this.apps].find(
        (app) => this.process(app).exitCode === null && this.process(app).signalCode === null,
      );
      try {
        if (live) {
          await within(restoreClipboard(live, this.clipboard), 5000, 'Clipboard restore');
        } else {
          // A crashed fixture must not leave its test contents in the user's clipboard.
          // Only bootstrap code is written to disk; the backup stays in Node memory.
          const entry = join(this.profile, 'restore-clipboard.cjs');
          await writeFile(
            entry,
            `const {app}=require('electron');app.setPath('userData', ${JSON.stringify(join(this.profile, 'restore-profile'))});app.whenReady();`,
          );
          live = await this.launch({ args: [entry] });
          await within(restoreClipboard(live, this.clipboard), 5000, 'Clipboard recovery');
        }
      } catch (error) {
        failure = error;
      }
    }
    for (const app of [...this.apps].reverse()) {
      await this.close(app).catch((error) => {
        failure ??= error;
      });
    }
    for (const cleanup of this.cleanup.reverse()) {
      await cleanup().catch((error) => {
        failure ??= error;
      });
    }
    // Helpers and updater relaunches can outlive Playwright's original process.
    await stopUpdateFixtureProcesses(this.profile, this.profile);
    await rm(this.profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
    if (failure) throw failure;
  }
}

export async function runDesktopTest(name: string, run: (test: DesktopTest) => Promise<void>) {
  const release = await acquireDesktopLock();
  let test: DesktopTest | undefined;
  let failure: unknown;
  try {
    test = new DesktopTest(name, await mkdtemp(join(tmpdir(), `polka-${name}-`)));
    await rm(test.artifacts, { recursive: true, force: true });
    await mkdir(test.artifacts, { recursive: true });
    await run(test);
    test.assertNoRendererErrors();
  } catch (error) {
    failure = error;
    await test?.diagnostics(error).catch((diagnosticError) => console.error(diagnosticError));
  } finally {
    await test?.dispose().catch((error) => {
      if (failure) console.error('Desktop cleanup:', error);
      else failure = error;
    });
    await release();
  }
  if (failure) throw failure;
}
