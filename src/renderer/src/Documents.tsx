import { useEffect, useRef, useState } from 'react';
import {
  ActionIcon,
  Alert,
  Badge,
  Button,
  ColorInput,
  Group,
  NumberInput,
  Modal,
  Select,
  Stack,
  Tabs,
  Text,
  TextInput,
  Tooltip,
} from '@mantine/core';
import {
  IconArrowBackUp,
  IconArrowForwardUp,
  IconFilePlus,
  IconFolderOpen,
  IconDeviceFloppy,
  IconX,
  IconZoomReset,
} from '@tabler/icons-react';
import { CodeEditor, documentLanguage } from '../../components/CodeEditor';
import { api, AnyRecord, perform, report } from './api';
import { registerDocumentFlush } from './documentFlush';
import { setSelection } from './selectionContext';
import {
  applyRasterOperation,
  validateRasterOperation,
  type RasterOperation,
} from './rasterOperations';
export function RasterEditor({
  value,
  onChange,
}: {
  value: string;
  onChange: (value: string) => void;
}) {
  const canvas = useRef<HTMLCanvasElement>(null);
  const [color, setColor] = useState('#473b31');
  const [geometry, setGeometry] = useState<'resize' | 'crop' | null>(null);
  const [geometryValues, setGeometryValues] = useState({ x: 0, y: 0, width: 1024, height: 768 });
  const [imageLoading, setImageLoading] = useState(false);
  const loadSequence = useRef(0);
  const [size, setSize] = useState<number | string>(6);
  const [tool, setTool] = useState('brush');
  const history = useRef<string[]>([]);
  const future = useRef<string[]>([]);
  const drawing = useRef(false);
  const emitted = useRef('');
  const [version, setVersion] = useState(0);
  const [dimensions, setDimensions] = useState([1024, 768]);
  function load(data: string) {
    const c = canvas.current;
    if (!c) return;
    const ctx = c.getContext('2d')!;
    const sequence = ++loadSequence.current;
    if (data) {
      setImageLoading(true);
      const img = new Image();
      img.onload = () => {
        if (sequence !== loadSequence.current) return;
        setImageLoading(false);
        if (
          img.naturalWidth * img.naturalHeight > 16_777_216 ||
          img.naturalWidth > 8192 ||
          img.naturalHeight > 8192
        ) {
          report(Error('Изображение превышает лимит 16 мегапикселей или 8192 пикселя по стороне'));
          return;
        }
        c.width = img.naturalWidth;
        c.height = img.naturalHeight;
        setDimensions([c.width, c.height]);
        ctx.clearRect(0, 0, c.width, c.height);
        ctx.save();
        ctx.globalCompositeOperation = 'source-over';
        ctx.drawImage(img, 0, 0);
        ctx.restore();
      };
      img.onerror = () => {
        if (sequence === loadSequence.current) {
          setImageLoading(false);
          report(Error('Не удалось прочитать изображение'));
        }
      };
      img.src = data;
    }
  }
  useEffect(() => {
    if (value !== emitted.current) load(value);
  }, [value]);
  function save() {
    const data = canvas.current!.toDataURL('image/png');
    emitted.current = data;
    onChange(data);
    setVersion((v) => v + 1);
  }
  function transform(operation: RasterOperation) {
    const c = canvas.current!;
    try {
      validateRasterOperation(operation, c.width, c.height);
      const previous = c.toDataURL('image/png');
      applyRasterOperation(c, operation);
      history.current = [...history.current, previous].slice(-30);
      future.current = [];
      setDimensions([c.width, c.height]);
      setGeometry(null);
      save();
    } catch (e) {
      report(e);
    }
  }
  function point(e: React.PointerEvent<HTMLCanvasElement>) {
    const r = e.currentTarget.getBoundingClientRect();
    return {
      x: ((e.clientX - r.left) * e.currentTarget.width) / r.width,
      y: ((e.clientY - r.top) * e.currentTarget.height) / r.height,
    };
  }
  function undo() {
    const previous = history.current.pop();
    if (previous === undefined) return;
    future.current.push(canvas.current!.toDataURL());
    load(previous);
    emitted.current = previous;
    onChange(previous);
    setVersion((v) => v + 1);
  }
  function redo() {
    const next = future.current.pop();
    if (!next) return;
    history.current.push(canvas.current!.toDataURL());
    load(next);
    emitted.current = next;
    onChange(next);
    setVersion((v) => v + 1);
  }
  return (
    <Stack gap="sm">
      <Group>
        <Select
          aria-label="Инструмент рисования"
          w={140}
          data={[
            { value: 'brush', label: 'Кисть' },
            { value: 'eraser', label: 'Ластик' },
          ]}
          value={tool}
          onChange={(v) => setTool(v || 'brush')}
        />
        <ColorInput aria-label="Цвет кисти" value={color} onChange={setColor} w={150} />
        <NumberInput
          label=""
          aria-label="Размер кисти"
          value={size}
          onChange={setSize}
          min={1}
          max={100}
          w={90}
          suffix=" px"
        />
        <Tooltip label="Отменить штрих">
          <ActionIcon
            variant="default"
            size="lg"
            disabled={imageLoading || !history.current.length}
            onClick={undo}
            aria-label="Отменить штрих"
          >
            <IconArrowBackUp size={17} />
          </ActionIcon>
        </Tooltip>
        <Tooltip label="Повторить штрих">
          <ActionIcon
            variant="default"
            size="lg"
            disabled={imageLoading || !future.current.length}
            onClick={redo}
            aria-label="Повторить штрих"
          >
            <IconArrowForwardUp size={17} />
          </ActionIcon>
        </Tooltip>
        <Text size="xs" c="dimmed">
          {dimensions[0]} × {dimensions[1]} · PNG
        </Text>
      </Group>
      <Group gap="xs">
        <Button
          size="xs"
          variant="default"
          disabled={imageLoading}
          onClick={() => transform({ type: 'rotate', direction: 'left' })}
        >
          Повернуть влево
        </Button>
        <Button
          size="xs"
          variant="default"
          disabled={imageLoading}
          onClick={() => transform({ type: 'rotate', direction: 'right' })}
        >
          Повернуть вправо
        </Button>
        <Button
          size="xs"
          variant="default"
          disabled={imageLoading}
          onClick={() => transform({ type: 'flip', axis: 'horizontal' })}
        >
          Отразить по горизонтали
        </Button>
        <Button
          size="xs"
          variant="default"
          disabled={imageLoading}
          onClick={() => transform({ type: 'flip', axis: 'vertical' })}
        >
          Отразить по вертикали
        </Button>
        {(['resize', 'crop'] as const).map((type) => (
          <Button
            key={type}
            size="xs"
            variant="default"
            disabled={imageLoading}
            onClick={() => {
              setGeometryValues({ x: 0, y: 0, width: dimensions[0], height: dimensions[1] });
              setGeometry(type);
            }}
          >
            {type === 'resize' ? 'Изменить размер…' : 'Обрезать…'}
          </Button>
        ))}
      </Group>
      <Modal
        opened={!!geometry}
        onClose={() => setGeometry(null)}
        title={geometry === 'crop' ? 'Обрезать изображение' : 'Изменить размер изображения'}
      >
        <Stack>
          <Text size="sm" c="dimmed">
            {geometry === 'crop'
              ? 'Координаты считаются от левого верхнего угла. Вне выбранной области пиксели будут удалены.'
              : 'Укажите ширину и высоту. Пропорции задаются этими значениями.'}{' '}
            Операцию можно отменить.
          </Text>
          <Group grow>
            {(geometry === 'crop' ? ['x', 'y', 'width', 'height'] : ['width', 'height']).map(
              (key) => (
                <NumberInput
                  key={key}
                  label={({ x: 'X', y: 'Y', width: 'Ширина', height: 'Высота' } as any)[key]}
                  value={(geometryValues as any)[key]}
                  min={['x', 'y'].includes(key) ? 0 : 1}
                  max={8192}
                  allowDecimal={false}
                  onChange={(v) => setGeometryValues({ ...geometryValues, [key]: Number(v) })}
                />
              ),
            )}
          </Group>
          <Button onClick={() => transform({ type: geometry!, ...geometryValues })}>
            Применить
          </Button>
        </Stack>
      </Modal>
      <div className="canvas-wrap">
        <canvas
          ref={canvas}
          width={1024}
          height={768}
          aria-label="Холст растрового редактора"
          tabIndex={0}
          onPointerDown={(e) => {
            if (imageLoading) return;
            e.currentTarget.setPointerCapture(e.pointerId);
            history.current.push(e.currentTarget.toDataURL());
            if (history.current.length > 30) history.current.shift();
            future.current = [];
            drawing.current = true;
            const p = point(e),
              ctx = e.currentTarget.getContext('2d')!;
            ctx.globalCompositeOperation = tool === 'eraser' ? 'destination-out' : 'source-over';
            ctx.strokeStyle = color;
            ctx.fillStyle = color;
            ctx.lineWidth = Number(size);
            ctx.lineCap = 'round';
            ctx.lineJoin = 'round';
            ctx.beginPath();
            ctx.arc(p.x, p.y, Number(size) / 2, 0, Math.PI * 2);
            ctx.fill();
            ctx.beginPath();
            ctx.moveTo(p.x, p.y);
          }}
          onPointerMove={(e) => {
            if (!drawing.current) return;
            const p = point(e),
              ctx = e.currentTarget.getContext('2d')!;
            ctx.lineTo(p.x, p.y);
            ctx.stroke();
          }}
          onPointerUp={() => {
            if (drawing.current) {
              drawing.current = false;
              save();
            }
          }}
          onPointerCancel={() => {
            drawing.current = false;
            save();
          }}
        />
      </div>
    </Stack>
  );
}
export default function Documents({ appId, kind = 'text' }: { appId: string; kind?: string }) {
  const [docs, setDocs] = useState<AnyRecord[]>([]);
  const [active, setActive] = useState<string | null>(null);
  const [doc, setDoc] = useState<AnyRecord>();
  const [content, setContent] = useState('');
  const [dirty, setDirty] = useState(false);
  const [conflict, setConflict] = useState('');
  const [batchErrors, setBatchErrors] = useState('');
  const [opening, setOpening] = useState(false);
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const contentRef = useRef('');
  const revisionRef = useRef(0);
  const lastDraft = useRef('');
  const currentDocument = useRef<string | undefined>(undefined);
  const pending = useRef<Promise<any>>(Promise.resolve());
  const refresh = () =>
    api('docs.list', { appId })
      .then((d: any[]) => {
        setDocs(d);
        return d;
      })
      .catch(report);
  useEffect(() => {
    refresh().then((d) => {
      if (d?.length)
        setActive((d.find((document: AnyRecord) => document.kind === kind) || d[0]).id);
    });
  }, [appId]);
  useEffect(() => {
    if (!active) {
      currentDocument.current = undefined;
      setDoc(undefined);
      return;
    }
    api('docs.get', { appId, id: active })
      .then((d: any) => {
        currentDocument.current = d.id;
        setDoc(d);
        setContent(d.content || '');
        contentRef.current = d.content || '';
        lastDraft.current = d.content || '';
        revisionRef.current = d.revision;
        setDirty(d.dirty);
        setConflict('');
      })
      .catch(report);
  }, [active]);
  async function writeDraft(id: string, value: string) {
    pending.current = pending.current
      .catch(() => {})
      .then(async () => {
        if (value === lastDraft.current) return;
        const d = await api('docs.draft', {
          appId,
          id,
          content: value,
          revision: revisionRef.current,
        });
        revisionRef.current = d.revision;
        lastDraft.current = value;
      });
    return pending.current;
  }
  async function draft() {
    clearTimeout(timer.current);
    if (doc) await writeDraft(doc.id, contentRef.current);
  }
  useEffect(
    () => () => {
      clearTimeout(timer.current);
      if (currentDocument.current)
        void writeDraft(currentDocument.current, contentRef.current).catch(report);
    },
    [],
  );
  function edit(value: string) {
    setContent(value);
    contentRef.current = value;
    setDirty(true);
    clearTimeout(timer.current);
    const id = doc?.id;
    timer.current = setTimeout(() => {
      if (id) writeDraft(id, value).catch(report);
    }, 450);
  }
  useEffect(() => registerDocumentFlush(draft), [doc?.id]);
  useEffect(() => () => setSelection(null), [doc?.id]);
  async function openMany(folder = false, files?: File[]) {
    setOpening(true);
    setBatchErrors('');
    try {
      await draft();
      const result = files
        ? await window.platform.openDropped(appId, files)
        : await api('docs.openMany', { appId, folder });
      if (result) {
        setBatchErrors(result.errors.map((e: AnyRecord) => `${e.name}: ${e.error}`).join('\n'));
        await refresh();
        const preferred =
          result.documents.find((d: AnyRecord) => d.kind === kind) || result.documents[0];
        if (preferred) setActive(preferred.id);
      }
    } catch (e) {
      report(e);
    } finally {
      setOpening(false);
    }
  }
  async function reloadDocument() {
    const list = await refresh();
    const next = list?.find((d: AnyRecord) => d.id === active);
    if (next) {
      setDoc(next);
      setContent(next.content);
      contentRef.current = next.content;
      lastDraft.current = next.content;
      revisionRef.current = next.revision;
      setDirty(next.dirty);
    }
  }
  async function changeFormat(key: string, value: string | null) {
    if (!value || !doc) return;
    await perform(async () => {
      await draft();
      await api('docs.draft', {
        appId,
        id: doc.id,
        content: contentRef.current,
        revision: revisionRef.current,
        [key]: value,
      });
      await reloadDocument();
    });
  }
  async function open(create = false) {
    await draft();
    let blank = '';
    if (create && kind === 'image') {
      const c = document.createElement('canvas');
      c.width = 1024;
      c.height = 768;
      blank = c.toDataURL('image/png');
    }
    const d = await perform(() =>
      api(create ? 'docs.create' : 'docs.open', {
        appId,
        kind,
        content: blank,
        name: kind === 'image' ? 'Новый рисунок.png' : 'Новый документ.txt',
      }),
    );
    if (d) {
      await refresh();
      setActive(d.id);
    }
  }
  async function save(saveAs = false, force = false) {
    try {
      clearTimeout(timer.current);
      await draft();
      const d = await api('docs.save', { appId, id: doc?.id, saveAs, force });
      if (d) {
        setDoc(d);
        revisionRef.current = d.revision;
        setDirty(false);
        setConflict('');
        refresh();
      }
    } catch (e) {
      setConflict(String(e instanceof Error ? e.message : e));
    }
  }
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key === 's') {
        e.preventDefault();
        save(e.shiftKey);
      }
    };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  });
  return (
    <Stack
      gap="md"
      onDragOver={(e) => {
        if (e.dataTransfer.types.includes('Files')) {
          e.preventDefault();
          e.dataTransfer.dropEffect = 'copy';
        }
      }}
      onDrop={(e) => {
        e.preventDefault();
        if (!opening && e.dataTransfer.files.length)
          void openMany(false, [...e.dataTransfer.files]);
      }}
    >
      <Group justify="space-between">
        <Group>
          <Button
            variant="default"
            leftSection={<IconFilePlus size={16} />}
            onClick={() => open(true)}
          >
            Новый
          </Button>
          <Button
            variant="default"
            leftSection={<IconFolderOpen size={16} />}
            loading={opening}
            onClick={() => openMany()}
          >
            Открыть файлы…
          </Button>
          <Button variant="subtle" disabled={opening} onClick={() => openMany(true)}>
            Открыть папку…
          </Button>
        </Group>
        {doc && (
          <Group>
            <Badge color={dirty ? 'orange' : 'gray'} variant="light">
              {dirty ? 'Черновик сохранится автоматически' : 'Сохранено'}
            </Badge>
            <Button leftSection={<IconDeviceFloppy size={16} />} onClick={() => save()}>
              Сохранить
            </Button>
            <Button variant="default" onClick={() => save(true)}>
              Сохранить как…
            </Button>
          </Group>
        )}
      </Group>
      {batchErrors && (
        <Alert color="orange" title="Открытие файлов" style={{ whiteSpace: 'pre-wrap' }}>
          {batchErrors}
        </Alert>
      )}
      {docs.length > 0 && (
        <Tabs
          value={active}
          onChange={async (v) => {
            await draft();
            setActive(v);
          }}
        >
          <Tabs.List>
            {docs.map((d) => (
              <Tabs.Tab key={d.id} value={d.id}>
                {d.name}
                {d.dirty ? ' •' : ''}
              </Tabs.Tab>
            ))}
          </Tabs.List>
        </Tabs>
      )}
      {conflict && (
        <Alert color="orange" title="Файл не сохранён">
          <Text size="sm" mb="sm">
            {conflict}
          </Text>
          <Group>
            <Button size="xs" variant="default" onClick={() => save(true)}>
              Сохранить отдельную копию
            </Button>
            <Button size="xs" color="orange" onClick={() => save(false, true)}>
              Заменить внешний файл
            </Button>
          </Group>
        </Alert>
      )}
      {doc ? (
        <>
          <Group justify="space-between">
            <Text fw={500}>{doc.name}</Text>
            <Group gap="xs">
              <Text c="dimmed" size="xs">
                {doc.external ? 'Внешний файл' : 'Файл приложения'} · {doc.encoding || 'UTF-8'} ·{' '}
                {doc.lineEnding || 'LF'}
              </Text>
              <Button
                size="compact-xs"
                variant="subtle"
                onClick={async () => {
                  if (!window.confirm('Отменить последнюю сохранённую в черновике правку?')) return;
                  await draft();
                  const d = await perform(() => api('docs.revert', { appId, id: doc.id }));
                  if (d) {
                    setDoc(d);
                    setContent(d.content);
                    contentRef.current = d.content;
                    lastDraft.current = d.content;
                    revisionRef.current = d.revision;
                    setDirty(d.dirty);
                  }
                }}
              >
                Отменить правку
              </Button>
            </Group>
          </Group>
          <Group gap="sm">
            {doc.kind === 'text' && (
              <>
                <Select
                  aria-label="Кодировка документа"
                  label="Кодировка"
                  w={170}
                  value={doc.encoding}
                  data={['utf8', 'utf16-le', 'utf16-be', 'windows-1251', 'latin1']}
                  onChange={(v) => changeFormat('encoding', v)}
                />
                <Select
                  aria-label="Окончания строк"
                  label="Окончания строк"
                  w={130}
                  value={doc.lineEnding}
                  data={['LF', 'CRLF']}
                  onChange={(v) => changeFormat('lineEnding', v)}
                />
              </>
            )}
            <Button
              variant="subtle"
              size="xs"
              onClick={async () => {
                await draft();
                await perform(() => api('docs.redo', { appId, id: doc.id }));
                await reloadDocument();
              }}
            >
              Повторить правку
            </Button>
            <Button
              variant="subtle"
              size="xs"
              onClick={async () => {
                await draft();
                if (dirty && !window.confirm('Закрыть вкладку и удалить несохранённый черновик?'))
                  return;
                const result = await perform(() =>
                  api('docs.close', { appId, id: doc.id, discard: true }),
                );
                if (result) {
                  currentDocument.current = undefined;
                  const remaining = await refresh();
                  setActive(remaining?.[0]?.id || null);
                }
              }}
            >
              Закрыть документ
            </Button>
          </Group>
          {doc.kind === 'image' ? (
            <RasterEditor key={doc.id} value={content} onChange={edit} />
          ) : doc.kind === 'binary' ? (
            <Alert title="Двоичный файл">
              Этот документ можно сохранить. Текстовое редактирование недоступно.
            </Alert>
          ) : (
            <CodeEditor
              label="Текст документа"
              language={documentLanguage(doc.name)}
              value={content}
              onChange={edit}
              onUpdate={(update) => {
                if (update.selectionSet) {
                  const range = update.state.selection.main;
                  setSelection(
                    range.empty
                      ? null
                      : {
                          documentId: doc.id,
                          name: doc.name,
                          text: update.state.sliceDoc(
                            range.from,
                            Math.min(range.to, range.from + 8000),
                          ),
                        },
                  );
                }
              }}
              height="calc(100vh - 350px)"
              minHeight="300px"
            />
          )}
        </>
      ) : (
        <div className="empty-state">
          <IconFolderOpen size={36} />
          <Text fw={500} mt="md">
            Откройте файл или начните новый документ
          </Text>
          <Text c="dimmed" size="sm">
            Перетащите файлы или папку сюда. Изменения хранятся локально, включая незавершённую
            работу.
          </Text>
        </div>
      )}
    </Stack>
  );
}
