/** Fixed libraries shipped with the app. Never resolved from the network. */
export const extensionDependencies: Record<string, string> = Object.freeze({
  react: '19.3.0',
  'react-dom': '19.3.0',
  '@mantine/core': '9.6.3',
  '@mantine/hooks': '9.6.3',
  recharts: '3.10.1',
  zod: '4.6.5',
  '@everything/ui': '1.0.0',
});
export const extensionImports = new Set([
  ...Object.keys(extensionDependencies).filter((name) => name !== 'react-dom'),
  'react/jsx-runtime',
  'react-dom/client',
]);
