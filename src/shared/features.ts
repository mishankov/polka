export function shelfMethodAllowed(method: string) {
  return (
    /^(clipboardHistory|shelf|updates)\./.test(method) ||
    [
      'macShortcuts.state',
      'macShortcuts.run',
      'macShortcuts.openApp',
      'launcher.show',
      'launcher.hide',
      'launcher.apps',
      'launcher.macApps',
      'launcher.usage',
      'launcher.openMac',
      'launcher.getPreferences',
      'launcher.setShortcut',
      'mediaIndicator.getState',
      'mediaIndicator.setEnabled',
      'mediaIndicator.setTracking',
      'settings.get',
      'settings.set',
      'system.status',
      'system.login',
      'system.quit',
      'windows.close',
    ].includes(method)
  );
}
