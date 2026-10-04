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

/** Register only for workspace-owned contents, never standalone app windows. */
export function bindAssistantShortcut(contents: WebContents, workspace: WebContents) {
  contents.on('before-input-event', (event, input) => {
    if (
      input.type !== 'keyDown' ||
      !(input.meta || input.control) ||
      input.alt ||
      input.shift ||
      input.isComposing ||
      !(input.code === 'KeyJ' || input.key.toLowerCase() === 'j') ||
      workspace.isDestroyed()
    )
      return;
    // Consume repeats too, but toggle only once for each physical press.
    event.preventDefault();
    if (!input.isAutoRepeat)
      workspace.send('platform:event', { type: 'workspace.toggleAssistant' });
  });
}
