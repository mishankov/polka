export const DEFAULT_LAUNCHER_SHORTCUT = 'CommandOrControl+Shift+Space';
export interface LauncherPreferences {
  accelerator: string;
  registered: boolean;
  error?: string;
}
export interface MacLauncherApp {
  kind: 'mac';
  id: string;
  name: string;
  icon: string;
  description: string;
  searchTerms?: string[];
}
export interface BuiltinLauncherApp {
  kind: 'builtin';
  id: 'builtin:clipboard';
  name: string;
  icon: string;
  description: string;
  searchTerms: string[];
}
export const BUILTIN_APPS: BuiltinLauncherApp[] = [
  {
    kind: 'builtin',
    id: 'builtin:clipboard',
    name: 'История буфера обмена',
    icon: 'clipboard',
    description: 'Скопированный текст и изображения',
    searchTerms: ['clipboard', 'history', 'буфер', 'копировать'],
  },
];
export type LauncherApp = MacLauncherApp | BuiltinLauncherApp;

export function launcherApps(apps: LauncherApp[], query: string): LauncherApp[] {
  const terms = query.trim().toLocaleLowerCase().split(/\s+/).filter(Boolean);
  return apps
    .filter((app) =>
      terms.every((term) =>
        `${app.name} ${app.description} ${app.searchTerms?.join(' ') || ''}`
          .toLocaleLowerCase()
          .includes(term),
      ),
    )
    .sort(
      (a, b) =>
        Number(b.kind === 'builtin') - Number(a.kind === 'builtin') ||
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
