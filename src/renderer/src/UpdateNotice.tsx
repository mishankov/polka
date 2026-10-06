import { Button, Group, Progress, Text } from './NativeControls';
import UpdateReleaseNotes from './UpdateReleaseNotes';
import { useUpdates } from './useUpdates';

export default function UpdateNotice() {
  const { state, pending, action } = useUpdates();
  if (
    !state?.version ||
    state.notification !== 'visible' ||
    !['checking', 'downloading', 'ready', 'installing', 'error'].includes(state.status)
  )
    return null;
  const installing = state.status === 'installing';
  const downloading = state.status === 'downloading';
  const checking = state.status === 'checking';
  return (
    <section className="update-notice" aria-label={`Доступно обновление Полки ${state.version}`}>
      <Text fw={600} role="status">
        Доступна Полка {state.version}
      </Text>
      <Text size="sm" c="dimmed">
        {installing
          ? 'Устанавливаем обновление…'
          : checking
            ? 'Проверяем обновление…'
            : downloading
              ? `Загружаем обновление… ${Math.round(state.progress || 0)}%`
              : state.status === 'ready'
                ? 'Обновление готово. Полка перезапустится после установки.'
                : 'Не удалось обновить Полку. Повторите проверку.'}
      </Text>
      {state.message && (
        <Text role="alert" size="sm">
          {state.message}
        </Text>
      )}
      {downloading && <Progress aria-label="Загрузка обновления" value={state.progress || 0} />}
      <UpdateReleaseNotes key={state.version} notes={state.releaseNotes} />
      <Group gap="xs">
        <Button
          disabled={!!pending || downloading || installing || checking}
          loading={pending === 'install' || pending === 'check' || installing || checking}
          onClick={() => void action(state.status === 'error' ? 'check' : 'install')}
        >
          {state.status === 'error'
            ? 'Повторить проверку'
            : checking
              ? 'Проверяем обновление…'
              : downloading
                ? 'Обновление загружается…'
                : 'Обновить и перезапустить'}
        </Button>
        <Button
          variant="default"
          disabled={!!pending || installing}
          loading={pending === 'remind'}
          onClick={() => void action('remind')}
        >
          Напомнить завтра
        </Button>
        <Button
          variant="subtle"
          disabled={!!pending || installing}
          loading={pending === 'skip'}
          onClick={() => void action('skip')}
        >
          Пропустить эту версию
        </Button>
      </Group>
    </section>
  );
}
