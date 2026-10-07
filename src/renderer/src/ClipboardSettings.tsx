import { useEffect, useState } from 'react';
import { Alert, Button, Group, Select, Stack, Switch, Text, TextInput } from './NativeControls';
import type { ClipboardState } from '../../shared/clipboard';
import { shortcutLabel } from '../../shared/launcher';
import ClipboardSyncSettings from './ClipboardSyncSettings';
import ClipboardStorageFailure from './ClipboardStorageFailure';
import ClipboardHelperStatus from './ClipboardHelperStatus';
import ClipboardPrivacy from './ClipboardPrivacy';
import { api, errorMessage } from './api';

export default function ClipboardSettings() {
  const [state, setState] = useState<ClipboardState>();
  const writable = !!state && state.storage?.status === 'ready';
  const [error, setError] = useState('');
  const [recording, setRecording] = useState(false);
  const [saving, setSaving] = useState(false);
  useEffect(() => {
    let active = true;
    const refresh = () =>
      void api<ClipboardState>('clipboardHistory.state')
        .then((next) => {
          if (active) setState(next);
        })
        .catch((reason) => {
          if (active) setError(errorMessage(reason));
        });
    refresh();
    window.addEventListener('focus', refresh);
    const unsubscribe = window.platform.onEvent((event) => {
      if (event.type === 'clipboardHistory.changed') refresh();
    });
    return () => {
      active = false;
      window.removeEventListener('focus', refresh);
      unsubscribe();
    };
  }, []);
  async function save(method: string, params: Record<string, unknown>) {
    setSaving(true);
    setError('');
    setRecording(false);
    try {
      setState(await api(`clipboardHistory.${method}`, params));
      return true;
    } catch (reason) {
      setError(errorMessage(reason));
      return false;
    } finally {
      setSaving(false);
    }
  }
  return (
    <Stack gap="sm" className="clipboard-settings">
      <Text size="sm" fw={500}>
        История буфера обмена
      </Text>
      <Text size="sm" c="dimmed">
        Встроенное приложение на полке. Откройте его из списка приложений или своим сочетанием
        клавиш. Выбор записи копирует её и вставляет в поле, которое было активно до открытия полки.
      </Text>
      <ClipboardStorageFailure
        storage={state?.storage}
        store="history"
        readable={state?.preferencesAvailable}
      />
      {state?.helper?.status === 'failed' && <Alert color="red">{state.helper.error}</Alert>}
      <ClipboardHelperStatus state={state} />
      <ClipboardPrivacy
        preferences={state?.preferences}
        disabled={!writable || saving}
        save={save}
        settings
      />
      <Switch
        label="Вставлять выбранную запись в предыдущее поле"
        checked={state?.preferences.pasteOnSelect ?? false}
        disabled={!writable || saving}
        onChange={(event) =>
          void save('preferences', { pasteOnSelect: event.currentTarget.checked })
        }
      />
      {state?.preferences.pasteOnSelect && state.helper?.status !== 'starting' && (
        <Text size="xs" c="dimmed">
          {state.pasteAccess === 'granted'
            ? 'Доступ разрешён. Для копирования без вставки используйте ⇧ Enter в истории.'
            : state.pasteAccess === 'unavailable'
              ? 'Автоматическая вставка недоступна: не удалось проверить разрешение. Запись можно скопировать и вставить сочетанием ⌘ V.'
              : 'macOS требует разрешение в «Конфиденциальность и безопасность → Универсальный доступ». Разрешите приложение, указанное в системном запросе. Без разрешения запись только копируется; используйте ⌘ V.'}
        </Text>
      )}
      {state?.preferences.pasteOnSelect && state.pasteAccess === 'required' && (
        <Button variant="default" onClick={() => void save('requestPasteAccess', {})}>
          Разрешить автоматическую вставку…
        </Button>
      )}
      <Select
        label="Хранить незакреплённые записи"
        value={String(state?.preferences.retentionDays || 7)}
        data={[
          { value: '1', label: '1 день' },
          { value: '7', label: '7 дней' },
          { value: '30', label: '30 дней' },
        ]}
        disabled={!writable || saving}
        onChange={(value) => {
          if (value) void save('preferences', { retentionDays: Number(value) });
        }}
      />
      <TextInput
        label="Сочетание для истории буфера"
        readOnly
        disabled={!writable || saving}
        value={
          recording
            ? ''
            : state?.preferences.accelerator
              ? shortcutLabel(state.preferences.accelerator)
              : 'Не назначено'
        }
        placeholder="Нажмите сочетание клавиш…"
        onFocus={() => setRecording(true)}
        onBlur={() => setRecording(false)}
        onKeyDown={(event) => {
          if (!recording) return;
          if (event.key === 'Tab') {
            setRecording(false);
            return;
          }
          event.preventDefault();
          if (event.key === 'Escape') {
            setRecording(false);
            return;
          }
          const key =
            event.code === 'Space'
              ? 'Space'
              : /^Key[A-Z]$/.test(event.code)
                ? event.code.slice(3)
                : /^Digit[0-9]$/.test(event.code)
                  ? event.code.slice(5)
                  : /^F(?:[1-9]|1[0-2])$/.test(event.code)
                    ? event.code
                    : '';
          if (!key || !(event.metaKey || event.ctrlKey || event.altKey)) return;
          const modifiers = [
            event.metaKey && 'CommandOrControl',
            event.ctrlKey && 'Control',
            event.altKey && 'Alt',
            event.shiftKey && 'Shift',
          ].filter(Boolean);
          void save('shortcut', { accelerator: [...modifiers, key].join('+') });
          event.currentTarget.blur();
        }}
      />
      {(error || state?.error) && <Alert color="red">{error || state?.error}</Alert>}
      <Group>
        <Button
          variant="default"
          onClick={() =>
            void api('clipboardHistory.show').catch((reason) => setError(errorMessage(reason)))
          }
        >
          Открыть историю буфера
        </Button>
        <Button
          variant="subtle"
          disabled={!writable || !state?.preferences.accelerator || saving}
          onClick={() => void save('shortcut', { accelerator: '' })}
        >
          Отключить сочетание
        </Button>
      </Group>
      <ClipboardSyncSettings
        state={state?.sync}
        paused={state?.preferences.paused ?? false}
        save={save}
        saving={saving}
      />
      <Text size="xs" c="dimmed">
        История хранится локально в зашифрованном виде: до 200 записей и 128 МБ. Закреплённые записи
        сохраняются дольше выбранного срока. Данные, помеченные программой как конфиденциальные или
        временные, пропускаются.
      </Text>
    </Stack>
  );
}
