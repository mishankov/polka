import type { KeyboardEvent } from 'react';

export function consumedKey(event: KeyboardEvent) {
  return event.nativeEvent.isComposing || event.defaultPrevented;
}

export function editingTarget(target: EventTarget) {
  return (
    target instanceof HTMLElement &&
    !!target.closest('input, textarea, select, [contenteditable]:not([contenteditable="false"])')
  );
}

export function numberShortcut(event: KeyboardEvent, alt = false) {
  const key = /^Digit[1-9]$/.test(event.code) ? event.code.slice(-1) : event.key;
  return !consumedKey(event) &&
    event.metaKey &&
    !event.ctrlKey &&
    event.altKey === alt &&
    !event.shiftKey &&
    /^[1-9]$/.test(key)
    ? Number(key) - 1
    : undefined;
}
