import {
  IconCalculator,
  IconClipboard,
  IconArrowRight,
  IconTextSize,
  IconMoodSmile,
  IconNotes,
  IconFiles,
} from '@tabler/icons-react';
import { clipboardSnippet, type ShelfSearchResult } from '../../shared/shelf-search';
import { consumedKey } from './shelf-keyboard';

export default function SearchResult({
  result,
  query,
  selected,
  busy,
  copied,
  canPaste,
  shortcut,
  onSelect,
  onActivate,
}: {
  result: ShelfSearchResult;
  query: string;
  selected: boolean;
  busy: boolean;
  copied: boolean;
  canPaste: boolean;
  shortcut?: number;
  onSelect: () => void;
  onActivate: (copyOnly: boolean) => void;
}) {
  const app = result.kind === 'app' ? result.app : undefined;
  const clip = result.kind === 'clip' ? result.clip : undefined;
  const calculation = result.kind === 'calculation' ? result.calculation : undefined;
  const title = app
    ? app.name
    : clip
      ? clip.name || clipboardSnippet(clip, query)
      : calculation
        ? calculation.displayValue || calculation.value
        : result.kind === 'more-snippets'
          ? 'Показать все сниппеты'
          : 'Показать все записи';
  const description = app
    ? app.description || 'Полка'
    : clip
      ? `${clip.kind === 'image' ? 'Изображение · ' : ''}${clip.name ? clipboardSnippet(clip, query) + ' · ' : ''}${clip.pinned && !clip.snippet ? 'Закреплено · ' : ''}${new Date(clip.createdAt).toLocaleString('ru', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}`
      : calculation
        ? calculation.interpretation || calculation.expression
        : result.kind === 'more-clips'
          ? `Найдено в истории: ${result.count}`
          : result.kind === 'more-snippets'
            ? `Найдено сниппетов: ${result.count}`
            : '';
  const hint = calculation
    ? copied
      ? 'Скопировано'
      : 'Копировать'
    : clip
      ? canPaste
        ? 'Вставить'
        : 'Копировать'
      : app
        ? app.kind === 'builtin'
          ? 'Встроенное'
          : 'macOS'
        : 'Открыть';
  return (
    <button
      type="button"
      role="option"
      tabIndex={-1}
      id={`launcher-app-${result.id}`}
      data-kind={app?.kind || result.kind}
      className={`launcher-result${selected ? ' selected' : ''}${calculation ? ' launcher-calculation' : ''}${calculation?.conversion ? ' launcher-conversion' : ''}`}
      aria-selected={selected}
      aria-keyshortcuts={shortcut ? `Meta+${shortcut}` : undefined}
      disabled={busy}
      onMouseMove={onSelect}
      onFocus={onSelect}
      onClick={(event) => onActivate(event.shiftKey)}
      onKeyDown={(event) => {
        if (consumedKey(event)) return;
        if (event.key === 'Enter') {
          event.preventDefault();
          if (
            !event.nativeEvent.isComposing &&
            !event.repeat &&
            !event.metaKey &&
            !event.ctrlKey &&
            !event.altKey
          )
            onActivate(event.shiftKey);
        }
      }}
    >
      <span className="launcher-icon" aria-hidden="true">
        {calculation ? (
          <IconCalculator size={26} stroke={1.5} />
        ) : clip ? (
          clip.kind === 'image' ? (
            <img src={clip.preview} alt="" />
          ) : (
            <IconTextSize size={22} stroke={1.5} />
          )
        ) : app ? (
          app.kind === 'builtin' ? (
            app.id === 'builtin:snippets' ? (
              <IconNotes size={22} stroke={1.5} />
            ) : app.id === 'builtin:files' ? (
              <IconFiles size={22} stroke={1.5} />
            ) : app.id === 'builtin:emoji' ? (
              <IconMoodSmile size={22} stroke={1.5} />
            ) : (
              <IconClipboard size={22} stroke={1.5} />
            )
          ) : app.kind === 'mac' && app.icon ? (
            <img src={app.icon} alt="" />
          ) : (
            app.icon || '◈'
          )
        ) : (
          <IconArrowRight size={22} stroke={1.5} />
        )}
      </span>
      <span className="launcher-result-text">
        <strong>{title}</strong>
        <span>{description}</span>
      </span>
      <span className="launcher-result-hint">
        <span>{hint}</span>
        {shortcut && <kbd>⌘{shortcut}</kbd>}
      </span>
    </button>
  );
}
