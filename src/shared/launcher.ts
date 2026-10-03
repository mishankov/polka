import type { AppInstance } from './types';

export const DEFAULT_LAUNCHER_SHORTCUT = 'CommandOrControl+Shift+Space';
export interface LauncherPreferences {
  accelerator: string;
  registered: boolean;
  error?: string;
}
export type EverythingLauncherApp = Pick<
  AppInstance,
  'id' | 'name' | 'icon' | 'description' | 'favorite' | 'status'
> & { kind: 'everything' };
export interface MacLauncherApp {
  kind: 'mac';
  id: string;
  name: string;
  icon: string;
  description: string;
  searchTerms?: string[];
}
export type LauncherApp = EverythingLauncherApp | MacLauncherApp;

export function launcherApps(apps: LauncherApp[], query: string): LauncherApp[] {
  const terms = query.trim().toLocaleLowerCase().split(/\s+/).filter(Boolean);
  return apps
    .filter(
      (app) =>
        (app.kind === 'mac' || app.status !== 'archived') &&
        terms.every((term) =>
          `${app.name} ${app.description} ${app.kind === 'mac' ? app.searchTerms?.join(' ') || '' : ''}`
            .toLocaleLowerCase()
            .includes(term),
        ),
    )
    .sort(
      (a, b) =>
        Number(b.kind === 'everything' && b.favorite) -
          Number(a.kind === 'everything' && a.favorite) ||
        Number(b.kind === 'everything') - Number(a.kind === 'everything') ||
        a.name.localeCompare(b.name, 'ru') ||
        a.id.localeCompare(b.id),
    );
}

export function shortcutLabel(accelerator: string) {
  return accelerator
    .replace('CommandOrControl', navigator.platform.includes('Mac') ? '⌘' : 'Ctrl')
    .replace('Shift', '⇧')
    .replace('Alt', '⌥')
    .replace('Control', 'Ctrl')
    .replace('Space', 'Пробел')
    .split('+')
    .join(' ');
}
