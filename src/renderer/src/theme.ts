import {
  createTheme,
  defaultVariantColorsResolver,
  type CSSVariablesResolver,
} from '@mantine/core';

// Shared by the shell and app screens; application theme choices can override it.
export const workspaceTheme = createTheme({
  primaryColor: 'orange',
  autoContrast: true,
  variantColorResolver: (input) => {
    const colors = defaultVariantColorsResolver(input);
    return input.variant === 'filled' && (input.color || input.theme.primaryColor) === 'orange'
      ? { ...colors, color: 'var(--accent-contrast)' }
      : colors;
  },
  primaryShade: { light: 7, dark: 3 },
  defaultRadius: 'md',
  radius: { xs: '6px', sm: '10px', md: '14px', lg: '20px', xl: '28px' },
  fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif',
  headings: { fontFamily: 'inherit', fontWeight: '550' },
  colors: {
    sage: [
      '#f3f5ee',
      '#e7ebdc',
      '#d2dbc0',
      '#bbc9a2',
      '#a3b583',
      '#8c9f6b',
      '#738754',
      '#5c6e43',
      '#4a5838',
      '#3c4830',
    ],
    orange: [
      '#fcf1e9',
      '#f4e2d5',
      '#e8c5af',
      '#dca68a',
      '#cd8b69',
      '#b97353',
      '#a86142',
      '#8f4f36',
      '#77412e',
      '#613728',
    ],
    gray: [
      '#faf7f2',
      '#f2ece3',
      '#e9e0d5',
      '#d9cfc2',
      '#bbae9d',
      '#a29484',
      '#857667',
      '#6d5e51',
      '#514438',
      '#392f27',
    ],
    dark: [
      '#ede4da',
      '#d1c3b5',
      '#b09f8e',
      '#8e7d6e',
      '#65564a',
      '#4c4036',
      '#352d27',
      '#29231f',
      '#211c19',
      '#191613',
    ],
  },
});

const surfaceVariables = {
  '--mantine-color-default-border': 'var(--line)',
  '--mantine-color-default': 'var(--surface-raised)',
  '--mantine-color-default-hover': 'var(--soft)',
  '--mantine-color-default-color': 'var(--ink)',
  '--mantine-color-body': 'var(--workspace-bg)',
  '--mantine-color-text': 'var(--ink)',
  '--mantine-color-bright': 'var(--ink)',
  '--mantine-color-dimmed': 'var(--muted)',
  '--mantine-color-placeholder': 'var(--muted)',
  '--mantine-color-anchor': 'var(--accent)',
};

export const workspaceVariables: CSSVariablesResolver = () => ({
  variables: {
    '--home-chrome': 'var(--sidebar-bg)',
    '--home-canvas': 'var(--workspace-bg)',
    '--home-ink': 'var(--ink)',
    '--home-muted': 'var(--muted)',
    '--home-hover': 'var(--soft)',
    '--home-border': 'var(--line)',
    '--character-face': '#47513d',
    '--character-body': '#c5ceab',
    '--character-shade': '#afbc91',
    '--character-error': '#dfaa95',
    '--character-waiting': '#ddc794',
  },
  light: {
    ...surfaceVariables,
    '--workspace-bg': '#faf7f2',
    '--surface-raised': '#fffcf7',
    '--sidebar-bg': '#eee5d9',
    '--line': '#e3d8ca',
    '--ink': '#473b31',
    '--muted': '#877767',
    '--accent': '#94573e',
    '--accent-contrast': '#fffcf7',
    '--soft': '#e9d9c8',
    '--home-composer-shadow': '0 3px 10px #76523305, 0 12px 36px #76523308',
    '--character-shadow': '#76523312',
  },
  dark: {
    ...surfaceVariables,
    '--workspace-bg': '#28221e',
    '--surface-raised': '#302822',
    '--sidebar-bg': '#201b17',
    '--line': '#493c31',
    '--ink': '#eee3d5',
    '--muted': '#b5a28e',
    '--accent': '#dca68a',
    '--accent-contrast': '#39271e',
    '--soft': '#3f3027',
    '--home-composer-shadow': '0 4px 24px #0d08051c',
    '--character-shadow': '#0d080518',
  },
});
