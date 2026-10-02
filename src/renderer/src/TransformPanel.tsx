import { useEffect, useRef, useState } from 'react';
import {
  ActionIcon,
  Alert,
  Button,
  Group,
  MultiSelect,
  Progress,
  Select,
  Stack,
  Text,
  TextInput,
  useMantineColorScheme,
} from '@mantine/core';
import { IconPlus, IconX } from '@tabler/icons-react';
import CodeMirror from '@uiw/react-codemirror';
import { api, type AnyRecord, errorMessage, report } from './api';
interface Props {
  appId: string;
  config?: AnyRecord;
  documentId?: string;
  selection?: { text: string; apply: (value: string) => Promise<void> };
  flush?: () => Promise<void>;
  onApplied?: () => Promise<void>;
}
const imageResult = (
  value: unknown,
): value is { type: 'image'; dataUrl: string; width: number; height: number } =>
  !!value &&
  typeof value === 'object' &&
  (value as AnyRecord).type === 'image' &&
  typeof (value as AnyRecord).dataUrl === 'string';
const resultKind = (r: AnyRecord) =>
  r.outputType === 'bytes' ? 'binary' : r.outputType === 'image' ? 'image' : 'text';
const resultContent = (r: AnyRecord) =>
  r.outputType === 'bytes'
    ? bytesBase64(r.output)
    : r.outputType === 'image'
      ? r.output.dataUrl
      : display(r.output);
const imageOptions: Record<string, string> = {
  'image.crop': '{"x":0,"y":0,"width":100,"height":100}',
  'image.resize': '{"width":512,"height":512}',
  'image.rotate': '{"angle":90}',
  'image.flip': '{"axis":"horizontal"}',
};
const display = (value: unknown) =>
  typeof value === 'string' ? value : JSON.stringify(value, null, 2);
