import React from 'react';
import { createRoot } from 'react-dom/client';
import { MantineProvider } from '@mantine/core';
import { Notifications } from '@mantine/notifications';
import '@mantine/core/styles.css';
import '@mantine/notifications/styles.css';
import './styles.css';
import App from './App';
import { ErrorBoundary } from './ErrorBoundary';
import { workspaceTheme, workspaceVariables, shelfTheme, shelfVariables } from './theme';
const mode = new URLSearchParams(location.search).get('mode');
if (mode === 'shelf') document.documentElement.dataset.windowMode = mode;
createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <MantineProvider
      theme={mode === 'shelf' ? shelfTheme : workspaceTheme}
      cssVariablesResolver={mode === 'shelf' ? shelfVariables : workspaceVariables}
      defaultColorScheme="auto"
      forceColorScheme={mode === 'shelf' ? 'dark' : undefined}
    >
      <Notifications position="bottom-right" />
      <ErrorBoundary>
        <App />
      </ErrorBoundary>
    </MantineProvider>
  </React.StrictMode>,
);
