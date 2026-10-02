import { useEffect, useState } from 'react';
import { Button, Group, PasswordInput, Stack, Text, TextInput, Title } from '@mantine/core';
import { api, perform, report } from './api';
type Connection = { id: string; name: string; kind: string; origin: string; configured: boolean };
function ConnectionForm({
  appId,
  connection,
  refresh,
}: {
  appId: string;
  connection: Connection;
  refresh: () => void;
}) {
  const [origin, setOrigin] = useState(connection.origin),
    [token, setToken] = useState(''),
    [busy, setBusy] = useState(false);
  return (
    <Stack gap="sm" style={{ borderTop: '1px solid var(--line)', paddingTop: 16 }}>
      <Text fw={500}>{connection.name}</Text>
      <TextInput
        label="Адрес сервиса"
        placeholder="https://api.example.com"
        value={origin}
        onChange={(e) => setOrigin(e.target.value)}
      />
      <PasswordInput
        label="Ключ доступа"
        autoComplete="new-password"
        value={token}
        onChange={(e) => setToken(e.target.value)}
        placeholder={
          connection.configured
            ? 'Ключ сохранён; оставьте пустым, чтобы сохранить его'
            : 'Bearer token сервиса'
        }
        description="Ключ хранится в защищённом хранилище и не передаётся модели или в файл приложения."
      />
      <Group>
        <Button
          size="sm"
          loading={busy}
          onClick={async () => {
            setBusy(true);
            const result = await perform(
              () => api('connections.save', { appId, connectionId: connection.id, origin, token }),
              'Подключение сохранено',
            );
            setBusy(false);
            if (result) {
              setToken('');
              refresh();
            }
          }}
        >
          Сохранить подключение
        </Button>
        {connection.configured && (
          <Button
            size="sm"
            color="red"
            variant="subtle"
            onClick={() =>
              perform(() => api('connections.remove', { appId, connectionId: connection.id })).then(
                refresh,
              )
            }
          >
            Отключить
          </Button>
        )}
      </Group>
    </Stack>
  );
}
export default function Connections({ appId }: { appId: string }) {
  const [connections, setConnections] = useState<Connection[]>([]);
  const refresh = () => api('connections.list', { appId }).then(setConnections).catch(report);
  useEffect(() => {
    refresh();
  }, [appId]);
  if (!connections.length) return null;
  return (
    <Stack mt="lg">
      <Title order={3}>Подключения к сервисам</Title>
      <Text size="sm" c="dimmed">
        Настройте адрес и ключ каждого сервиса. Доступ к этому адресу отдельно разрешается выше;
        настройка ключа не выдаёт разрешение.
      </Text>
      {connections.map((c) => (
        <ConnectionForm
          key={c.id + ':' + c.origin + ':' + c.configured}
          appId={appId}
          connection={c}
          refresh={refresh}
        />
      ))}
    </Stack>
  );
}
