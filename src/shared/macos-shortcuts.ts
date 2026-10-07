export const SHORTCUT_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export interface MacShortcut {
  id: string;
  name: string;
  selected: boolean;
  availability: 'available' | 'missing' | 'unknown';
}
export interface ShortcutRun {
  id: string;
  name: string;
  status: 'running' | 'completed' | 'cancelled' | 'failed';
  message?: string;
}
export interface ShortcutsState {
  shortcuts: MacShortcut[];
  error?: string;
  run?: ShortcutRun;
}
