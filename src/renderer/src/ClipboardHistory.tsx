import { useCallback, useEffect, useRef, useState } from 'react';
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

function ClipboardPreview({ clip, text }: { clip: ClipboardClip; text?: string }) {
  const [image, setImage] = useState('');
  const [error, setError] = useState('');
  const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    if (clip.kind !== 'image') return;
    let cancelled = false;
    setImage('');
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
      aria-busy={clip.kind === 'image' && !image && !error}
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
        <img src={image} alt="Просмотр скопированного изображения" />
      ) : (
        <Loader size="sm" color="gray" />
      )}
    </div>
  );
}

export default function ClipboardHistory({
  onBack,
  initialQuery = '',
}: {
  onBack: () => void;
  initialQuery?: string;
}) {
  const [state, setState] = useState<ClipboardState>();
  const [query, setQuery] = useState(initialQuery);
  const [selected, setSelected] = useState<string>();
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [confirmClear, setConfirmClear] = useState(false);
  const [previewId, setPreviewId] = useState<string>();
  const [transformation, setTransformation] = useState<TextTransformation>();
  const [notice, setNotice] = useState('');
  const [menuOpen, setMenuOpen] = useState(false);
  const input = useRef<HTMLInputElement>(null);
  const request = useRef(0);
  const pending = useRef(false);
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
                      document
                        .querySelector<HTMLButtonElement>('.clipboard-preview .clipboard-back')
                        ?.focus(),
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
        ];
  const originalActionIndex = previewActions.findIndex((action) => action.id === 'original');
  function openPreview(id: string) {
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
    void refresh();
    const unsubscribe = window.platform.onEvent((event) => {
      if (event.type === 'clipboardHistory.changed') void refresh();
    });
    return () => {
      request.current++;
      unsubscribe();
    };
  }, [refresh]);
  useEffect(() => {
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
      if (method === 'saveImage' && result === 'saved') setNotice('Изображение сохранено');
      await refresh();
      return true;
    } catch (reason) {
      setError(
        errorMessage(reason).replace(/^Error invoking remote method 'platform:call': Error: /, ''),
      );
    } finally {
      pending.current = false;
      setBusy(false);
      if (method === 'saveImage')
        requestAnimationFrame(() => {
          if (
            focusedBefore instanceof HTMLElement &&
            focusedBefore.isConnected &&
            document.activeElement === document.body
          )
            focusedBefore.focus();
        });
    }
  }
  return (
    <section
      className="clipboard-app"
      aria-label="История буфера обмена"
      onKeyDown={(event) => {
        const actionNumber = /^Digit[1-9]$/.test(event.code) ? event.code.slice(-1) : event.key;
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
          const editing = target.closest('input, textarea, [contenteditable="true"]');
          if (!editing || (target === input.current && query.length === 0)) {
            event.preventDefault();
            if (confirmClear) closeConfirmation();
            else if (preview) closePreview();
            else onBack();
            return;
          }
        }
        if (event.key === 'Escape' && !event.nativeEvent.isComposing && !busy) {
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
          <Tooltip label="Назад к приложениям · ⌫">
            <ActionIcon aria-label="Назад к приложениям" variant="subtle" onClick={onBack}>
              <IconArrowLeft size={18} />
            </ActionIcon>
          </Tooltip>
          <div className="clipboard-heading">
            <h1>Буфер обмена</h1>
            {state?.preferences.paused && <span>Запись на паузе</span>}
          </div>
        </div>
        <div className="clipboard-header-actions">
          <div
            className="native-history-menu"
            onBlur={(event) => {
              if (!event.currentTarget.contains(event.relatedTarget)) setMenuOpen(false);
            }}
            onKeyDown={(event) => {
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
                  disabled={!state?.clips.length || busy}
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
            placeholder="Найти скопированный текст…"
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
                if (event.metaKey) openPreview(selection.id);
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
            if (event.key === 'Enter' && event.shiftKey && !event.nativeEvent.isComposing) {
              event.preventDefault();
              void run('copy', { id: preview.id, transformation });
            }
          }}
        >
          <div className="clipboard-preview-toolbar">
            <button
              className="clipboard-back"
              onClick={closePreview}
              disabled={busy}
              title="Назад к списку · ⌫"
              aria-keyshortcuts="Backspace"
              autoFocus
            >
              <IconArrowLeft size={16} />
              Назад
            </button>
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
          <ClipboardPreview key={preview.id} clip={preview} text={previewText} />
        </section>
      ) : (
        <div
          className="clipboard-results"
          id="clipboard-results"
          role="listbox"
          aria-label="Скопированные записи"
          aria-busy={busy}
        >
          {!state ? (
            <div className="clipboard-empty">
              <Loader size="sm" color="gray" />
            </div>
          ) : !results.length ? (
            <div className="clipboard-empty">
              <IconClipboard size={36} stroke={1.2} />
              <strong>{query ? 'Ничего не найдено' : 'Здесь появится скопированное'}</strong>
              <p>
                {query
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
                    if (event.key === 'Enter' && event.metaKey) {
                      event.preventDefault();
                      openPreview(clip.id);
                    } else if (event.key === 'Enter' && event.shiftKey) {
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
                        ? 'Изображение'
                        : clip.preview.trim() || 'Пустой текст'}
                    </span>
                    <span className="clipboard-meta">
                      {clip.pinned && <IconPin size={12} aria-label="Закреплено" />}
                      <span className="clipboard-origin" title={clip.sourceDevice}>
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
                      disabled={busy}
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
                      disabled={busy}
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
