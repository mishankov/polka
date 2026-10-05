import { useEffect, useState } from 'react';
import { Alert, Stack, Switch, Text } from './NativeControls';
import { api, errorMessage } from './api';
import { mediaActivityLabel, type MediaIndicatorState } from '../../shared/media-indicator';

export default function MediaIndicatorSettings() {
  const [state, setState] = useState<MediaIndicatorState>();
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');
  useEffect(() => {
    let alive = true;
    let received = false;
    const unsubscribe = window.platform.onEvent((event) => {
      if (event.type === 'mediaIndicator.changed') {
        received = true;
        setState(event.state);
      }
    });
    void api<MediaIndicatorState>('mediaIndicator.getState')
      .then((value) => {
        if (alive && !received) setState(value);
      })
      .catch((reason) => {
        if (alive) setError(errorMessage(reason));
      });
    return () => {
      alive = false;
      unsubscribe();
    };
  }, []);
  return (
    <Stack gap="xs" mt="md">
      <Switch
        label="Показывать активность камеры и микрофона"
        aria-label="Показывать активность камеры и микрофона"
        description="Индикатор у выреза виден всё время, пока используется камера или микрофон. На экране без выреза — в центре верхнего края."
        checked={state?.enabled ?? false}
        disabled={!state || saving}
        onChange={async (event) => {
          const value = event.currentTarget.checked;
          setSaving(true);
          setError('');
          try {
            setState(
              await api<MediaIndicatorState>('mediaIndicator.setEnabled', { enabled: value }),
            );
          } catch (reason) {
            setError(errorMessage(reason));
          } finally {
            setSaving(false);
          }
        }}
      />
      {state?.enabled && (
        <Text size="sm" c="dimmed">
          {mediaActivityLabel(state)}
        </Text>
      )}
      <Text size="xs" c="dimmed">
        Индикатор может быть виден при демонстрации экрана. Чтобы скрыть его наверняка, выключите
        эту настройку.
      </Text>
      {error && <Alert color="red">{error}</Alert>}
    </Stack>
  );
}
