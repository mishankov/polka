import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react';
import { clipboardResults, type ClipboardState } from '../../shared/clipboard';
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
};

export function useClipboardHistory({
  onBack,
  initialQuery = '',
  initialContext,
  onContextChange,
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
  const [notice, setNotice] = useState('');
  const [menuOpen, setMenuOpen] = useState(false);
  const input = useRef<HTMLInputElement>(null);
  const request = useRef(0);
  const pending = useRef(false);
  const alive = useRef(true);
  const root = useRef<HTMLElement>(null);
  const contextMounted = useRef(false);
  const list = useRef<HTMLDivElement>(null);
  const scroll = useRef({
    list: initialContext?.scrollTop ?? 0,
    preview: initialContext?.previewScrollTop ?? 0,
  });
  const skipInitialScroll = useRef(!!initialContext);
  const results = clipboardResults(state?.clips || [], query);
  const index = Math.max(
    0,
    results.findIndex((clip) => clip.id === selected),
  );
  const selection = results[index];
  const canPaste =
    !!state?.preferences.pasteOnSelect && state.pasteAccess === 'granted' && state.pasteReady;
  const preview = state?.clips.find((clip) => clip.id === previewId);
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
        ];
  const originalActionIndex = previewActions.findIndex((action) => action.id === 'original');
  const context = useRef<ClipboardContext>({
    destination: 'clipboard',
    query,
    scrollTop: 0,
    previewScrollTop: 0,
  });
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
      destination: 'clipboard',
      query,
      selected,
      previewId,
      transformation,
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
  function closeConfirmation() {
    setConfirmClear(false);
    requestAnimationFrame(() => input.current?.focus());
  }
  function closePreview() {
    setPreviewId(undefined);
    requestAnimationFrame(() => input.current?.focus());
  }
  function goBack() {
    if (confirmClear) closeConfirmation();
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
        setSelected((id) => (next.clips.some((clip) => clip.id === id) ? id : undefined));
        setPreviewId((id) => (next.clips.some((clip) => clip.id === id) ? id : undefined));
      }
    } catch (reason) {
      if (token === request.current) setError(errorMessage(reason));
    }
  }, []);
  useEffect(() => {
    alive.current = true;
    void refresh();
    const unsubscribe = window.platform.onEvent((event) => {
      if (event.type === 'clipboardHistory.changed') void refresh();
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
      setBusy(false);
      if (method === 'saveImage' && alive.current)
        requestAnimationFrame(() => {
          if (
            alive.current &&
            focusedBefore instanceof HTMLElement &&
            focusedBefore.isConnected &&
            document.activeElement === document.body
          )
            focusedBefore.focus();
        });
    }
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
  };
}
