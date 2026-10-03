import { useCallback, useEffect, useRef, useState, type CSSProperties } from 'react';
import { ActionIcon, Alert, Button, Group, Loader, Menu, TextInput, Tooltip } from '@mantine/core';
import {
  IconClipboard,
  IconSearch,
  IconPin,
  IconPinnedOff,
  IconTrash,
  IconPlayerPause,
  IconPlayerPlay,
  IconDots,
  IconEye,
  IconArrowLeft,
  IconTextSize,
} from '@tabler/icons-react';
import {
  clipboardResults,
  type ClipboardState,
  type ClipboardPresentation,
  type ClipboardClip,
} from '../../shared/clipboard';
import { api, errorMessage } from './api';

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

function ClipboardPreview({ clip }: { clip: ClipboardClip }) {
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
        <pre>{clip.content}</pre>
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

export default function ClipboardShelf() {
  const hasOpened = useRef(false);
  const [presentation, setPresentation] = useState<ClipboardPresentation>({
    revision: -1,
    visible: false,
    focusSearch: false,
    topInset: 0,
    notchWidth: 96,
    notchHeight: 3,
  });
  const applyPresentation = useCallback((next: ClipboardPresentation) => {
    if (next.visible) hasOpened.current = true;
    setPresentation((previous) => (next.revision >= previous.revision ? next : previous));
  }, []);
  const [state, setState] = useState<ClipboardState>();
  const [query, setQuery] = useState('');
  const [selected, setSelected] = useState<string>();
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [confirmClear, setConfirmClear] = useState(false);
  const [previewId, setPreviewId] = useState<string>();
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
  const preview = state?.clips.find((clip) => clip.id === previewId);
  function openPreview(id: string) {
    setSelected(id);
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
    void api<ClipboardPresentation>('clipboardHistory.presentation')
      .then(applyPresentation)
      .catch((reason) => setError(errorMessage(reason)));
    const unsubscribe = window.platform.onEvent((event) => {
      if (event.type === 'clipboardHistory.changed') void refresh();
      if (event.type === 'clipboardHistory.presentation') applyPresentation(event.presentation);
      if (event.type === 'clipboardHistory.shown') {
        applyPresentation(event.presentation);
        setQuery('');
        setSelected(undefined);
        setError('');
        setConfirmClear(false);
        setPreviewId(undefined);
        setMenuOpen(false);
        void refresh();
      }
      if (event.type === 'workspace.beforeClose')
        void api('windows.confirmClose', { token: event.token });
    });
    return () => {
      request.current++;
      unsubscribe();
    };
  }, [refresh, applyPresentation]);
  useEffect(() => {
    // The snapshot also carries focus intent if the initial shown event arrived
    // before React subscribed, including the first hover opening.
    if (presentation.visible && presentation.focusSearch) input.current?.focus();
  }, [presentation]);
  useEffect(() => {
    if (
      !presentation.visible &&
      presentation.revision >= 0 &&
      window.matchMedia('(prefers-reduced-motion: reduce)').matches
    )
      void api('clipboardHistory.didHide', { revision: presentation.revision });
  }, [presentation]);
  useEffect(() => {
    document.getElementById(`clip-${selection?.id}`)?.scrollIntoView({ block: 'nearest' });
  }, [selection?.id, previewId, confirmClear]);
  async function run(method: string, params = {}) {
    if (pending.current) return;
    pending.current = true;
    setBusy(true);
    setError('');
    try {
      await api(`clipboardHistory.${method}`, params);
      await refresh();
      return true;
    } catch (reason) {
      setError(errorMessage(reason));
    } finally {
      pending.current = false;
      setBusy(false);
    }
  }
  return (
    <main
      className={`clipboard-shelf ${presentation.visible ? 'is-open' : hasOpened.current ? 'is-closed' : 'is-idle'}`}
      data-notched={presentation.topInset > 0 || undefined}
      style={
        {
          '--notch-width': `${presentation.notchWidth}px`,
          '--notch-height': `${presentation.notchHeight}px`,
          '--notch-inset': `${presentation.topInset}px`,
        } as CSSProperties
      }
      onAnimationEnd={(event) => {
        if (
          event.target === event.currentTarget &&
          event.animationName === 'clipboard-hide' &&
          !presentation.visible
        )
          void api('clipboardHistory.didHide', { revision: presentation.revision });
      }}
      aria-label="История буфера обмена"
      onKeyDown={(event) => {
        if (event.key === 'Escape') {
          event.preventDefault();
          if (menuOpen) setMenuOpen(false);
          else if (confirmClear) closeConfirmation();
          else if (preview) closePreview();
          else void run('hide');
        }
      }}
    >
      <header className="clipboard-header">
        <div className="clipboard-heading">
          <h1>Буфер обмена</h1>
          {state?.preferences.paused && <span>Запись на паузе</span>}
        </div>
        <div className="clipboard-header-actions">
          <Tooltip label={state?.preferences.paused ? 'Продолжить запись' : 'Приостановить запись'}>
            <ActionIcon
              variant="subtle"
              color="gray"
              size="sm"
              data-active={state?.preferences.paused || undefined}
              disabled={!state || busy}
              aria-label={state?.preferences.paused ? 'Продолжить запись' : 'Приостановить запись'}
              onClick={() => void run('preferences', { paused: !state?.preferences.paused })}
            >
              {state?.preferences.paused ? (
                <IconPlayerPlay size={18} />
              ) : (
                <IconPlayerPause size={18} />
              )}
            </ActionIcon>
          </Tooltip>
          <Menu opened={menuOpen} onChange={setMenuOpen} withinPortal={false} position="bottom-end">
            <Menu.Target>
              <ActionIcon variant="subtle" color="gray" size="sm" aria-label="Действия с историей">
                <IconDots size={18} />
              </ActionIcon>
            </Menu.Target>
            <Menu.Dropdown className="clipboard-menu">
              <Menu.Item
                leftSection={<IconTrash size={15} />}
                disabled={!state?.clips.length || busy}
                onClick={() => {
                  setPreviewId(undefined);
                  setConfirmClear(true);
                }}
              >
                Очистить историю…
              </Menu.Item>
            </Menu.Dropdown>
          </Menu>
        </div>
      </header>
      {!preview && !confirmClear && (
        <div className="clipboard-search">
          <TextInput
            ref={input}
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
                else void run('copy', { id: selection.id });
              }
            }}
          />
        </div>
      )}
      {(error || state?.error) && (
        <Alert className="clipboard-error" color="red">
          {error || state?.error}
        </Alert>
      )}
      {confirmClear ? (
        <div className="clipboard-confirm">
          <h2>Удалить всю историю?</h2>
          <p>Закреплённые записи тоже будут удалены. Текущий буфер обмена останется на месте.</p>
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
              Удалить всю историю
            </Button>
            <Button variant="default" onClick={closeConfirmation} autoFocus>
              Отмена
            </Button>
          </Group>
        </div>
      ) : preview ? (
        <section className="clipboard-preview" aria-label="Просмотр записи">
          <div className="clipboard-preview-toolbar">
            <button className="clipboard-back" onClick={closePreview} autoFocus>
              <IconArrowLeft size={16} />
              Назад
            </button>
            <span>{clipDate(preview.createdAt)}</span>
            <Button
              size="compact-sm"
              variant="default"
              disabled={busy}
              onClick={() => void run('copy', { id: preview.id })}
            >
              Копировать
            </Button>
          </div>
          <ClipboardPreview key={preview.id} clip={preview} />
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
                    ? 'Продолжите запись, чтобы сохранять новые копии.'
                    : 'Скопируйте текст или изображение в любой программе. Выберите запись, чтобы скопировать её снова.'}
              </p>
            </div>
          ) : (
            results.map((clip) => (
              <div
                key={clip.id}
                className={`clipboard-row${selection?.id === clip.id ? ' selected' : ''}`}
              >
                <button
                  id={`clip-${clip.id}`}
                  role="option"
                  aria-selected={selection?.id === clip.id}
                  className="clipboard-copy"
                  disabled={busy}
                  onFocus={() => setSelected(clip.id)}
                  onClick={() => void run('copy', { id: clip.id })}
                  onKeyDown={(event) => {
                    if (event.key === 'Enter' && event.metaKey) {
                      event.preventDefault();
                      openPreview(clip.id);
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
                      {clipDate(clip.createdAt)}
                    </span>
                  </span>
                </button>
                <div className="clipboard-row-actions">
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
              <kbd>↵</kbd> копировать
            </span>
            <span>
              <kbd>esc</kbd> закрыть
            </span>
          </div>
        )}
        {preview ? (
          <span>esc вернуться к списку</span>
        ) : confirmClear ? (
          <span>esc отменить</span>
        ) : (
          <button
            disabled={!selection || busy}
            onClick={() => selection && openPreview(selection.id)}
          >
            ⌘↵ просмотр
          </button>
        )}
      </footer>
    </main>
  );
}
