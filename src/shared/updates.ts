export type ReleaseNotes = { ru: string; en: string };
export type UpdatePreferences = {
  skippedVersion?: string;
  reminder?: { version: string; after: number };
};
export const UPDATE_REMINDER_DELAY = 24 * 60 * 60 * 1000;

/** Appcast descriptions carry plain text in both languages, never executable HTML. */
export function parseReleaseNotes(value: unknown): ReleaseNotes | undefined {
  try {
    const notes = typeof value === 'string' ? JSON.parse(value) : value;
    if (
      notes &&
      typeof notes.ru === 'string' &&
      typeof notes.en === 'string' &&
      notes.ru.trim() &&
      notes.en.trim() &&
      notes.ru.length <= 20_000 &&
      notes.en.length <= 20_000
    )
      return { ru: notes.ru.trim(), en: notes.en.trim() };
  } catch {
    // Older releases may have a regular RSS description instead.
  }
  return undefined;
}

export function updatePreferences(value: unknown): UpdatePreferences {
  if (!value || typeof value !== 'object') return {};
  const saved = value as UpdatePreferences;
  return {
    ...(typeof saved.skippedVersion === 'string' ? { skippedVersion: saved.skippedVersion } : {}),
    ...(typeof saved.reminder?.version === 'string' && Number.isFinite(saved.reminder.after)
      ? { reminder: { version: saved.reminder.version, after: saved.reminder.after } }
      : {}),
  };
}
