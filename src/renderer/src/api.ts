import { notify } from './DesktopNotifications';
export type AnyRecord = Record<string, any>;
import type {} from '../../shared/types';
export const api = <T = any>(method: string, params: any = {}): Promise<T> =>
  window.platform.call<T>(method, params);
export const errorMessage = (error: unknown) =>
  error instanceof Error ? error.message : String(error);
export function report(error: unknown) {
  notify({ message: errorMessage(error), error: true });
}
export async function perform<T>(
  operation: () => Promise<T>,
  message?: string,
): Promise<T | undefined> {
  try {
    const result = await operation();
    if (message) notify({ message });
    return result;
  } catch (error) {
    report(error);
    return undefined;
  }
}
