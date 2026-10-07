import { useCallback, useEffect, useRef, useState } from 'react';
import type { ShortcutsState } from '../../shared/macos-shortcuts';
import { api, errorMessage } from './api';

export function useMacShortcuts() {
  const [state, setState] = useState<ShortcutsState>({ shortcuts: [] });
  const [loading, setLoading] = useState(true);
  const generation = useRef(0);
  const apply = useCallback((next: ShortcutsState) => {
    generation.current++;
    setState(next);
    setLoading(false);
  }, []);
  const refresh = useCallback(async () => {
    const token = ++generation.current;
    try {
      const next = await api<ShortcutsState>('macShortcuts.state', { refresh: true });
      if (token === generation.current) setState(next);
    } catch (error) {
      if (token === generation.current)
        setState((previous) => ({ ...previous, error: errorMessage(error) }));
    } finally {
      if (token === generation.current) setLoading(false);
    }
  }, []);
  useEffect(() => {
    void refresh();
    const unsubscribe = window.platform.onEvent((event) => {
      if (event.type === 'macShortcuts.changed') {
        apply(event.state);
      }
    });
    const timer = window.setInterval(() => void refresh(), 30000);
    const focus = () => void refresh();
    window.addEventListener('focus', focus);
    return () => {
      generation.current++;
      unsubscribe();
      clearInterval(timer);
      window.removeEventListener('focus', focus);
    };
  }, [refresh, apply]);
  return { state, loading, refresh };
}
