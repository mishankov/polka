// Avoid repeated quantified groups: V8 can exhaust its regexp stack on valid multi-MiB data.
export function decodeBase64(text: string, maxBytes = Infinity) {
  if (typeof text !== 'string' || text.length % 4 !== 0) throw Error('Некорректный Base64');
  const padding = text.endsWith('==') ? 2 : text.endsWith('=') ? 1 : 0;
  const body = padding ? text.slice(0, -padding) : text;
  if (/[^A-Za-z0-9+/]/.test(body) || (text.length / 4) * 3 - padding > maxBytes)
    throw Error('Некорректный или слишком большой Base64');
  return Buffer.from(text, 'base64');
}
