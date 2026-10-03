export const DEFAULT_CLIPBOARD_SHORTCUT = 'CommandOrControl+Shift+V';
export interface ClipboardPreferences {
  paused: boolean;
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
}
export interface ClipboardState {
  clips: ClipboardClip[];
  preferences: ClipboardPreferences;
  registered: boolean;
  error?: string;
}
export const DEFAULT_CLIPBOARD_PREFERENCES: ClipboardPreferences = {
  paused: false,
  hoverEnabled: true,
  retentionDays: 7,
  accelerator: DEFAULT_CLIPBOARD_SHORTCUT,
};
export function clipboardResults(clips: ClipboardClip[], query: string) {
  const terms = query.toLocaleLowerCase().trim().split(/\s+/).filter(Boolean);
  return clips
    .filter((clip) =>
      terms.every((term) =>
        (clip.kind === 'text' ? clip.content : 'Изображение').toLocaleLowerCase().includes(term),
      ),
    )
    .sort((a, b) => Number(b.pinned) - Number(a.pinned) || b.createdAt - a.createdAt);
}

export interface ClipboardPresentation {
  revision: number;
  visible: boolean;
  focusSearch: boolean;
  topInset: number;
  notchWidth: number;
  notchHeight: number;
}
