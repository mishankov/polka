import { expect } from '@playwright/test';
import { execFile, execFileSync, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import { createInterface } from 'node:readline';
import { writeFile, readFile, mkdir } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { runDesktopTest } from './desktop-test';
import { SettingsStore } from '../src/main/settings-store';
import type { FileShelfState } from '../src/shared/file-shelf';

void runDesktopTest('file-shelf-native', async (test) => {
  const bundle = join(test.profile, 'File Shelf Fixture.app');
  await mkdir(join(bundle, 'Contents/MacOS'), { recursive: true });
  await writeFile(
    join(bundle, 'Contents/Info.plist'),
    '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>app.polka.file-shelf-fixture</string><key>CFBundleExecutable</key><string>Fixture</string><key>CFBundleName</key><string>File Shelf Fixture</string><key>CFBundlePackageType</key><string>APPL</string><key>NSPrincipalClass</key><string>NSApplication</string><key>LSUIElement</key><true/></dict></plist>',
  );
  const binary = join(bundle, 'Contents/MacOS/Fixture');
  execFileSync('swiftc', [
    'scripts/file-shelf-fixture.swift',
    '-o',
    binary,
    '-framework',
    'AppKit',
  ]);
  execFileSync('codesign', ['--force', '--sign', '-', bundle]);
  if (execFileSync(binary, ['--access'], { encoding: 'utf8', timeout: 10000 }).trim() !== 'true') {
    throw Error('Native mouse validation needs Accessibility permission for the invoking app.');
  }
  const settings = new SettingsStore(test.profile);
  await settings.handle('settings.set', { key: 'mediaIndicatorEnabled', value: false });
  settings.close();
  const sourceDirectory = join(test.profile, 'Transfer source');
  await mkdir(sourceDirectory);
  const paths = [
    join(sourceDirectory, 'Native plan.txt'),
    join(sourceDirectory, 'Native report.txt'),
  ];
  for (const path of paths) await writeFile(path, 'Synthetic native drag fixture');
  const app = await test.launch({ args: [resolve('.')] });
  app.process().stdout?.on('data', (data) => console.log(String(data)));
  app.process().stderr?.on('data', (data) => console.log(String(data)));
  const page = await app.firstWindow();
  await test.shelfReady(app, page, 'Поиск по полке');
  await page.evaluate(() => window.platform.call('launcher.hide'));
  await test.shelfHidden(app, page);
  const child = spawn(binary, paths, { stdio: ['pipe', 'pipe', 'pipe'] });
  test.deferCleanup(async () => {
    child.stdin.end();
    child.kill();
  });
  const messages: any[] = [];
  createInterface({ input: child.stdout }).on('line', (line) => {
    const message = JSON.parse(line);
    messages.push(message);
    console.log('Native fixture:', message);
  });
  child.stderr.on('data', (data) => console.error(String(data)));
  await expect.poll(() => messages.find((message) => message.type === 'ready')).toBeTruthy();
  await page.evaluate(() => {
    for (const type of ['dragenter', 'dragover', 'drop'])
      document.addEventListener(type, (event) =>
        console.log(
          'File drag DOM',
          type,
          Array.from((event as DragEvent).dataTransfer?.types || []),
        ),
      );
  });
  page.on('console', (message) => {
    if (message.text().includes('File drag')) console.log(message.text());
  });
  const ready = messages.find((message) => message.type === 'ready');
  const gesture = (start: { x: number; y: number }, end: { x: number; y: number }) =>
    promisify(execFile)(binary, [
      '--mouse',
      String(start.x),
      String(start.y),
      String(end.x),
      String(end.y),
    ]);
  await gesture(ready.source, ready.target);
  await expect
    .poll(
      () =>
        page
          .evaluate(() => window.platform.call<FileShelfState>('shelf.files.state'))
          .then((state) => state.items.length),
      { timeout: 15000 },
    )
    .toBe(2);
  await expect(page.getByRole('heading', { name: 'Файлы на полке' })).toBeVisible();
  const artifacts = resolve('artifacts/issue-12');
  await mkdir(artifacts, { recursive: true });
  await page.screenshot({ path: join(artifacts, 'file-shelf-native-drop.png') });
  await page.getByRole('button', { name: 'Native plan.txt', exact: true }).click();
  await page
    .getByRole('button', { name: 'Native report.txt', exact: true })
    .click({ modifiers: ['Meta'] });
  const bounds = await app.evaluate(({ BrowserWindow }) =>
    BrowserWindow.getAllWindows()
      .find((win) => win.webContents.getURL().includes('mode=shelf'))!
      .getBounds(),
  );
  const box = (await page
    .getByRole('button', { name: 'Native plan.txt', exact: true })
    .boundingBox())!;
  await gesture({ x: bounds.x + box.x + 30, y: bounds.y + box.y + box.height / 2 }, ready.source);
  await expect
    .poll(() => messages.find((message) => message.type === 'received'), { timeout: 15000 })
    .toMatchObject({ paths });
  await test.shelfHidden(app, page);
  for (const path of paths)
    expect(await readFile(path, 'utf8')).toBe('Synthetic native drag fixture');
  await test.close(app, true);
})
  .then(() => console.log('Native cross-app multi-file drop and transfer passed.'))
  .catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
