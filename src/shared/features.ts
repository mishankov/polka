// Product switch: keep the workspace implementation and stored data dormant.
// Re-enable this together with the legacy desktop workflow checks when work resumes.
export const CUSTOM_APPS_ENABLED: boolean = false;
export const FROZEN_FEATURE_MESSAGE =
  'AI-помощник и пользовательские приложения временно приостановлены. Данные сохранены.';

export function shelfMethodAllowed(method: string) {
  return (
    /^(clipboardHistory|shelf|updates)\./.test(method) ||
    [
      'launcher.show',
      'launcher.hide',
      'launcher.apps',
      'launcher.macApps',
      'launcher.openMac',
      'launcher.getPreferences',
      'launcher.setShortcut',
      'mediaIndicator.getState',
      'mediaIndicator.setEnabled',
      'settings.get',
      'settings.set',
      'system.status',
      'system.login',
      'system.quit',
      'windows.confirmClose',
      'windows.close',
    ].includes(method)
  );
}
