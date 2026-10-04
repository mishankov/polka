import { useEffect, useRef, useState } from 'react';
import {
  ActionIcon,
  Alert,
  Badge,
  Button,
  Drawer,
  Group,
  Loader,
  Menu,
  Modal,
  Paper,
  Stack,
  Text,
  TextInput,
  Textarea,
  Title,
  Tooltip,
} from '@mantine/core';
import {
  IconAdjustments,
  IconArrowUp,
  IconBell,
  IconBox,
  IconChevronDown,
  IconCode,
  IconCommand,
  IconDownload,
  IconExternalLink,
  IconHome,
  IconPlus,
  IconSearch,
  IconSettings,
  IconSparkles,
  IconStar,
  IconUpload,
} from '@tabler/icons-react';
import type { AppInstance } from '../../shared/types';
import { api, AnyRecord, labels, perform, report } from './api';
import AgentPanel, { Character } from './AgentPanel';
import Runtime from './Runtime';
import Settings from './Settings';
import {
  AppDetails,
  CreateApp,
  DefinitionEditor,
  ExportDialog,
  ImportDialog,
  PackageProgress,
} from './Management';
import Inbox from './Inbox';
import { flushDocuments } from './documentFlush';
import StandaloneApp from './StandaloneApp';
import Shelf from './Shelf';
export default function App() {
  if (new URLSearchParams(location.search).get('mode') === 'shelf') return <Shelf />;
  const appId = new URLSearchParams(location.search).get('appId');
  return appId ? <StandaloneApp appId={appId} /> : <Workspace />;
}
function Workspace() {
  const [apps, setApps] = useState<AppInstance[]>([]);
  const [page, setPage] = useState(() =>
    new URLSearchParams(location.search).get('page') === 'settings' ? 'settings' : 'home',
  );
  const [appId, setAppId] = useState<string | null>(null);
  const [openingApp, setOpeningApp] = useState(false);
  const [openFailed, setOpenFailed] = useState(false);
  const openRequest = useRef(0);
  const [screen, setScreen] = useState<string>();
  const [agent, setAgent] = useState(false);
  const [prompt, setPrompt] = useState('');
  const [homePrompt, setHomePrompt] = useState('');
  const [create, setCreate] = useState(false);
  const [definition, setDefinition] = useState(false);
  const [details, setDetails] = useState(false);
  const [exporting, setExporting] = useState(false);
  const [preview, setPreview] = useState<any>();
  const [query, setQuery] = useState('');
  const [searching, setSearching] = useState(false);
  const [results, setResults] = useState<any[]>([]);
  const [initial, setInitial] = useState(true);
  const [error, setError] = useState('');
  const [showArchived, setShowArchived] = useState(false);
  const [libraryOpen, setLibraryOpen] = useState(false);
  const searchInput = useRef<HTMLInputElement>(null);
  const [showCharacter, setShowCharacter] = useState(true);
  const [characterSize, setCharacterSize] = useState('normal');
  const [agentState, setAgentState] = useState('idle');
  const app = apps.find((a) => a.id === appId);
  const refresh = () =>
    api('apps.list')
      .then((r: AppInstance[]) => {
        setApps(r);
        setError('');
        setInitial(false);
      })
      .catch((e) => {
        setError(e.message);
        setInitial(false);
      });
  async function open(a: Pick<AppInstance, 'id'>) {
    const request = ++openRequest.current;
    setOpeningApp(appId !== a.id || app?.status !== 'running');
    setOpenFailed(false);
    setLibraryOpen(false);
    setAppId(a.id);
    setPage('app');
    setScreen(localStorage.getItem('screen:' + a.id) || undefined);
    localStorage.setItem('lastApp', a.id);
    try {
      const started = await api<AppInstance>('apps.start', { appId: a.id });
      if (request !== openRequest.current) return;
      setApps((current) =>
        current.some((item) => item.id === started.id)
          ? current.map((item) => (item.id === started.id ? started : item))
          : [...current, started],
      );
    } catch {
      if (request === openRequest.current) setOpenFailed(true);
    } finally {
      if (request === openRequest.current) setOpeningApp(false);
    }
  }
  useEffect(() => {
    refresh();
    api('settings.get')
      .then((s: any) => {
        setShowCharacter(s.showCharacter !== false);
        setCharacterSize(s.characterSize || 'normal');
        if (s.restoreLastApp && new URLSearchParams(location.search).get('page') !== 'settings') {
          const last = localStorage.getItem('lastApp');
          if (last && openRequest.current === 0) void open({ id: last });
        }
      })
      .catch(() => {});
    return window.platform.onEvent((e) => {
      if (e.type === 'platform.error') setError(e.message);
      if (e.type === 'workspace.beforeClose') {
        void flushDocuments()
          .then(() => api('windows.confirmClose', { token: e.token }))
          .catch((error) => {
            report(error);
            void api('windows.confirmClose', { token: e.token, error: String(error) });
          });
      }
      if (e.type === 'workspace.changed') refresh();
      if (e.type === 'agent.updated') setAgentState(e.status || 'idle');
      if (e.type === 'workspace.toggleAssistant') setAgent((value) => !value);
      if (e.type === 'platform.error') setError(e.message);
      if (e.type === 'package.opened') setPreview(e.preview);
      if (e.type === 'navigate') {
        ++openRequest.current;
        setPage(e.page);
        setAppId(null);
        setSearching(false);
        setLibraryOpen(false);
      }
    });
  }, []);
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key === 'k') {
        e.preventDefault();
        setSearching(true);
        setTimeout(() => searchInput.current?.focus(), 30);
      }
      if (e.key === 'Escape') setSearching(false);
    };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, []);
  useEffect(() => {
    if (!query) {
      setResults([]);
      return;
    }
    const timeout = setTimeout(() => api('search', { query }).then(setResults).catch(report), 180);
    return () => clearTimeout(timeout);
  }, [query]);
  async function importApp() {
    const p = await perform(() => api('packages.chooseImport'));
    if (p) setPreview(p);
  }
  function ask(text: string) {
    if (!text.trim()) return;
    setPrompt(text.trim());
    setAgent(true);
    setHomePrompt('');
  }
  const nav = (next: string) => {
    ++openRequest.current;
    setPage(next);
    setAppId(null);
    api('settings.get')
      .then((s) => {
        setShowCharacter(s.showCharacter !== false);
        setCharacterSize(s.characterSize || 'normal');
      })
      .catch(() => {});
  };
  const visibleApps = apps.filter((a) => showArchived || a.status !== 'archived');
  return (
    <div className="workspace cozy-shell">
      <aside className="home-rail" aria-label="Навигация">
        <nav className="rail-navigation">
          <Tooltip label="Главная" position="right">
            <button
              className={`rail-button ${page === 'home' ? 'active' : ''}`}
              aria-label="Главная"
              aria-current={page === 'home' ? 'page' : undefined}
              onClick={() => nav('home')}
            >
              <IconHome size={20} />
            </button>
          </Tooltip>
          <Tooltip label="Приложения" position="right">
            <button
              className="rail-button"
              aria-label="Приложения"
              onClick={() => setLibraryOpen(true)}
            >
              <IconBox size={20} />
            </button>
          </Tooltip>
          <Tooltip label="Поиск · ⌘ K" position="right">
            <button className="rail-button" aria-label="Поиск" onClick={() => setSearching(true)}>
              <IconSearch size={20} />
            </button>
          </Tooltip>
          <Tooltip label="Быстрый запуск" position="right">
            <button
              className="rail-button"
              aria-label="Быстрый запуск"
              onClick={() => perform(() => api('launcher.show'))}
            >
              <IconCommand size={20} />
            </button>
          </Tooltip>
          <Tooltip label="Входящие и фоновые задачи" position="right">
            <button
              className={`rail-button ${page === 'inbox' ? 'active' : ''}`}
              aria-current={page === 'inbox' ? 'page' : undefined}
              aria-label="Входящие и фоновые задачи"
              onClick={() => nav('inbox')}
            >
              <IconBell size={20} />
            </button>
          </Tooltip>
          <Tooltip label="Помощник · ⌘ J" position="right">
            <button
              className={`rail-button ${agent ? 'active' : ''}`}
              aria-label="Помощник"
              aria-pressed={agent}
              onClick={() => setAgent((v) => !v)}
            >
              <IconSparkles size={20} />
            </button>
          </Tooltip>
        </nav>
        {visibleApps.length > 0 && (
          <nav className="rail-apps" aria-label="Открыть приложение">
            {[...visibleApps]
              .sort((a, b) => Number(b.favorite) - Number(a.favorite))
              .map((a) => (
                <Tooltip key={a.id} label={a.name} position="right">
                  <button
                    className={`rail-button app-nav ${appId === a.id ? 'active' : ''}`}
                    aria-current={appId === a.id ? 'page' : undefined}
                    aria-label={a.name}
                    onClick={() => open(a)}
                  >
                    <span aria-hidden="true">{a.icon || '◈'}</span>
                    <span className="visually-hidden">{a.name}</span>
                  </button>
                </Tooltip>
              ))}
          </nav>
        )}
        <Tooltip label="Настройки · ⌘ ," position="right">
          <button
            className={`rail-button rail-settings ${page === 'settings' ? 'active' : ''}`}
            aria-current={page === 'settings' ? 'page' : undefined}
            aria-label="Настройки"
            onClick={() => nav('settings')}
          >
            <IconSettings size={20} />
          </button>
        </Tooltip>
      </aside>
      <div className="workspace-main">
        {page === 'app' && (
          <header className="topbar">
            <Group gap="xs" wrap="nowrap" className="app-identity">
              <span className="app-identity-icon" aria-hidden="true">
                {app?.icon || '◈'}
              </span>
              <Title order={1} title={app?.name}>
                {app?.name || 'Приложение'}
              </Title>
              {app?.status === 'archived' && (
                <Badge color="gray" size="xs">
                  В архиве
                </Badge>
              )}
            </Group>
            <Group gap="xs">
              {app && (
                <>
                  <Tooltip label={app.favorite ? 'Убрать из избранного' : 'Добавить в избранное'}>
                    <ActionIcon
                      variant="subtle"
                      color={app.favorite ? 'yellow' : 'gray'}
                      aria-label="Избранное"
                      onClick={() =>
                        perform(() =>
                          api('apps.updateMeta', { appId: app.id, favorite: !app.favorite }),
                        ).then(refresh)
                      }
                    >
                      <IconStar size={18} fill={app.favorite ? 'currentColor' : 'none'} />
                    </ActionIcon>
                  </Tooltip>
                  <Menu position="bottom-end">
                    <Menu.Target>
                      <Button
                        size="xs"
                        variant="default"
                        rightSection={<IconChevronDown size={13} />}
                      >
                        Приложение
                      </Button>
                    </Menu.Target>
                    <Menu.Dropdown>
                      <Menu.Item
                        leftSection={<IconAdjustments size={16} />}
                        onClick={() => setDetails(true)}
                      >
                        Свойства и доступ
                      </Menu.Item>
                      <Menu.Item
                        leftSection={<IconCode size={16} />}
                        onClick={() => setDefinition(true)}
                      >
                        Изменить экраны и данные
                      </Menu.Item>
                      <Menu.Item
                        leftSection={<IconDownload size={16} />}
                        onClick={() => setExporting(true)}
                      >
                        Экспортировать…
                      </Menu.Item>
                      <Menu.Item
                        onClick={async () => {
                          const p = await perform(() =>
                            api('packages.chooseUpdate', { appId: app.id }),
                          );
                          if (p) setPreview({ ...p, updating: true });
                        }}
                      >
                        Обновить из файла…
                      </Menu.Item>
                      <Menu.Divider />
                      <Menu.Item
                        onClick={() =>
                          perform(() =>
                            api('apps.updateMeta', {
                              appId: app.id,
                              status: app.status === 'running' ? 'stopped' : 'running',
                            }),
                          ).then(refresh)
                        }
                      >
                        {app.status === 'running'
                          ? 'Остановить приложение'
                          : 'Запустить приложение'}
                      </Menu.Item>
                      <Menu.Item
                        leftSection={<IconExternalLink size={16} />}
                        onClick={() => perform(() => api('windows.open', { appId: app.id }))}
                      >
                        Открыть в отдельном окне
                      </Menu.Item>
                    </Menu.Dropdown>
                  </Menu>
                </>
              )}
              <Button
                variant={agent ? 'light' : 'subtle'}
                leftSection={<IconSparkles size={16} />}
                size="xs"
                onClick={() => setAgent((v) => !v)}
              >
                Помощник <kbd>⌘ J</kbd>
              </Button>
            </Group>
          </header>
        )}
        <div className="workspace-body">
          <main className="main-content">
            {error && (
              <Alert color="red" title="Не удалось открыть рабочее пространство" m="lg">
                {error}
                <Button variant="subtle" onClick={refresh}>
                  Повторить
                </Button>
              </Alert>
            )}
            {page === 'home' && (
              <div className="home-page">
                <div className="home-welcome">
                  {showCharacter && (
                    <div className={`home-character ${characterSize === 'small' ? 'compact' : ''}`}>
                      <Character small state={agentState} />
                    </div>
                  )}
                  <Title order={1}>Что создадим?</Title>
                </div>
                {!agent && (
                  <form
                    className="home-composer"
                    onSubmit={(e) => {
                      e.preventDefault();
                      ask(homePrompt);
                    }}
                  >
                    <Textarea
                      className="home-prompt"
                      variant="unstyled"
                      autosize
                      minRows={2}
                      maxRows={6}
                      aria-label="Описание нового приложения"
                      placeholder="Опишите, что хотите создать…"
                      value={homePrompt}
                      onChange={(e) => setHomePrompt(e.target.value)}
                      onKeyDown={(e) => {
                        if (
                          e.key === 'Enter' &&
                          !e.shiftKey &&
                          !e.nativeEvent.isComposing &&
                          e.keyCode !== 229
                        ) {
                          e.preventDefault();
                          if (!e.repeat) ask(homePrompt);
                        }
                      }}
                    />
                    <div className="home-composer-actions">
                      <Menu position="top-start" withinPortal>
                        <Menu.Target>
                          <ActionIcon
                            type="button"
                            variant="subtle"
                            color="gray"
                            size="lg"
                            aria-label="Добавить приложение"
                          >
                            <IconPlus size={20} />
                          </ActionIcon>
                        </Menu.Target>
                        <Menu.Dropdown>
                          <Menu.Item leftSection={<IconUpload size={16} />} onClick={importApp}>
                            Открыть файл приложения…
                          </Menu.Item>
                          <Menu.Item
                            leftSection={<IconPlus size={16} />}
                            onClick={() => setCreate(true)}
                          >
                            Создать вручную…
                          </Menu.Item>
                        </Menu.Dropdown>
                      </Menu>
                      <Tooltip label="Обсудить идею · Enter (Shift+Enter — новая строка)">
                        <ActionIcon
                          className="home-send"
                          type="submit"
                          variant="filled"
                          size="lg"
                          radius="xl"
                          aria-label="Обсудить идею"
                          disabled={!homePrompt.trim()}
                        >
                          <IconArrowUp size={18} />
                        </ActionIcon>
                      </Tooltip>
                    </div>
                  </form>
                )}
              </div>
            )}
            {page === 'settings' && <Settings />}
            {page === 'inbox' && <Inbox apps={apps} />}{' '}
            {page === 'app' && openingApp && (
              <Loader aria-label="Открытие приложения" m="lg" size="sm" />
            )}
            {page === 'app' && !openingApp && openFailed && (
              <Alert title="Не удалось открыть приложение" color="red" m="lg">
                <Text size="sm">Попробуйте открыть приложение ещё раз.</Text>
                <Button variant="subtle" onClick={() => appId && open({ id: appId })}>
                  Повторить
                </Button>
              </Alert>
            )}
            {page === 'app' && !openingApp && !openFailed && app && (
              <>
                <Runtime
                  app={app}
                  screenId={screen}
                  onScreenChange={(id) => {
                    setScreen(id);
                    localStorage.setItem('screen:' + app.id, id);
                  }}
                  onEdit={() => setDefinition(true)}
                />
              </>
            )}
            {page === 'app' && !openingApp && !openFailed && !app && !initial && (
              <div className="empty-state">
                <Text>Приложение недоступно</Text>
                <Button variant="light" mt="md" onClick={() => nav('home')}>
                  На главную
                </Button>
              </div>
            )}
          </main>
          {agent && (
            <AgentPanel
              app={app}
              pageId={screen}
              onClose={() => setAgent(false)}
              onChanged={refresh}
              initialPrompt={prompt}
              onPromptUsed={() => setPrompt('')}
            />
          )}
        </div>
      </div>
      <Drawer
        opened={libraryOpen}
        onClose={() => setLibraryOpen(false)}
        title="Приложения"
        size={340}
      >
        <Stack gap="sm">
          <Group grow>
            <Button
              variant="default"
              size="sm"
              onClick={() => {
                setLibraryOpen(false);
                setCreate(true);
              }}
            >
              Создать
            </Button>
            <Button variant="default" size="sm" onClick={importApp}>
              Открыть файл…
            </Button>
          </Group>
          {initial ? (
            <Text size="sm" c="dimmed" py="lg">
              Загружаем приложения…
            </Text>
          ) : !visibleApps.length ? (
            <Text size="sm" c="dimmed" py="lg">
              Приложений пока нет.
            </Text>
          ) : (
            visibleApps.map((a) => (
              <button className="nav-item app-nav" key={a.id} onClick={() => open(a)}>
                <span className="app-mini-icon">{a.icon || '◈'}</span>
                <span>{a.name}</span>
                {a.favorite && <IconStar size={14} />}
              </button>
            ))
          )}
          {apps.some((a) => a.status === 'archived') && (
            <Button
              variant="subtle"
              color="gray"
              size="compact-sm"
              onClick={() => setShowArchived((v) => !v)}
            >
              {showArchived ? 'Скрыть архив' : 'Показать архив'}
            </Button>
          )}
        </Stack>
      </Drawer>
      <CreateApp
        opened={create}
        onClose={() => setCreate(false)}
        onCreated={(a) => {
          refresh();
          open(a);
          setDefinition(true);
        }}
      />
      {app && (
        <>
          <DefinitionEditor
            key={app.id}
            app={app}
            opened={definition}
            onClose={() => setDefinition(false)}
            onChanged={refresh}
          />
          <AppDetails
            key={app.id + 'details'}
            app={app}
            opened={details}
            onClose={() => setDetails(false)}
            onChanged={refresh}
          />
          <ExportDialog
            key={app.id + 'export'}
            app={app}
            opened={exporting}
            onClose={() => setExporting(false)}
          />
        </>
      )}
      <PackageProgress />
      <ImportDialog
        preview={preview}
        onClose={() => setPreview(undefined)}
        onImported={(a) => {
          refresh();
          open(a);
        }}
      />
      <Modal
        opened={searching}
        onClose={() => setSearching(false)}
        title="Поиск по рабочему пространству"
        size="lg"
      >
        <TextInput
          ref={searchInput}
          leftSection={<IconSearch size={17} />}
          placeholder={labels.search}
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          data-autofocus
        />
        <Stack mt="md" gap="xs">
          {apps
            .filter((a) => query && a.name.toLowerCase().includes(query.toLowerCase()))
            .map((a) => (
              <Button
                key={a.id}
                justify="start"
                variant="subtle"
                onClick={() => {
                  open(a);
                  setSearching(false);
                }}
              >
                {a.icon} {a.name}
              </Button>
            ))}
          {results.map((r, i) => (
            <Paper
              key={i}
              withBorder
              p="sm"
              component="button"
              ta="left"
              onClick={() => {
                const a = apps.find((a) => a.id === r.appId);
                if (a) {
                  open(a);
                  setScreen(a.definition.screens.find((s) => s.entityId === r.entityId)?.id);
                  setSearching(false);
                }
              }}
            >
              <Text fw={500} size="sm">
                {r.title}
              </Text>
              <Text c="dimmed" size="xs" lineClamp={2}>
                {r.excerpt}
              </Text>
            </Paper>
          ))}
          {query &&
            !results.length &&
            !apps.some((a) => a.name.toLowerCase().includes(query.toLowerCase())) && (
              <Text c="dimmed" size="sm">
                Ничего не найдено
              </Text>
            )}
        </Stack>
      </Modal>
    </div>
  );
}
