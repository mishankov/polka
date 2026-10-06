import { Button, Group, Progress, Stack, Text, Title } from './NativeControls';
import { useUpdates } from './useUpdates';
import UpdateReleaseNotes from './UpdateReleaseNotes';
export default function Updates() {
  const { state, pending, action } = useUpdates();
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
        {state && state.status !== 'unavailable' && (
          <Text size="sm" c="dimmed">
            Обновления проверяются и загружаются автоматически. Установка — после подтверждения.
          </Text>
        )}
        {state?.status === 'current' && <Text size="sm">Установлена последняя версия.</Text>}
        {state?.version && (
          <Text size="sm">
            {state.status === 'ready' ? 'Готова к установке' : 'Доступна версия'} {state.version}
          </Text>
        )}
        {state?.notification === 'skipped' && (
          <Text size="sm" c="dimmed">
            Вы пропустили эту версию. Её можно установить здесь.
          </Text>
        )}
        {state?.notification === 'deferred' && (
          <Text size="sm" c="dimmed">
            Напомним {new Date(state.remindAfter!).toLocaleString('ru-RU')}. Можно обновиться
            сейчас.
          </Text>
        )}
        {state?.version && <UpdateReleaseNotes key={state.version} notes={state.releaseNotes} />}
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
              disabled={!!pending}
              onClick={() => action('check')}
            >
              Проверить обновления
            </Button>
          )}
          {state && ['ready', 'installing'].includes(state.status) && (
            <Button
              disabled={!!pending}
              loading={state.status === 'installing' || pending === 'install'}
              onClick={() => action('install')}
            >
              Установить и перезапустить
            </Button>
          )}
        </Group>
      </Stack>
    </section>
  );
}
