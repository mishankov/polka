import { useEffect, useState } from 'react';
import {
  Alert,
  Badge,
  Button,
  Group,
  PasswordInput,
  SegmentedControl,
  Select,
  Stack,
  Switch,
  Text,
  TextInput,
  Title,
  useMantineColorScheme,
} from '@mantine/core';
import Updates from './Updates';
import { api, AnyRecord, perform, report } from './api';
export default function Settings() {
  const { colorScheme, setColorScheme } = useMantineColorScheme();
  const [config, setConfig] = useState<AnyRecord>({
    type: 'openai',
    endpoint: 'https://api.openai.com/v1',
    model: '',
  });
  const [key, setKey] = useState('');
  const [models, setModels] = useState<any[]>([]);
  const [testing, setTesting] = useState(false);
  const [test, setTest] = useState<any>();
  const [settings, setSettings] = useState<any>({});
  useEffect(() => {
    api('provider.get')
      .then((c) => {
        if (c) setConfig(c);
      })
      .catch(report);
    api('settings.get')
      .then(setSettings)
      .catch(() => {});
  }, []);
  async function save() {
    return perform(
      () => api('provider.save', { ...config, ...(key ? { apiKey: key } : {}) }),
      'Подключение сохранено',
    );
  }
  async function check() {
    setTesting(true);
    const saved = await save();
    if (saved === undefined) {
      setTesting(false);
      return;
    }
    const m = await perform(() => api('provider.models'));
    if (m) setModels(m.models || []);
    if (config.model) setTest(await perform(() => api('provider.test')));
    else setTest({ ok: false, message: 'Выберите модель из списка и повторите проверку.' });
    setTesting(false);
  }
  function preference(name: string, value: any) {
    setSettings({ ...settings, [name]: value });
    perform(() => api('settings.set', { key: name, value }));
  }
  return (
    <div className="page settings-page">
      <header className="page-heading">
        <Title order={1}>Настройки</Title>
      </header>
      <div className="settings-sections">
        <section className="settings-section" aria-labelledby="connection-heading">
          <div className="settings-section-intro">
            <Title order={2} id="connection-heading">
              Подключение AI
            </Title>
            <Text c="dimmed" size="sm">
              Для создания и изменения приложений с помощником.
            </Text>
          </div>
          <Stack className="settings-section-content" gap="md">
            <Select
              label="Провайдер"
              value={config.type}
              data={[
                { value: 'openai', label: 'OpenAI / совместимый API' },
                { value: 'anthropic', label: 'Anthropic' },
              ]}
              onChange={(v) => {
                setConfig({
                  ...config,
                  type: v,
                  endpoint:
                    v === 'anthropic'
                      ? 'https://api.anthropic.com/v1'
                      : 'https://api.openai.com/v1',
                });
                setTest(undefined);
              }}
            />
            <TextInput
              label="Адрес API"
              value={config.endpoint || ''}
              onChange={(e) => setConfig({ ...config, endpoint: e.target.value })}
            />
            <PasswordInput
              label="API-ключ"
              placeholder={
                config.hasKey
                  ? 'Ключ сохранён. Оставьте пустым, чтобы сохранить его'
                  : 'Введите ключ провайдера'
              }
              value={key}
              onChange={(e) => setKey(e.target.value)}
              description="Ключ хранится локально в защищённом хранилище и не входит в файлы приложений."
            />
            {models.length ? (
              <Select
                searchable
                label="Модель"
                data={models.map((m) => ({ value: m.id, label: m.name || m.id }))}
                value={config.model}
                onChange={(v) => setConfig({ ...config, model: v })}
              />
            ) : (
              <TextInput
                label="Модель"
                placeholder="Идентификатор модели с поддержкой инструментов"
                value={config.model || ''}
                onChange={(e) => setConfig({ ...config, model: e.target.value })}
              />
            )}
            <Group className="settings-actions" gap="sm">
              <Button onClick={save}>Сохранить подключение</Button>
              <Button variant="default" loading={testing} onClick={check}>
                Проверить и получить модели
              </Button>
            </Group>
            {test && (
              <Alert
                color={test.ok ? 'sage' : 'red'}
                title={test.ok ? 'Соединение установлено' : 'Не удалось подключиться'}
              >
                {test.message}
                <Group mt="sm">
                  <Badge color={test.tools ? 'sage' : 'orange'}>
                    Инструменты: {test.tools ? 'да' : 'нет'}
                  </Badge>
                  <Badge color={test.structuredOutput ? 'sage' : 'gray'}>
                    Структурированный ответ: {test.structuredOutput ? 'да' : 'нет'}
                  </Badge>
                </Group>
              </Alert>
            )}
          </Stack>
        </section>
        <section className="settings-section" aria-labelledby="workspace-heading">
          <div className="settings-section-intro">
            <Title order={2} id="workspace-heading">
              Ваше рабочее место
            </Title>
            <Text c="dimmed" size="sm">
              Оформление и поведение приложения.
            </Text>
          </div>
          <Stack className="settings-section-content" gap="lg">
            <div>
              <Text size="sm" fw={500} mb={8}>
                Оформление
              </Text>
              <SegmentedControl
                className="settings-theme-control"
                aria-label="Оформление"
                value={colorScheme}
                onChange={(v) => setColorScheme(v as any)}
                data={[
                  { label: 'Как в системе', value: 'auto' },
                  { label: 'Светлое', value: 'light' },
                  { label: 'Тёмное', value: 'dark' },
                ]}
              />
            </div>
            <Switch
              className="settings-preference"
              labelPosition="left"
              label="Открывать последнее приложение при запуске"
              checked={!!settings.restoreLastApp}
              onChange={(e) => preference('restoreLastApp', e.currentTarget.checked)}
            />
            <Switch
              className="settings-preference"
              labelPosition="left"
              label="Показывать персонажа"
              checked={settings.showCharacter !== false}
              onChange={(e) => {
                preference('showCharacter', e.currentTarget.checked);
                localStorage.setItem('showCharacter', String(e.currentTarget.checked));
              }}
            />
            <Switch
              className="settings-preference"
              labelPosition="left"
              label="Запускать при входе в macOS"
              checked={!!settings.loginItem}
              onChange={(e) => {
                preference('loginItem', e.currentTarget.checked);
                perform(() => api('system.login', { enabled: e.currentTarget.checked }));
              }}
            />
            <Select
              label="Размер персонажа"
              value={settings.characterSize || 'normal'}
              data={[
                { value: 'normal', label: 'Обычный' },
                { value: 'small', label: 'Компактный' },
              ]}
              onChange={(v) => preference('characterSize', v)}
            />
          </Stack>
        </section>
        <Updates />
        <Text className="settings-note" size="sm" c="dimmed">
          Установленные локальные приложения продолжают работать без подключения модели. Во время
          сна и при выключенном Mac локальные задания не выполняются.
        </Text>
      </div>
    </div>
  );
}
