import { clipboard, ClipboardItem } from 'electron';
import { decodeBase64 } from '../services/base64';
const MAX_PIXELS = 16_777_216,
  MAX_SIDE = 8192,
  MAX_BYTES = 12 * 1024 * 1024;
function pngSize(bytes: Buffer) {
  if (
    bytes.length > MAX_BYTES ||
    bytes.length < 33 ||
    !bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])) ||
    bytes.readUInt32BE(8) !== 13 ||
    bytes.toString('ascii', 12, 16) !== 'IHDR'
  )
    throw Error('Ожидается корректный PNG до 12 МБ');
  const width = bytes.readUInt32BE(16),
    height = bytes.readUInt32BE(20);
  if (!width || !height || width > MAX_SIDE || height > MAX_SIDE || width * height > MAX_PIXELS)
    throw Error('Изображение буфера превышает 16 мегапикселей или 8192 пикселя по стороне');
  for (let offset = 8; offset + 12 <= bytes.length;) {
    const length = bytes.readUInt32BE(offset);
    if (length > bytes.length - offset - 12) throw Error('Повреждённый PNG');
    const type = bytes.toString('ascii', offset + 4, offset + 8);
    if ((type === 'IHDR' && offset !== 8) || type === 'acTL')
      throw Error('Ожидается статический PNG с одним заголовком');
    offset += length + 12;
    if (type === 'IEND') break;
  }
  return { width, height };
}
export async function readDocumentClipboard(p: any = {}) {
  if (p.kind !== 'image') return clipboard.readText();
  const item = (await clipboard.read()).find((item) => item.types.includes('image/png'));
  if (!item) throw Error('В буфере обмена нет изображения PNG');
  const blob = await item.getType('image/png');
  if (blob.size > MAX_BYTES) throw Error('PNG буфера превышает 12 МБ');
  const bytes = Buffer.from(await blob.arrayBuffer());
  return {
    type: 'image',
    dataUrl: `data:image/png;base64,${bytes.toString('base64')}`,
    ...pngSize(bytes),
  };
}
export async function writeDocumentClipboard(p: any = {}) {
  if (!p.image) {
    if (typeof p.text !== 'string' || Buffer.byteLength(p.text) > 16 * 1024 * 1024)
      throw Error('Текст буфера должен быть не больше 16 МБ');
    await clipboard.writeText(p.text);
    return true;
  }
  const data = p.image.dataUrl;
  if (
    typeof data !== 'string' ||
    data.length > (MAX_BYTES * 4) / 3 + 32 ||
    !data.startsWith('data:image/png;base64,')
  )
    throw Error('Ожидается PNG до 12 МБ');
  const bytes = decodeBase64(data.slice('data:image/png;base64,'.length), MAX_BYTES);
  pngSize(bytes);
  await clipboard.write([
    new ClipboardItem({ 'image/png': new Blob([new Uint8Array(bytes)], { type: 'image/png' }) }),
  ]);
  return true;
}
