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
      'windows.close',
    ].includes(method)
  );
}
