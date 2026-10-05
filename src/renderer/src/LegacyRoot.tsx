import { MantineProvider } from '@mantine/core';
import { Notifications } from '@mantine/notifications';
import '@mantine/core/styles.css';
import '@mantine/notifications/styles.css';
import App from './App';
import { workspaceTheme, workspaceVariables } from './theme';
export default function LegacyRoot() {
  return (
    <MantineProvider
      theme={workspaceTheme}
      cssVariablesResolver={workspaceVariables}
      defaultColorScheme="auto"
    >
      <Notifications position="bottom-right" />
      <App />
    </MantineProvider>
  );
}
