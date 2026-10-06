import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type KeyboardEvent,
} from 'react';
import { IconArrowLeft, IconLayoutGrid, IconSearch, IconX } from '@tabler/icons-react';
import { ActionIcon, Alert, TextInput, Tooltip } from './NativeControls';
import {
  EMOJI_CATEGORIES,
  EMOJI_TONES,
  emojiGridIndex,
  emojiResults,
  type Emoji,
} from '../../shared/emoji';
import type { ClipboardState } from '../../shared/clipboard';
import { api, errorMessage } from './api';
import ClipboardPasteHint from './ClipboardPasteHint';
import type { EmojiContext } from './shelf-context';
import { consumedKey, editingTarget, numberShortcut } from './shelf-keyboard';
import './emoji.css';

export default function EmojiPicker({
  onBack,
  initialContext,
  onContextChange,
}: {
  onBack: () => void;
  initialContext?: EmojiContext;
  onContextChange: (context: EmojiContext) => void;
}) {
  const [query, setQuery] = useState(initialContext?.query ?? '');
  const [category, setCategory] = useState(initialContext?.category ?? 'all');
  const [tone, setTone] = useState(initialContext?.tone ?? 'default');
  const [selected, setSelected] = useState<string | undefined>(initialContext?.selected);
  const [columns, setColumns] = useState(initialContext?.columns ?? 10);
  const [state, setState] = useState<ClipboardState>();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const pending = useRef(false);
  const input = useRef<HTMLInputElement>(null);
  const grid = useRef<HTMLDivElement>(null);
  const request = useRef(0);
  const alive = useRef(true);
  const scrollTop = useRef(initialContext?.scrollTop ?? 0);
  const skipInitialScroll = useRef(!!initialContext);
  const contextMounted = useRef(false);
  const context = useRef<EmojiContext>({
    destination: 'emoji',
    query,
    category,
    tone,
    columns,
    scrollTop: scrollTop.current,
  });
  useLayoutEffect(() => {
    if (contextMounted.current && grid.current) scrollTop.current = grid.current.scrollTop;
    contextMounted.current = true;
    context.current = {
      destination: 'emoji',
      query,
      selected,
      category,
      tone,
      columns,
      scrollTop: scrollTop.current,
    };
    onContextChange(context.current);
  });
  useLayoutEffect(() => {
    if (grid.current) grid.current.scrollTop = scrollTop.current;
  }, []);
  const results = emojiResults(query, category, tone);
  const index = Math.max(
    0,
    results.findIndex((emoji) => emoji.id === selected),
  );
  const selection = results[index];
  const canPaste =
    !!state?.preferences.pasteOnSelect && state.pasteAccess === 'granted' && state.pasteReady;
  const rows = Array.from({ length: Math.ceil(results.length / columns) }, (_, row) =>
    results.slice(row * columns, (row + 1) * columns),
  );
  const refresh = useCallback(async () => {
    const token = ++request.current;
    try {
      const next = await api<ClipboardState>('clipboardHistory.state');
      if (token === request.current) setState(next);
    } catch (reason) {
      if (token === request.current) setError(errorMessage(reason));
    }
  }, []);
  useEffect(() => {
    alive.current = true;
    void refresh();
    const unsubscribe = window.platform.onEvent((event) => {
      if (event.type === 'clipboardHistory.changed') void refresh();
    });
    return () => {
      alive.current = false;
      request.current++;
      unsubscribe();
    };
  }, [refresh]);
  useEffect(() => {
    const element = grid.current;
    if (!element) return;
    const observer = new ResizeObserver(([entry]) => {
      setColumns(Math.max(4, Math.min(10, Math.floor(entry.contentRect.width / 48))));
    });
    observer.observe(element);
    return () => observer.disconnect();
  }, []);
  useEffect(() => {
    if (skipInitialScroll.current) {
      skipInitialScroll.current = false;
      return;
    }
    document.getElementById(`emoji-${selection?.id}`)?.scrollIntoView({ block: 'nearest' });
  }, [selection?.id, columns]);
  async function run(method: string, params = {}) {
    if (pending.current) return;
    pending.current = true;
    setBusy(true);
    setError('');
    try {
      await api(method, params);
      if (!alive.current) return;
      await refresh();
    } catch (reason) {
      if (!alive.current) return;
      setError(errorMessage(reason));
      input.current?.focus();
    } finally {
      pending.current = false;
      setBusy(false);
    }
  }
  function choose(emoji: Emoji, copyOnly = false) {
    return run(copyOnly ? 'shelf.copyEmoji' : 'shelf.selectEmoji', { id: emoji.id });
  }
  function navigate(event: KeyboardEvent, fromSearch = false) {
    if (consumedKey(event) || event.metaKey || event.ctrlKey || event.altKey) return;
    if (event.key.startsWith('Arrow') || (!fromSearch && ['Home', 'End'].includes(event.key))) {
      if (fromSearch && (event.key === 'ArrowLeft' || event.key === 'ArrowRight')) return;
      event.preventDefault();
      const next =
        results[fromSearch ? index : emojiGridIndex(index, event.key, results.length, columns)];
      if (next) {
        setSelected(next.id);
        document.getElementById(`emoji-${next.id}`)?.focus();
      }
    }
    if (event.key === 'Enter' && selection) {
      event.preventDefault();
      if (!event.repeat) void choose(selection, event.shiftKey);
    }
  }
  return (
    <section
      className="clipboard-app emoji-picker"
      aria-label="Эмодзи"
      onKeyDown={(event) => {
        if (consumedKey(event)) return;
        if (document.querySelector('[role="dialog"], [role="menu"], [role="listbox"]')) return;
        const target = event.target as HTMLElement;
        // A native select owns dismissal of its popup and must retain normal keys.
        if (target.closest('select')) {
          event.stopPropagation();
          return;
        }
        if (busy) {
          if (
            ['Enter', 'Escape', 'Backspace'].includes(event.key) ||
            numberShortcut(event) !== undefined
          )
            event.preventDefault();
          return;
        }
        const number = numberShortcut(event);
        if (number !== undefined) {
          event.preventDefault();
          if (!event.repeat && results[number]) void choose(results[number]);
          return;
        }
        if (
          event.key === 'Enter' &&
          event.shiftKey &&
          !event.metaKey &&
          !event.ctrlKey &&
          !event.altKey
        ) {
          event.preventDefault();
          if (!event.repeat && selection) void choose(selection, true);
          return;
        }
        if (event.key === 'Escape') {
          event.preventDefault();
          if (!event.repeat)
            void api('launcher.hide').catch((reason) => setError(errorMessage(reason)));
        }
        if (
          event.key === 'Backspace' &&
          !event.repeat &&
          !event.metaKey &&
          !event.ctrlKey &&
          !event.altKey &&
          !busy
        ) {
          if (!editingTarget(target) || (target === input.current && !query)) {
            event.preventDefault();
            onBack();
          }
        }
      }}
    >
      <header className="clipboard-header">
        <div className="clipboard-app-heading">
          <Tooltip label="Назад к приложениям · ⌫">
            <ActionIcon
              aria-label="Назад к приложениям"
              variant="subtle"
              onClick={onBack}
              disabled={busy}
            >
              <IconArrowLeft size={18} />
            </ActionIcon>
          </Tooltip>
          <h1>Эмодзи</h1>
        </div>
        <span className="clipboard-header-actions emoji-language-hint">Русский / English</span>
      </header>
      <div className="clipboard-search">
        <TextInput
          ref={input}
          autoFocus
          aria-label="Найти эмодзи"
          placeholder="Название или слово: улыбка, heart…"
          maxLength={256}
          leftSection={<IconSearch size={17} />}
          rightSection={
            query && (
              <ActionIcon
                variant="subtle"
                aria-label="Очистить поиск"
                onClick={() => {
                  setQuery('');
                  setSelected(undefined);
                  input.current?.focus();
                }}
              >
                <IconX size={14} />
              </ActionIcon>
            )
          }
          value={query}
          onChange={(event) => {
            setQuery(event.currentTarget.value);
            setCategory('all');
            setSelected(undefined);
          }}
          role="combobox"
          aria-haspopup="grid"
          aria-expanded="true"
          aria-controls="emoji-results"
          aria-autocomplete="list"
          aria-activedescendant={selection ? `emoji-${selection.id}` : undefined}
          onKeyDown={(event) => navigate(event, true)}
        />
      </div>
      <div className="emoji-tools">
        <div className="emoji-categories" role="tablist" aria-label="Категории эмодзи">
          {EMOJI_CATEGORIES.map((item, position) => (
            <button
              key={item.id}
              type="button"
              role="tab"
              id={`emoji-category-${position}`}
              aria-label={item.label}
              title={item.label}
              aria-selected={category === item.id}
              aria-controls="emoji-category-panel"
              tabIndex={category === item.id ? 0 : -1}
              onClick={() => {
                setCategory(item.id);
                setSelected(undefined);
              }}
              onKeyDown={(event) => {
                if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
                event.preventDefault();
                const next =
                  event.key === 'Home'
                    ? 0
                    : event.key === 'End'
                      ? EMOJI_CATEGORIES.length - 1
                      : (position +
                          (event.key === 'ArrowRight' ? 1 : -1) +
                          EMOJI_CATEGORIES.length) %
                        EMOJI_CATEGORIES.length;
                setCategory(EMOJI_CATEGORIES[next].id);
                setSelected(undefined);
                document.getElementById(`emoji-category-${next}`)?.focus();
              }}
            >
              <span aria-hidden="true">
                {item.id === 'all' ? <IconLayoutGrid size={17} /> : item.symbol}
              </span>
            </button>
          ))}
        </div>
        <select
          aria-label="Оттенок кожи"
          title="Оттенок кожи"
          className="emoji-tone"
          value={tone}
          onChange={(event) => {
            setTone(event.currentTarget.value);
            setSelected(undefined);
          }}
        >
          {EMOJI_TONES.map((item) => (
            <option key={item.value} value={item.value}>
              {item.value.length === 2 ? `${item.value} ` : ''}
              {item.label}
            </option>
          ))}
        </select>
      </div>
      <ClipboardPasteHint
        state={state}
        busy={busy}
        item="Эмодзи"
        onRequestAccess={() => void run('clipboardHistory.requestPasteAccess')}
      />
      {error && (
        <Alert className="clipboard-error" color="red">
          {error}
        </Alert>
      )}
      <div
        id="emoji-category-panel"
        className="emoji-category-panel"
        role="tabpanel"
        aria-labelledby={`emoji-category-${EMOJI_CATEGORIES.findIndex((item) => item.id === category)}`}
      >
        <div className="emoji-results-heading">
          <span>
            {query.trim()
              ? 'Результаты поиска'
              : EMOJI_CATEGORIES.find((item) => item.id === category)?.label}
          </span>
          <span role="status" aria-live="polite">
            {results.length}
          </span>
        </div>
        <div
          ref={grid}
          id="emoji-results"
          className="emoji-results"
          role="grid"
          aria-label="Эмодзи для вставки"
          aria-rowcount={rows.length}
          aria-colcount={columns}
          aria-busy={busy}
          onKeyDown={(event) => navigate(event)}
          onScroll={(event) => {
            scrollTop.current = event.currentTarget.scrollTop;
            onContextChange({ ...context.current, scrollTop: scrollTop.current });
          }}
        >
          {rows.map((row, rowIndex) => (
            <div
              key={rowIndex}
              className="emoji-row"
              role="row"
              aria-rowindex={rowIndex + 1}
              style={{ gridTemplateColumns: `repeat(${columns}, minmax(0, 1fr))` }}
            >
              {row.map((emoji, column) => (
                <button
                  key={emoji.id}
                  type="button"
                  id={`emoji-${emoji.id}`}
                  className="emoji-cell"
                  role="gridcell"
                  aria-colindex={column + 1}
                  aria-label={`${emoji.name} · ${emoji.englishName}`}
                  aria-selected={selection?.id === emoji.id}
                  aria-keyshortcuts={
                    rowIndex * columns + column < 9
                      ? `Meta+${rowIndex * columns + column + 1}`
                      : undefined
                  }
                  title={emoji.name}
                  tabIndex={selection?.id === emoji.id ? 0 : -1}
                  disabled={busy}
                  onFocus={() => setSelected(emoji.id)}
                  onMouseMove={() => {
                    if (!grid.current?.contains(document.activeElement)) setSelected(emoji.id);
                  }}
                  onClick={() => void choose(emoji)}
                >
                  <span aria-hidden="true">{emoji.value}</span>
                  {rowIndex * columns + column < 9 && (
                    <kbd aria-hidden="true">⌘{rowIndex * columns + column + 1}</kbd>
                  )}
                </button>
              ))}
            </div>
          ))}
        </div>
        {!results.length && (
          <div className="clipboard-empty emoji-empty" role="status">
            <IconSearch size={30} stroke={1.3} aria-hidden="true" />
            <strong>Ничего не найдено</strong>
            <p>Попробуйте другое слово на русском или английском.</p>
            {(category !== 'all' || tone !== 'default') && (
              <button
                type="button"
                className="native-button"
                onClick={() => {
                  setCategory('all');
                  setTone('all');
                  input.current?.focus();
                }}
              >
                Искать во всех категориях и оттенках
              </button>
            )}
          </div>
        )}
      </div>
      <div className="emoji-selection" aria-live="polite" aria-atomic="true">
        <span className="emoji-selection-glyph" aria-hidden="true">
          {selection?.value || '⌕'}
        </span>
        <span className="emoji-selection-name">
          <strong>{selection?.name || 'Выберите эмодзи'}</strong>
          <span>{selection?.englishName || 'Поиск по названиям и ключевым словам'}</span>
        </span>
        <button
          type="button"
          className="emoji-copy-only"
          title="Копировать без вставки · ⇧↵"
          disabled={!selection || busy}
          onClick={() => selection && void choose(selection, true)}
        >
          Копировать
        </button>
      </div>
      <footer className="clipboard-footer emoji-footer">
        <div className="clipboard-shortcuts">
          <span>
            <kbd>↑ ↓ ← →</kbd> выбрать
          </span>
          <span>
            <kbd>↵</kbd> {canPaste ? 'вставить' : 'копировать'}
          </span>
          <span>
            <kbd>⇧ ↵</kbd> только копировать
          </span>
          <span>
            <kbd>esc</kbd> закрыть
          </span>
        </div>
      </footer>
    </section>
  );
}
