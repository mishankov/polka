import type { ShortcutsState } from '../../shared/macos-shortcuts';
import { useState } from 'react';
import { Alert, Button, Group, Loader, Stack, Checkbox, Text, TextInput } from './NativeControls';
import { api, errorMessage } from './api';
import { useMacShortcuts } from './useMacShortcuts';

export default function MacShortcutsSettings() {
  const { state, loading, refresh, apply } = useMacShortcuts(true);
  const [query, setQuery] = useState('');
  const [saving, setSaving] = useState(false);
  const [pendingChoice, setPendingChoice] = useState<{ id: string; enabled: boolean }>();
  const [error, setError] = useState('');
  const shown = state.shortcuts.filter((s) =>
    s.name.toLocaleLowerCase().includes(query.trim().toLocaleLowerCase()),
  );
  return (
    <Stack gap="lg">
      <Text>Выберите команды, которые хотите находить и запускать с полки.</Text>
      <Text c="dimmed">
        Полка запускает команды без входных файлов. Если команде нужны данные или разрешение, macOS
        запросит их при запуске. Ответьте в системном окне. Отмена и ошибки показываются по ответу
        macOS.
      </Text>
      <Group>
        <Button onClick={() => void refresh()}>Обновить список</Button>
        <Button
          variant="subtle"
          onClick={() => void api('macShortcuts.openApp').catch((e) => setError(errorMessage(e)))}
        >
          Открыть «Команды»
        </Button>
      </Group>
      {(error || state.error) && <Alert>{error || state.error}</Alert>}
      {loading ? (
        <Loader aria-label="Загрузка команд" />
      ) : (
        <>
          <TextInput
            aria-label="Найти команду в настройках"
            placeholder="Найти команду…"
            value={query}
            onChange={(e) => setQuery(e.currentTarget.value)}
          />
          <Text c="dimmed">На полке: {state.shortcuts.filter((s) => s.selected).length}</Text>
          {!state.shortcuts.length && (
            <Text c="dimmed">
              Команд пока нет. Создайте команду в приложении «Команды», затем обновите список.
            </Text>
          )}
          {!!state.shortcuts.length && !shown.length && <Text c="dimmed">Ничего не найдено.</Text>}
          {shown.map((s) => (
            <Checkbox
              key={s.id}
              label={s.name}
              description={
                s.availability === 'missing'
                  ? 'Нет на этом Mac. Снимите выбор или восстановите команду.'
                  : s.availability === 'unknown'
                    ? 'Доступность не проверена. Обновите список.'
                    : 'Команда macOS · Запуск по Enter или клику'
              }
              checked={pendingChoice?.id === s.id ? pendingChoice.enabled : s.selected}
              disabled={saving || (!s.selected && s.availability !== 'available')}
              onChange={async (e) => {
                const enabled = e.currentTarget.checked;
                setPendingChoice({ id: s.id, enabled });
                setSaving(true);
                setError('');
                try {
                  apply(await api<ShortcutsState>('macShortcuts.select', { id: s.id, enabled }));
                } catch (reason) {
                  setError(errorMessage(reason));
                } finally {
                  setPendingChoice(undefined);
                  setSaving(false);
                }
              }}
            />
          ))}
        </>
      )}
    </Stack>
  );
}
