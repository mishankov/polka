import { useEffect, useState } from 'react';
import { Button } from './NativeControls';
export type DesktopNotice = { message: string; error?: boolean };
export function notify(notice: DesktopNotice) {
  window.dispatchEvent(new CustomEvent('desktop-notice', { detail: notice }));
}
export default function DesktopNotifications() {
  const [notice, setNotice] = useState<DesktopNotice>();
  useEffect(() => {
    const receive = (event: Event) => setNotice((event as CustomEvent<DesktopNotice>).detail);
    window.addEventListener('desktop-notice', receive);
    return () => window.removeEventListener('desktop-notice', receive);
  }, []);
  useEffect(() => {
    if (!notice || notice.error) return;
    const timer = setTimeout(() => setNotice(undefined), 4000);
    return () => clearTimeout(timer);
  }, [notice]);
  return notice ? (
    <div className="native-notice" role={notice.error ? 'alert' : 'status'}>
      <div>
        {notice.error && <strong>Не удалось выполнить действие</strong>}
        <p>{notice.message}</p>
      </div>
      <Button
        variant="subtle"
        aria-label="Закрыть уведомление"
        onClick={() => setNotice(undefined)}
      >
        ×
      </Button>
    </div>
  ) : null;
}
