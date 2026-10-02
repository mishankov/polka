import { notifications } from '@mantine/notifications';
export type AnyRecord = Record<string, any>;
import type {} from '../../shared/types';
export const api = <T = any>(method: string, params: any = {}): Promise<T> =>
  window.platform.call<T>(method, params);
export const errorMessage = (error: unknown) =>
  error instanceof Error ? error.message : String(error);
export function report(error: unknown) {
  notifications.show({
    title: 'Не удалось выполнить действие',
    message: errorMessage(error),
    color: 'red',
    autoClose: false,
  });
}
export async function perform<T>(
  operation: () => Promise<T>,
  message?: string,
): Promise<T | undefined> {
  try {
    const result = await operation();
    if (message) notifications.show({ message, color: 'teal' });
    return result;
  } catch (error) {
    report(error);
    return undefined;
  }
}
export const labels = {
  brand: 'everything',
  home: 'Рабочее пространство',
  apps: 'Мои приложения',
  inbox: 'Входящие',
  settings: 'Настройки',
  agent: 'Помощник',
  search: 'Найти приложение или запись…',
  create: 'Создать приложение',
  import: 'Открыть файл приложения',
  empty: 'Здесь появится ваша работа',
  local: 'Данные на этом Mac',
};
export function useStorageValue<T>(key: string, fallback: T): T {
  try {
    return JSON.parse(localStorage.getItem(key) || 'null') ?? fallback;
  } catch {
    return fallback;
  }
}
