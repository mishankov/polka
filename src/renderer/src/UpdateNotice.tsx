import { Button, Group, Text } from './NativeControls';
import { api, report } from './api';
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
  const status = installing
    ? 'Устанавливаем…'
    : checking
      ? 'Проверяем…'
      : downloading
        ? `Загружаем… ${Math.round(state.progress || 0)}%`
        : state.status === 'ready'
          ? 'Готова к установке'
          : 'Ошибка обновления';
  return (
    <section className="update-notice" aria-label={`Доступно обновление Полки ${state.version}`}>
      <div className="update-notice-status" role={state.status === 'error' ? 'alert' : 'status'}>
        <Text fw={600}>Доступна Полка {state.version}</Text>
        <Text size="sm" c="dimmed" title={state.message || status}>
          {status}
        </Text>
      </div>
      <Group gap="xs" wrap="nowrap" className="update-notice-actions">
        <Button
          disabled={!!pending || downloading || installing || checking}
          loading={pending === 'install' || pending === 'check' || installing || checking}
          onClick={() => void action(state.status === 'error' ? 'check' : 'install')}
          title="После установки Полка перезапустится"
        >
          {state.status === 'error' ? 'Повторить проверку' : 'Обновить и перезапустить'}
        </Button>
        <Button
          variant="default"
          aria-label="Напомнить завтра"
          title="Напомнить завтра"
          disabled={!!pending || installing}
          loading={pending === 'remind'}
          onClick={() => void action('remind')}
        >
          Завтра
        </Button>
        <Button
          variant="subtle"
          aria-label="Пропустить эту версию"
          title="Пропустить эту версию"
          disabled={!!pending || installing}
          loading={pending === 'skip'}
          onClick={() => void action('skip')}
        >
          Пропустить
        </Button>
        <Button
          variant="subtle"
          onClick={() => void api('shelf.settings', { section: 'about' }).catch(report)}
        >
          Что нового
        </Button>
      </Group>
    </section>
  );
}