export default function TransformPanel({
  appId,
  config,
  documentId,
  selection,
  flush,
  onApplied,
}: Props) {
  const [operations, setOperations] = useState<AnyRecord[]>([]);
  const [steps, setSteps] = useState([
    { operation: config?.operation || 'base64.encode', options: '{}' },
  ]);
  const [source, setSource] = useState(selection ? 'selection' : documentId ? 'document' : 'text');
  const [input, setInput] = useState('');
  const [clipboardImage, setClipboardImage] = useState<AnyRecord>();
  const [docs, setDocs] = useState<AnyRecord[]>([]);
  const [documentIds, setDocumentIds] = useState<string[]>(documentId ? [documentId] : []);
  const [job, setJob] = useState<AnyRecord>();
  const [results, setResults] = useState<AnyRecord[]>([]);
  const [selectedResult, setSelectedResult] = useState<string | null>(null);
  const [error, setError] = useState('');
  const [applying, setApplying] = useState(false);
  const [applied, setApplied] = useState(false);
  const jobRef = useRef<string | undefined>(undefined);
  const runSource = useRef('');
  const { colorScheme } = useMantineColorScheme();
  const busy = job?.status === 'running';
  useEffect(() => {
    api('transforms.list').then(setOperations).catch(report);
    api('docs.list', { appId }).then(setDocs).catch(report);
    return () => {
      if (jobRef.current)
        void api('transforms.jobs.release', { appId, id: jobRef.current }).catch(() => {});
    };
  }, [appId]);
  useEffect(() => {
    if (!busy) return;
    let disposed = false;
    const poll = async () => {
      try {
        const state = await api('transforms.jobs.status', {
          appId,
          id: jobRef.current,
          results: true,
        });
        if (disposed) return;
        setJob(state);
        if (state.status === 'done') {
          setResults(state.results);
          setSelectedResult(state.results[0]?.id || null);
        }
        if (state.status === 'error') setError(state.error);
      } catch (e) {
        if (!disposed) {
          setError(errorMessage(e));
          setJob(undefined);
        }
      }
    };
    const timer = setInterval(() => void poll(), 150);
    void poll();
    return () => {
      disposed = true;
      clearInterval(timer);
    };
  }, [busy, appId]);
  function invalidate() {
    setResults([]);
    setApplied(false);
    setError('');
  }
  async function run() {
    setError('');
    setResults([]);
    setApplied(false);
    try {
      await flush?.();
      if (jobRef.current) await api('transforms.jobs.release', { appId, id: jobRef.current });
      let value: unknown = source === 'selection' ? selection?.text : input;
      if (source === 'clipboard') {
        value = await api('documents.clipboardRead', {
          kind:
            operations.find((o) => o.id === steps[0]?.operation)?.input === 'image'
              ? 'image'
              : 'text',
        });
        if (imageResult(value)) {
          setClipboardImage(value);
          setInput('');
        } else {
          setClipboardImage(undefined);
          setInput(String(value));
        }
      }
      if (
        source === 'text' &&
        operations.find((o) => o.id === steps[0]?.operation)?.input !== 'text'
      )
        value = JSON.parse(input);
      runSource.current = source;
      const next = await api('transforms.jobs.start', {
        appId,
        steps: steps.map((s) => ({ operation: s.operation, options: JSON.parse(s.options) })),
        ...(['document', 'files'].includes(source)
          ? {
              documentIds:
                source === 'document'
                  ? [documentId || documentIds[0]].filter(Boolean)
                  : documentIds,
            }
          : { input: value }),
      });
      jobRef.current = next.id;
      setJob(next);
    } catch (e) {
      setError(errorMessage(e));
    }
  }
  async function apply() {
    setApplying(true);
    setError('');
    try {
      if (results.some((r) => r.error))
        throw Error('Исправьте ошибки файлов и повторите предпросмотр');
      if (runSource.current === 'selection') {
        if (results[0].outputType !== 'text')
          throw Error('В выделение можно вставить только текст');
        await selection?.apply(results[0].output);
      } else if (['document', 'files'].includes(runSource.current)) {
        await api('docs.applyBatch', {
          appId,
          changes: results.map((r) => ({
            id: r.id,
            revision: r.revision,
            kind: resultKind(r),
            content: resultContent(r),
          })),
        });
      } else {
        const r = results[0];
        await api('docs.create', {
          appId,
          name:
            r.outputType === 'bytes'
              ? 'Результат.bin'
              : r.outputType === 'image'
                ? 'Результат.png'
                : 'Результат.txt',
          kind: resultKind(r),
          content: resultContent(r),
        });
        setDocs(await api('docs.list', { appId }));
      }
      await onApplied?.();
      setApplied(true);
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setApplying(false);
    }
  }
  const result = results.find((r) => r.id === selectedResult);
  const sourceDoc = docs.find(
    (d) =>
      d.id ===
      (source === 'document' ? documentId || documentIds[0] : selectedResult || documentIds[0]),
  );
  const sourceImage =
    source === 'clipboard'
      ? clipboardImage
      : ['document', 'files'].includes(source) && sourceDoc?.kind === 'image'
        ? { dataUrl: sourceDoc.content }
        : undefined;
  const warning = [
    ...new Set(
      steps.map((s) => operations.find((o) => o.id === s.operation)?.warning).filter(Boolean),
    ),
  ];
  return (
    <Stack gap="md">
      <Group align="end">
        <Select
          label="Источник"
          value={source}
          disabled={busy}
          onChange={(v) => {
            setSource(v || 'text');
            invalidate();
          }}
          data={[
            { value: 'text', label: 'Введённый текст' },
            ...(selection ? [{ value: 'selection', label: 'Выделение' }] : []),
            { value: 'document', label: 'Документ' },
            { value: 'clipboard', label: 'Буфер обмена' },
            { value: 'files', label: 'Набор открытых файлов' },
          ]}
        />
        {['document', 'files'].includes(source) && (
          <MultiSelect
            style={{ flex: 1 }}
            label={source === 'files' ? 'Документы' : 'Документ'}
            maxValues={source === 'document' ? 1 : undefined}
            value={source === 'document' && documentId ? [documentId] : documentIds}
            disabled={busy || (source === 'document' && !!documentId)}
            data={docs.map((d) => ({ value: d.id, label: d.name }))}
            onChange={(v) => {
              setDocumentIds(v);
              invalidate();
            }}
          />
        )}
        {source === 'files' && (
          <Button
            variant="default"
            disabled={busy}
            onClick={async () => {
              try {
                const batch = await api('docs.openMany', { appId });
                if (batch) {
                  invalidate();
                  setDocs(await api('docs.list', { appId }));
                  setDocumentIds(batch.documents.map((d: AnyRecord) => d.id));
                  if (batch.errors.length)
                    setError(
                      batch.errors.map((e: AnyRecord) => `${e.name}: ${e.error}`).join('\n'),
                    );
                }
              } catch (e) {
                setError(errorMessage(e));
              }
            }}
          >
            Выбрать файлы…
          </Button>
        )}
      </Group>
      {steps.map((step, index) => {
        const op = operations.find((o) => o.id === step.operation);
        const previous = operations.find((o) => o.id === steps[index - 1]?.operation);
        return (
          <Group key={index} align="end" wrap="wrap">
            <Select
              style={{ flex: 1, minWidth: 220 }}
              label={`Шаг ${index + 1}`}
              searchable
              value={step.operation}
              disabled={busy}
              data={operations.map((o) => ({
                value: o.id,
                label: o.name,
                disabled: !!previous && previous.output !== o.input,
              }))}
              onChange={(v) => {
                setSteps(
                  steps.map((s, i) =>
                    i === index
                      ? {
                          ...s,
                          operation: v || s.operation,
                          options: imageOptions[v || ''] || '{}',
                        }
                      : s,
                  ),
                );
                invalidate();
              }}
            />
            {(['text.lines', 'text.encoding'].includes(step.operation) ||
              imageOptions[step.operation]) && (
              <TextInput
                label="Параметры (JSON)"
                placeholder={
                  imageOptions[step.operation] ||
                  (step.operation === 'text.lines'
                    ? '{"lineEnding":"CRLF"}'
                    : '{"from":"utf8","to":"windows-1251"}')
                }
                value={step.options}
                disabled={busy}
                onChange={(e) => {
                  const value = e.currentTarget.value;
                  setSteps(steps.map((s, i) => (i === index ? { ...s, options: value } : s)));
                  invalidate();
                }}
              />
            )}
            <Text size="xs" c="dimmed" pb="xs">
              {op?.input} → {op?.output}
            </Text>
            <ActionIcon
              variant="subtle"
              size="lg"
              aria-label={`Удалить шаг ${index + 1}`}
              disabled={busy || steps.length === 1}
              onClick={() => {
                setSteps(steps.filter((_, i) => i !== index));
                invalidate();
              }}
            >
              <IconX size={16} />
            </ActionIcon>
          </Group>
        );
      })}
      <Group justify="space-between">
        <Button
          variant="subtle"
          size="xs"
          leftSection={<IconPlus size={15} />}
          disabled={busy || steps.length >= 64}
          onClick={() => {
            const previous = operations.find((o) => o.id === steps.at(-1)?.operation);
            const next = operations.find((o) => o.input === previous?.output);
            if (next) {
              setSteps([...steps, { operation: next.id, options: '{}' }]);
              invalidate();
            }
          }}
        >
          Добавить шаг
        </Button>
        <Group>
          {busy && (
            <Button
              variant="default"
              onClick={async () => {
                try {
                  setJob(await api('transforms.jobs.cancel', { appId, id: jobRef.current }));
                } catch (e) {
                  setError(errorMessage(e));
                }
              }}
            >
              Отменить
            </Button>
          )}
          <Button loading={busy} onClick={run}>
            Преобразовать
          </Button>
        </Group>
      </Group>
      {warning.map((w) => (
        <Alert key={w} color="orange">
          {w}
        </Alert>
      ))}
      <Text size="xs" c="dimmed">
        Предпросмотр не изменяет файлы. До 256 документов, 32 МБ суммарно; один шаг — до 16 МБ.
        Результат применяется в черновики, сохранение на диск — отдельно.
      </Text>
      {busy && (
        <>
          <Progress value={job.total ? (job.completed / job.total) * 100 : 0} />
          <Text size="xs" c="dimmed">
            {job.current || 'Подготовка'} · {job.completed} / {job.total}
          </Text>
        </>
      )}
      {job?.status === 'cancelled' && (
        <Text c="dimmed">Преобразование отменено. Документы не изменены.</Text>
      )}
      <div className="editor-grid">
        <div>
          <Text fw={500} mb="sm">
            {source === 'selection'
              ? 'Выделенный текст'
              : source === 'document' || source === 'files'
                ? 'Исходный документ'
                : 'Исходный текст'}
          </Text>
          {sourceImage ? (
            <img
              src={sourceImage.dataUrl}
              alt="Исходное изображение"
              style={{
                maxWidth: '100%',
                maxHeight: 320,
                objectFit: 'contain',
                border: '1px solid var(--line)',
                borderRadius: 12,
              }}
            />
          ) : ['text', 'clipboard', 'selection'].includes(source) ? (
            <CodeMirror
              value={source === 'selection' ? selection?.text : input}
              onChange={(v) => {
                setInput(v);
                invalidate();
              }}
              editable={!busy && source === 'text'}
              height="250px"
              theme={colorScheme === 'dark' ? 'dark' : 'light'}
            />
          ) : (
            <Text size="sm" c="dimmed">
              Будут использованы актуальные черновики выбранных документов.
            </Text>
          )}
        </div>
        <div>
          <Group justify="space-between" mb="sm">
            <Text fw={500}>Результат</Text>
            {results.length > 1 && (
              <Select
                aria-label="Результат файла"
                data={results.map((r) => ({
                  value: r.id,
                  label: r.name + (r.error ? ' — ошибка' : ''),
                }))}
                value={selectedResult}
                onChange={setSelectedResult}
              />
            )}
          </Group>
          {result?.error ? (
            <Alert color="red">
              {result.name}: {result.error}
            </Alert>
          ) : result && imageResult(result.output) ? (
            <Stack gap="xs">
              <img
                src={result.output.dataUrl}
                alt="Предпросмотр результата изображения"
                style={{
                  maxWidth: '100%',
                  maxHeight: 320,
                  objectFit: 'contain',
                  border: '1px solid var(--line)',
                  borderRadius: 12,
                }}
              />
              <Text size="xs" c="dimmed">
                {result.output.width} × {result.output.height} · PNG
              </Text>
            </Stack>
          ) : (
            <CodeMirror
              value={result ? display(result.output) : ''}
              editable={false}
              height="250px"
              theme={colorScheme === 'dark' ? 'dark' : 'light'}
            />
          )}
        </div>
      </div>
      {results.length > 0 && (
        <Group>
          <Button
            disabled={applied || results.some((r) => r.error)}
            loading={applying}
            onClick={apply}
          >
            {applied
              ? 'Результат применён'
              : ['document', 'files', 'selection'].includes(runSource.current)
                ? 'Применить в черновик'
                : 'Сохранить новым документом'}
          </Button>
          <Button
            variant="default"
            disabled={!result || !!result.error}
            onClick={async () => {
              try {
                await api(
                  'documents.clipboardWrite',
                  result && imageResult(result.output)
                    ? { image: result.output }
                    : { text: display(result?.output) },
                );
              } catch (e) {
                setError(errorMessage(e));
              }
            }}
          >
            Копировать результат
          </Button>
        </Group>
      )}
      {error && (
        <Alert color="red" title="Проверьте исходные данные" style={{ whiteSpace: 'pre-wrap' }}>
          {error}
        </Alert>
      )}
    </Stack>
  );
}
function bytesBase64(bytes: number[]) {
  let result = '';
  for (let i = 0; i < bytes.length; i += 8192)
    result += String.fromCharCode(...bytes.slice(i, i + 8192));
  return btoa(result);
}
