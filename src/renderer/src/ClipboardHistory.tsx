import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react';
import { ActionIcon, Alert, Button, Group, Loader, TextInput, Tooltip } from './NativeControls';
import {
  IconClipboard,
  IconSearch,
  IconPin,
  IconPinnedOff,
  IconTrash,
  IconDots,
  IconEye,
  IconArrowLeft,
  IconTextSize,
  IconExternalLink,
  IconDownload,
} from '@tabler/icons-react';
import { clipboardResults, type ClipboardState, type ClipboardClip } from '../../shared/clipboard';
import {
  clipboardWebUrl,
  TEXT_TRANSFORMATIONS,
  TEXT_TRANSFORMATION_LABELS,
  transformClipboardText,
  type TextTransformation,
} from '../../shared/clipboard-actions';
import { api, errorMessage } from './api';
import ClipboardPasteHint from './ClipboardPasteHint';
import { clipboardSnippet } from '../../shared/shelf-search';
import type { ClipboardContext } from './shelf-context';
import { consumedKey, editingTarget, numberShortcut } from './shelf-keyboard';
import ClipboardStorageFailure from './ClipboardStorageFailure';

type PreviewAction = {
  id: string;
  label: string;
  disabled: boolean;
  title?: string;
  pressed?: boolean;
  run: () => void;
};

function clipDate(timestamp: number) {
  const date = new Date(timestamp);
  const today = new Date();
  const yesterday = new Date(today);
  yesterday.setDate(today.getDate() - 1);
  const day =
    date.toDateString() === today.toDateString()
      ? 'Сегодня'
      : date.toDateString() === yesterday.toDateString()
        ? 'Вчера'
        : date.toLocaleDateString('ru', { day: 'numeric', month: 'short' });
  return `${day}, ${date.toLocaleTimeString('ru', { hour: '2-digit', minute: '2-digit' })}`;
}

function ClipboardPreview({
  clip,
  text,
  scrollTop,
}: {
  clip: ClipboardClip;
  text?: string;
  scrollTop: number;
}) {
  const [image, setImage] = useState('');
  const [imageReady, setImageReady] = useState(false);
  const [error, setError] = useState('');
  const [attempt, setAttempt] = useState(0);
  const content = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    if (content.current) content.current.scrollTop = scrollTop;
  }, [clip.id, text, image]);
  useEffect(() => {
    if (clip.kind !== 'image') return;
    let cancelled = false;
    setImage('');
    setImageReady(false);
    setError('');
    void api<string>('clipboardHistory.preview', { id: clip.id })
      .then((result) => {
        if (!cancelled) setImage(result);
      })
      .catch((reason) => {
        if (!cancelled) setError(errorMessage(reason));
      });
    return () => {
      cancelled = true;
    };
  }, [clip.id, clip.kind, attempt]);
  return (
    <div
      className="clipboard-preview-content"
      ref={content}
      aria-busy={clip.kind === 'image' && !imageReady && !error}
    >
      {clip.kind === 'text' ? (
        <pre>{text ?? clip.content}</pre>
      ) : error ? (
        <div className="clipboard-empty" role="alert">
          <p>{error}</p>
          <Button variant="subtle" color="gray" onClick={() => setAttempt(attempt + 1)}>
            Повторить
          </Button>
        </div>
      ) : image ? (
        <img
          className="clipboard-preview-image"
          src={image}
          alt="Просмотр скопированного изображения"
          onLoad={() => {
            if (content.current) content.current.scrollTop = scrollTop;
            setImageReady(true);
          }}
        />
      ) : (
        <Loader size="sm" color="gray" />
      )}
      {clip.kind === 'image' && (
        <section className="clipboard-image-text" aria-label="Распознанный текст">
          <h2>Текст на изображении</h2>
          {!clip.ocr ? (
            <p role="status">Распознаём текст на этом Mac… Изображение уже можно копировать.</p>
          ) : clip.ocr.status === 'failed' ? (
            <p role="status">Не удалось распознать текст. Повторите распознавание.</p>
          ) : clip.ocr.status === 'empty' ? (
            <p role="status">Текст на изображении не найден.</p>
          ) : (
            <pre tabIndex={0} aria-label="Распознанный текст">
              {clip.ocr.text}
            </pre>
          )}
          {clip.ocr && clip.ocr.status !== 'failed' && !clip.ocr.languages.includes('ru-RU') && (
            <p>Эта версия macOS не поддерживает распознавание русского текста.</p>
          )}
        </section>
      )}
    </div>
  );
}

