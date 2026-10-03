import { useEffect, useState } from 'react';
import { ActionIcon, Alert, Button, Loader, Modal, Stack, Text, Tooltip } from '@mantine/core';
import { IconSettings } from '@tabler/icons-react';
import type { AppInstance } from '../../shared/types';
import { api, report } from './api';
import { flushDocuments } from './documentFlush';
import Runtime from './Runtime';
import WindowPreferences from './WindowPreferences';

/** An app window stays bound to its requested app; workspace navigation lives elsewhere. */
export default function StandaloneApp({ appId }: { appId: string }) {
  const [app, setApp] = useState<AppInstance>();
  const [failed, setFailed] = useState(false);
  const [attempt, setAttempt] = useState(0);
  const [settingsOpened, setSettingsOpened] = useState(false);
  const [screen, setScreen] = useState<string | undefined>(
    () => localStorage.getItem('screen:' + appId) || undefined,
  );
  useEffect(() => {
    let active = true;
    let request = 0;
    let opening = true;
    const refresh = async (start = false) => {
      const current = ++request;
      try {
        const next = await api(start ? 'apps.start' : 'apps.get', { appId });
        if (!active || current !== request) return;
        setApp(next);
        setFailed(false);
        document.title = next.name;
      } catch {
        if (!active || current !== request) return;
        setApp(undefined);
        setFailed(true);
      } finally {
        if (start) opening = false;
      }
    };
    void refresh(true);
    const unsubscribe = window.platform.onEvent((event) => {
      if (event.type === 'workspace.changed' && !opening) void refresh();
      if (event.type === 'workspace.beforeClose') {
        void flushDocuments()
          .then(() => api('windows.confirmClose', { token: event.token }))
          .catch((error) => {
            report(error);
            void api('windows.confirmClose', { token: event.token, error: String(error) });
          });
      }
    });
    return () => {
      active = false;
      unsubscribe();
    };
  }, [appId, attempt]);
  return (
    <main className="standalone-app" aria-label={app?.name || 'Приложение'}>
      <header className="standalone-titlebar">
        <span>{app?.name || 'Приложение'}</span>
        <Tooltip label="Настройки окна">
          <ActionIcon
            className="standalone-window-settings"
            variant="subtle"
            color="gray"
            aria-label="Настройки окна"
            onClick={() => setSettingsOpened(true)}
          >
            <IconSettings size={17} />
          </ActionIcon>
        </Tooltip>
      </header>
      <Modal
        opened={settingsOpened}
        onClose={() => setSettingsOpened(false)}
        title={`Настройки окна · ${app?.name || 'Приложение'}`}
        centered
      >
        {settingsOpened && <WindowPreferences appId={appId} />}
      </Modal>
      <div className="standalone-content">
        {app ? (
          <Runtime
            app={app}
            standalone
            screenId={screen}
            onScreenChange={(id) => {
              setScreen(id);
              localStorage.setItem('screen:' + appId, id);
            }}
          />
        ) : failed ? (
          <Alert title="Не удалось открыть приложение" color="red" m="md">
            <Stack gap="sm" align="flex-start">
              <Text size="sm">
                Попробуйте открыть его снова или проверьте его в рабочем пространстве.
              </Text>
              <Button
                variant="default"
                onClick={() => {
                  setFailed(false);
                  setAttempt((value) => value + 1);
                }}
              >
                Повторить
              </Button>
            </Stack>
          </Alert>
        ) : (
          <Loader aria-label="Открытие приложения" m="md" size="sm" />
        )}
      </div>
    </main>
  );
}
