import type { MacShortcut } from './macos-shortcuts';
import { calculate, type Calculation, type CalculationContext } from './calculator';
import { clipboardResults, type ClipboardClip } from './clipboard';
import { launcherApps, type LauncherApp, type LauncherUsageStats } from './launcher';

export type ShelfSearchResult =
  | { id: string; kind: 'app'; app: LauncherApp }
  | { id: string; kind: 'shortcut'; shortcut: MacShortcut }
  | { id: string; kind: 'shortcut-folder'; count: number }
  | { id: string; kind: 'calculation'; calculation: Extract<Calculation, { status: 'result' }> }
  | { id: string; kind: 'clip'; clip: ClipboardClip }
  | { id: string; kind: 'more-clips'; count: number; query: string };

const shortcutFolder: LauncherApp = {
  kind: 'mac',
  id: 'shortcut-folder',
  name: 'Команды macOS',
  description: 'Папка команд',
  searchTerms: ['Shortcuts', 'команды', 'папка команд'],
  icon: '',
};

export function shortcutSearch(shortcuts: MacShortcut[], query: string): ShelfSearchResult[] {
  const byId = new Map(shortcuts.map((s) => [`shortcut:${s.id}`, s]));
  return launcherApps(
    shortcuts.map((s) => ({
      kind: 'mac' as const,
      id: `shortcut:${s.id}`,
      name: s.name,
      description: 'Команда macOS',
      icon: '',
    })),
    query,
  ).map((app) => ({ id: app.id, kind: 'shortcut', shortcut: byId.get(app.id)! }));
}

export function shelfSearch(
  apps: LauncherApp[],
  clips: ClipboardClip[],
  query: string,
  usage: LauncherUsageStats = {},
  context: CalculationContext = {},
  shortcuts: MacShortcut[] = [],
) {
  const calculation = calculate(query, context);
  const results: ShelfSearchResult[] = [];
  if (calculation?.status === 'result')
    results.push({
      id: `calculation:${encodeURIComponent(query)}`,
      kind: 'calculation',
      calculation,
    });
  results.push(
    ...launcherApps(apps, query, usage).map((app) => ({
      id: `app:${app.id}`,
      kind: 'app' as const,
      app,
    })),
  );
  if (shortcuts.length && launcherApps([shortcutFolder], query).length)
    results.push({ id: shortcutFolder.id, kind: 'shortcut-folder', count: shortcuts.length });
  // Keep the main shelf compact. Individual commands are available through
  // global search without requiring navigation into the folder.
  if (query.trim()) results.push(...shortcutSearch(shortcuts, query));
  const matches = query.trim() ? clipboardResults(clips, query) : [];
  results.push(
    ...matches.slice(0, 3).map((clip) => ({ id: `clip:${clip.id}`, kind: 'clip' as const, clip })),
  );
  if (matches.length > 3)
    results.push({ id: 'more-clips', kind: 'more-clips', count: matches.length, query });
  return { calculation, results };
}

/** Show the matching part even when it lies beyond the history's saved preview. */
export function clipboardSnippet(clip: ClipboardClip, query: string) {
  if (clip.kind === 'image') return 'Изображение';
  const text = clip.content.replace(/\s+/g, ' ').trim();
  const term = query.trim().split(/\s+/)[0]?.toLocaleLowerCase() || '';
  const start = Math.max(0, text.toLocaleLowerCase().indexOf(term) - 30);
  return `${start ? '…' : ''}${text.slice(start, start + 160)}${text.length > start + 160 ? '…' : ''}`;
}
