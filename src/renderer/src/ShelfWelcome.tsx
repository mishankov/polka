import { useEffect, useState } from 'react';
import { Button, Group, Text } from '@mantine/core';
import { DEFAULT_LAUNCHER_SHORTCUT, shortcutLabel } from '../../shared/launcher';
import { api, report } from './api';

export default function ShelfWelcome() {
  const [visible, setVisible] = useState(false);
  const [shortcut, setShortcut] = useState(DEFAULT_LAUNCHER_SHORTCUT);
  const [saving, setSaving] = useState(false);
  useEffect(() => {
    void api('settings.get', { key: 'shelfIntroduced' })
      .then((seen) => setVisible(!seen))
      .catch(report);
    void api('launcher.getPreferences')
      .then((preferences) => setShortcut(preferences.accelerator))
      .catch(report);
  }, []);
  if (!visible) return null;
  return (
    <div className="shelf-welcome">
      <Text fw={550} size="sm">
        Всё начинается с полки
      </Text>
      <Text size="sm" c="dimmed" mt={4}>
        Открывайте приложения и находите скопированное. Вернуться сюда можно через значок в строке
        меню, наведением к вырезу камеры{shortcut ? ` или ${shortcutLabel(shortcut)}` : ''}.
      </Text>
      <Group mt="sm" gap="xs">
        <Button
          size="xs"
          variant="default"
          loading={saving}
          onClick={() => {
            setSaving(true);
            void api('settings.set', { key: 'shelfIntroduced', value: true })
              .then(() => setVisible(false))
              .catch(report)
              .finally(() => setSaving(false));
          }}
        >
          Понятно
        </Button>
        <Button size="xs" variant="subtle" onClick={() => void api('shelf.settings').catch(report)}>
          Настроить полку
        </Button>
      </Group>
    </div>
  );
}
