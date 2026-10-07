import { useState } from 'react';
import type { ClipboardStorageState } from '../../shared/clipboard';
import { Alert, Button } from './NativeControls';
import { api, errorMessage } from './api';
import { KEYCHAIN_ACCESS_RECOVERY } from '../../shared/keychain-access';

export default function ClipboardStorageFailure({
  storage,
  store,
  readable = false,
  snippets = false,
}: {
  storage?: ClipboardStorageState;
  store: 'history' | 'sync';
  readable?: boolean;
  snippets?: boolean;
}) {
  const [error, setError] = useState('');
  if (storage?.status !== 'failed') return null;
  return (
    <Alert
      className="clipboard-storage-failure"
      gap="sm"
      color="red"
      title={
        snippets
          ? 'Сниппеты недоступны'
          : store === 'history'
            ? 'История буфера недоступна'
            : 'Хранилище синхронизации недоступно'
      }
    >
      <p>
        {snippets
          ? readable
            ? 'Нельзя сохранять или изменять сниппеты. Сохранённые сниппеты можно просматривать и копировать. Синхронизация остановлена.'
            : 'Не удалось загрузить сохранённые сниппеты. Их просмотр, копирование и изменение недоступны. Эмодзи можно копировать.'
          : store === 'history'
            ? readable
              ? 'Новые записи не сохраняются. Сохранённые записи можно просматривать и копировать. Синхронизация остановлена.'
              : 'Не удалось загрузить сохранённую историю и её настройки. Сохранение новых записей, наведение, сочетание истории и автоматическая вставка недоступны. Эмодзи можно копировать.'
            : 'Синхронизация остановлена. Локальная история и остальные функции Полки остаются доступны.'}
      </p>
      <p>
        Файл не сброшен. Восстановите доступ к хранилищу и перезапустите Полку. Перед заменой файла
        сохраните его зашифрованную копию.
      </p>
      {['decrypt', 'encrypt'].includes(storage.diagnostic?.stage ?? '') && (
        <p>{KEYCHAIN_ACCESS_RECOVERY}</p>
      )}
      <details>
        <summary>Подробности ошибки</summary>
        <p>
          {storage.diagnostic?.message}
          {storage.diagnostic?.code && ` · ${storage.diagnostic.code}`}
        </p>
        <p style={{ overflowWrap: 'anywhere' }}>{storage.path}</p>
      </details>
      <Button
        variant="default"
        onClick={() => {
          setError('');
          void api('clipboardHistory.revealStorage', { store }).catch((reason) =>
            setError(errorMessage(reason)),
          );
        }}
      >
        Показать файл в Finder
      </Button>
      {error && <p>{error}</p>}
    </Alert>
  );
}
