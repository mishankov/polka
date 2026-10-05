import React from 'react';
import { createRoot } from 'react-dom/client';
import { MantineProvider } from '@mantine/core';
import { Notifications } from '@mantine/notifications';
import '@mantine/core/styles.css';
import '@mantine/notifications/styles.css';
import './styles.css';
import App from './App';
import { ErrorBoundary } from './ErrorBoundary';
import { shelfTheme, shelfVariables } from './theme';
document.documentElement.dataset.windowMode = 'shelf';
createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <MantineProvider
      theme={shelfTheme}
      cssVariablesResolver={shelfVariables}
      defaultColorScheme="auto"
      forceColorScheme={'dark'}
    >
      <Notifications position="bottom-right" />
      <ErrorBoundary>
        <App />
      </ErrorBoundary>
    </MantineProvider>
  </React.StrictMode>,
);
