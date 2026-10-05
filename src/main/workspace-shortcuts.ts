import type { WebContents } from 'electron';

/** Route Command-comma through the shared settings destination. */
export function bindSettingsShortcut(contents: WebContents, openSettings: () => void) {
  contents.on('before-input-event', (event, input) => {
    const modifier =
      process.platform === 'darwin' ? input.meta && !input.control : input.control && !input.meta;
    if (
      input.type !== 'keyDown' ||
      !modifier ||
      input.alt ||
      input.shift ||
      input.isComposing ||
      !(input.code === 'Comma' || input.key === ',')
    )
      return;
    event.preventDefault();
    if (!input.isAutoRepeat) openSettings();
  });
}
