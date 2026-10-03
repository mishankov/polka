import { useEffect, useState } from 'react';
import { Alert, Button, Stack, Switch } from '@mantine/core';
import { api, report } from './api';

export default function WindowPreferences({ appId }: { appId: string }) {
  const [preferences, setPreferences] = useState<{ alwaysOnTop: boolean }>();
  const [busy, setBusy] = useState(false);
  const [failed, setFailed] = useState(false);
  const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    let active = true;
    let changed = false;
    setPreferences(undefined);
    setFailed(false);
    const unsubscribe = window.platform.onEvent((event) => {
      if (event.type === 'windows.preferencesChanged' && event.appId === appId) {
        changed = true;
        setFailed(false);
        setPreferences(event.preferences);
      }
    });
    api('windows.getPreferences', { appId })
      .then((value) => {
        if (active && !changed) setPreferences(value);
      })
      .catch(() => {
        if (active && !changed) setFailed(true);
      });
    return () => {
      active = false;
      unsubscribe();
    };
  }, [appId, attempt]);
  return (
    <Stack gap="sm">
      <Switch
        label="Поверх других окон"
        aria-label="Поверх других окон"
        description="Отдельные окна этого приложения будут видны на всех рабочих столах, в том числе поверх полноэкранных приложений. Настройка сохраняется автоматически."
        checked={preferences?.alwaysOnTop ?? false}
        disabled={!preferences || busy}
        onChange={async (event) => {
          const alwaysOnTop = event.currentTarget.checked;
          setBusy(true);
          try {
            setPreferences(await api('windows.setPreferences', { appId, alwaysOnTop }));
          } catch (error) {
            report(error);
          } finally {
            setBusy(false);
          }
        }}
      />
      {failed && (
        <Alert color="red" title="Не удалось загрузить настройки окна">
          <Button variant="subtle" onClick={() => setAttempt((value) => value + 1)}>
            Повторить
          </Button>
        </Alert>
      )}
    </Stack>
  );
}
