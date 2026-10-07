import { execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import { constants } from 'node:fs';
import { access, readdir, realpath, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { basename, dirname, isAbsolute, join } from 'node:path';
import { promisify } from 'node:util';
import type { MacLauncherApp } from '../shared/launcher';

const execFileAsync = promisify(execFile);
export async function openMacApplication(path: string): Promise<void> {
  // Launch the bundle explicitly instead of treating it as a document via shell.openPath.
  // Pass the exact catalogued path as one argument; names and bundle IDs can be ambiguous.
  await execFileAsync('/usr/bin/open', ['-a', path], { timeout: 15000, maxBuffer: 128 * 1024 });
}
// NSWorkspace resolves bundle-specific icons, including modern asset-catalog icons.
// Run in batches so indexing does not start a process for every application.
const iconScript = `function run(paths) {
  ObjC.import('AppKit');
  return JSON.stringify(paths.map(function(path) {
    try {
      var icon = $.NSWorkspace.sharedWorkspace.iconForFile(path);
      var small = $.NSImage.alloc.initWithSize($.NSMakeSize(32, 32));
      small.lockFocus;
      icon.drawInRectFromRectOperationFraction($.NSMakeRect(0, 0, 32, 32), $.NSMakeRect(0, 0, 0, 0), $.NSCompositingOperationCopy, 1);
      small.unlockFocus;
      var bitmap = $.NSBitmapImageRep.imageRepWithData(small.TIFFRepresentation);
      var png = bitmap.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $({}));
      return 'data:image/png;base64,' + ObjC.unwrap(png.base64EncodedStringWithOptions(0));
    } catch (_) { return ''; }
  }));
}`;
export async function readApplicationIcons(paths: string[]): Promise<Map<string, string>> {
  const icons = new Map<string, string>();
  for (let start = 0; start < paths.length; start += 64) {
    const batch = paths.slice(start, start + 64);
    try {
      const { stdout } = await execFileAsync(
        '/usr/bin/osascript',
        ['-l', 'JavaScript', '-e', iconScript, ...batch],
        { timeout: 15000, maxBuffer: 8 * 1024 * 1024 },
      );
      const images: unknown = JSON.parse(stdout);
      if (!Array.isArray(images) || images.length !== batch.length) continue;
      images.forEach((icon, index) => {
        if (typeof icon === 'string' && /^data:image\/png;base64,[A-Za-z0-9+/=]+$/.test(icon))
          icons.set(batch[index], icon);
      });
    } catch {
      /* Apps remain launchable when macOS cannot render their icons. */
    }
  }
  return icons;
}
type Info = Record<string, unknown>;
// Bundle localization follows macOS language preferences without loading app code.
const namesScript = `function run(args) {
  ObjC.import('Foundation');
  var languages = JSON.parse(args.shift());
  if (!languages.length) languages = ObjC.deepUnwrap($.NSLocale.preferredLanguages);
  return JSON.stringify(args.map(function(path) {
    try {
      var bundle = $.NSBundle.bundleWithPath(path);
      var localization = ObjC.unwrap($.NSBundle.preferredLocalizationsFromArrayForPreferences(
        bundle.localizations, $(languages)).firstObject);
      var stringsPath = ObjC.unwrap(bundle.pathForResourceOfTypeInDirectoryForLocalization(
        'InfoPlist', 'strings', '', localization));
      var info = stringsPath ? ObjC.deepUnwrap($.NSDictionary.dictionaryWithContentsOfFile(stringsPath)) : undefined;
      // Recent Apple apps store localized Info.plist values in one .loctable.
      if (!info) {
        var table = ObjC.deepUnwrap($.NSDictionary.dictionaryWithContentsOfFile(
          ObjC.unwrap(bundle.resourcePath) + '/InfoPlist.loctable'));
        info = table && table[localization];
      }
      if (!info) return '';
      return typeof info.CFBundleDisplayName === 'string' && info.CFBundleDisplayName.trim()
        ? info.CFBundleDisplayName : typeof info.CFBundleName === 'string' ? info.CFBundleName : '';
    } catch (_) { return ''; }
  }));
}`;
export async function readApplicationNames(paths: string[], languages: string[] = []) {
  const names = new Map<string, string>();
  for (let start = 0; start < paths.length; start += 64) {
    const batch = paths.slice(start, start + 64);
    try {
      const { stdout } = await execFileAsync(
        '/usr/bin/osascript',
        ['-l', 'JavaScript', '-e', namesScript, JSON.stringify(languages), ...batch],
        { timeout: 5000, maxBuffer: 1024 * 1024 },
      );
      const values: unknown = JSON.parse(stdout);
      if (!Array.isArray(values) || values.length !== batch.length) continue;
      values.forEach((name, index) => {
        if (typeof name === 'string' && name.trim()) names.set(batch[index], name.trim());
      });
    } catch {
      /* Plain bundle names remain available if localization fails. */
    }
  }
  return names;
}
export async function readApplicationInfo(path: string): Promise<Info> {
  const { stdout } = await execFileAsync(
    '/usr/bin/plutil',
    ['-convert', 'json', '-o', '-', join(path, 'Contents/Info.plist')],
    { timeout: 3000, maxBuffer: 1024 * 1024 },
  );
  const info: unknown = JSON.parse(stdout);
  if (!info || typeof info !== 'object' || Array.isArray(info))
    throw Error('Неверные сведения о приложении');
  return info as Info;
}
async function spotlightApplications() {
  try {
    const { stdout } = await execFileAsync(
      '/usr/bin/mdfind',
      ['-0', 'kMDItemContentType == "com.apple.application-bundle"'],
      { timeout: 4000, maxBuffer: 4 * 1024 * 1024 },
    );
    return stdout
      .split('\0')
      .filter(
        (path) =>
          path &&
          !path.startsWith('/Volumes/') &&
          !path.includes('/Library/') &&
          !path.split('/').some((part) => part.startsWith('.')),
      );
  } catch {
    return [];
  }
}
export const macApplicationRoots = () => [
  '/Applications',
  join(homedir(), 'Applications'),
  '/System/Applications',
  '/System/Library/CoreServices/Applications',
];
export async function discoverApplicationBundles(roots: string[], extra: string[] = []) {
  const bundles = new Set<string>();
  const visited = new Set<string>();
  async function visit(path: string, depth: number) {
    if (depth > 8 || visited.size >= 10000 || !isAbsolute(path) || /\.app\//i.test(path)) return;
    try {
      const canonical = await realpath(path);
      if (visited.has(canonical)) return;
      visited.add(canonical);
      if (!(await stat(canonical)).isDirectory()) return;
      if (/\.app$/i.test(canonical)) {
        if (!/\.app\//i.test(canonical)) bundles.add(canonical);
        return; // Never walk into app bundles and expose their internal helpers.
      }
      for (const entry of await readdir(canonical, { withFileTypes: true })) {
        if (!entry.name.startsWith('.') && (entry.isDirectory() || entry.isSymbolicLink()))
          await visit(join(canonical, entry.name), depth + 1);
      }
    } catch {
      /* Missing/inaccessible folders do not prevent other apps from being listed. */
    }
  }
  for (const root of roots) await visit(root, 0);
  for (const path of extra) if (/\.app$/i.test(path)) await visit(path, 0);
  return [...bundles];
}

async function mapConcurrent<T, U>(items: T[], map: (item: T) => Promise<U>): Promise<U[]> {
  const results = new Array<U>(items.length);
  let next = 0;
  await Promise.all(
    Array.from({ length: Math.min(6, items.length) }, async () => {
      while (next < items.length) {
        const index = next++;
        results[index] = await map(items[index]);
      }
    }),
  );
  return results;
}
type Entry = {
  app: MacLauncherApp;
  path: string;
  signature: string;
  baseName: string;
  bundleId?: string;
};
interface Options {
  platform?: string;
  roots?: string[];
  extraPaths?: () => Promise<string[]>;
  readInfo?: (path: string) => Promise<Info>;
  getIcon?: (path: string) => Promise<string>;
  getIcons?: (paths: string[]) => Promise<Map<string, string>>;
  getNames?: (paths: string[]) => Promise<Map<string, string>>;
  openApplication?: (path: string) => Promise<void>;
}

/** The renderer receives IDs, never authority to launch an arbitrary filesystem path. */
export class InstalledApps {
  private entries = new Map<string, Entry>();
  private scan?: Promise<MacLauncherApp[]>;
  constructor(private options: Options) {}
  list(): Promise<MacLauncherApp[]> {
    if ((this.options.platform || process.platform) !== 'darwin') return Promise.resolve([]);
    if (!this.scan) {
      this.scan = this.refresh().finally(() => {
        this.scan = undefined;
      });
    }
    return this.scan;
  }
  private async validate(path: string) {
    if ((await realpath(path)) !== path) throw Error('Путь приложения изменился');
    const info = await (this.options.readInfo || readApplicationInfo)(path);
    const background = info.LSBackgroundOnly;
    if (
      info.CFBundlePackageType !== 'APPL' ||
      background === true ||
      background === 1 ||
      (typeof background === 'string' && ['1', 'true', 'yes'].includes(background.toLowerCase()))
    )
      throw Error('Это не пользовательское приложение');
    const executable = info.CFBundleExecutable;
    if (
      typeof executable !== 'string' ||
      !executable ||
      basename(executable) !== executable ||
      executable === '.' ||
      executable === '..'
    )
      throw Error('Исполняемый файл приложения не найден');
    const target = join(path, 'Contents/MacOS', executable);
    if (!(await stat(target)).isFile()) throw Error('Исполняемый файл приложения не найден');
    await access(target, constants.X_OK);
    return info;
  }
  private async refresh() {
    const extra = await (this.options.extraPaths || spotlightApplications)().catch(() => []);
    const paths = await discoverApplicationBundles(this.options.roots || macApplicationRoots(), [
      ...(this.options.roots ? [] : ['/System/Library/CoreServices/Finder.app']),
      ...extra,
    ]);
    const found = await mapConcurrent(paths, async (path): Promise<Entry | undefined> => {
      try {
        const metadata = await stat(join(path, 'Contents/Info.plist'));
        const signature = `${metadata.mtimeMs}:${metadata.size}`;
        const id = `mac:${createHash('sha256').update(path).digest('hex').slice(0, 32)}`;
        const cached = this.entries.get(id);
        if (cached?.signature === signature) return cached;
        const info = await this.validate(path);
        const name = [info.CFBundleDisplayName, info.CFBundleName].find(
          (value) => typeof value === 'string' && value.trim(),
        ) as string | undefined;
        return {
          path,
          signature,
          baseName: name?.trim() || basename(path).replace(/\.app$/i, ''),
          bundleId:
            typeof info.CFBundleIdentifier === 'string' ? info.CFBundleIdentifier : undefined,
          app: {
            kind: 'mac',
            id,
            name: name?.trim() || basename(path).replace(/\.app$/i, ''),
            icon: '',
            description: `macOS · ${dirname(path)}`,
            searchTerms: [
              basename(path).replace(/\.app$/i, ''),
              info.CFBundleDisplayName,
              info.CFBundleName,
              info.CFBundleIdentifier,
            ].filter((term): term is string => typeof term === 'string'),
          },
        };
      } catch {
        return undefined;
      }
    });
    const fresh = found.filter(
      (entry): entry is Entry => !!entry && entry !== this.entries.get(entry.app.id),
    );
    if (fresh.length) {
      const paths = fresh.map((entry) => entry.path);
      const icons = this.options.getIcons
        ? await this.options.getIcons(paths).catch(() => new Map<string, string>())
        : this.options.getIcon
          ? new Map(
              await mapConcurrent(
                paths,
                async (path) => [path, await this.options.getIcon!(path).catch(() => '')] as const,
              ),
            )
          : await readApplicationIcons(paths);
      for (const entry of fresh)
        entry.app.icon =
          icons.get(entry.path) ||
          (this.options.getIcons && this.options.getIcon
            ? await this.options.getIcon(entry.path).catch(() => '')
            : '');
    }
    const entries = found.filter((entry): entry is Entry => !!entry);
    const names = await (
      this.options.getNames ||
      (this.options.readInfo ? async () => new Map<string, string>() : readApplicationNames)
    )(entries.map((entry) => entry.path)).catch(() => new Map<string, string>());
    this.entries = new Map(
      entries.map((entry) => {
        const name = names.get(entry.path) || entry.baseName;
        const localized =
          name !== entry.app.name ? { ...entry, app: { ...entry.app, name } } : entry;
        return [entry.app.id, localized];
      }),
    );
    return [...this.entries.values()]
      .map((entry) => entry.app)
      .sort((a, b) => a.name.localeCompare(b.name));
  }
  async open(id: string) {
    const entry = this.entries.get(id);
    if (!entry)
      throw Error('Приложение не найдено. Откройте быстрый запуск снова, чтобы обновить список.');
    try {
      const info = await this.validate(entry.path);
      if (entry.bundleId && info.CFBundleIdentifier !== entry.bundleId)
        throw Error('Приложение изменилось');
      await (this.options.openApplication || openMacApplication)(entry.path);
    } catch (error) {
      throw Error(
        `Не удалось открыть ${entry.app.name}. ${error instanceof Error ? error.message : String(error)}`,
      );
    }
    return { opened: true };
  }
}
