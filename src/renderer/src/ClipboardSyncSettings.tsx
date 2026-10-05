import { useState } from 'react';
import { Alert, Button, Group, Stack, Switch, Text, Textarea } from './NativeControls';
import type { ClipboardSyncState } from '../../shared/clipboard';
import { api, errorMessage } from './api';

export default function ClipboardSyncSettings({
  state,
  paused,
  save,
  saving,
}: {
  state?: ClipboardSyncState;
  paused: boolean;
  save(method: string, params: Record<string, unknown>): Promise<boolean>;
  saving: boolean;
}) {
  const [code, setCode] = useState('');
  const [copyError, setCopyError] = useState('');
  const [copied, setCopied] = useState(false);
  return (
    <Stack gap="xs">
      <Text size="sm" fw={500}>
        История на других Mac
      </Text>
      <Switch
        label="Синхронизировать историю по локальной сети"
        checked={state?.enabled ?? false}
        disabled={!state || saving}
        onChange={(event) => void save('syncEnabled', { enabled: event.currentTarget.checked })}
      />
      <Text size="xs" c="dimmed">
        Свяжите свои Mac один раз. Текст, изображения, закрепление и удаление записей
        синхронизируются в зашифрованном виде, когда приложения запущены в одной сети. Текущий буфер
        обмена не меняется.
      </Text>
      {state?.error && <Alert color="red">{state.error}</Alert>}
      {state?.enabled && (
        <>
          <Text size="xs" c="dimmed">
            Этот Mac: {state.deviceName}. При первом соединении и после перерыва объединяется вся
            сохранённая история. Срок хранения остаётся отдельным на каждом Mac.
          </Text>
          {paused && (
            <Alert color="yellow">
              Сохранение истории на паузе. Синхронизация продолжится, когда вы включите сохранение.
            </Alert>
          )}
          {state.peers.map((peer) => (
            <Stack gap={4} key={peer.id}>
              <Group style={{ justifyContent: 'space-between' }} wrap="nowrap">
                <div>
                  <Text size="sm" style={{ overflowWrap: 'anywhere' }}>
                    {peer.name}
                  </Text>
                  <Text size="xs" c="dimmed">
                    {paused
                      ? 'На паузе'
                      : peer.status === 'syncing'
                        ? 'Синхронизация…'
                        : peer.status === 'connected'
                          ? 'История синхронизирована'
                          : 'Нет соединения'}
                    {peer.lastSync
                      ? ` · ${new Date(peer.lastSync).toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit' })}`
                      : ''}
                  </Text>
                </div>
                <Button
                  size="compact-xs"
                  variant="subtle"
                  disabled={saving}
                  onClick={() => void save('syncForget', { id: peer.id })}
                >
                  Отвязать
                </Button>
              </Group>
              {peer.error && (
                <Text size="xs" c="red">
                  {peer.error}
                </Text>
              )}
            </Stack>
          ))}
          {!!state.peers.length && (
            <Button
              variant="default"
              size="xs"
              disabled={saving || paused}
              onClick={() => void save('syncNow', {})}
            >
              Синхронизировать сейчас
            </Button>
          )}
          {state.invitation ? (
            <>
              <Textarea
                label="Код для другого Mac"
                readOnly
                rows={3}
                value={state.invitation.code}
              />
              <Text size="xs" c="dimmed">
                На другом Mac включите синхронизацию и вставьте этот код. Он действует 5 минут и
                связывает одно устройство. Передавайте его только своему Mac.
              </Text>
              <Group>
                <Button
                  variant="default"
                  size="xs"
                  onClick={() => {
                    setCopyError('');
                    void api('clipboardHistory.copyPairingCode')
                      .then(() => setCopied(true))
                      .catch((reason) => setCopyError(errorMessage(reason)));
                  }}
                >
                  {copied ? 'Код скопирован' : 'Скопировать код'}
                </Button>
                <Button
                  variant="subtle"
                  size="xs"
                  disabled={saving}
                  onClick={() => void save('syncCancelInvite', {})}
                >
                  Отменить код
                </Button>
              </Group>
              {copyError && (
                <Text size="xs" c="red">
                  {copyError}
                </Text>
              )}
            </>
          ) : (
            <Button
              variant="default"
              size="xs"
              disabled={saving}
              onClick={() => {
                setCopied(false);
                void save('syncInvite', {});
              }}
            >
              Получить код для другого Mac
            </Button>
          )}
          <Textarea
            label="Код с другого Mac"
            placeholder="Вставьте код из настроек Полки на другом Mac"
            rows={3}
            value={code}
            disabled={saving}
            onChange={(event) => setCode(event.currentTarget.value)}
          />
          <Button
            size="xs"
            disabled={saving || !code.trim()}
            loading={saving && !!code.trim()}
            onClick={() => {
              void save('syncPair', { code: code.trim() }).then((ok) => {
                if (ok) setCode('');
              });
            }}
          >
            Связать Mac и объединить историю
          </Button>
          <Text size="xs" c="dimmed">
            {state.nearby.length
              ? `Другие Mac в сети: ${state.nearby.map((peer) => peer.name).join(', ')}`
              : 'Другие Mac пока не найдены. Включите синхронизацию на втором Mac и проверьте, что оба подключены к одной сети.'}
          </Text>
        </>
      )}
    </Stack>
  );
}
