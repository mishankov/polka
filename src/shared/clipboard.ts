export const DEFAULT_CLIPBOARD_SHORTCUT = 'CommandOrControl+Shift+V';
export interface ClipboardPreferences {
  paused: boolean;
  pasteOnSelect: boolean;
  hoverEnabled: boolean;
  retentionDays: 1 | 7 | 30;
  accelerator: string;
}
export interface ClipboardClip {
  id: string;
  kind: 'text' | 'image';
  content: string;
  preview: string;
  createdAt: number;
  pinned: boolean;
  snippet?: boolean;
  name?: string;
  sourceDevice?: string;
  ocr?: ImageText;
}
export interface ImageText {
  version: string;
  status: 'ready' | 'empty' | 'failed';
  text: string;
  languages: string[];
}
export interface ClipboardState {
  clips: ClipboardClip[];
  snippets: ClipboardSnippet[];
  preferences: ClipboardPreferences;
  registered: boolean;
  pasteAccess: 'granted' | 'required' | 'unavailable';
  pasteReady: boolean;
  preferencesAvailable: boolean;
  storage: ClipboardStorageState;
  helper: {
    status: 'starting' | 'running' | 'failed' | 'stopped';
    error?: string;
  };
  error?: string;
  sync?: ClipboardSyncState;
}
export type ClipboardSnippet = ClipboardClip & { kind: 'text'; snippet: true };
export interface ClipboardStorageState {
  status: 'starting' | 'ready' | 'failed';
  path: string;
  diagnostic?: {
    stage: 'read' | 'decrypt' | 'parse' | 'encrypt' | 'write';
    code?: string;
    message: string;
  };
}
export const DEFAULT_CLIPBOARD_PREFERENCES: ClipboardPreferences = {
  paused: false,
  pasteOnSelect: true,
  hoverEnabled: true,
  retentionDays: 7,
  accelerator: DEFAULT_CLIPBOARD_SHORTCUT,
};
export function clipboardResults(clips: ClipboardClip[], query: string) {
  const terms = query.toLocaleLowerCase().trim().split(/\s+/).filter(Boolean);
  return clips
    .filter((clip) =>
      terms.every((term) =>
        (clip.kind === 'text'
          ? `${clip.name || ''} ${clip.content}`
          : `Изображение ${clip.ocr?.text ?? ''}`
        )
          .toLocaleLowerCase()
          .includes(term),
      ),
    )
    .sort((a, b) => Number(b.pinned) - Number(a.pinned) || b.createdAt - a.createdAt);
}

export interface ClipboardSyncState {
  enabled: boolean;
  status: 'starting' | 'disabled' | 'active' | 'paused' | 'blocked' | 'failed';
  storage: ClipboardStorageState;
  deviceName: string;
  nearby: { id: string; name: string }[];
  peers: {
    id: string;
    name: string;
    status: 'offline' | 'syncing' | 'connected';
    lastSync?: number;
    error?: string;
  }[];
  invitation?: { code: string; expiresAt: number };
  error?: string;
}
