import test from 'node:test';
import assert from 'node:assert/strict';
import {
  chmod,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rename,
  rm,
  symlink,
  writeFile,
} from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  discoverApplicationBundles,
  InstalledApps,
  readApplicationInfo,
  readApplicationNames,
} from '../src/main/installed-apps';
import { launcherApps } from '../src/shared/launcher';

async function fixture(getNames?: (paths: string[]) => Promise<Map<string, string>>) {
  const root = await realpath(await mkdtemp(join(tmpdir(), 'everything-installed-apps-')));
  const applications = join(root, 'Applications');
  await mkdir(applications);
  async function bundle(name: string, info: Record<string, unknown> = {}, parent = applications) {
    const path = join(parent, name + '.app');
    await mkdir(join(path, 'Contents/MacOS'), { recursive: true });
    await writeFile(join(path, 'Contents/MacOS/main'), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
    await writeFile(
      join(path, 'Contents/Info.plist'),
      JSON.stringify({
        CFBundlePackageType: 'APPL',
        CFBundleExecutable: 'main',
        CFBundleIdentifier: `qa.${name}`,
        ...info,
      }),
    );
    return path;
  }
  let reads = 0,
    icons = 0;
  const opened: string[] = [];
  const service = new InstalledApps({
    platform: 'darwin',
    roots: [applications],
    extraPaths: async () => [],
    readInfo: async (path) => {
      reads++;
      return JSON.parse(await readFile(join(path, 'Contents/Info.plist'), 'utf8'));
    },
    getIcon: async () => {
      icons++;
      return 'data:image/png;base64,icon';
    },
    getNames,
    openPath: async (path) => {
      opened.push(path);
      return '';
    },
  });
  return {
    root,
    applications,
    bundle,
    service,
    opened,
    counts: () => ({ reads, icons }),
    cleanup: () => rm(root, { recursive: true, force: true }),
  };
}

test('discovery walks app folders, deduplicates symlinks, avoids cycles, hidden directories and nested helpers', async () => {
  const f = await fixture();
  try {
    const first = await f.bundle('First');
    const second = await f.bundle('Second', {}, join(f.applications, 'Utilities'));
    const helper = await f.bundle('Helper', {}, join(first, 'Contents/Helpers'));
    await f.bundle('Hidden', {}, join(f.applications, '.hidden'));
    await symlink(first, join(f.applications, 'Alias.app'));
    await symlink(second, join(f.applications, 'Alias without extension'));
    await symlink(f.applications, join(f.applications, 'Loop'));
    assert.deepEqual(
      (
        await discoverApplicationBundles(
          [f.applications, join(f.root, 'missing')],
          [first, helper, 'relative.app'],
        )
      ).sort(),
      [first, second].sort(),
    );
  } finally {
    await f.cleanup();
  }
});

test('localized catalog names retain English aliases and stable IDs, refresh with language, and fall back on failure', async () => {
  let language = 'ru';
  const f = await fixture(async (paths) => {
    if (language === 'unavailable') throw Error('Name reader unavailable');
    return new Map(paths.map((path) => [path, language === 'ru' ? 'Калькулятор' : 'Calculator']));
  });
  try {
    await f.bundle('Calculator', { CFBundleDisplayName: 'Calculator', CFBundleName: 'Calculator' });
    const [russian] = await f.service.list();
    assert.equal(russian.name, 'Калькулятор');
    for (const query of ['калькулятор', 'Calculator', 'кальк'])
      assert.equal(launcherApps([russian], query)[0]?.id, russian.id);
    const counts = f.counts();
    language = 'en';
    const [english] = await f.service.list();
    assert.equal(english.name, 'Calculator');
    assert.equal(english.id, russian.id);
    assert.equal(f.counts().icons, counts.icons);
    language = 'ru';
    await f.service.list();
    language = 'unavailable';
    assert.equal((await f.service.list())[0].name, 'Calculator');
    await f.service.open(russian.id);
    assert.equal(f.opened.length, 1);
  } finally {
    await f.cleanup();
  }
});

test(
  'macOS resolves preferred localized names from strings and modern loctables without loading applications',
  { skip: process.platform !== 'darwin' },
  async () => {
    const { execFile } = await import('node:child_process');
    const { promisify } = await import('node:util');
    const f = await fixture();
    try {
      const calculator = await f.bundle('Calculator', {
        CFBundleDisplayName: 'Calculator',
        CFBundleDevelopmentRegion: 'en',
      });
      const calendar = await f.bundle('Calendar', {
        CFBundleDisplayName: 'Calendar',
        CFBundleDevelopmentRegion: 'en',
      });
      for (const path of [calculator, calendar]) {
        await promisify(execFile)('/usr/bin/plutil', [
          '-convert',
          'xml1',
          join(path, 'Contents/Info.plist'),
        ]);
        for (const locale of ['ru', 'en'])
          await mkdir(join(path, 'Contents/Resources', locale + '.lproj'), { recursive: true });
      }
      await writeFile(
        join(calculator, 'Contents/Resources/ru.lproj/InfoPlist.strings'),
        '"CFBundleDisplayName" = "Калькулятор";',
      );
      await writeFile(
        join(calculator, 'Contents/Resources/en.lproj/InfoPlist.strings'),
        '"CFBundleDisplayName" = "Calculator";',
      );
      await writeFile(
        join(calendar, 'Contents/Resources/InfoPlist.loctable'),
        JSON.stringify({
          ru: { CFBundleDisplayName: 'Календарь' },
          en: { CFBundleDisplayName: 'Calendar' },
        }),
      );
      await promisify(execFile)('/usr/bin/plutil', [
        '-convert',
        'binary1',
        join(calendar, 'Contents/Resources/InfoPlist.loctable'),
      ]);
      const russian = await readApplicationNames([calculator, calendar], ['ru-RU', 'en']);
      assert.equal(russian.get(calculator), 'Калькулятор');
      assert.equal(russian.get(calendar), 'Календарь');
      const english = await readApplicationNames([calculator, calendar], ['en']);
      assert.equal(english.get(calculator), 'Calculator');
      assert.equal(english.get(calendar), 'Calendar');
      assert.equal((await readApplicationNames([join(f.root, 'Missing.app')], ['ru'])).size, 0);
    } finally {
      await f.cleanup();
    }
  },
);

test('catalog retains menu-bar apps and same-named copies, rejects invalid bundles, and caches unchanged metadata/icons', async () => {
  const f = await fixture();
  try {
    const first = await f.bundle('First', {
      CFBundleDisplayName: 'Display Name',
      LSUIElement: true,
    });
    await f.bundle('Other', { CFBundleDisplayName: 'Display Name' });
    await f.bundle('Invalid', { CFBundlePackageType: 'BNDL' });
    await f.bundle('Background', { LSBackgroundOnly: true });
    await f.bundle('Traversal', { CFBundleExecutable: '../main' });
    const broken = await f.bundle('Broken');
    await chmod(join(broken, 'Contents/MacOS/main'), 0o644);
    const list = await f.service.list();
    assert.equal(list.length, 2);
    assert(
      list.every(
        (app) => app.name === 'Display Name' && app.kind === 'mac' && app.icon.startsWith('data:'),
      ),
    );
    assert.notEqual(list[0].id, list[1].id);
    const counts = f.counts();
    await Promise.all([f.service.list(), f.service.list()]);
    assert.equal(f.counts().icons, counts.icons, 'Unchanged icons are reused');
    assert.equal(
      f.counts().reads,
      counts.reads + 4,
      'Only rejected bundles need their metadata checked again',
    );
    await rm(first, { recursive: true });
    assert.equal((await f.service.list()).length, 1);
    await f.bundle('New', { CFBundleDisplayName: 'Newly Installed' });
    assert.equal((await f.service.list()).length, 2);
  } finally {
    await f.cleanup();
  }
});

test('only catalogued apps can launch; removal, bundle replacement and symlink swaps are rejected', async () => {
  const f = await fixture();
  try {
    const path = await f.bundle("App with spaces and 'quotes'");
    const [app] = await f.service.list();
    await assert.rejects(f.service.open('/tmp/anything.app'), /не найдено/);
    assert.deepEqual(await f.service.open(app.id), { opened: true });
    assert.deepEqual(f.opened, [path]);
    const info = JSON.parse(await readFile(join(path, 'Contents/Info.plist'), 'utf8'));
    await writeFile(
      join(path, 'Contents/Info.plist'),
      JSON.stringify({ ...info, CFBundleIdentifier: 'qa.replaced' }),
    );
    await assert.rejects(f.service.open(app.id), /изменилось/);
    assert.equal(f.opened.length, 1);
    const other = await f.bundle('Other');
    await rename(path, path + '.removed');
    await symlink(other, path);
    await assert.rejects(f.service.open(app.id), /Путь приложения изменился/);
    await rm(path);
    await assert.rejects(f.service.open(app.id), /Не удалось открыть/);
    assert.equal(f.opened.length, 1);
  } finally {
    await f.cleanup();
  }
});

test('missing icons do not prevent listing; native launch errors reach the caller', async () => {
  const f = await fixture();
  try {
    await f.bundle('No Icon');
    const service = new InstalledApps({
      platform: 'darwin',
      roots: [f.applications],
      extraPaths: async () => {
        throw Error('Spotlight unavailable');
      },
      readInfo: async (path) =>
        JSON.parse(await readFile(join(path, 'Contents/Info.plist'), 'utf8')),
      getIcon: async () => {
        throw Error('No icon');
      },
      openPath: async () => 'LaunchServices failure',
    });
    const [app] = await service.list();
    assert.equal(app.icon, '');
    await assert.rejects(service.open(app.id), /LaunchServices failure/);
    const otherPlatform = new InstalledApps({
      platform: 'linux',
      roots: [f.applications],
      getIcon: async () => '',
      openPath: async () => '',
    });
    assert.deepEqual(await otherPlatform.list(), []);
  } finally {
    await f.cleanup();
  }
});

test(
  'macOS property-list reader handles binary bundles without executing their contents',
  { skip: process.platform !== 'darwin' },
  async () => {
    const { execFile } = await import('node:child_process');
    const { promisify } = await import('node:util');
    const f = await fixture();
    try {
      const path = await f.bundle('Binary', { CFBundleDisplayName: 'Binary App' });
      await promisify(execFile)('/usr/bin/plutil', [
        '-convert',
        'binary1',
        join(path, 'Contents/Info.plist'),
      ]);
      const info = await readApplicationInfo(path);
      assert.equal(info.CFBundleDisplayName, 'Binary App');
      assert.equal(info.CFBundlePackageType, 'APPL');
    } finally {
      await f.cleanup();
    }
  },
);
