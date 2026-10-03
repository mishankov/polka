import type { WebContents } from 'electron';

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
