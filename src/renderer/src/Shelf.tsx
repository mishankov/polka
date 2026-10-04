import { useCallback, useEffect, useRef, useState, type CSSProperties } from 'react';
import type { ShelfDestination, ShelfPresentation } from '../../shared/shelf';
import { api, report } from './api';
import Launcher from './Launcher';

export default function Shelf() {
  const hasOpened = useRef(false);
  const [presentation, setPresentation] = useState<ShelfPresentation>({
    revision: -1,
    destination: 'apps',
    visible: false,
    focusSearch: false,
    topInset: 0,
    notchWidth: 96,
    notchHeight: 3,
  });
  const [entry, setEntry] = useState({
    revision: -1,
    destination: 'apps' as ShelfDestination,
    searchQuery: '',
  });
  const latest = useRef(-1);
  const apply = useCallback((next: ShelfPresentation, navigate = false) => {
    if (next.revision < latest.current) return;
    latest.current = next.revision;
    if (next.visible) hasOpened.current = true;
    setPresentation(next);
    if (navigate && next.visible)
      setEntry({
        revision: next.revision,
        destination: next.destination,
        searchQuery: next.searchQuery || '',
      });
  }, []);
  useEffect(() => {
    const unsubscribe = window.platform.onEvent((event) => {
      if (event.type === 'shelf.presentation') apply(event.presentation);
      if (event.type === 'shelf.shown') apply(event.presentation, true);
    });
    void api<ShelfPresentation>('shelf.presentation')
      .then((next) => apply(next, true))
      .catch(report);
    return unsubscribe;
  }, [apply]);
  useEffect(() => {
    if (
      !presentation.visible &&
      presentation.revision >= 0 &&
      window.matchMedia('(prefers-reduced-motion: reduce)').matches
    )
      void api('shelf.didHide', { revision: presentation.revision }).catch(report);
  }, [presentation]);
  return (
    <main
      className={`clipboard-shelf ${presentation.visible ? 'is-open' : hasOpened.current ? 'is-closed' : 'is-idle'}`}
      aria-label="Полка Everything App"
      data-notched={presentation.topInset > 0 || undefined}
      style={
        {
          '--notch-width': `${presentation.notchWidth}px`,
          '--notch-height': `${presentation.notchHeight}px`,
          '--notch-inset': `${presentation.topInset}px`,
        } as CSSProperties
      }
      onAnimationEnd={(event) => {
        if (
          event.target === event.currentTarget &&
          event.animationName === 'clipboard-hide' &&
          !presentation.visible
        )
          void api('shelf.didHide', { revision: presentation.revision }).catch(report);
      }}
    >
      <Launcher entry={entry} />
    </main>
  );
}
