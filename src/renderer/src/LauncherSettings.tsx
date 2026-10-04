import { useEffect, useState } from 'react';
import { Alert, Button, Group, Stack, Switch, Text, TextInput } from '@mantine/core';
import type { ClipboardState } from '../../shared/clipboard';
import { api, errorMessage } from './api';
import { shortcutLabel, type LauncherPreferences } from '../../shared/launcher';

export default function LauncherSettings() {
  const [hoverEnabled, setHoverEnabled] = useState<boolean>();
  const [preferences, setPreferences] = useState<LauncherPreferences>();
  const [recording, setRecording] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');
  useEffect(() => {
    const refreshHover = () =>
      void api<ClipboardState>('clipboardHistory.state')
        .then((state) => setHoverEnabled(state.preferences.hoverEnabled))
        .catch((error) => setError(errorMessage(error)));
    refreshHover();
    api<LauncherPreferences>('launcher.getPreferences')
      .then(setPreferences)
      .catch((error) => setError(errorMessage(error)));
    return window.platform.onEvent((event) => {
      if (event.type === 'clipboardHistory.changed') refreshHover();
      if (event.type === 'launcher.preferencesChanged') setPreferences(event.preferences);
    });
  }, []);
  async function save(accelerator: string) {
    setRecording(false);
    setSaving(true);
    setError('');
    try {
      setPreferences(await api('launcher.setShortcut', { accelerator }));
    } catch (error) {
      setError(errorMessage(error));
    } finally {
      setSaving(false);
    }
  }
  return (
    <Stack gap="sm">
      <Text size="sm" fw={500}>
        Полка и быстрый запуск
      </Text>
      <Text size="sm" c="dimmed">
        Наведите указатель на вырез камеры или нажмите сочетание — откроется одна полка с поиском
        приложений. На других мониторах наведите указатель к середине верхнего края. Поиск сразу
        получает фокус. Everything App должен быть запущен.
      </Text>
      <Switch
        label="Открывать полку при наведении к вырезу камеры"
        checked={hoverEnabled || false}
        disabled={hoverEnabled === undefined || saving}
        onChange={(event) => {
          const value = event.currentTarget.checked;
          setSaving(true);
          void api<ClipboardState>('clipboardHistory.preferences', { hoverEnabled: value })
            .then((state) => setHoverEnabled(state.preferences.hoverEnabled))
            .catch((error) => setError(errorMessage(error)))
            .finally(() => setSaving(false));
        }}
      />
      <TextInput
        label="Сочетание для запуска"
        readOnly
        value={
          recording
            ? ''
            : preferences?.accelerator
              ? shortcutLabel(preferences.accelerator)
              : 'Не назначено'
        }
        placeholder="Нажмите сочетание клавиш…"
        onBlur={() => setRecording(false)}
        onFocus={() => setRecording(true)}
        disabled={saving || !preferences}
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
          void save([...modifiers, key].join('+'));
          event.currentTarget.blur();
        }}
      />
      {(error || preferences?.error) && <Alert color="red">{error || preferences?.error}</Alert>}
      <Group gap="sm">
        <Button
          variant="default"
          onClick={() => void api('launcher.show').catch((error) => setError(errorMessage(error)))}
        >
          Открыть быстрый запуск
        </Button>
        <Button
          variant="subtle"
          disabled={!preferences?.accelerator || saving}
          onClick={() => void save('')}
        >
          Отключить сочетание
        </Button>
      </Group>
    </Stack>
  );
}
