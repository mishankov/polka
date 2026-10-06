import { Fragment, useCallback, useEffect, useRef, useState } from 'react';
import { ActionIcon, Alert, Button, Loader, Text, TextInput, Tooltip } from './NativeControls';
import { IconSettings, IconSearch, IconX } from '@tabler/icons-react';
import { type LauncherApp, type MacLauncherApp } from '../../shared/launcher';
import { type ClipboardState } from '../../shared/clipboard';
import { shelfSearch, type ShelfSearchResult } from '../../shared/shelf-search';
import SearchResult from './ShelfSearchResult';
import { api, errorMessage, report } from './api';
import ClipboardHistory from './ClipboardHistory';
import EmojiPicker from './EmojiPicker';
import ShelfSettings from './ShelfSettings';
import ShelfWelcome from './ShelfWelcome';
import UpdateNotice from './UpdateNotice';
import type { ShelfDestination } from '../../shared/shelf';

export default function Launcher({
  entry,
}: {
  entry: { revision: number; destination: ShelfDestination; searchQuery?: string };
}) {
  // Apply the entry destination in this render. Mirroring it in an effect briefly
  // remounts clipboard history when a closed shelf reopens on the app list.
  const settings = entry.destination === 'settings' || entry.destination === 'about';
  const builtin = entry.destination === 'clipboard' || entry.destination === 'emoji';
  const navigation = useRef(0);
  const [apps, setApps] = useState<LauncherApp[]>([]);
  const [macApps, setMacApps] = useState<MacLauncherApp[]>([]);
  const [macLoading, setMacLoading] = useState(true);
  const [macError, setMacError] = useState('');
  const [clipboard, setClipboard] = useState<ClipboardState>();
  const [clipboardError, setClipboardError] = useState('');
  const [clipboardLoading, setClipboardLoading] = useState(true);
  const [copied, setCopied] = useState('');
  const [query, setQuery] = useState('');
  const [selected, setSelected] = useState<string>();
  const [loading, setLoading] = useState(true);
  const [opening, setOpening] = useState(false);
  const [error, setError] = useState('');
  const input = useRef<HTMLInputElement>(null);
  const launchPending = useRef(false);
  const request = useRef(0);
  const macRequest = useRef(0);
  const clipboardRequest = useRef(0);
  const { results, calculation } = shelfSearch(
    [...apps, ...macApps],
    clipboard?.clips || [],
    query,
  );
  const index = Math.max(
    0,
    results.findIndex((app) => app.id === selected),
  );
  const selection = results[index];
  const canPaste =
    !!clipboard?.preferences.pasteOnSelect &&
    clipboard.pasteAccess === 'granted' &&
    clipboard.pasteReady;
  const actionLabel =
    selection?.kind === 'calculation'
      ? 'копировать результат'
      : selection?.kind === 'clip'
        ? canPaste
          ? 'вставить'
          : 'копировать'
        : 'открыть';
  const refreshClipboard = useCallback(async () => {
    const id = ++clipboardRequest.current;
    try {
      const next = await api<ClipboardState>('clipboardHistory.state');
      if (id !== clipboardRequest.current) return;
      setClipboard(next);
      setClipboardError(next.error || '');
    } catch (error) {
      if (id === clipboardRequest.current) setClipboardError(errorMessage(error));
    } finally {
      if (id === clipboardRequest.current) setClipboardLoading(false);
    }
  }, []);
  useEffect(() => {
    if (builtin || settings) return;
    void refreshClipboard();
    const unsubscribe = window.platform.onEvent((event) => {
      if (event.type === 'clipboardHistory.changed') void refreshClipboard();
    });
    return () => {
      clipboardRequest.current++;
      unsubscribe();
    };
  }, [builtin, settings, entry.revision, refreshClipboard]);
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
    return () => {
      request.current++;
      macRequest.current++;
    };
  }, [refresh, refreshMac]);
  useEffect(() => {
    navigation.current++;
    setQuery('');
    setSelected(undefined);
    setError('');
    setCopied('');
    void refresh();
    void refreshMac();
  }, [entry.revision, entry.destination, refresh, refreshMac]);
  useEffect(() => {
    if (!builtin && !settings) input.current?.focus();
  }, [builtin, settings, entry.revision]);
  useEffect(() => {
    document.getElementById(`launcher-app-${selection?.id}`)?.scrollIntoView({ block: 'nearest' });
  }, [selection?.id]);
  async function open(app: LauncherApp) {
    if (launchPending.current) return;
    launchPending.current = true;
    setOpening(true);
    setError('');
    try {
      if (app.kind === 'builtin') {
        await api(app.id === 'builtin:emoji' ? 'shelf.showEmoji' : 'clipboardHistory.show');
        return;
      }
      if (app.kind === 'mac') {
        await api('launcher.openMac', { id: app.id });
        return;
      }
    } catch (error) {
      setError(errorMessage(error));
    } finally {
      launchPending.current = false;
      setOpening(false);
    }
  }
  async function activate(result: ShelfSearchResult, copyOnly = false) {
    if (result.kind === 'app') return open(result.app);
    if (launchPending.current) return;
    launchPending.current = true;
    setOpening(true);
    setError('');
    const token = navigation.current;
    try {
      if (result.kind === 'calculation') {
        await api('shelf.copyCalculation', { expression: result.calculation.expression });
        if (token === navigation.current) {
          setCopied(result.id);
          input.current?.focus();
        }
      } else if (result.kind === 'clip') {
        await api(copyOnly ? 'clipboardHistory.copy' : 'clipboardHistory.select', {
          id: result.clip.id,
        });
      } else {
        await api('clipboardHistory.show', { query: result.query });
      }
    } catch (error) {
      if (token === navigation.current) setError(errorMessage(error));
    } finally {
      launchPending.current = false;
      setOpening(false);
    }
  }
  const hide = () => void api('launcher.hide').catch((error) => setError(errorMessage(error)));
  return (
    <section
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
          if (settings) void api('launcher.show').catch(report);
          else hide();
        }
      }}
    >
      {settings ? (
        <ShelfSettings
          key={entry.revision}
          initialTab={entry.destination === 'about' ? 'about' : 'general'}
        />
      ) : entry.destination === 'emoji' ? (
        <EmojiPicker
          key={entry.revision}
          onBack={() => void api('launcher.show').catch((error) => setError(errorMessage(error)))}
        />
      ) : builtin ? (
        <ClipboardHistory
          key={entry.revision}
          initialQuery={entry.searchQuery}
          onBack={() => void api('launcher.show').catch((error) => setError(errorMessage(error)))}
        />
      ) : (
        <>
          <div className="launcher-search clipboard-search">
            <TextInput
              ref={input}
              autoFocus
              leftSection={<IconSearch size={22} />}
              placeholder="Найти или посчитать…"
              aria-label="Поиск по полке"
              maxLength={10000}
              value={query}
              onChange={(event) => {
                setQuery(event.currentTarget.value);
                setSelected(undefined);
                setCopied('');
                setError('');
              }}
              role="combobox"
              aria-expanded="true"
              aria-controls="launcher-results"
              aria-autocomplete="list"
              aria-activedescendant={selection ? `launcher-app-${selection.id}` : undefined}
              onKeyDown={(event) => {
                if (event.nativeEvent.isComposing) return;
                if (
                  event.metaKey &&
                  !event.ctrlKey &&
                  !event.altKey &&
                  !event.shiftKey &&
                  /^[1-9]$/.test(event.key)
                ) {
                  if (
                    event.defaultPrevented ||
                    document.querySelector(
                      '[role="dialog"], [role="menu"], [role="listbox"]:not(#launcher-results)',
                    )
                  )
                    return;
                  event.preventDefault();
                  const result = results[Number(event.key) - 1];
                  if (result && !event.repeat) void activate(result);
                  return;
                }
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
                  void activate(selection, event.shiftKey);
                }
              }}
            />
            <Tooltip label="Настройки · ⌘ ,">
              <ActionIcon
                aria-label="Настройки"
                variant="subtle"
                onClick={() => void api('shelf.settings').catch(report)}
              >
                <IconSettings size={20} />
              </ActionIcon>
            </Tooltip>
          </div>
          {!query.trim() && (
            <div className="launcher-start">
              <UpdateNotice />
              <ShelfWelcome />
            </div>
          )}
          {query.trim() && clipboardError && (
            <Alert color="red" mx="sm" mt="sm" title="История буфера обмена">
              {clipboardError}
              <Button variant="subtle" onClick={() => void refreshClipboard()}>
                Повторить
              </Button>
            </Alert>
          )}
          {calculation && calculation.status !== 'result' && (
            <div className="launcher-calculation-status" role="status">
              {calculation.status === 'incomplete' ? 'Продолжите выражение…' : calculation.message}
            </div>
          )}
          <span className="sr-only" role="status">
            {copied === selection?.id ? 'Результат скопирован' : ''}
          </span>
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
            aria-label="Результаты поиска"
            aria-busy={loading || macLoading || clipboardLoading || opening}
          >
            {(loading || macLoading || clipboardLoading) && !results.length ? (
              <div className="launcher-message">
                <Loader size="sm" aria-label="Загрузка результатов" />
              </div>
            ) : results.length ? (
              results.map((result, position) => (
                <Fragment key={result.id}>
                  {result.kind !== 'more-clips' && result.kind !== results[position - 1]?.kind && (
                    <div className="launcher-result-group" role="presentation">
                      {result.kind === 'calculation'
                        ? 'Калькулятор'
                        : result.kind === 'clip'
                          ? 'Буфер обмена'
                          : 'Приложения'}
                    </div>
                  )}
                  <SearchResult
                    result={result}
                    query={query}
                    selected={selection?.id === result.id}
                    busy={opening}
                    copied={copied === result.id}
                    canPaste={canPaste}
                    shortcut={position < 9 ? position + 1 : undefined}
                    onSelect={() => setSelected(result.id)}
                    onActivate={(copyOnly) => void activate(result, copyOnly)}
                  />
                </Fragment>
              ))
            ) : calculation ? null : (
              <div className="launcher-message">
                <Text c="dimmed" size="sm">
                  {query.trim()
                    ? 'Ничего не найдено. Попробуйте другое слово.'
                    : 'Список приложений пока пуст. Попробуйте обновить его.'}
                </Text>
              </div>
            )}
          </div>
          <footer className="launcher-footer clipboard-footer">
            <span>
              {macLoading || clipboardLoading
                ? 'Ищем…'
                : `Результаты · ${results.filter((result) => result.kind !== 'more-clips').length}`}
            </span>
            <div className="clipboard-shortcuts">
              {opening ? (
                <span>Выполняем…</span>
              ) : (
                <>
                  <span>
                    <kbd>↑</kbd>
                    <kbd>↓</kbd> выбрать
                  </span>
                  {selection && (
                    <span>
                      <kbd>↵</kbd> {actionLabel}
                    </span>
                  )}
                  {selection?.kind === 'clip' && canPaste && (
                    <span>
                      <kbd>⇧↵</kbd> копировать
                    </span>
                  )}
                  <span>
                    <kbd>esc</kbd> закрыть
                  </span>
                </>
              )}
            </div>
          </footer>
        </>
      )}
    </section>
  );
}
