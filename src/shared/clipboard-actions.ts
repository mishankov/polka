export const TEXT_TRANSFORMATIONS = ['upperCase', 'lowerCase'] as const;
export type TextTransformation = (typeof TEXT_TRANSFORMATIONS)[number];

export const TEXT_TRANSFORMATION_LABELS: Record<TextTransformation, string> = {
  upperCase: 'ПРОПИСНЫЕ',
  lowerCase: 'строчные',
};

export function transformClipboardText(text: string, transformation: TextTransformation) {
  switch (transformation) {
    case 'upperCase':
      return text.toUpperCase();
    case 'lowerCase':
      return text.toLowerCase();
  }
}

// Only a whole, explicit web URL is eligible; never extract links from prose.
export function clipboardWebUrl(text: string): string | undefined {
  const value = text.trim();
  if (!/^https?:\/\//i.test(value) || /[\s\u0000-\u001f\u007f\\]/u.test(value)) return;
  try {
    const url = new URL(value);
    if (!url.hostname || url.username || url.password) return;
    return url.href;
  } catch {
    return;
  }
}
