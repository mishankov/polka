import { useEffect, useState } from 'react';
import type { UpdateState } from '../../main/updates';
import { api, report } from './api';

export function useUpdates() {
  const [state, setState] = useState<UpdateState>();
  const [pending, setPending] = useState('');
  useEffect(() => {
    let changed = false;
    let active = true;
    const unsubscribe = window.platform.onEvent((event) => {
      if (event.type === 'updates.state') {
        changed = true;
        setState(event.state);
      }
    });
    void api<UpdateState>('updates.status')
      .then((value) => {
        if (active && !changed) setState(value);
      })
      .catch(report);
    return () => {
      active = false;
      unsubscribe();
    };
  }, []);
  const action = async (name: string) => {
    setPending(name);
    try {
      setState(await api<UpdateState>(`updates.${name}`, { version: state?.version }));
    } catch (error) {
      report(error);
    } finally {
      setPending('');
    }
  };
  return { state, pending, action };
}
