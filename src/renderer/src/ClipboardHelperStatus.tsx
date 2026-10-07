import type { ClipboardState } from '../../shared/clipboard';

export default function ClipboardHelperStatus({
  state,
  item = 'Запись',
}: {
  state?: ClipboardState;
  item?: 'Запись' | 'Эмодзи';
}) {
  if (state?.helper?.status !== 'starting') return null;
  return (
    <div className="clipboard-paste-hint clipboard-helper-status" role="status">
      <div className="clipboard-paste-hint-text">
        <p>Запускаем наблюдение за буфером обмена…</p>
        {state.preferences.pasteOnSelect && (
          <p>
            Пока {item.toLowerCase()} только копируется — вставьте{' '}
            {item === 'Эмодзи' ? 'его' : 'её'} ⌘ V.
          </p>
        )}
      </div>
    </div>
  );
}
