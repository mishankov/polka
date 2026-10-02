import * as React from 'react';
import * as JSX from 'react/jsx-runtime';
import * as DOM from 'react-dom/client';
import * as Mantine from '@mantine/core';
import * as Hooks from '@mantine/hooks';
import * as Charts from 'recharts';
import * as Zod from 'zod';
import * as Platform from './platform';
import { workspaceTheme, workspaceVariables } from '../renderer/src/theme';
import '@mantine/core/styles.css';

type Theme = { scheme: 'light' | 'dark'; primaryColor?: string; radius?: string; density?: string };
declare global {
  interface Window {
    extensionHost: {
      call: Platform.ExtensionSDK['call'];
      theme: () => Promise<Theme>;
      onTheme: (callback: (theme: Theme) => void) => () => void;
      ready: () => void;
      failure: (message: string) => void;
    };
    __extensionModules: Record<string, unknown>;
    __mountExtension: (component: React.ComponentType<any>) => void;
  }
}
window.__extensionModules = {
  react: React,
  'react/jsx-runtime': JSX,
  'react-dom/client': DOM,
  '@mantine/core': Mantine,
  '@mantine/hooks': Hooks,
  recharts: Charts,
  zod: Zod,
  '@everything/ui': Platform,
};
class Boundary extends React.Component<{ children: React.ReactNode }, { error?: Error }> {
  state: { error?: Error } = {};
  static getDerivedStateFromError(error: Error) {
    return { error };
  }
  componentDidCatch(error: Error) {
    window.extensionHost.failure(error.message);
  }
  render() {
    return this.state.error ? <Platform.ErrorView error={this.state.error} /> : this.props.children;
  }
}
function Screen({ component: Component }: { component: React.ComponentType<any> }) {
  const [theme, setTheme] = React.useState<Theme>({ scheme: 'light' });
  React.useEffect(() => {
    let live = true;
    window.extensionHost.theme().then((t) => live && setTheme(t));
    const unsubscribe = window.extensionHost.onTheme(setTheme);
    window.extensionHost.ready();
    return () => {
      live = false;
      unsubscribe();
    };
  }, []);
  const sdk = React.useMemo(() => ({ call: window.extensionHost.call }), []);
  return (
    <Mantine.MantineProvider
      forceColorScheme={theme.scheme}
      cssVariablesResolver={workspaceVariables}
      theme={{
        ...workspaceTheme,
        primaryColor: theme.primaryColor || workspaceTheme.primaryColor,
        defaultRadius: theme.radius || workspaceTheme.defaultRadius,
        ...(theme.density === 'compact'
          ? { spacing: { xs: '6px', sm: '10px', md: '14px', lg: '18px', xl: '24px' } }
          : {}),
      }}
    >
      <Platform.SDKContext.Provider value={sdk}>
        <Boundary>
          <Component sdk={sdk} />
        </Boundary>
      </Platform.SDKContext.Provider>
    </Mantine.MantineProvider>
  );
}
window.__mountExtension = (component) =>
  DOM.createRoot(document.getElementById('root')!).render(<Screen component={component} />);