export default function ClipboardHistory({
  onBack,
  initialQuery = '',
  initialContext,
  onContextChange,
}: {
  onBack: () => void;
  initialQuery?: string;
  initialContext?: ClipboardContext;
  onContextChange: (context: ClipboardContext) => void;
}) {
  const [state, setState] = useState<ClipboardState | undefined>(
    initialContext?.state ? { ...initialContext.state, pasteReady: false } : undefined,
  );
  const [query, setQuery] = useState(initialContext?.query ?? initialQuery);
  const [selected, setSelected] = useState<string | undefined>(initialContext?.selected);
  const writable = !!state && (!state.storage || state.storage.status === 'ready');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [confirmClear, setConfirmClear] = useState(false);
  const [previewId, setPreviewId] = useState<string | undefined>(initialContext?.previewId);
  const [transformation, setTransformation] = useState<TextTransformation | undefined>(
    initialContext?.transformation,
  );
  const [notice, setNotice] = useState('');
  const [menuOpen, setMenuOpen] = useState(false);
  const input = useRef<HTMLInputElement>(null);
  const request = useRef(0);
  const pending = useRef(false);
  const alive = useRef(true);
  const restoreFocus = useRef<HTMLElement | undefined>(undefined);
  const root = useRef<HTMLElement>(null);
  const contextMounted = useRef(false);
  const list = useRef<HTMLDivElement>(null);
  const scroll = useRef({
    list: initialContext?.scrollTop ?? 0,
    preview: initialContext?.previewScrollTop ?? 0,
  });
  const skipInitialScroll = useRef(!!initialContext);
  const results = clipboardResults(state?.clips || [], query);
  const index = Math.max(
    0,
    results.findIndex((clip) => clip.id === selected),
  );
  const selection = results[index];
  const canPaste =
    !!state?.preferences.pasteOnSelect && state.pasteAccess === 'granted' && state.pasteReady;
  const preview = state?.clips.find((clip) => clip.id === previewId);
  const previewText =
    preview?.kind === 'text'
      ? transformation
        ? transformClipboardText(preview.content, transformation)
        : preview.content
      : undefined;
  const previewActions: PreviewAction[] = !preview
    ? []
    : preview.kind === 'text'
      ? [
          ...TEXT_TRANSFORMATIONS.map((action) => {
            const unchanged = transformClipboardText(preview.content, action) === preview.content;
            return {
              id: action,
              label: TEXT_TRANSFORMATION_LABELS[action],
              disabled: busy || unchanged,
              title: unchanged ? 'Исходный текст уже в этом виде' : undefined,
              pressed: transformation === action,
              run: () => setTransformation(action),
            };
          }),
          ...(transformation
            ? [
                {
                  id: 'original',
                  label: 'Показать оригинал',
                  disabled: busy,
                  run: () => {
                    setTransformation(undefined);
                    requestAnimationFrame(() =>
                      document.querySelector<HTMLButtonElement>('.clipboard-back')?.focus(),
                    );
                  },
                },
              ]
            : []),
        ]
      : [
          {
            id: 'saveImage',
            label: 'Сохранить изображение…',
            disabled: busy,
            run: () => {
              void run('saveImage', { id: preview.id });
            },
          },
          ...(preview.ocr?.status === 'ready'
            ? [
                {
                  id: 'copyImageText',
                  label: 'Копировать текст',
                  disabled: busy,
                  run: () => {
                    void run('copyImageText', { id: preview.id });
                  },
                },
              ]
            : preview.ocr?.status === 'failed'
              ? [
                  {
                    id: 'retryImageText',
                    label: 'Повторить распознавание',
                    disabled: busy || !writable,
                    run: () => {
                      void run('retryImageText', { id: preview.id });
                    },
                  },
                ]
              : []),
        ];
  const originalActionIndex = previewActions.findIndex((action) => action.id === 'original');
  useLayoutEffect(() => {
    if (busy) return;
    const target = restoreFocus.current;
    restoreFocus.current = undefined;
    // A disabled button loses focus. Restore it only after React has committed
    // the enabled control, without replacing a focus choice made by the user.
    if (target?.isConnected && document.activeElement === document.body) target.focus();
  }, [busy]);
  const context = useRef<ClipboardContext>({
    destination: 'clipboard',
    query,
    scrollTop: 0,
    previewScrollTop: 0,
  });
  useLayoutEffect(() => {
    // Also sample on dismissal; the browser may not have emitted its scroll event yet.
    if (contextMounted.current) {
      if (list.current) scroll.current.list = list.current.scrollTop;
      const content = root.current?.querySelector<HTMLElement>('.clipboard-preview-content');
      if (content && content.getAttribute('aria-busy') !== 'true')
        scroll.current.preview = content.scrollTop;
    }
    contextMounted.current = true;
    context.current = {
      destination: 'clipboard',
      query,
      selected,
      previewId,
      transformation,
      scrollTop: scroll.current.list,
      previewScrollTop: scroll.current.preview,
      state,
    };
    onContextChange(context.current);
  });
  useLayoutEffect(() => {
    if (list.current) list.current.scrollTop = scroll.current.list;
  }, [preview?.id, confirmClear, !!state]);
  function openPreview(id: string) {
    scroll.current.preview = 0;
    setSelected(id);
    setTransformation(undefined);
    setNotice('');
    setError('');
    setPreviewId(id);
  }
  function closeConfirmation() {
    setConfirmClear(false);
    requestAnimationFrame(() => input.current?.focus());
  }
  function closePreview() {
    setPreviewId(undefined);
    requestAnimationFrame(() => input.current?.focus());
  }
  function goBack() {
    if (confirmClear) closeConfirmation();
    else if (preview) closePreview();
    else onBack();
  }
  useLayoutEffect(() => {
    if (preview) document.querySelector<HTMLButtonElement>('.clipboard-back')?.focus();
  }, [preview?.id]);
  const refresh = useCallback(async () => {
    const token = ++request.current;
    try {
      const next = await api<ClipboardState>('clipboardHistory.state');
      if (token === request.current) {
        setState(next);
        setSelected((id) => (next.clips.some((clip) => clip.id === id) ? id : undefined));
        setPreviewId((id) => (next.clips.some((clip) => clip.id === id) ? id : undefined));
      }
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
    if (skipInitialScroll.current) {
      skipInitialScroll.current = false;
      return;
    }
    document.getElementById(`clip-${selection?.id}`)?.scrollIntoView({ block: 'nearest' });
  }, [selection?.id, previewId, confirmClear]);
  async function run(method: string, params = {}) {
    if (pending.current) return;
    const focusedBefore = document.activeElement;
    pending.current = true;
    setBusy(true);
    setError('');
    setNotice('');
    try {
      const result = await api(`clipboardHistory.${method}`, params);
      if (!alive.current) return false;
      if (method === 'saveImage' && result === 'saved') setNotice('Изображение сохранено');
      await refresh();
      return true;
    } catch (reason) {
      if (!alive.current) return false;
      setError(
        errorMessage(reason).replace(/^Error invoking remote method 'platform:call': Error: /, ''),
      );
    } finally {
      pending.current = false;
      if (method === 'saveImage' && alive.current && focusedBefore instanceof HTMLElement)
        restoreFocus.current = focusedBefore;
      setBusy(false);
    }
  }
  return (
    <section
      className="clipboard-app"
      ref={root}
      onScrollCapture={(event) => {
        const target = event.target as HTMLElement;
        if (target.id === 'clipboard-results') scroll.current.list = target.scrollTop;
        else if (target.classList.contains('clipboard-preview-content'))
          scroll.current.preview = target.scrollTop;
        else return;
        onContextChange({
          ...context.current,
          scrollTop: scroll.current.list,
          previewScrollTop: scroll.current.preview,
        });
      }}
      aria-label="История буфера обмена"
      onKeyDown={(event) => {
        if (consumedKey(event)) return;
        if (
          document.querySelector(
            '[role="dialog"], [role="menu"], [role="listbox"]:not(#clipboard-results)',
          )
        )
          return;
        if (busy) {
          if (
            ['Enter', 'Escape', 'Backspace'].includes(event.key) ||
            numberShortcut(event) !== undefined
          )
            event.preventDefault();
          return;
        }
        if (
          event.key === 'Enter' &&
          event.shiftKey &&
          !event.metaKey &&
          !event.ctrlKey &&
          !event.altKey &&
          !confirmClear &&
          !menuOpen
        ) {
          event.preventDefault();
          const clip = preview ?? selection;
          if (clip && !event.repeat)
            void run('copy', { id: clip.id, transformation: preview ? transformation : undefined });
          return;
        }
        const actionNumber = /^Digit[1-9]$/.test(event.code) ? event.code.slice(-1) : event.key;
        const number = numberShortcut(event);
        if (number !== undefined && !preview && !confirmClear && !menuOpen) {
          event.preventDefault();
          const clip = results[number];
          if (clip && !event.repeat) void run('select', { id: clip.id });
          return;
        }
        if (
          !preview &&
          !confirmClear &&
          !menuOpen &&
          !busy &&
          !event.nativeEvent.isComposing &&
          !event.defaultPrevented &&
          event.metaKey &&
          event.altKey &&
          !event.ctrlKey &&
          !event.shiftKey &&
          /^[1-9]$/.test(actionNumber) &&
          !document.querySelector(
            '[role="dialog"], [role="menu"], [role="listbox"]:not(#clipboard-results)',
          )
        ) {
          event.preventDefault();
          const clip = results[Number(actionNumber) - 1];
          if (clip && !event.repeat) {
            if (clip.kind === 'image') void run('saveImage', { id: clip.id });
            else if (clipboardWebUrl(clip.content)) void run('openUrl', { id: clip.id });
          }
          return;
        }
        if (
          preview &&
          !confirmClear &&
          !menuOpen &&
          !busy &&
          !event.nativeEvent.isComposing &&
          !event.defaultPrevented &&
          event.metaKey &&
          !event.ctrlKey &&
          !event.altKey &&
          !event.shiftKey &&
          /^[1-9]$/.test(event.key) &&
          !document.querySelector('[role="dialog"], [role="menu"]')
        ) {
          event.preventDefault();
          const action = previewActions[Number(event.key) - 1];
          if (action && !action.disabled && !event.repeat) action.run();
          return;
        }
        if (
          event.key === 'Backspace' &&
          !event.repeat &&
          !event.nativeEvent.isComposing &&
          !event.defaultPrevented &&
          !event.metaKey &&
          !event.ctrlKey &&
          !event.altKey &&
          !menuOpen &&
          !busy
        ) {
          const target = event.target as HTMLElement;
          const editing = editingTarget(target);
          if (!editing || (target === input.current && query.length === 0)) {
            event.preventDefault();
            if (confirmClear) closeConfirmation();
            else if (preview) closePreview();
            else onBack();
            return;
          }
        }
        if (event.key === 'Escape' && !event.repeat) {
          event.preventDefault();
          if (menuOpen) setMenuOpen(false);
          else if (confirmClear) closeConfirmation();
          else if (preview) closePreview();
          else void run('hide');
        }
      }}
    >
      <header className="clipboard-header">
        <div className="clipboard-app-heading">
          <Tooltip
            label={`${preview || confirmClear ? 'Назад к списку' : 'Назад к приложениям'} · ⌫`}
          >
            <ActionIcon
              className="clipboard-back"
              aria-label={preview || confirmClear ? 'Назад к списку' : 'Назад к приложениям'}
              variant="subtle"
              onClick={goBack}
              disabled={busy}
            >
              <IconArrowLeft size={18} />
            </ActionIcon>
          </Tooltip>
          <div className="clipboard-heading">
            <h1>Буфер обмена</h1>
            {state?.storage?.status === 'failed' ? (
              <span>{state.preferencesAvailable ? 'Только чтение' : 'Недоступна'}</span>
            ) : (
              state?.preferences.paused && <span>Запись на паузе</span>
            )}
          </div>
        </div>
        <div className="clipboard-header-actions">
          <div
            className="native-history-menu"
            onBlur={(event) => {
              if (!event.currentTarget.contains(event.relatedTarget)) setMenuOpen(false);
            }}
            onKeyDown={(event) => {
              if (consumedKey(event)) return;
              if (event.key === 'Escape' && menuOpen) {
                event.preventDefault();
                event.stopPropagation();
                setMenuOpen(false);
                event.currentTarget.querySelector<HTMLButtonElement>(':scope > button')?.focus();
              }
            }}
          >
            <ActionIcon
              variant="subtle"
              aria-label="Действия с историей"
              aria-expanded={menuOpen}
              onClick={() => setMenuOpen(!menuOpen)}
            >
              <IconDots size={18} />
            </ActionIcon>
            {menuOpen && (
              <div className="clipboard-menu" role="group" aria-label="Действия с историей">
                <Button
                  variant="subtle"
                  disabled={!selection || busy}
                  onClick={() => {
                    setMenuOpen(false);
                    if (selection)
                      void run('copy', {
                        id: preview?.id ?? selection.id,
                        transformation: preview ? transformation : undefined,
                      });
                  }}
                >
                  Копировать без вставки · ⇧↵
                </Button>
                <Button
                  variant="subtle"
                  color="red"
                  disabled={!writable || !state?.clips.length || busy}
                  onClick={() => {
                    setMenuOpen(false);
                    setPreviewId(undefined);
                    setConfirmClear(true);
                  }}
                >
                  Очистить историю на всех связанных Mac…
                </Button>
              </div>
            )}
          </div>
        </div>
      </header>
      {!preview && !confirmClear && (
        <div className="clipboard-search">
          <TextInput
            ref={input}
            autoFocus
            aria-label="Найти в истории"
            placeholder="Найти текст, в том числе на изображениях…"
            leftSection={<IconSearch size={17} />}
            value={query}
            onChange={(event) => {
              setQuery(event.currentTarget.value);
              setSelected(undefined);
            }}
            role="combobox"
            aria-expanded="true"
            aria-controls="clipboard-results"
            aria-autocomplete="list"
            aria-activedescendant={selection ? `clip-${selection.id}` : undefined}
            onKeyDown={(event) => {
              if (consumedKey(event)) return;
              if (event.key === 'Enter' && (busy || menuOpen)) {
                event.preventDefault();
                return;
              }
              if (
                event.metaKey &&
                !event.ctrlKey &&
                !event.altKey &&
                !event.shiftKey &&
                /^[1-9]$/.test(event.key)
              ) {
                if (
                  event.defaultPrevented ||
                  menuOpen ||
                  document.querySelector(
                    '[role="dialog"], [role="menu"], [role="listbox"]:not(#clipboard-results)',
                  )
                )
                  return;
                event.preventDefault();
                const clip = results[Number(event.key) - 1];
                if (clip && !event.repeat) void run('select', { id: clip.id });
                return;
              }
              if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
                event.preventDefault();
                const next =
                  results[
                    Math.max(
                      0,
                      Math.min(results.length - 1, index + (event.key === 'ArrowDown' ? 1 : -1)),
                    )
                  ];
                setSelected(next?.id);
              }
              if (event.key === 'Enter' && selection) {
                event.preventDefault();
                if (event.repeat || event.ctrlKey || event.altKey) return;
                if (event.metaKey && !event.shiftKey) openPreview(selection.id);
                else void run(event.shiftKey ? 'copy' : 'select', { id: selection.id });
              }
            }}
          />
        </div>
      )}
      <ClipboardPasteHint
        state={state}
        busy={busy}
        onRequestAccess={() => void run('requestPasteAccess')}
      />
      <ClipboardStorageFailure
        storage={state?.storage}
        store="history"
        readable={state?.preferencesAvailable}
      />
      {state?.helper?.status === 'failed' && (
        <Alert className="clipboard-error" color="red">
          {state.helper.error}
        </Alert>
      )}
      {(error || state?.error) && (
        <Alert className="clipboard-error" color="red">
          {error || state?.error}
        </Alert>
      )}
      {notice && (
        <p className="clipboard-action-notice" role="status">
          {notice}
        </p>
      )}
      {confirmClear ? (
        <div className="clipboard-confirm">
          <h2>Удалить историю на всех связанных Mac?</h2>
          <p>
            Закреплённые записи тоже будут удалены. Удаление передастся связанным Mac, в том числе
            после их подключения. Текущий буфер обмена останется на месте.
          </p>
          <Group>
            <Button
              className="clipboard-delete-confirm"
              disabled={!writable}
              loading={busy}
              onClick={() =>
                void run('clear').then((ok) => {
                  if (ok) closeConfirmation();
                })
              }
            >
              Удалить на всех связанных Mac
            </Button>
            <Button variant="default" onClick={closeConfirmation} autoFocus>
              Отмена
            </Button>
          </Group>
        </div>
      ) : preview ? (
        <section
          className="clipboard-preview"
          aria-label="Просмотр записи"
          onKeyDown={(event) => {
            if (
              event.key === 'Enter' &&
              event.shiftKey &&
              !consumedKey(event) &&
              !event.metaKey &&
              !event.ctrlKey &&
              !event.altKey
            ) {
              event.preventDefault();
              if (!event.repeat) void run('copy', { id: preview.id, transformation });
            }
          }}
        >
          <div className="clipboard-preview-toolbar">
            <span>{clipDate(preview.createdAt)}</span>
            {canPaste && (
              <Button
                size="compact-sm"
                variant="subtle"
                disabled={busy}
                onClick={() => void run('copy', { id: preview.id, transformation })}
              >
                Копировать
              </Button>
            )}
            <Button
              size="compact-sm"
              variant="default"
              disabled={busy}
              onClick={() => void run('select', { id: preview.id, transformation })}
            >
              {canPaste ? 'Вставить' : 'Копировать'}
            </Button>
          </div>
          <div className="clipboard-context-actions" role="group" aria-label="Действия с записью">
            {previewActions.map((action, position) =>
              action.id === 'original' ? null : (
                <Button
                  key={action.id}
                  size="compact-sm"
                  variant="default"
                  disabled={action.disabled}
                  title={action.title}
                  aria-label={action.label}
                  aria-keyshortcuts={`Meta+${position + 1}`}
                  aria-pressed={action.pressed}
                  onClick={action.run}
                >
                  {action.label}
                  <kbd aria-hidden="true">⌘{position + 1}</kbd>
                </Button>
              ),
            )}
          </div>
          {transformation && (
            <div className="clipboard-transformation-status" role="status">
              <span>
                Результат: {TEXT_TRANSFORMATION_LABELS[transformation]}. Оригинал сохранён.
              </span>
              <Button
                size="compact-sm"
                variant="subtle"
                disabled={busy}
                aria-label="Показать оригинал"
                aria-keyshortcuts={`Meta+${originalActionIndex + 1}`}
                onClick={previewActions[originalActionIndex]?.run}
              >
                Показать оригинал<kbd aria-hidden="true">⌘{originalActionIndex + 1}</kbd>
              </Button>
            </div>
          )}
          <ClipboardPreview
            key={preview.id}
            clip={preview}
            text={previewText}
            scrollTop={scroll.current.preview}
          />
        </section>
      ) : (
        <div
          className="clipboard-results"
          ref={list}
          id="clipboard-results"
          role="listbox"
          aria-label="Скопированные записи"
          aria-busy={busy}
        >
          {!state ? (
            <div className="clipboard-empty">
              <Loader size="sm" color="gray" />
            </div>
          ) : state.storage?.status === 'starting' ? (
            <div className="clipboard-empty">
              <Loader size="sm" color="gray" />
            </div>
          ) : !results.length ? (
            <div className="clipboard-empty">
              <IconClipboard size={36} stroke={1.2} />
              <strong>
                {state.storage?.status === 'failed'
                  ? 'История недоступна'
                  : query
                    ? 'Ничего не найдено'
                    : 'Здесь появится скопированное'}
              </strong>
              <p>
                {state.storage?.status === 'failed'
                  ? 'Восстановите доступ к хранилищу и перезапустите Полку.'
                  : query
                    ? 'Попробуйте другое слово.'
                    : state.preferences.paused
                      ? 'Включите сохранение буфера обмена в настройках приложения.'
                      : 'Скопируйте текст или изображение в любой программе. Выберите запись, чтобы вставить её в предыдущее поле или скопировать снова.'}
              </p>
            </div>
          ) : (
            results.map((clip, position) => (
              <div
                key={clip.id}
                className={`clipboard-row${selection?.id === clip.id ? ' selected' : ''}`}
              >
                <button
                  id={`clip-${clip.id}`}
                  role="option"
                  aria-selected={selection?.id === clip.id}
                  aria-keyshortcuts={position < 9 ? `Meta+${position + 1}` : undefined}
                  className="clipboard-copy"
                  disabled={busy}
                  onFocus={() => setSelected(clip.id)}
                  onClick={() => void run('select', { id: clip.id })}
                  onKeyDown={(event) => {
                    if (consumedKey(event)) return;
                    if (event.key === 'Enter' && event.repeat) {
                      event.preventDefault();
                      return;
                    }
                    if (
                      event.key === 'Enter' &&
                      event.metaKey &&
                      !event.shiftKey &&
                      !event.ctrlKey &&
                      !event.altKey
                    ) {
                      event.preventDefault();
                      openPreview(clip.id);
                    } else if (
                      event.key === 'Enter' &&
                      event.shiftKey &&
                      !event.metaKey &&
                      !event.ctrlKey &&
                      !event.altKey
                    ) {
                      event.preventDefault();
                      void run('copy', { id: clip.id });
                    }
                  }}
                >
                  <span className="clipboard-thumbnail">
                    {clip.kind === 'image' ? (
                      <img src={clip.preview} alt="Скопированное изображение" />
                    ) : (
                      <IconTextSize size={20} stroke={1.5} aria-hidden="true" />
                    )}
                  </span>
                  <span className="clipboard-row-content">
                    <span className="clipboard-text">
                      {clip.kind === 'image'
                        ? query.trim()
                          ? clipboardSnippet(clip, query)
                          : 'Изображение'
                        : clip.preview.trim() || 'Пустой текст'}
                    </span>
                    <span className="clipboard-meta">
                      {clip.pinned && <IconPin size={12} aria-label="Закреплено" />}
                      <span className="clipboard-origin" title={clip.sourceDevice}>
                        {clip.kind === 'image' && query.trim() && 'Изображение · '}
                        {clipDate(clip.createdAt)}
                        {clip.sourceDevice && ` · ${clip.sourceDevice}`}
                      </span>
                    </span>
                  </span>
                </button>
                <div className="clipboard-row-actions">
                  {clip.kind === 'image' && (
                    <Tooltip
                      label={`Сохранить изображение…${position < 9 ? ` · ⌘⌥${position + 1}` : ''}`}
                    >
                      <ActionIcon
                        variant="subtle"
                        color="gray"
                        aria-label="Сохранить изображение…"
                        aria-keyshortcuts={position < 9 ? `Meta+Alt+${position + 1}` : undefined}
                        disabled={busy}
                        onClick={() => void run('saveImage', { id: clip.id })}
                      >
                        <IconDownload size={16} />
                      </ActionIcon>
                    </Tooltip>
                  )}
                  {clip.kind === 'text' && clipboardWebUrl(clip.content) && (
                    <Tooltip
                      label={`Открыть ссылку в браузере${position < 9 ? ` · ⌘⌥${position + 1}` : ''}`}
                    >
                      <ActionIcon
                        variant="subtle"
                        color="gray"
                        aria-label="Открыть ссылку в браузере"
                        aria-keyshortcuts={position < 9 ? `Meta+Alt+${position + 1}` : undefined}
                        disabled={busy}
                        onClick={() => void run('openUrl', { id: clip.id })}
                      >
                        <IconExternalLink size={16} />
                      </ActionIcon>
                    </Tooltip>
                  )}
                  <Tooltip label="Просмотр · ⌘↵">
                    <ActionIcon
                      variant="subtle"
                      color="gray"
                      aria-label="Просмотреть запись"
                      disabled={busy}
                      onClick={() => {
                        openPreview(clip.id);
                      }}
                    >
                      <IconEye size={16} />
                    </ActionIcon>
                  </Tooltip>
                  <Tooltip label={clip.pinned ? 'Открепить' : 'Закрепить'}>
                    <ActionIcon
                      variant="subtle"
                      color="gray"
                      data-active={clip.pinned || undefined}
                      aria-label={clip.pinned ? 'Открепить запись' : 'Закрепить запись'}
                      disabled={!writable || busy}
                      onClick={() => void run('pin', { id: clip.id, pinned: !clip.pinned })}
                    >
                      {clip.pinned ? <IconPinnedOff size={16} /> : <IconPin size={16} />}
                    </ActionIcon>
                  </Tooltip>
                  <Tooltip label="Удалить">
                    <ActionIcon
                      variant="subtle"
                      color="gray"
                      aria-label="Удалить запись"
                      disabled={!writable || busy}
                      onClick={() => void run('remove', { id: clip.id })}
                    >
                      <IconTrash size={16} />
                    </ActionIcon>
                  </Tooltip>
                </div>
                <span className="clipboard-result-shortcut">
                  {position < 9 && <kbd>⌘{position + 1}</kbd>}
                </span>
              </div>
            ))
          )}
        </div>
      )}
      <footer className="clipboard-footer">
        {!preview && !confirmClear && (
          <div className="clipboard-shortcuts">
            <span>
              <kbd>↑</kbd>
              <kbd>↓</kbd> выбрать
            </span>
            <span>
              <kbd>↵</kbd> {canPaste ? 'вставить' : 'копировать'}
            </span>
            <span>
              <kbd>esc</kbd> закрыть
            </span>
          </div>
        )}
        {preview ? (
          <span>⌫ / esc вернуться к списку</span>
        ) : confirmClear ? (
          <span>⌫ / esc отменить</span>
        ) : (
          <button
            disabled={!selection || busy}
            onClick={() => selection && openPreview(selection.id)}
          >
            ⌘↵ просмотр
          </button>
        )}
      </footer>
    </section>
  );
}
