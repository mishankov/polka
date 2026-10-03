import { useCallback, useEffect, useRef, useState, type CSSProperties } from 'react';
import { ActionIcon, Alert, Button, Group, Loader, TextInput, Tooltip } from '@mantine/core';
import {
  IconClipboard,
  IconSearch,
  IconPin,
  IconPinnedOff,
  IconTrash,
  IconPlayerPause,
  IconPlayerPlay,
  IconX,
} from '@tabler/icons-react';
import {
  clipboardResults,
  type ClipboardState,
  type ClipboardPresentation,
} from '../../shared/clipboard';
import { api, errorMessage } from './api';

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
  const input = useRef<HTMLInputElement>(null);
  const request = useRef(0);
  const pending = useRef(false);
  const results = clipboardResults(state?.clips || [], query);
  const index = Math.max(
    0,
    results.findIndex((clip) => clip.id === selected),
  );
  const selection = results[index];
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
    // before React subscribed. Hover must never focus a newly mounted input.
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
  }, [selection?.id]);
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
          if (confirmClear) setConfirmClear(false);
          else void run('hide');
        }
      }}
    >
      <header className="clipboard-header">
        <div className="clipboard-header-icon" aria-hidden="true">
          <IconClipboard size={20} stroke={1.5} />
        </div>
        <div className="clipboard-heading">
          <h1>Буфер обмена</h1>
          <span>
            {state?.preferences.paused ? 'Запись на паузе' : 'Недавние копии · только на этом Mac'}
          </span>
        </div>
        <Tooltip label={state?.preferences.paused ? 'Продолжить запись' : 'Приостановить запись'}>
          <ActionIcon
            variant="subtle"
            color="gray"
            size="lg"
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
        <ActionIcon
          variant="subtle"
          color="gray"
          size="lg"
          aria-label="Закрыть историю"
          onClick={() => void run('hide')}
        >
          <IconX size={18} />
        </ActionIcon>
      </header>
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
              void run('copy', { id: selection.id });
            }
          }}
        />
      </div>
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
                  if (ok) setConfirmClear(false);
                })
              }
            >
              Удалить всю историю
            </Button>
            <Button variant="default" onClick={() => setConfirmClear(false)}>
              Отмена
            </Button>
          </Group>
        </div>
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
                >
                  {clip.kind === 'image' ? (
                    <img src={clip.preview} alt="Скопированное изображение" />
                  ) : (
                    <span className="clipboard-text">{clip.preview}</span>
                  )}
                  <span className="clipboard-meta">
                    {clip.pinned && <IconPin size={12} />}
                    {clip.kind === 'image'
                      ? 'Изображение'
                      : `${clip.content.length.toLocaleString('ru')} симв.`}
                    <span>·</span>
                    {new Date(clip.createdAt).toLocaleString('ru', {
                      day: 'numeric',
                      month: 'short',
                      hour: '2-digit',
                      minute: '2-digit',
                    })}
                  </span>
                </button>
                <div className="clipboard-row-actions">
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
        <button disabled={!state?.clips.length || busy} onClick={() => setConfirmClear(true)}>
          Очистить…
        </button>
      </footer>
    </main>
  );
}
