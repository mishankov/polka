import React, { Suspense, lazy, useEffect } from 'react';
import { createRoot } from 'react-dom/client';
import './styles.css';
import './native.css';
import { ErrorBoundary } from './ErrorBoundary';
import Shelf from './Shelf';
import ShelfSettings from './ShelfSettings';
import DesktopNotifications from './DesktopNotifications';
import { CUSTOM_APPS_ENABLED } from '../../shared/features';
import { api } from './api';
const LegacyRoot = lazy(() => import('./LegacyRoot'));
const params = new URLSearchParams(location.search);
const mode = params.get('mode');
const desktop = !CUSTOM_APPS_ENABLED || mode === 'shelf' || mode === 'settings';
if (desktop)
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
      if (event.type === 'workspace.beforeClose' && mode === 'settings')
        void api('windows.confirmClose', { token: event.token });
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
        <ShelfSettings initialTab={params.get('pane') === 'about' ? 'about' : undefined} />
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
      {desktop ? (
        <Desktop />
      ) : (
        <Suspense>
          <LegacyRoot />
        </Suspense>
      )}
    </ErrorBoundary>
  </React.StrictMode>,
);
