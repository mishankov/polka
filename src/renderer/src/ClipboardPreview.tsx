import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import { Button, Loader } from './NativeControls';
import type { ClipboardClip } from '../../shared/clipboard';
import { api, errorMessage } from './api';
import { consumedKey } from './shelf-keyboard';
import { TEXT_TRANSFORMATION_LABELS } from '../../shared/clipboard-actions';
import type { useClipboardHistory } from './useClipboardHistory';
function ClipboardPreviewContent({
  clip,
  text,
  scrollTop,
}: {
  clip: ClipboardClip;
  text?: string;
  scrollTop: number;
}) {
  const [image, setImage] = useState('');
  const [imageReady, setImageReady] = useState(false);
  const [error, setError] = useState('');
  const [attempt, setAttempt] = useState(0);
  const content = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    if (content.current) content.current.scrollTop = scrollTop;
  }, [clip.id, text, image]);
  useEffect(() => {
    if (clip.kind !== 'image') return;
    let cancelled = false;
    setImage('');
    setImageReady(false);
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
      ref={content}
      aria-busy={clip.kind === 'image' && !imageReady && !error}
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
        <img
          className="clipboard-preview-image"
          src={image}
          alt="Просмотр скопированного изображения"
          onLoad={() => {
            if (content.current) content.current.scrollTop = scrollTop;
            setImageReady(true);
          }}
        />
      ) : (
        <Loader size="sm" color="gray" />
      )}
      {clip.kind === 'image' && (
        <section className="clipboard-image-text" aria-label="Распознанный текст">
          <h2>Текст на изображении</h2>
          {!clip.ocr ? (
            <p role="status">Распознаём текст на этом Mac… Изображение уже можно копировать.</p>
          ) : clip.ocr.status === 'failed' ? (
            <p role="status">Не удалось распознать текст. Повторите распознавание.</p>
          ) : clip.ocr.status === 'empty' ? (
            <p role="status">Текст на изображении не найден.</p>
          ) : (
            <pre tabIndex={0} aria-label="Распознанный текст">
              {clip.ocr.text}
            </pre>
          )}
          {clip.ocr && clip.ocr.status !== 'failed' && !clip.ocr.languages.includes('ru-RU') && (
            <p>Эта версия macOS не поддерживает распознавание русского текста.</p>
          )}
        </section>
      )}
    </div>
  );
}
export function clipDate(timestamp: number) {
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
type PreviewProps = Pick<
  ReturnType<typeof useClipboardHistory>,
  | 'canPaste'
  | 'busy'
  | 'run'
  | 'transformation'
  | 'previewActions'
  | 'originalActionIndex'
  | 'previewText'
  | 'writable'
  | 'editClip'
> & { preview: ClipboardClip; scrollTop: number };
export default function ClipboardPreview({
  preview,
  canPaste,
  busy,
  run,
  transformation,
  previewActions,
  originalActionIndex,
  previewText,
  writable,
  editClip,
  scrollTop,
}: PreviewProps) {
  return (
    <section
      className="clipboard-preview"
      aria-label="Просмотр записи"
      onKeyDown={(event) => {
        if (
          event.key === 'Enter' &&
          event.shiftKey &&
          !consumedKey(event) &&
          !event.metaKey &&
          !event.ctrlKey &&
          !event.altKey
        ) {
          event.preventDefault();
          if (!event.repeat) void run('copy', { id: preview.id, transformation });
        }
      }}
    >
      <div className="clipboard-preview-toolbar">
        <span>{preview.name || clipDate(preview.createdAt)}</span>
        {preview.kind === 'text' && (
          <Button
            variant="subtle"
            disabled={!writable || busy}
            onClick={() => void editClip(preview)}
          >
            {preview.snippet ? 'Изменить сниппет' : 'Создать сниппет'}
          </Button>
        )}
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
          <span>Результат: {TEXT_TRANSFORMATION_LABELS[transformation]}. Оригинал сохранён.</span>
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
      <ClipboardPreviewContent
        key={preview.id}
        clip={preview}
        text={previewText}
        scrollTop={scrollTop}
      />
    </section>
  );
}
