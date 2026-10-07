import { useCallback, useEffect, useRef, useState } from 'react';
import { IconArrowLeft, IconFile, IconFolder, IconX } from '@tabler/icons-react';
import { ActionIcon, Button } from './NativeControls';
import type { FileShelfState } from '../../shared/file-shelf';
import { api, errorMessage, report } from './api';
import { consumedKey } from './shelf-keyboard';

export default function FileShelf() {
  const [state, setState] = useState<FileShelfState>({ items: [], error: '' });
  const [selected, setSelected] = useState<string[]>([]);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const pending = useRef(false);
  const view = useRef<HTMLDivElement>(null);
  const request = useRef(0);
  const anchor = useRef<string | undefined>(undefined);
  const refresh = useCallback(async () => {
    const revision = ++request.current;
    try {
      const next = await api<FileShelfState>('shelf.files.state');
      if (revision !== request.current) return;
      setState(next);
      setSelected((ids) => ids.filter((id) => next.items.some((item) => item.id === id)));
    } catch (error) {
      setError(errorMessage(error));
    }
  }, []);
  useEffect(() => {
    // DOM focus prepares keyboard navigation without activating an incoming drag.
    view.current?.focus();
    void refresh();
    const unsubscribe = window.platform.onEvent((event) => {
      if (event.type === 'fileShelf.changed') void refresh();
    });
    const timer = setInterval(() => void refresh(), 1500);
    return () => {
      unsubscribe();
      clearInterval(timer);
      request.current++;
    };
  }, [refresh]);
  async function remove(ids?: string[]) {
    if (pending.current || (ids ? !ids.length : !state.items.length)) return;
    pending.current = true;
    setBusy(true);
    try {
      await api(ids ? 'shelf.files.remove' : 'shelf.files.clear', ids ? { ids } : {});
      setError('');
      await refresh();
    } catch (error) {
      setError(errorMessage(error));
    } finally {
      pending.current = false;
      setBusy(false);
      view.current?.focus();
    }
  }
  const goBack = () => {
    if (!pending.current) void api('launcher.show', { destination: 'apps' }).catch(report);
  };
  const close = () => {
    if (!pending.current) void api('launcher.hide').catch(report);
  };
  function select(
    id: string,
    modifiers: { metaKey: boolean; ctrlKey: boolean; shiftKey: boolean },
  ) {
    if (modifiers.shiftKey && anchor.current) {
      const start = state.items.findIndex((item) => item.id === anchor.current);
      const end = state.items.findIndex((item) => item.id === id);
      setSelected(
        state.items.slice(Math.min(start, end), Math.max(start, end) + 1).map((item) => item.id),
      );
    } else if (modifiers.metaKey || modifiers.ctrlKey) {
      setSelected((ids) => (ids.includes(id) ? ids.filter((value) => value !== id) : [...ids, id]));
      anchor.current = id;
    } else {
      setSelected([id]);
      anchor.current = id;
    }
  }
  return (
    <div
      className="file-shelf-view"
      ref={view}
      tabIndex={-1}
      aria-busy={busy}
      onKeyDown={(event) => {
        if (consumedKey(event)) return;
        const command = event.metaKey || event.ctrlKey;
        if (event.key === 'Escape') {
          event.preventDefault();
          event.stopPropagation();
          if (!event.repeat) close();
          return;
        }
        if (
          command &&
          !event.altKey &&
          !event.shiftKey &&
          (event.code === 'KeyA' || event.key.toLowerCase() === 'a')
        ) {
          event.preventDefault();
          if (!event.repeat && !pending.current) setSelected(state.items.map((item) => item.id));
          return;
        }
        if (event.key === 'Backspace' && command && !event.altKey) {
          event.preventDefault();
          if (!event.repeat) {
            const focused = (event.target as HTMLElement).closest<HTMLElement>('[data-file-remove]')
              ?.dataset.fileRemove;
            void remove(event.shiftKey ? undefined : focused ? [focused] : selected);
          }
          return;
        }
        if (event.key === 'Backspace' && !command && !event.altKey) {
          event.preventDefault();
          if (!event.repeat) goBack();
        }
        if (event.key === 'Delete' && !command && !event.altKey && !event.shiftKey) {
          event.preventDefault();
          const focused = (event.target as HTMLElement).closest<HTMLElement>('[data-file-remove]')
            ?.dataset.fileRemove;
          if (!event.repeat) void remove(focused ? [focused] : selected);
        }
      }}
    >
      <header className="file-shelf-header">
        <ActionIcon
          variant="subtle"
          aria-label="Назад к приложениям"
          title="Назад к приложениям · ⌫"
          aria-keyshortcuts="Backspace"
          disabled={busy}
          onClick={goBack}
        >
          <IconArrowLeft size={19} />
        </ActionIcon>
        <h1>Файлы на полке</h1>
        <Button
          variant="subtle"
          title="Очистить полку · ⌘ ⇧ ⌫"
          aria-keyshortcuts="Meta+Shift+Backspace"
          disabled={busy || !state.items.length}
          onClick={() => void remove()}
        >
          Очистить полку
        </Button>
        <ActionIcon
          variant="subtle"
          aria-label="Закрыть полку"
          title="Закрыть полку · Esc"
          aria-keyshortcuts="Escape"
          disabled={busy}
          onClick={close}
        >
          <IconX size={19} />
        </ActionIcon>
      </header>
      <p className="file-shelf-intro">
        Перетащите сюда файлы, затем заберите их в другую программу.
      </p>
      {(error || state.error) && (
        <p className="file-shelf-error" role="alert">
          {error || state.error}
        </p>
      )}
      <div className="file-shelf-list" role="group" aria-label="Файлы на полке">
        {!state.items.length && (
          <div className="file-shelf-empty">
            <IconFolder size={42} />
            <strong>Оставьте файлы здесь</strong>
            <span>Они останутся на своих местах. Полка хранит ссылки до выхода из Полки.</span>
          </div>
        )}
        {state.items.map((item) => (
          <div
            key={item.id}
            className={`file-shelf-row${selected.includes(item.id) ? ' selected' : ''}${!item.available ? ' unavailable' : ''}`}
          >
            <button
              type="button"
              className="file-shelf-item"
              aria-pressed={selected.includes(item.id)}
              aria-label={item.name}
              disabled={busy}
              draggable={item.available && !busy}
              onClick={(event) => select(item.id, event)}
              onDragStart={(event) => {
                event.preventDefault();
                const ids = selected.includes(item.id) ? selected : [item.id];
                setSelected(ids);
                window.platform.startFileDrag(ids);
              }}
            >
              {item.icon ? (
                <img src={item.icon} alt="" />
              ) : item.directory ? (
                <IconFolder size={32} />
              ) : (
                <IconFile size={32} />
              )}
              <span>
                <strong>{item.name}</strong>
                <small>{item.available ? item.path : 'Перемещён, удалён или недоступен'}</small>
              </span>
            </button>
            <ActionIcon
              variant="subtle"
              aria-label={`Убрать ${item.name} с полки`}
              title="Убрать ссылку с полки · ⌘ ⌫"
              aria-keyshortcuts="Meta+Backspace Delete"
              data-file-remove={item.id}
              disabled={busy}
              onClick={() => void remove([item.id])}
            >
              <IconX size={17} />
            </ActionIcon>
          </div>
        ))}
      </div>
      <footer className="launcher-footer clipboard-footer">
        <span>
          {selected.length ? `Выбрано: ${selected.length}` : `Файлов: ${state.items.length}`}
        </span>
        <span>⌘ / ⇧ выбрать несколько · ⌘ A все</span>
      </footer>
      <p className="file-shelf-note">
        Очистка и удаление с полки убирают только ссылки. Файлы не синхронизируются.
      </p>
    </div>
  );
}
