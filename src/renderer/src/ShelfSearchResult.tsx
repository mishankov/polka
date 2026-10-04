import { IconCalculator, IconClipboard, IconArrowRight, IconTextSize } from '@tabler/icons-react';
import { clipboardSnippet, type ShelfSearchResult } from '../../shared/shelf-search';

export default function SearchResult({
  result,
  query,
  selected,
  busy,
  copied,
  canPaste,
  onSelect,
  onActivate,
}: {
  result: ShelfSearchResult;
  query: string;
  selected: boolean;
  busy: boolean;
  copied: boolean;
  canPaste: boolean;
  onSelect: () => void;
  onActivate: (copyOnly: boolean) => void;
}) {
  const app = result.kind === 'app' ? result.app : undefined;
  const clip = result.kind === 'clip' ? result.clip : undefined;
  const calculation = result.kind === 'calculation' ? result.calculation : undefined;
  const title = app
    ? app.name
    : clip
      ? clipboardSnippet(clip, query)
      : calculation
        ? calculation.value
        : 'Показать все записи';
  const description = app
    ? app.description || 'Everything App'
    : clip
      ? `${clip.pinned ? 'Закреплено · ' : ''}${new Date(clip.createdAt).toLocaleString('ru', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}`
      : calculation
        ? calculation.expression
        : result.kind === 'more-clips'
          ? `Найдено в истории: ${result.count}`
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
          : app.kind === 'mac'
            ? 'macOS'
            : app.favorite
              ? '★'
              : app.status === 'stopped'
                ? 'Запустить'
                : 'Открыть'
        : 'Открыть';
  return (
    <button
      type="button"
      role="option"
      tabIndex={-1}
      id={`launcher-app-${result.id}`}
      data-kind={app?.kind || result.kind}
      className={`launcher-result${selected ? ' selected' : ''}${calculation ? ' launcher-calculation' : ''}`}
      aria-selected={selected}
      disabled={busy}
      onMouseMove={onSelect}
      onFocus={onSelect}
      onClick={(event) => onActivate(event.shiftKey)}
      onKeyDown={(event) => {
        if (event.key === 'Enter') {
          event.preventDefault();
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
            <IconClipboard size={22} stroke={1.5} />
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
      <span className="launcher-result-hint">{hint}</span>
    </button>
  );
}
