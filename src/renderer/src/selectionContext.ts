export interface SelectionContext {
  documentId: string;
  name: string;
  text: string;
}
let current: SelectionContext | null = null;
const subscribers = new Set<(value: SelectionContext | null) => void>();
export function setSelection(value: SelectionContext | null) {
  current = value;
  for (const fn of subscribers) fn(value);
}
export function subscribeSelection(fn: (value: SelectionContext | null) => void) {
  subscribers.add(fn);
  fn(current);
  return () => {
    subscribers.delete(fn);
  };
}
