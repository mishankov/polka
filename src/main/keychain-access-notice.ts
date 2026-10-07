import { promises as fs } from 'node:fs';
import { join } from 'node:path';
import type { MessageBoxOptions } from 'electron';

export const keychainAccessNotice: MessageBoxOptions = {
  type: 'info',
  title: 'Доступ к зашифрованной истории',
  message: 'Полке нужен ключ для истории буфера обмена',
  detail:
    'Полка шифрует сохранённую историю буфера обмена и данные подключения к другим Mac. Ключ хранится в Связке ключей macOS под именем «polka Safe Storage».\n\n' +
    'На следующем шаге macOS может запросить доступ к этому ключу. В системном окне введите пароль связки ключей «Вход» — обычно это пароль входа в Mac — и выберите «Разрешать всегда». Пароль вводится только в окне macOS.\n\n' +
    'После обновления macOS может запросить доступ снова. Если выбрать «Отказать», история и синхронизация будут недоступны. Сохранённые данные останутся на месте.',
  buttons: ['Продолжить'],
  defaultId: 0,
  noLink: true,
};

// safeStorage cannot report whether Keychain will prompt without attempting access.
// Explain before the first access in each packaged version, never on every launch.
export async function explainKeychainAccess(
  profile: string,
  version: string,
  show: (options: MessageBoxOptions) => Promise<unknown>,
) {
  const path = join(profile, 'keychain-notice-version');
  try {
    if ((await fs.readFile(path, 'utf8')) === version) return;
  } catch {
    // Missing/unreadable notice preferences must not prevent encrypted storage access.
  }
  try {
    await show(keychainAccessNotice);
  } catch {
    // An informational dialog failure must not leave history stuck in "starting".
    console.error('Could not show the Keychain access explanation');
    return;
  }
  try {
    await fs.mkdir(profile, { recursive: true, mode: 0o700 });
    await fs.writeFile(path, version, { mode: 0o600 });
  } catch {
    console.error('Could not remember the Keychain access explanation');
  }
}
