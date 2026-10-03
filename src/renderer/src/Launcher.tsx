import { useCallback, useEffect, useRef, useState } from 'react';
import { ActionIcon, Alert, Button, Loader, Text, TextInput, Tooltip } from '@mantine/core';
import { IconArrowLeft, IconExternalLink, IconSearch, IconX } from '@tabler/icons-react';
import { launcherApps, type LauncherApp, type MacLauncherApp } from '../../shared/launcher';
import type { AppInstance } from '../../shared/types';
import { api, errorMessage, report } from './api';
import { flushDocuments } from './documentFlush';
import Runtime from './Runtime';

export default function Launcher() {
  const [apps, setApps] = useState<LauncherApp[]>([]);
  const [macApps, setMacApps] = useState<MacLauncherApp[]>([]);
  const [macLoading, setMacLoading] = useState(true);
  const [macError, setMacError] = useState('');
  const [query, setQuery] = useState('');
  const [selected, setSelected] = useState<string>();
  const [loading, setLoading] = useState(true);
  const [opening, setOpening] = useState(false);
  const [error, setError] = useState('');
  const [current, setCurrent] = useState<AppInstance>();
  const [screen, setScreen] = useState<string>();
  const input = useRef<HTMLInputElement>(null);
  const activeApp = useRef<AppInstance | undefined>(undefined);
  const launchPending = useRef(false);
  const request = useRef(0);
  const macRequest = useRef(0);
  const results = launcherApps([...apps, ...macApps], query);
  const index = Math.max(
    0,
    results.findIndex((app) => app.id === selected),
  );
  const selection = results[index];
  const refreshMac = useCallback(async () => {
    const id = ++macRequest.current;
    try {
      const next = await api<MacLauncherApp[]>('launcher.macApps');
      if (id !== macRequest.current) return;
      setMacApps(next);
      setMacError('');
    } catch (error) {
      if (id === macRequest.current) setMacError(errorMessage(error));
    } finally {
      if (id === macRequest.current) setMacLoading(false);
    }
  }, []);
  const refresh = useCallback(async () => {
    const id = ++request.current;
    try {
      const next = await api<LauncherApp[]>('launcher.apps');
      if (id !== request.current) return;
      setApps(next);
      setError('');
    } catch (error) {
      if (id === request.current) setError(errorMessage(error));
    } finally {
      if (id === request.current) setLoading(false);
    }
  }, []);
  useEffect(() => {
    void refresh();
    void refreshMac();
    const unsubscribe = window.platform.onEvent((event) => {
      if (event.type === 'launcher.shown') {
        void refresh();
        void refreshMac();
        if (!activeApp.current) input.current?.focus();
      }
      if (event.type === 'workspace.changed') {
        void refresh();
        const currentId = activeApp.current?.id;
        if (currentId)
          void api<AppInstance>('apps.get', { appId: currentId })
            .then((app) => {
              if (activeApp.current?.id === currentId) {
                activeApp.current = app;
                setCurrent(app);
              }
            })
            .catch((error) => setError(errorMessage(error)));
      }
      if (event.type === 'workspace.beforeClose')
        void flushDocuments()
          .then(() => api('windows.confirmClose', { token: event.token }))
          .catch((error) => {
            report(error);
            void api('windows.confirmClose', { token: event.token, error: String(error) });
          });
    });
    return () => {
      request.current++;
      macRequest.current++;
      unsubscribe();
    };
  }, [refresh, refreshMac]);
  useEffect(() => {
    document.getElementById(`launcher-app-${selection?.id}`)?.scrollIntoView({ block: 'nearest' });
  }, [selection?.id]);
  async function open(app: LauncherApp) {
    if (launchPending.current) return;
    launchPending.current = true;
    setOpening(true);
    setError('');
    try {
      if (app.kind === 'mac') {
        await api('launcher.openMac', { id: app.id });
        return;
      }
      const instance = await api<AppInstance>('launcher.open', { appId: app.id });
      activeApp.current = instance;
      setCurrent(instance);
      setScreen(localStorage.getItem('screen:' + app.id) || undefined);
    } catch (error) {
      setError(errorMessage(error));
    } finally {
      launchPending.current = false;
      setOpening(false);
    }
  }
  async function back() {
    if (launchPending.current) return;
    launchPending.current = true;
    setOpening(true);
    try {
      await flushDocuments();
      await api('launcher.back');
      activeApp.current = undefined;
      setCurrent(undefined);
      setError('');
      void refresh();
      void refreshMac();
    } catch (error) {
      setError(errorMessage(error));
    } finally {
      launchPending.current = false;
      setOpening(false);
    }
  }
  const hide = () => void api('launcher.hide').catch((error) => setError(errorMessage(error)));
  return (
    <main
      className="launcher"
      aria-label="Быстрый запуск"
      onKeyDown={(event) => {
        if (
          event.key === 'Escape' &&
          !event.nativeEvent.isComposing &&
          !event.defaultPrevented &&
          !document.querySelector(
            '[role="dialog"], [role="menu"], [role="listbox"]:not(#launcher-results)',
          )
        ) {
          event.preventDefault();
          hide();
        }
      }}
    >
      {current ? (
        <>
          <header className="launcher-app-header">
            <Tooltip label="Назад к приложениям">
              <ActionIcon
                aria-label="Назад к приложениям"
                variant="subtle"
                disabled={opening}
                onClick={() => void back()}
              >
                <IconArrowLeft size={20} />
              </ActionIcon>
            </Tooltip>
            <Text fw={550} truncate>
              {current.icon} {current.name}
            </Text>
            <Tooltip label="Открыть в отдельном окне">
              <ActionIcon
                aria-label="Открыть в отдельном окне"
                variant="subtle"
                onClick={() => {
                  void flushDocuments()
                    .then(() => api('windows.open', { appId: current.id }))
                    .then(hide)
                    .catch((error) => setError(errorMessage(error)));
                }}
              >
                <IconExternalLink size={18} />
              </ActionIcon>
            </Tooltip>
            <ActionIcon aria-label="Закрыть быстрый запуск" variant="subtle" onClick={hide}>
              <IconX size={18} />
            </ActionIcon>
          </header>
          {error && (
            <Alert color="red" m="sm">
              {error}
            </Alert>
          )}
          <div className="launcher-content">
            <Runtime
              key={current.id}
              app={current}
              standalone
              screenId={screen}
              onScreenChange={(id) => {
                setScreen(id);
                localStorage.setItem('screen:' + current.id, id);
              }}
            />
          </div>
        </>
      ) : (
        <>
          <div className="launcher-search">
            <TextInput
              ref={input}
              autoFocus
              variant="unstyled"
              size="lg"
              leftSection={<IconSearch size={22} />}
              placeholder="Найти приложение…"
              aria-label="Найти приложение"
              value={query}
              onChange={(event) => {
                setQuery(event.currentTarget.value);
                setSelected(undefined);
              }}
              role="combobox"
              aria-expanded="true"
              aria-controls="launcher-results"
              aria-autocomplete="list"
              aria-activedescendant={selection ? `launcher-app-${selection.id}` : undefined}
              onKeyDown={(event) => {
                if (event.nativeEvent.isComposing) return;
                if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
                  event.preventDefault();
                  if (results.length)
                    setSelected(
                      results[
                        (index + (event.key === 'ArrowDown' ? 1 : -1) + results.length) %
                          results.length
                      ].id,
                    );
                }
                if (event.key === 'Enter' && selection) {
                  event.preventDefault();
                  void open(selection);
                }
              }}
            />
            <ActionIcon aria-label="Закрыть быстрый запуск" variant="subtle" onClick={hide}>
              <IconX size={18} />
            </ActionIcon>
          </div>
          {(error || macError) && (
            <Alert color="red" mx="sm" mt="sm">
              {error || macError}
              <Button
                variant="subtle"
                onClick={() => {
                  void refresh();
                  void refreshMac();
                }}
              >
                Обновить список
              </Button>
            </Alert>
          )}
          <div
            className="launcher-results"
            id="launcher-results"
            role="listbox"
            aria-label="Ваши приложения"
            aria-busy={loading || opening}
          >
            {(loading || macLoading) && !results.length ? (
              <div className="launcher-message">
                <Loader size="sm" aria-label="Загрузка приложений" />
              </div>
            ) : results.length ? (
              results.map((app) => (
                <button
                  type="button"
                  role="option"
                  tabIndex={-1}
                  id={`launcher-app-${app.id}`}
                  key={app.id}
                  data-kind={app.kind}
                  className={`launcher-result ${selection?.id === app.id ? 'selected' : ''}`}
                  aria-selected={selection?.id === app.id}
                  disabled={opening}
                  onMouseMove={() => setSelected(app.id)}
                  onClick={() => void open(app)}
                >
                  <span className="launcher-icon" aria-hidden="true">
                    {app.kind === 'mac' && app.icon ? (
                      <img src={app.icon} alt="" />
                    ) : (
                      app.icon || '◈'
                    )}
                  </span>
                  <span className="launcher-result-text">
                    <strong>{app.name}</strong>
                    <span>{app.description || 'Everything App'}</span>
                  </span>
                  <span className="launcher-result-hint">
                    {app.kind === 'mac'
                      ? 'macOS'
                      : app.favorite
                        ? '★'
                        : app.status === 'stopped'
                          ? 'Запустить'
                          : 'Открыть'}
                  </span>
                </button>
              ))
            ) : (
              <div className="launcher-message">
                <Text c="dimmed" size="sm">
                  {apps.length || macApps.length
                    ? 'Приложения не найдены. Попробуйте другое название.'
                    : 'Пока нет приложений. Создайте своё в рабочем пространстве.'}
                </Text>
                {!apps.length && (
                  <Button
                    variant="default"
                    mt="md"
                    onClick={() =>
                      void api('windows.open')
                        .then(hide)
                        .catch((error) => setError(errorMessage(error)))
                    }
                  >
                    Открыть рабочее пространство
                  </Button>
                )}
              </div>
            )}
          </div>
          <footer className="launcher-footer">
            <span>{macLoading ? 'Ищем приложения macOS…' : `Приложения · ${results.length}`}</span>
            <span>{opening ? 'Открываем…' : '↑ ↓ выбрать · Enter открыть · Esc закрыть'}</span>
          </footer>
        </>
      )}
    </main>
  );
}
