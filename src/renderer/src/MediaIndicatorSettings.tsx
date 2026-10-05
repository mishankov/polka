import { useEffect, useState } from 'react';
import { Alert, Stack, Switch, Text } from './NativeControls';
import { api, errorMessage } from './api';
import {
  mediaActivityLabel,
  type MediaDevice,
  type MediaIndicatorState,
} from '../../shared/media-indicator';

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
  async function save(device: MediaDevice, enabled: boolean) {
    setSaving(true);
    setError('');
    try {
      setState(await api<MediaIndicatorState>('mediaIndicator.setTracking', { device, enabled }));
    } catch (reason) {
      setError(errorMessage(reason));
    } finally {
      setSaving(false);
    }
  }
  return (
    <Stack gap="xs" mt="md">
      <Text size="sm" fw={500}>
        Индикаторы активности
      </Text>
      <Text size="sm" c="dimmed">
        Индикатор у выреза виден всё время, пока используется выбранное устройство. На экране без
        выреза — в центре верхнего края.
      </Text>
      <div className="native-setting-group" role="group" aria-label="Индикаторы активности">
        <Switch
          label="Показывать активность камеры"
          checked={state?.cameraEnabled ?? false}
          disabled={!state || saving}
          onChange={(event) => void save('camera', event.currentTarget.checked)}
        />
        <Switch
          label="Показывать активность микрофона"
          checked={state?.microphoneEnabled ?? false}
          disabled={!state || saving}
          onChange={(event) => void save('microphone', event.currentTarget.checked)}
        />
      </div>
      {state?.enabled && (
        <Text size="sm" c="dimmed">
          {mediaActivityLabel(state)}
        </Text>
      )}
      <Text size="xs" c="dimmed">
        Индикатор может быть виден при демонстрации экрана. Чтобы скрыть его наверняка, выключите
        оба индикатора.
      </Text>
      {error && <Alert color="red">{error}</Alert>}
    </Stack>
  );
}
