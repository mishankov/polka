import ClipboardPreview, { clipDate } from './ClipboardPreview';
import { useClipboardHistory, type ClipboardHistoryOptions } from './useClipboardHistory';
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
import { clipboardWebUrl } from '../../shared/clipboard-actions';
import ClipboardPasteHint from './ClipboardPasteHint';
import { consumedKey, editingTarget, numberShortcut } from './shelf-keyboard';
import ClipboardStorageFailure from './ClipboardStorageFailure';

export default function ClipboardHistory(options: ClipboardHistoryOptions) {
  const { onBack, onContextChange } = options;
  const {
    state,
    query,
    setQuery,
    setSelected,
    writable,
    error,
    busy,
    confirmClear,
    setConfirmClear,
    setPreviewId,
    transformation,
    notice,
    menuOpen,
    setMenuOpen,
    input,
    root,
    list,
    scroll,
    results,
    index,
    selection,
    canPaste,
    preview,
    previewText,
    previewActions,
    originalActionIndex,
    context,
    openPreview,
    closeConfirmation,
    closePreview,
    goBack,
    run,
  } = useClipboardHistory(options);
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
        <ClipboardPreview
          preview={preview}
          canPaste={canPaste}
          busy={busy}
          run={run}
          transformation={transformation}
          previewActions={previewActions}
          originalActionIndex={originalActionIndex}
          previewText={previewText}
          scrollTop={scroll.current.preview}
        />
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
