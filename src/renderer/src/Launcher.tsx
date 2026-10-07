import {
  Fragment,
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from 'react';
import { ActionIcon, Alert, Button, Loader, Text, TextInput, Tooltip } from './NativeControls';
import { IconSettings, IconSearch, IconX } from '@tabler/icons-react';
import {
  type LauncherApp,
  type MacLauncherApp,
  type LauncherUsageStats,
} from '../../shared/launcher';
import { type ClipboardState } from '../../shared/clipboard';
import { shelfSearch, type ShelfSearchResult } from '../../shared/shelf-search';
import SearchResult from './ShelfSearchResult';
import { api, errorMessage, report } from './api';
import ClipboardHistory from './ClipboardHistory';
import FileShelf from './FileShelf';
import EmojiPicker from './EmojiPicker';
import ShelfSettings from './ShelfSettings';
import ShelfWelcome from './ShelfWelcome';
import UpdateNotice from './UpdateNotice';
import type { ShelfEntry } from '../../shared/shelf';
import type { BuiltinContext } from './shelf-context';
import { consumedKey, numberShortcut } from './shelf-keyboard';

// Catalog data outlives a presentation; navigation only resets browsing state.
function useLauncherCatalog() {
  const [apps, setApps] = useState<LauncherApp[]>([]);
  const [macApps, setMacApps] = useState<MacLauncherApp[]>([]);
  const [usage, setUsage] = useState<LauncherUsageStats>({});
  const [loading, setLoading] = useState(true);
  const [macLoading, setMacLoading] = useState(true);
  const [error, setError] = useState('');
  const [macError, setMacError] = useState('');
  const request = useRef(0);
  const macRequest = useRef(0);
  const usageRevision = useRef(0);
  const updateUsage = useCallback((next: LauncherUsageStats) => {
    usageRevision.current++;
    setUsage(next);
  }, []);
  const refreshMac = useCallback(async () => {
    const id = ++macRequest.current;
    const usageAtRequest = usageRevision.current;
    setMacError('');
    try {
      const [next, nextUsage] = await Promise.all([
        api<MacLauncherApp[]>('launcher.macApps'),
        api<LauncherUsageStats>('launcher.usage'),
      ]);
      if (id !== macRequest.current) return;
      setMacApps(next);
      // A launch while discovery is pending already returned newer statistics.
      if (usageAtRequest === usageRevision.current) setUsage(nextUsage || {});
    } catch (error) {
      if (id === macRequest.current) setMacError(errorMessage(error));
    } finally {
      if (id === macRequest.current) setMacLoading(false);
    }
  }, []);
  const refresh = useCallback(async () => {
    const id = ++request.current;
    setError('');
    try {
      const next = await api<LauncherApp[]>('launcher.apps');
      if (id !== request.current) return;
      setApps(next);
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
  return {
    apps,
    macApps,
    usage,
    setUsage: updateUsage,
    loading,
    macLoading,
    error,
    macError,
    refresh,
    refreshMac,
  };
}

export default function Launcher({
  entry,
  committedRevision,
}: {
  entry: ShelfEntry;
  committedRevision: number;
}) {
  const catalog = useLauncherCatalog();
  const initialRevision = useRef(entry.revision);
  useEffect(() => {
    if (entry.destination === 'apps' && entry.revision !== initialRevision.current)
      void catalog.refreshMac();
  }, [entry.destination, entry.revision, catalog.refreshMac]);
  const snapshot = useRef<BuiltinContext | undefined>(undefined);
  const draft = useRef<BuiltinContext | undefined>(undefined);
  const saveContext = useCallback(
    (context: BuiltinContext) => {
      draft.current = context;
      if (entry.revision === committedRevision) snapshot.current = context;
    },
    [entry.revision, committedRevision],
  );
  useLayoutEffect(() => {
    // Preparing an entry must not replace the last successfully opened context.
    if (entry.revision === committedRevision)
      snapshot.current =
        entry.destination === 'clipboard' || entry.destination === 'emoji'
          ? draft.current
          : undefined;
  }, [entry.revision, entry.destination, committedRevision]);
  return (
    <LauncherEntry
      key={entry.revision}
      entry={entry}
      context={entry.entryMode === 'resume' ? snapshot.current : undefined}
      saveContext={saveContext}
      catalog={catalog}
    />
  );
}

function LauncherEntry({
  entry,
  context,
  saveContext,
  catalog,
}: {
  entry: ShelfEntry;
  context?: BuiltinContext;
  saveContext: (context: BuiltinContext) => void;
  catalog: ReturnType<typeof useLauncherCatalog>;
}) {
  // Apply the entry destination in this render. Mirroring it in an effect briefly
  // remounts clipboard history when a closed shelf reopens on the app list.
  const settings = entry.destination === 'settings' || entry.destination === 'about';
  const builtin = entry.destination === 'clipboard' || entry.destination === 'emoji';
  const navigation = useRef(0);
  const { apps, macApps, usage, setUsage, macLoading, macError, loading, refresh, refreshMac } =
    catalog;
  const [clipboard, setClipboard] = useState<ClipboardState>();
  const [clipboardError, setClipboardError] = useState('');
  const [clipboardLoading, setClipboardLoading] = useState(true);
  const [copied, setCopied] = useState('');
  const [query, setQuery] = useState('');
  const [selected, setSelected] = useState<string>();
  const [opening, setOpening] = useState(false);
  const [error, setError] = useState('');
  const input = useRef<HTMLInputElement>(null);
  const launchPending = useRef(false);
  const clipboardRequest = useRef(0);
  // Keep an undated conversion anchored while the user reviews and copies it.
  const calculationNow = useMemo(() => new Date(), [query, entry.revision]);
  const { results, calculation } = shelfSearch(
    [...apps, ...macApps],
    clipboard?.clips || [],
    query,
    usage,
    { now: calculationNow },
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
  useEffect(
    () => () => {
      navigation.current++;
    },
    [],
  );
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
        await api(
          app.id === 'builtin:emoji'
            ? 'shelf.showEmoji'
            : app.id === 'builtin:files'
              ? 'shelf.showFiles'
              : 'clipboardHistory.show',
        );
        return;
      }
      if (app.kind === 'mac') {
        const result = await api<{ usage?: LauncherUsageStats }>('launcher.openMac', {
          id: app.id,
        });
        if (result?.usage) setUsage(result.usage);
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
        await api('shelf.copyCalculation', {
          expression: result.calculation.expression,
          ...(result.calculation.sourceDate ? { sourceDate: result.calculation.sourceDate } : {}),
        });
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
      onKeyDownCapture={(event) => {
        // An underlying search or result must not activate behind another popup.
        const popup = document.querySelector(
          '[role="dialog"], [role="menu"], [role="listbox"]:not(#launcher-results):not(#clipboard-results)',
        );
        if (!consumedKey(event) && popup && !popup.contains(event.target as Node))
          event.preventDefault();
      }}
      onKeyDown={(event) => {
        if (consumedKey(event)) return;
        if (event.key === 'Enter' && event.repeat) {
          event.preventDefault();
          return;
        }
        if (
          event.key === 'Escape' &&
          !event.repeat &&
          !document.querySelector(
            '[role="dialog"], [role="menu"], [role="listbox"]:not(#launcher-results)',
          )
        ) {
          event.preventDefault();
          if (settings) void api('launcher.show', { destination: 'apps' }).catch(report);
          else hide();
        }
      }}
    >
      {entry.destination === 'files' ? (
        <FileShelf />
      ) : settings ? (
        <ShelfSettings
          key={entry.revision}
          initialTab={entry.destination === 'about' ? 'about' : 'general'}
        />
      ) : entry.destination === 'emoji' ? (
        <EmojiPicker
          key={entry.revision}
          initialContext={context?.destination === 'emoji' ? context : undefined}
          onContextChange={saveContext}
          onBack={() =>
            void api('launcher.show', { destination: 'apps' }).catch((error) =>
              setError(errorMessage(error)),
            )
          }
        />
      ) : builtin ? (
        <ClipboardHistory
          key={entry.revision}
          initialQuery={entry.searchQuery}
          initialContext={context?.destination === 'clipboard' ? context : undefined}
          onContextChange={saveContext}
          onBack={() =>
            void api('launcher.show', { destination: 'apps' }).catch((error) =>
              setError(errorMessage(error)),
            )
          }
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
                if (consumedKey(event)) return;
                if (event.key === 'Enter' && launchPending.current) {
                  event.preventDefault();
                  return;
                }
                const number = numberShortcut(event);
                if (number !== undefined) {
                  if (
                    event.defaultPrevented ||
                    document.querySelector(
                      '[role="dialog"], [role="menu"], [role="listbox"]:not(#launcher-results)',
                    )
                  )
                    return;
                  event.preventDefault();
                  const result = results[number];
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
                  if (!event.repeat && !event.metaKey && !event.ctrlKey && !event.altKey)
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
          <div className="launcher-scroll">
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
                {calculation.status === 'incomplete'
                  ? calculation.message || 'Продолжите выражение…'
                  : calculation.message}
              </div>
            )}
            <span className="sr-only" role="status">
              {copied === selection?.id ? 'Результат скопирован' : ''}
            </span>
            {(error || catalog.error || macError) && (
              <Alert color="red" mx="sm" mt="sm">
                {error || catalog.error || macError}
                <Button
                  variant="subtle"
                  onClick={() => {
                    setError('');
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
                    {result.kind !== 'more-clips' &&
                      result.kind !== results[position - 1]?.kind && (
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
