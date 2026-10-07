import { useRef } from 'react';
import { Button, Group } from './NativeControls';
import type { ClipboardClip } from '../../shared/clipboard';

export default function ClipboardLocalOnly({
  clip,
  disabled,
  apply,
}: {
  clip: ClipboardClip;
  disabled: boolean;
  apply: (value: boolean) => Promise<unknown>;
}) {
  const dialog = useRef<HTMLDialogElement>(null);
  return (
    <>
      <Button
        size="compact-sm"
        variant="default"
        disabled={disabled}
        onClick={() => {
          dialog.current?.showModal();
          dialog.current?.querySelector<HTMLButtonElement>('button:last-child')?.focus();
        }}
      >
        {clip.localOnly ? 'Разрешить синхронизацию…' : 'Оставить на этом Mac…'}
      </Button>
      <dialog
        ref={dialog}
        className="clipboard-local-dialog"
        aria-labelledby="local-clip-title"
        onKeyDown={(event) => event.stopPropagation()}
      >
        <h2 id="local-clip-title">
          {clip.localOnly ? 'Синхронизировать запись?' : 'Оставить запись на этом Mac?'}
        </h2>
        <p>
          {clip.localOnly
            ? 'Запись снова станет доступна связанным Mac при следующей синхронизации.'
            : 'Этот Mac перестанет передавать запись. Уже полученные копии останутся на других Mac и могут передаваться между ними. Это действие не отзывает ранее отправленные данные.'}
        </p>
        <p>Текущий буфер обмена останется на месте.</p>
        <Group>
          <Button
            disabled={disabled}
            onClick={() => void apply(!clip.localOnly).then(() => dialog.current?.close())}
          >
            {clip.localOnly ? 'Разрешить синхронизацию' : 'Оставить на этом Mac'}
          </Button>
          <Button variant="default" onClick={() => dialog.current?.close()}>
            Отмена
          </Button>
        </Group>
      </dialog>
    </>
  );
}
