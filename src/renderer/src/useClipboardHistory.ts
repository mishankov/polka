import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react';
import { clipboardResults, type ClipboardState, type ClipboardClip } from '../../shared/clipboard';
import {
  TEXT_TRANSFORMATIONS,
  TEXT_TRANSFORMATION_LABELS,
  transformClipboardText,
  type TextTransformation,
} from '../../shared/clipboard-actions';
import { api, errorMessage } from './api';
import type { ClipboardContext } from './shelf-context';
export type PreviewAction = {
  id: string;
  label: string;
  disabled: boolean;
  title?: string;
  pressed?: boolean;
  run: () => void;
};
export type ClipboardHistoryOptions = {
  onBack: () => void;
  initialQuery?: string;
  initialContext?: ClipboardContext;
  onContextChange: (context: ClipboardContext) => void;
  snippets?: boolean;
  initialSourceClipId?: string;
};
export function useClipboardHistory({
  onBack,
  initialQuery = '',
  initialContext,
  onContextChange,
  snippets = false,
  initialSourceClipId,
}: ClipboardHistoryOptions) {
  const [state, setState] = useState<ClipboardState | undefined>(
    initialContext?.state ? { ...initialContext.state, pasteReady: false } : undefined,
  );
  const [query, setQuery] = useState(initialContext?.query ?? initialQuery);
  const [selected, setSelected] = useState<string | undefined>(initialContext?.selected);
  const writable = !!state && (!state.storage || state.storage.status === 'ready');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [confirmClear, setConfirmClear] = useState(false);
  const [previewId, setPreviewId] = useState<string | undefined>(initialContext?.previewId);
  const [transformation, setTransformation] = useState<TextTransformation | undefined>(
    initialContext?.transformation,
  );
  const [editor, setEditor] = useState<ClipboardContext['editor']>(initialContext?.editor);
  const [notice, setNotice] = useState('');
  const [menuOpen, setMenuOpen] = useState(false);
  const input = useRef<HTMLInputElement>(null);
  const request = useRef(0);
  const pending = useRef(false);
  const alive = useRef(true);
  const restoreFocus = useRef<HTMLElement | undefined>(undefined);
  const root = useRef<HTMLElement>(null);
  const contextMounted = useRef(false);
  const list = useRef<HTMLDivElement>(null);
  const scroll = useRef({
    list: initialContext?.scrollTop ?? 0,
    preview: initialContext?.previewScrollTop ?? 0,
  });
  const skipInitialScroll = useRef(!!initialContext);
  const records = (snippets ? state?.snippets : state?.clips) || [];
  const results = clipboardResults(records, query);
  const sourceOpened = useRef(false);
  useEffect(() => {
    if (
      !snippets ||
      !initialSourceClipId ||
      !state ||
      sourceOpened.current ||
      state.storage?.status === 'starting'
    )
      return;
    sourceOpened.current = true;
    const clip = state.clips.find((item) => item.id === initialSourceClipId);
    if (!clip) setError('Запись уже удалена');
    else if (clip.kind !== 'text') setError('Редактирование доступно только для текста');
    else setEditor({ clip, name: clip.name || '', content: clip.content });
  }, [snippets, initialSourceClipId, state]);
  const index = Math.max(
    0,
    results.findIndex((clip) => clip.id === selected),
  );
  const selection = results[index];
  const canPaste =
    !!state?.preferences.pasteOnSelect && state.pasteAccess === 'granted' && state.pasteReady;
  const preview = records.find((clip) => clip.id === previewId);
  const previewText =
    preview?.kind === 'text'
      ? transformation
        ? transformClipboardText(preview.content, transformation)
        : preview.content
      : undefined;
  const previewActions: PreviewAction[] = !preview
    ? []
    : preview.kind === 'text'
      ? [
          ...TEXT_TRANSFORMATIONS.map((action) => {
            const unchanged = transformClipboardText(preview.content, action) === preview.content;
            return {
              id: action,
              label: TEXT_TRANSFORMATION_LABELS[action],
              disabled: busy || unchanged,
              title: unchanged ? 'Исходный текст уже в этом виде' : undefined,
              pressed: transformation === action,
              run: () => setTransformation(action),
            };
          }),
          ...(transformation
            ? [
                {
                  id: 'original',
                  label: 'Показать оригинал',
                  disabled: busy,
                  run: () => {
                    setTransformation(undefined);
                    requestAnimationFrame(() =>
                      document.querySelector<HTMLButtonElement>('.clipboard-back')?.focus(),
                    );
                  },
                },
              ]
            : []),
        ]
      : [
          {
            id: 'saveImage',
            label: 'Сохранить изображение…',
            disabled: busy,
            run: () => {
              void run('saveImage', { id: preview.id });
            },
          },
          ...(preview.ocr?.status === 'ready'
            ? [
                {
                  id: 'copyImageText',
                  label: 'Копировать текст',
                  disabled: busy,
                  run: () => {
                    void run('copyImageText', { id: preview.id });
                  },
                },
              ]
            : preview.ocr?.status === 'failed'
              ? [
                  {
                    id: 'retryImageText',
                    label: 'Повторить распознавание',
                    disabled: busy || !writable,
                    run: () => {
                      void run('retryImageText', { id: preview.id });
                    },
                  },
                ]
              : []),
        ];
  const originalActionIndex = previewActions.findIndex((action) => action.id === 'original');
  useLayoutEffect(() => {
    if (busy) return;
    const target = restoreFocus.current;
    restoreFocus.current = undefined;
    // A disabled button loses focus. Restore it only after React has committed
    // the enabled control, without replacing a focus choice made by the user.
    if (target && document.activeElement === document.body) {
      const destination = target.isConnected
        ? target
        : root.current?.querySelector<HTMLButtonElement>('.clipboard-back');
      destination?.focus();
    }
  }, [busy]);
  const context = useRef<ClipboardContext>({
    destination: snippets ? 'snippets' : 'clipboard',
    query,
    scrollTop: 0,
    previewScrollTop: 0,
  });
  const contextWriter = useRef(onContextChange);
  contextWriter.current = onContextChange;
  function rememberScroll() {
    if (list.current) scroll.current.list = list.current.scrollTop;
    const content = root.current?.querySelector<HTMLElement>('.clipboard-preview-content');
    if (content && content.getAttribute('aria-busy') !== 'true')
      scroll.current.preview = content.scrollTop;
    context.current = {
      ...context.current,
      scrollTop: scroll.current.list,
      previewScrollTop: scroll.current.preview,
    };
    contextWriter.current(context.current);
  }
  useLayoutEffect(() => {
    // Also sample on dismissal; the browser may not have emitted its scroll event yet.
    if (contextMounted.current) {
      if (list.current) scroll.current.list = list.current.scrollTop;
      const content = root.current?.querySelector<HTMLElement>('.clipboard-preview-content');
      if (content && content.getAttribute('aria-busy') !== 'true')
        scroll.current.preview = content.scrollTop;
    }
    contextMounted.current = true;
    context.current = {
      destination: snippets ? 'snippets' : 'clipboard',
      query,
      selected,
      previewId,
      transformation,
      editor,
      scrollTop: scroll.current.list,
      previewScrollTop: scroll.current.preview,
      state,
    };
    onContextChange(context.current);
  });
  useLayoutEffect(() => {
    if (list.current) list.current.scrollTop = scroll.current.list;
  }, [preview?.id, confirmClear, !!state]);
  function openPreview(id: string) {
    scroll.current.preview = 0;
    setSelected(id);
    setTransformation(undefined);
    setNotice('');
    setError('');
    setPreviewId(id);
  }
  async function editClip(clip: ClipboardClip) {
    setError('');
    setMenuOpen(false);
    if (snippets) setEditor({ clip, name: clip.name || '', content: clip.content });
    else {
      if (pending.current) return;
      pending.current = true;
      setBusy(true);
      try {
        await api('shelf.showSnippets', { sourceClipId: clip.id });
      } catch (reason) {
        if (alive.current) setError(errorMessage(reason));
      } finally {
        pending.current = false;
        if (alive.current) setBusy(false);
      }
    }
  }
  function closeConfirmation() {
    setConfirmClear(false);
    requestAnimationFrame(() => input.current?.focus());
  }
  function closePreview() {
    setPreviewId(undefined);
    requestAnimationFrame(() => input.current?.focus());
  }
  function goBack() {
    if (editor) {
      setEditor(undefined);
      setError('');
      requestAnimationFrame(() => {
        if (preview) document.querySelector<HTMLButtonElement>('.clipboard-back')?.focus();
        else input.current?.focus();
      });
    } else if (confirmClear) closeConfirmation();
    else if (preview) closePreview();
    else onBack();
  }
  useLayoutEffect(() => {
    if (preview) document.querySelector<HTMLButtonElement>('.clipboard-back')?.focus();
  }, [preview?.id]);
  const refresh = useCallback(async () => {
    const token = ++request.current;
    try {
      const next = await api<ClipboardState>('clipboardHistory.state');
      if (token === request.current) {
        setState(next);
        const nextRecords = (snippets ? next.snippets : next.clips) || [];
        setSelected((id) => (nextRecords.some((clip) => clip.id === id) ? id : undefined));
        setPreviewId((id) => (nextRecords.some((clip) => clip.id === id) ? id : undefined));
      }
    } catch (reason) {
      if (token === request.current) setError(errorMessage(reason));
    }
  }, [snippets]);
  useEffect(() => {
    alive.current = true;
    void refresh();
    const unsubscribe = window.platform.onEvent((event) => {
      if (event.type === 'clipboardHistory.changed') void refresh();
      // Capture directly on dismissal, before a subsequent shown event can
      // remount the view. A hidden window may defer the browser's scroll event.
      if (event.type === 'shelf.presentation' && !event.presentation.visible) rememberScroll();
    });
    return () => {
      alive.current = false;
      request.current++;
      unsubscribe();
    };
  }, [refresh]);
  useEffect(() => {
    if (skipInitialScroll.current) {
      skipInitialScroll.current = false;
      return;
    }
    document.getElementById(`clip-${selection?.id}`)?.scrollIntoView({ block: 'nearest' });
  }, [selection?.id, previewId, confirmClear]);
  async function run(method: string, params = {}) {
    if (pending.current) return;
    const focusedBefore = document.activeElement;
    pending.current = true;
    setBusy(true);
    setError('');
    setNotice('');
    try {
      const result = await api(`clipboardHistory.${method}`, params);
      if (!alive.current) return false;
      if (method === 'edit' || method === 'createSnippet') {
        setSelected((result as { id: string }).id);
        setPreviewId(undefined);
        setQuery('');
      }
      if (method === 'saveImage' && result === 'saved') setNotice('Изображение сохранено');
      await refresh();
      return true;
    } catch (reason) {
      if (!alive.current) return false;
      setError(
        errorMessage(reason).replace(/^Error invoking remote method 'platform:call': Error: /, ''),
      );
    } finally {
      pending.current = false;
      if (
        (method === 'saveImage' || method === 'retryImageText') &&
        alive.current &&
        focusedBefore instanceof HTMLElement
      )
        restoreFocus.current = focusedBefore;
      setBusy(false);
    }
  }
  function createSnippet() {
    if (!snippets || !writable || busy || pending.current || editor) return;
    setPreviewId(undefined);
    setError('');
    setEditor({ name: '', content: '' });
  }
  return {
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
    editor,
    setEditor,
    notice,
    menuOpen,
    setMenuOpen,
    input,
    pending,
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
    rememberScroll,
    openPreview,
    editClip,
    closeConfirmation,
    closePreview,
    goBack,
    run,
    createSnippet,
  };
}
