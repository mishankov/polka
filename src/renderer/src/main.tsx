import React from 'react';
import { createRoot } from 'react-dom/client';
import { MantineProvider } from '@mantine/core';
import { Notifications } from '@mantine/notifications';
import '@mantine/core/styles.css';
import '@mantine/notifications/styles.css';
import './styles.css';
import App from './App';
import { ErrorBoundary } from './ErrorBoundary';
import { workspaceTheme, workspaceVariables } from './theme';
const mode = new URLSearchParams(location.search).get('mode');
if (mode === 'launcher' || mode === 'clipboard') document.documentElement.dataset.windowMode = mode;
createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <MantineProvider
      theme={workspaceTheme}
      cssVariablesResolver={workspaceVariables}
      defaultColorScheme="auto"
      forceColorScheme={mode === 'clipboard' ? 'dark' : undefined}
    >
      <Notifications position="bottom-right" />
      <ErrorBoundary>
        <App />
      </ErrorBoundary>
    </MantineProvider>
  </React.StrictMode>,
);
