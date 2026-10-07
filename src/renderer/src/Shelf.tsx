import { useCallback, useEffect, useRef, useState, type CSSProperties } from 'react';
import { flushSync } from 'react-dom';
import type { ShelfEntry, ShelfPresentation } from '../../shared/shelf';
import { api, report } from './api';
import Launcher from './Launcher';

export default function Shelf() {
  const hasOpened = useRef(false);
  const [presentation, setPresentation] = useState<ShelfPresentation>({
    revision: -1,
    sessionId: 0,
    entryMode: 'fresh',
    destination: 'apps',
    visible: false,
    focusSearch: false,
    topInset: 0,
    notchWidth: 96,
    notchHeight: 3,
  });
  const [entry, setEntry] = useState<ShelfEntry>({
    revision: -1,
    sessionId: 0,
    entryMode: 'fresh',
    destination: 'apps',
    searchQuery: '',
  });
  const [committedRevision, setCommittedRevision] = useState(-1);
  const latest = useRef(-1);
  const apply = useCallback((next: ShelfPresentation, navigate = false) => {
    if (next.revision < latest.current) return;
    latest.current = next.revision;
    if (next.visible) hasOpened.current = true;
    setPresentation(next);
    if (navigate && next.visible) setEntry(next);
  }, []);
  useEffect(() => {
    const show = (next: ShelfPresentation) => {
      if (next.revision < latest.current) return;
      flushSync(() => apply(next, true));
      if (next.visible)
        void api<boolean>('shelf.didShow', { revision: next.revision })
          .then((accepted) => {
            if (accepted) setCommittedRevision((revision) => Math.max(revision, next.revision));
          })
          .catch(report);
    };
    const unsubscribe = window.platform.onEvent((event) => {
      if (event.type === 'shelf.presentation') {
        // Commit dismissal before a subsequent shown event can prepare a new
        // entry from the saved context. The departing UI samples its scroll in
        // layout effects, even when the browser has not emitted a scroll event.
        if (!event.presentation.visible) flushSync(() => apply(event.presentation));
        else apply(event.presentation);
      }
      if (event.type === 'shelf.shown') show(event.presentation);
    });
    // The first shown event can precede subscription on a cold startup. Commit
    // and acknowledge the snapshot too, so the native window can safely appear.
    void api<ShelfPresentation>('shelf.presentation').then(show).catch(report);
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
      aria-label="Полка"
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
      <Launcher entry={entry} committedRevision={committedRevision} />
    </main>
  );
}
