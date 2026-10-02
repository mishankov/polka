import { useCallback, useEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { IconDots } from '@tabler/icons-react';
import {
  ActionIcon,
  Alert,
  Button,
  Loader,
  Menu,
  Stack,
  Text,
  useComputedColorScheme,
} from '@mantine/core';
export function CustomExtension({
  appId,
  extensionId,
  controlsHost,
}: {
  appId: string;
  extensionId: string;
  controlsHost: HTMLElement | null;
}) {
  const area = useRef<HTMLDivElement>(null),
    viewId = useRef<string | null>(null),
    scheme = useComputedColorScheme('light');
  const [generation, setGeneration] = useState(0),
    [status, setStatus] = useState('loading'),
    [error, setError] = useState('');
  const schemeRef = useRef(scheme);
  schemeRef.current = scheme;
  const geometry = useCallback(() => {
    const node = area.current;
    if (!node) return { bounds: { x: 0, y: 0, width: 0, height: 0 }, visible: false };
    const box = node.getBoundingClientRect();
    let left = Math.max(0, box.left),
      top = Math.max(0, box.top),
      right = Math.min(innerWidth, box.right),
      bottom = Math.min(innerHeight, box.bottom);
    for (let parent = node.parentElement; parent; parent = parent.parentElement) {
      const css = getComputedStyle(parent);
      if (/(auto|scroll|hidden|clip)/.test(`${css.overflow} ${css.overflowY}`)) {
        const rect = parent.getBoundingClientRect();
        left = Math.max(left, rect.left);
        top = Math.max(top, rect.top);
        right = Math.min(right, rect.right);
        bottom = Math.min(bottom, rect.bottom);
      }
    }
    // Native child views are above the DOM; hide while shell dialogs/menus cover them.
    const overlay = [
      ...document.querySelectorAll(
        '[role="dialog"], [role="menu"], .mantine-Modal-overlay, .mantine-Drawer-overlay, .agent-panel',
      ),
    ].some((el) => {
      const rect = el.getBoundingClientRect();
      return (
        rect.width > 0 &&
        rect.height > 0 &&
        rect.left < right &&
        rect.right > left &&
        rect.top < bottom &&
        rect.bottom > top
      );
    });
    return {
      bounds: {
        x: left,
        y: top,
        width: Math.max(0, right - left),
        height: Math.max(0, bottom - top),
      },
      visible: !overlay && right > left && bottom > top && document.visibilityState === 'visible',
    };
  }, []);
  useEffect(() => {
    let active = true,
      opening = true;
    const id = crypto.randomUUID();
    viewId.current = id;
    setStatus('loading');
    setError('');
    const unsubscribe = window.platform.onEvent((event) => {
      if (event.type === 'extension.status' && event.viewId === id && active) {
        setStatus(event.status);
        setError(event.message || '');
      }
    });
    window.platform
      .call('extensions.view.open', {
        viewId: id,
        appId,
        extensionId,
        theme: { scheme: schemeRef.current },
        ...geometry(),
      })
      .then(() => {
        opening = false;
        if (active) sync();
        else void window.platform.call('extensions.view.close', { viewId: id }).catch(() => {});
      })
      .catch((e) => {
        opening = false;
        if (active) {
          setStatus('error');
          setError(e.message);
        }
      });
    let previous = '';
    function sync() {
      if (!active || opening) return;
      const next = geometry(),
        key = JSON.stringify(next);
      if (key === previous) return;
      previous = key;
      void window.platform.call('extensions.view.bounds', { viewId: id, ...next }).catch(() => {});
    }
    const observer = new ResizeObserver(sync);
    if (area.current) observer.observe(area.current);
    const mutations = new MutationObserver(sync);
    mutations.observe(document.body, {
      subtree: true,
      childList: true,
      attributes: true,
      attributeFilter: ['style', 'class', 'hidden'],
    });
    window.addEventListener('resize', sync);
    window.addEventListener('scroll', sync, true);
    document.addEventListener('visibilitychange', sync);
    return () => {
      active = false;
      unsubscribe();
      observer.disconnect();
      mutations.disconnect();
      window.removeEventListener('resize', sync);
      window.removeEventListener('scroll', sync, true);
      document.removeEventListener('visibilitychange', sync);
      void window.platform.call('extensions.view.close', { viewId: id }).catch(() => {});
      if (viewId.current === id) viewId.current = null;
    };
  }, [appId, extensionId, generation, geometry]);
  useEffect(() => {
    if (viewId.current)
      void window.platform
        .call('extensions.view.theme', { viewId: viewId.current, theme: { scheme } })
        .catch(() => {});
  }, [scheme]);
  async function stop() {
    if (viewId.current)
      await window.platform.call('extensions.view.close', { viewId: viewId.current });
    setStatus('stopped');
  }
  return (
    <Stack gap="sm" className="custom-extension" style={{ flex: 1, minHeight: 0 }}>
      {controlsHost &&
        createPortal(
          <Menu position="bottom-end">
            <Menu.Target>
              <ActionIcon
                variant="subtle"
                color="gray"
                aria-label="Меню экрана"
                title="Меню экрана"
              >
                <IconDots size={18} />
              </ActionIcon>
            </Menu.Target>
            <Menu.Dropdown>
              <Menu.Item onClick={() => setGeneration((v) => v + 1)}>Перезапустить экран</Menu.Item>
              {['loading', 'ready'].includes(status) && (
                <Menu.Item onClick={() => void stop().catch((e) => setError(e.message))}>
                  Остановить экран
                </Menu.Item>
              )}
            </Menu.Dropdown>
          </Menu>,
          controlsHost,
        )}
      {error && (
        <Alert color="red" title="Экран не запущен">
          <Text size="sm">
            Не удалось открыть экран. Попросите помощника проверить и исправить приложение.
          </Text>
          <Button size="xs" variant="subtle" onClick={() => setGeneration((v) => v + 1)}>
            Перезапустить экран
          </Button>
          <details className="agent-details">
            <summary>Подробности ошибки</summary>
            <Text size="xs">{error}</Text>
          </details>
        </Alert>
      )}
      <div
        ref={area}
        data-extension-view={extensionId}
        style={{
          width: '100%',
          flex: 1,
          minHeight: 0,
          position: 'relative',
        }}
      >
        {status === 'loading' && <Loader aria-label="Сборка расширения" />}
        {status === 'stopped' && (
          <Stack align="flex-start" gap="xs">
            <Text c="dimmed">
              Экран остановлен. Нажмите «Перезапустить экран», чтобы вернуться.
            </Text>
            <Button size="xs" variant="light" onClick={() => setGeneration((v) => v + 1)}>
              Перезапустить экран
            </Button>
          </Stack>
        )}
      </div>
    </Stack>
  );
}
