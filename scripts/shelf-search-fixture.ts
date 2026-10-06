import type {} from '../src/shared/types';
import type { ClipboardState } from '../src/shared/clipboard';
import type { ShelfDestination } from '../src/shared/shelf';

type PlatformEvent = Parameters<Parameters<Window['platform']['onEvent']>[0]>[0];

/** Isolated renderer fixture: actions never launch apps or change the system clipboard. */
export function createShelfSearchFixture() {
  const listeners = new Set<(event: PlatformEvent) => void>();
  const actions: { method: string; params: Record<string, unknown> }[] = [];
  const shownRevisions: number[] = [];
  let release: (() => void) | undefined;
  let hold = false;
  let revision = 0;
  const createClips = (count: number) =>
    Array.from({ length: count }, (_, i) => ({
      kind: 'text',
      id: `clip-${i}`,
      content: `Заметка ${i + 1}: 2+2 — пример`,
      preview: `Заметка ${i + 1}: 2+2 — пример`,
      createdAt: Date.UTC(2026, 9, 5, 10, i),
      pinned: false,
    }));
  let clips = createClips(4);
  let pasteOnSelect = true;
  let pasteAccess: ClipboardState['pasteAccess'] = 'granted';
  let pasteReady = true;
  let accessError = '';
  const changed = () => {
    for (const listener of listeners) listener({ type: 'clipboardHistory.changed' });
  };
  const presentation = {
    revision,
    destination: 'apps' as ShelfDestination,
    visible: true,
    focusSearch: true,
    topInset: 0,
    notchWidth: 96,
    notchHeight: 3,
    searchQuery: '',
  };
  const navigate = (destination: typeof presentation.destination, searchQuery = '') => {
    Object.assign(presentation, { destination, searchQuery, revision: ++revision });
    for (const listener of listeners)
      listener({ type: 'shelf.shown', presentation: { ...presentation } });
  };
  return {
    actions,
    shownRevisions,
    navigate,
    setClipCount: (count: number) => {
      clips = createClips(count);
      changed();
    },
    setPasteOnSelect: (enabled: boolean) => {
      pasteOnSelect = enabled;
      changed();
    },
    setPasteAccess: (access: ClipboardState['pasteAccess'], ready = false) => {
      pasteAccess = access;
      pasteReady = ready;
      changed();
    },
    setAccessError: (error: string) => {
      accessError = error;
    },
    hold: () => {
      hold = true;
    },
    release: () => {
      hold = false;
      release?.();
    },
    onEvent: (listener: (event: PlatformEvent) => void) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    async call(method: string, params: Record<string, unknown> = {}) {
      switch (method) {
        case 'shelf.didShow':
          shownRevisions.push(Number(params.revision));
          return;
        case 'shelf.presentation':
          return { ...presentation };
        case 'shelf.appearance':
          return { dark: true, contrast: false, reducedTransparency: false };
        case 'launcher.apps':
          return [
            {
              kind: 'builtin',
              id: 'builtin:clipboard',
              name: 'История буфера обмена',
              description: 'Скопированный текст и изображения',
              icon: '',
              searchTerms: ['clipboard', 'history', 'буфер'],
            },
          ];
        case 'launcher.macApps':
          return [
            'Calculator',
            'Calendar',
            'Contacts',
            'Finder',
            'Mail',
            'Notes',
            'Photos',
            'Safari',
            'Terminal',
            'TextEdit',
          ].map((name) => ({
            kind: 'mac',
            id: `mac:${name}`,
            name,
            description: `${name}.app`,
            icon: '',
            searchTerms: name === 'Calculator' ? ['2+2'] : [],
          }));
        case 'clipboardHistory.state':
          return {
            clips,
            preferences: {
              paused: false,
              pasteOnSelect,
              hoverEnabled: false,
              retentionDays: 7,
              accelerator: 'CommandOrControl+Shift+V',
            },
            registered: true,
            pasteAccess,
            pasteReady,
          };
        case 'launcher.getPreferences':
          return { accelerator: 'CommandOrControl+Shift+Space', registered: true };
        case 'settings.get':
          return true;
        case 'system.status':
          return { login: false };
        case 'launcher.show':
          navigate('apps');
          return;
        case 'shelf.settings':
          navigate('settings');
          return;
        case 'clipboardHistory.pin': {
          actions.push({ method, params });
          const clip = clips.find((clip) => clip.id === params.id);
          if (clip) clip.pinned = Boolean(params.pinned);
          changed();
          return;
        }
        case 'launcher.openMac':
        case 'shelf.copyCalculation':
        case 'shelf.copyEmoji':
        case 'shelf.selectEmoji':
        case 'clipboardHistory.requestPasteAccess':
        case 'clipboardHistory.copy':
        case 'clipboardHistory.select':
        case 'clipboardHistory.show':
          actions.push({ method, params });
          if (hold)
            await new Promise<void>((resolve) => {
              release = resolve;
            });
          if (method === 'clipboardHistory.requestPasteAccess' && accessError)
            throw Error(accessError);
          if (method === 'clipboardHistory.show') navigate('clipboard', String(params.query || ''));
          return;
        default:
          return;
      }
    },
  };
}
