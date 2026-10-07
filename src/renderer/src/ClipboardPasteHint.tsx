import { IconLock } from '@tabler/icons-react';
import type { ClipboardState } from '../../shared/clipboard';
import { Button } from './NativeControls';
import ClipboardHelperStatus from './ClipboardHelperStatus';

export default function ClipboardPasteHint({
  state,
  busy,
  onRequestAccess,
  item = 'Запись',
}: {
  state?: ClipboardState;
  busy: boolean;
  onRequestAccess: () => void;
  item?: 'Запись' | 'Эмодзи';
}) {
  if (state?.helper?.status === 'starting')
    return <ClipboardHelperStatus state={state} item={item} />;
  if (!state?.preferences.pasteOnSelect || state.pasteAccess === 'granted') return null;
  const required = state.pasteAccess === 'required';
  return (
    <div
      className={`clipboard-paste-hint${required ? ' clipboard-paste-permission' : ''}`}
      role="status"
    >
      {required && (
        <IconLock className="clipboard-paste-permission-icon" size={20} aria-hidden="true" />
      )}
      <div className="clipboard-paste-hint-text">
        {required && <strong>Автовставке нужен доступ</strong>}
        <p>
          {required
            ? `Разрешите «Универсальный доступ» в macOS. Пока ${item.toLowerCase()} только копируется — вставьте ${item === 'Эмодзи' ? 'его' : 'её'} ⌘ V.`
            : `Автовставка пока недоступна. ${item} будет скопирован${item === 'Запись' ? 'а' : ''}; вставьте ${item === 'Эмодзи' ? 'его' : 'её'} сочетанием ⌘ V.`}
        </p>
      </div>
      {required && (
        <Button variant="default" loading={busy} onClick={onRequestAccess}>
          Разрешить…
        </Button>
      )}
    </div>
  );
}
