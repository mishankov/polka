import React, { useEffect } from 'react';
import { createRoot } from 'react-dom/client';
import './styles.css';
import './native.css';
import { ErrorBoundary } from './ErrorBoundary';
import Shelf from './Shelf';
import ShelfSettings from './ShelfSettings';
import DesktopNotifications from './DesktopNotifications';
import { api } from './api';
const params = new URLSearchParams(location.search);
const mode = params.get('mode');
document.documentElement.dataset.windowMode = mode === 'settings' ? 'settings' : 'shelf';
function Desktop() {
  useEffect(() => {
    const apply = (appearance: {
      dark: boolean;
      contrast: boolean;
      reducedTransparency: boolean;
    }) => {
      document.documentElement.dataset.appearance = appearance.dark ? 'dark' : 'light';
      document.documentElement.dataset.contrast = String(appearance.contrast);
      document.documentElement.dataset.reducedTransparency = String(appearance.reducedTransparency);
    };
    let changed = false;
    const unsubscribe = window.platform.onEvent((event) => {
      if (event.type === 'appearance.changed') {
        changed = true;
        apply(event.appearance);
      }
    });
    void api('shelf.appearance')
      .then((value) => {
        if (!changed) apply(value);
      })
      .catch(() => {});
    return unsubscribe;
  }, []);
  return (
    <>
      {mode === 'settings' ? (
        <ShelfSettings
          initialTab={
            params.get('pane') === 'about'
              ? 'about'
              : params.get('pane') === 'clipboard'
                ? 'clipboard'
                : undefined
          }
        />
      ) : (
        <Shelf />
      )}
    </>
  );
}
createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <ErrorBoundary>
      <DesktopNotifications />
      <Desktop />
    </ErrorBoundary>
  </React.StrictMode>,
);
