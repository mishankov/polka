import { useEffect, useState } from 'react';
import { Button, Group, Progress, Stack, Text, Title } from './NativeControls';
import type { UpdateState } from '../../main/updates';
import { api, report } from './api';
export default function Updates() {
  const [state, setState] = useState<UpdateState>();
  useEffect(() => {
    api('updates.status').then(setState).catch(report);
    return window.platform.onEvent((e) => {
      if (e.type === 'updates.state') setState(e.state);
    });
  }, []);
  const action = (name: string) => api(`updates.${name}`).then(setState).catch(report);
  return (
    <section className="settings-section" aria-labelledby="updates-heading">
      <div className="settings-section-intro">
        <Title order={2} id="updates-heading">
          Обновления
        </Title>
        <Text size="sm" c="dimmed">
          {state ? `Полка ${state.currentVersion}` : 'Загрузка версии…'}
        </Text>
      </div>
      <Stack className="settings-section-content" gap="sm">
        {state?.message && (
          <Text size="sm" c="dimmed">
            {state.message}
          </Text>
        )}
        {state?.status === 'current' && <Text size="sm">Установлена последняя версия.</Text>}
        {state?.version && (
          <Text size="sm">
            {state.status === 'ready' ? 'Готова к установке' : 'Доступна версия'} {state.version}
          </Text>
        )}
        {state?.status === 'downloading' && (
          <>
            <Progress aria-label="Загрузка обновления" value={state.progress || 0} />
            <Text size="xs" c="dimmed">
              Загружено {Math.round(state.progress || 0)}%
            </Text>
          </>
        )}
        {state?.status === 'ready' && (
          <Text size="sm" c="dimmed">
            Приложение перезапустится для установки обновления.
          </Text>
        )}
        <Group>
          {state && ['idle', 'current', 'error', 'checking'].includes(state.status) && (
            <Button
              variant="default"
              loading={state.status === 'checking'}
              onClick={() => action('check')}
            >
              Проверить обновления
            </Button>
          )}
          {state?.status === 'available' && (
            <Button onClick={() => action('download')}>Загрузить обновление</Button>
          )}
          {state && ['ready', 'installing'].includes(state.status) && (
            <Button loading={state.status === 'installing'} onClick={() => action('install')}>
              Установить и перезапустить
            </Button>
          )}
        </Group>
      </Stack>
    </section>
  );
}
