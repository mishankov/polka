import { useEffect, useState } from 'react';
import { IconAdjustments, IconCommand, IconClipboard, IconInfoCircle } from '@tabler/icons-react';
import { Alert, Stack, Switch, Text } from './NativeControls';
import LauncherSettings from './LauncherSettings';
import ClipboardSettings from './ClipboardSettings';
import Updates from './Updates';
import { api, errorMessage, report } from './api';

const panes = [
  { id: 'general', label: 'Основные', icon: IconAdjustments },
  { id: 'shelf', label: 'Полка и сочетания', icon: IconCommand },
  { id: 'clipboard', label: 'Буфер обмена', icon: IconClipboard },
  { id: 'about', label: 'О приложении', icon: IconInfoCircle },
];
export default function ShelfSettings({ initialTab }: { initialTab?: 'general' | 'about' }) {
  const [tab, setTab] = useState(
    () => initialTab || localStorage.getItem('settingsPane') || 'general',
  );
  const [login, setLogin] = useState<boolean>();
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');
  const active = panes.find((pane) => pane.id === tab) || panes[0];
  useEffect(() => {
    void api<{ login: boolean }>('system.status')
      .then((state) => setLogin(state.login))
      .catch((reason) => setError(errorMessage(reason)));
    return window.platform.onEvent((event) => {
      if (event.type === 'settings.navigate' && event.pane === 'about') setTab('about');
    });
  }, []);
  useEffect(() => {
    localStorage.setItem('settingsPane', active.id);
    document.title = `${active.label} — Полка`;
  }, [active.id, active.label]);
  return (
    <main className="native-settings shelf-settings">
      <nav className="native-settings-sidebar" aria-label="Разделы настроек">
        <div className="native-settings-brand">Полка</div>
        <div role="tablist" aria-label="Разделы настроек" aria-orientation="vertical">
          {panes.map((pane, index) => (
            <button
              key={pane.id}
              id={`tab-${pane.id}`}
              role="tab"
              aria-selected={active.id === pane.id}
              aria-controls={`pane-${pane.id}`}
              tabIndex={active.id === pane.id ? 0 : -1}
              onClick={() => setTab(pane.id)}
              onKeyDown={(event) => {
                const next =
                  event.key === 'ArrowDown'
                    ? (index + 1) % panes.length
                    : event.key === 'ArrowUp'
                      ? (index + panes.length - 1) % panes.length
                      : event.key === 'Home'
                        ? 0
                        : event.key === 'End'
                          ? panes.length - 1
                          : -1;
                if (next >= 0) {
                  event.preventDefault();
                  setTab(panes[next].id);
                  document.getElementById(`tab-${panes[next].id}`)?.focus();
                }
              }}
            >
              <pane.icon size={18} stroke={1.7} />
              {pane.label}
            </button>
          ))}
        </div>
        <button
          className="native-settings-open"
          onClick={() => void api('launcher.show').catch(report)}
        >
          Открыть полку <span>↗</span>
        </button>
      </nav>
      <section
        className="native-settings-pane"
        role="tabpanel"
        id={`pane-${active.id}`}
        aria-labelledby={`tab-${active.id}`}
        tabIndex={0}
      >
        <header>
          <h1>{active.label}</h1>
        </header>
        <div className="native-settings-content">
          {error && <Alert>{error}</Alert>}
          {active.id === 'general' && (
            <Stack gap="lg">
              <Text c="dimmed">
                Приложения и история буфера обмена — всегда под рукой. Открывайте полку через значок
                в строке меню, наведением к вырезу камеры или сочетанием клавиш.
              </Text>
              <Switch
                label="Запускать при входе в macOS"
                description="В фоне, без открытия полки."
                checked={login || false}
                disabled={login === undefined || saving}
                onChange={async (event) => {
                  const enabled = event.currentTarget.checked;
                  setSaving(true);
                  setError('');
                  try {
                    setLogin(await api<boolean>('system.login', { enabled }));
                  } catch (reason) {
                    setError(errorMessage(reason));
                  } finally {
                    setSaving(false);
                  }
                }}
              />
              <Text c="dimmed">
                Закрытие полки и настроек оставляет историю и сочетания доступными. Для выхода
                выберите «Выйти из Полки» в строке меню.
              </Text>
            </Stack>
          )}
          {active.id === 'shelf' && <LauncherSettings />}
          {active.id === 'clipboard' && <ClipboardSettings />}
          {active.id === 'about' && (
            <Stack gap="lg">
              <div className="native-about">
                <h2>Полка</h2>
                <Text c="dimmed">Приложения и история буфера обмена — на одной полке.</Text>
              </div>
              <Updates />
              <Text c="dimmed">История хранится локально в зашифрованном виде.</Text>
            </Stack>
          )}
        </div>
      </section>
    </main>
  );
}
