import { Button, Group, Stack, Text } from './NativeControls';
import { clipboardPauseLabel, type ClipboardPreferences } from '../../shared/clipboard';

export default function ClipboardPrivacy({
  preferences,
  disabled,
  save,
  settings = false,
}: {
  preferences?: ClipboardPreferences;
  disabled: boolean;
  save: (method: string, params: Record<string, unknown>) => unknown;
  settings?: boolean;
}) {
  if (!preferences) return null;
  const apps = preferences.excludedApps ?? [];
  return (
    <Stack gap="xs" className="clipboard-privacy">
      <Text size="sm">{clipboardPauseLabel(preferences)}</Text>
      <Group>
        {preferences.paused && (
          <Button
            size="compact-sm"
            variant="default"
            disabled={disabled}
            onClick={() => save('preferences', { paused: false })}
          >
            Возобновить запись
          </Button>
        )}
        <Button
          size="compact-sm"
          variant="default"
          disabled={disabled}
          onClick={() => save('pause15', {})}
        >
          Пауза на 15 минут
        </Button>
        {(!preferences.paused || preferences.pauseUntil) && (
          <Button
            size="compact-sm"
            variant="subtle"
            disabled={disabled}
            onClick={() => save('preferences', { paused: true })}
          >
            Пауза до возобновления
          </Button>
        )}
      </Group>
      {settings ? (
        <>
          <Text size="sm">
            Не сохранять копии из приложений{apps.length ? ` (${apps.length})` : ''}
          </Text>
          {apps.map((app) => (
            <Group key={app.bundleId}>
              <Text size="sm" title={app.bundleId}>
                {app.name}
              </Text>
              <Button
                size="compact-sm"
                variant="subtle"
                disabled={disabled}
                onClick={() => save('allowApp', { bundleId: app.bundleId })}
                aria-label={`Разрешить копии из ${app.name}`}
              >
                Разрешить
              </Button>
            </Group>
          ))}
          <Button variant="default" disabled={disabled} onClick={() => save('excludeApp', {})}>
            Исключить приложение…
          </Button>
          <Text size="xs" c="dimmed">
            Источник определяется по активному приложению при изменении буфера. Если оно сменилось
            или источник неизвестен, при включённых исключениях запись пропускается. macOS не
            сообщает автора копии: фоновая программа может определиться неверно. Для гарантированной
            паузы используйте кнопки выше.
          </Text>
        </>
      ) : (
        apps.length > 0 && (
          <Button
            size="compact-sm"
            variant="subtle"
            onClick={() => window.platform.call('shelf.settings', { section: 'clipboard' })}
          >
            Исключено приложений: {apps.length} · Изменить…
          </Button>
        )
      )}
    </Stack>
  );
}
