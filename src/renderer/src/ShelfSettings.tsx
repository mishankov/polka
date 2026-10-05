import { useEffect, useRef, useState } from 'react';
import { ActionIcon, Alert, Button, Group, Stack, Switch, Tabs, Text, Title } from '@mantine/core';
import { IconArrowLeft, IconX } from '@tabler/icons-react';
import LauncherSettings from './LauncherSettings';
import ClipboardSettings from './ClipboardSettings';
import Updates from './Updates';
import { api, errorMessage, report } from './api';

export default function ShelfSettings({ initialTab }: { initialTab: 'general' | 'about' }) {
  const [tab, setTab] = useState<string | null>(initialTab);
  const [login, setLogin] = useState<boolean>();
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');
  const back = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    back.current?.focus();
    void api<{ login: boolean }>('system.status')
      .then((state) => setLogin(state.login))
      .catch((reason) => setError(errorMessage(reason)));
  }, []);
  async function changeLogin(enabled: boolean) {
    setSaving(true);
    setError('');
    try {
      setLogin(await api<boolean>('system.login', { enabled }));
    } catch (reason) {
      setError(errorMessage(reason));
    } finally {
      setSaving(false);
    }
  }
  return (
    <section className="shelf-settings" aria-label="Настройки полки">
      <header className="clipboard-header">
        <Group gap="sm">
          <ActionIcon
            ref={back}
            aria-label="Назад к приложениям"
            variant="subtle"
            onClick={() => void api('launcher.show').catch(report)}
          >
            <IconArrowLeft size={20} />
          </ActionIcon>
          <Title order={1} size="md">
            Настройки
          </Title>
        </Group>
        <ActionIcon
          className="clipboard-header-actions"
          aria-label="Закрыть настройки"
          variant="subtle"
          onClick={() => void api('launcher.hide').catch(report)}
        >
          <IconX size={18} />
        </ActionIcon>
      </header>
      <Tabs value={tab} onChange={setTab} keepMounted={false} className="shelf-settings-tabs">
        <Tabs.List aria-label="Разделы настроек">
          <Tabs.Tab value="general">Основные</Tabs.Tab>
          <Tabs.Tab value="shelf">Полка и сочетания</Tabs.Tab>
          <Tabs.Tab value="clipboard">Буфер обмена</Tabs.Tab>
          <Tabs.Tab value="about">О приложении</Tabs.Tab>
        </Tabs.List>
        <div className="shelf-settings-scroll">
          {error && (
            <Alert color="red" mb="md">
              {error}
            </Alert>
          )}
          <Tabs.Panel value="general">
            <Stack gap="lg">
              <Title order={2} size="lg">
                Всегда под рукой
              </Title>
              <Text c="dimmed" size="sm">
                Откройте полку через значок Полки в строке меню. Приложение работает без значка в
                Dock. Закрытие полки оставляет быстрый запуск и историю буфера доступными.
              </Text>
              <Switch
                label="Запускать при входе в macOS"
                description="Запуск в фоне, без открытия полки."
                checked={login || false}
                disabled={login === undefined || saving}
                onChange={(event) => void changeLogin(event.currentTarget.checked)}
              />
              <Text c="dimmed" size="sm">
                Полку можно открыть наведением к вырезу камеры или сочетанием клавиш. Escape
                возвращает из настроек к поиску. Щелчок вне полки скрывает её.
              </Text>
              <Group>
                <Button variant="default" onClick={() => setTab('shelf')}>
                  Настроить открытие полки
                </Button>
              </Group>
            </Stack>
          </Tabs.Panel>
          <Tabs.Panel value="shelf">
            <LauncherSettings />
          </Tabs.Panel>
          <Tabs.Panel value="clipboard">
            <ClipboardSettings />
          </Tabs.Panel>
          <Tabs.Panel value="about">
            <Stack gap="lg">
              <div>
                <Title order={2} size="lg">
                  Полка
                </Title>
                <Text c="dimmed" size="sm" mt="xs">
                  Приложения и история буфера обмена — на одной полке.
                </Text>
              </div>
              <Updates />
              <Text size="sm" c="dimmed">
                История хранится локально в зашифрованном виде. AI-помощник и пользовательские
                приложения временно приостановлены; их данные сохранены, фоновые задания не
                запускаются.
              </Text>
            </Stack>
          </Tabs.Panel>
        </div>
      </Tabs>
    </section>
  );
}
