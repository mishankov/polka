import { PNG } from 'pngjs';
import { decodeBase64 } from './base64';
export interface PngImage {
  type: 'image';
  dataUrl: string;
  width?: number;
  height?: number;
}
const MAX_PIXELS = 16_777_216;
const MAX_SIDE = 8192;
const MAX_ENCODED = 12 * 1024 * 1024;
function dimensions(width: number, height: number) {
  if (
    !Number.isInteger(width) ||
    !Number.isInteger(height) ||
    width < 1 ||
    height < 1 ||
    width > MAX_SIDE ||
    height > MAX_SIDE ||
    width * height > MAX_PIXELS
  )
    throw Error('PNG: размер от 1 до 8192 пикселей по стороне, не более 16 мегапикселей');
}
function decode(bytes: Buffer) {
  if (bytes.length > MAX_ENCODED) throw Error('PNG превышает 12 МБ');
  if (
    bytes.length < 33 ||
    !bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])) ||
    bytes.readUInt32BE(8) !== 13 ||
    bytes.toString('ascii', 12, 16) !== 'IHDR'
  )
    throw Error(
      'Ожидается корректный PNG; JPEG, GIF и WebP сначала сохраните как PNG в растровом редакторе',
    );
  // Reject oversized dimensions before the codec can allocate/decompress the pixel buffer.
  dimensions(bytes.readUInt32BE(16), bytes.readUInt32BE(20));
  if (bytes[24] > 8 || bytes[28] !== 0)
    throw Error(
      'PNG: поддерживаются глубина до 8 бит и обычная развёртка; сохраните 16-битный или чересстрочный PNG в растровом редакторе',
    );
  for (let offset = 8; offset + 12 <= bytes.length;) {
    const length = bytes.readUInt32BE(offset);
    if (length > bytes.length - offset - 12)
      throw Error('Повреждённый PNG: длина блока выходит за пределы файла');
    const type = bytes.toString('ascii', offset + 4, offset + 8);
    if (type === 'IHDR' && offset !== 8) throw Error('Повреждённый PNG: повторный заголовок IHDR');
    if (type === 'acTL')
      throw Error('Анимированный PNG не поддерживается; выберите отдельный кадр');
    offset += length + 12;
    if (type === 'IEND') break;
  }
  const png = PNG.sync.read(bytes, { checkCRC: true });
  dimensions(png.width, png.height);
  if (png.data.length !== png.width * png.height * 4)
    throw Error('PNG: неверный размер пиксельных данных');
  return png;
}
export function isPngImage(value: unknown): value is PngImage {
  return (
    !!value &&
    typeof value === 'object' &&
    (value as PngImage).type === 'image' &&
    typeof (value as PngImage).dataUrl === 'string'
  );
}
function imageBytes(value: unknown) {
  if (!isPngImage(value) || !value.dataUrl.startsWith('data:image/png;base64,'))
    throw Error('Ожидается изображение PNG');
  const base64 = value.dataUrl.slice('data:image/png;base64,'.length);
  return decodeBase64(base64, MAX_ENCODED);
}
function encode(png: { width: number; height: number; data: Buffer }): PngImage {
  dimensions(png.width, png.height);
  const encoded = PNG.sync.write(png as PNG, { colorType: 6, bitDepth: 8 });
  if (encoded.length > MAX_ENCODED) throw Error('Результат PNG превышает 12 МБ');
  return {
    type: 'image',
    dataUrl: `data:image/png;base64,${encoded.toString('base64')}`,
    width: png.width,
    height: png.height,
  };
}
export function transformImage(
  operation: string,
  input: unknown,
  options: Record<string, any> = {},
): unknown {
  if (operation === 'image.decodePng') return encode(decode(Buffer.from(input as number[])));
  const png = decode(imageBytes(input));
  if (operation === 'image.encodePng') {
    const bytes = imageBytes(encode(png));
    if (bytes.length * 4 + 2 > 16 * 1024 * 1024)
      throw Error('Массив байтов PNG превышает лимит шага 16 МБ');
    return [...bytes];
  }
  let width = png.width,
    height = png.height;
  const x = options.x ?? 0,
    y = options.y ?? 0;
  if (operation === 'image.crop' || operation === 'image.resize') {
    width = options.width ?? png.width;
    height = options.height ?? png.height;
    dimensions(width, height);
    if (
      operation === 'image.crop' &&
      (!Number.isInteger(x) ||
        !Number.isInteger(y) ||
        x < 0 ||
        y < 0 ||
        x + width > png.width ||
        y + height > png.height)
    )
      throw Error('Обрезка: выбранная область выходит за пределы изображения');
  }
  const angle = options.angle ?? 90,
    axis = options.axis ?? 'horizontal';
  if (operation === 'image.rotate') {
    if (![90, 180, 270].includes(angle)) throw Error('Поворот: выберите 90, 180 или 270 градусов');
    if (angle !== 180) {
      width = png.height;
      height = png.width;
    }
  }
  if (operation === 'image.flip' && !['horizontal', 'vertical'].includes(axis))
    throw Error('Отражение: выберите horizontal или vertical');
  if (!['image.crop', 'image.resize', 'image.rotate', 'image.flip'].includes(operation))
    throw Error('Неизвестная операция изображения');
  const data = Buffer.alloc(width * height * 4);
  for (let dy = 0; dy < height; dy++)
    for (let dx = 0; dx < width; dx++) {
      let sx = dx,
        sy = dy;
      if (operation === 'image.crop') {
        sx = dx + x;
        sy = dy + y;
      }
      if (operation === 'image.resize') {
        sx = Math.min(png.width - 1, Math.floor((dx * png.width) / width));
        sy = Math.min(png.height - 1, Math.floor((dy * png.height) / height));
      }
      if (operation === 'image.flip') {
        sx = axis === 'horizontal' ? png.width - 1 - dx : dx;
        sy = axis === 'vertical' ? png.height - 1 - dy : dy;
      }
      if (operation === 'image.rotate') {
        if (angle === 90) {
          sx = dy;
          sy = png.height - 1 - dx;
        } else if (angle === 180) {
          sx = png.width - 1 - dx;
          sy = png.height - 1 - dy;
        } else {
          sx = png.width - 1 - dy;
          sy = dx;
        }
      }
      const from = (sy * png.width + sx) * 4,
        to = (dy * width + dx) * 4;
      data[to] = png.data[from];
      data[to + 1] = png.data[from + 1];
      data[to + 2] = png.data[from + 2];
      data[to + 3] = png.data[from + 3];
    }
  return encode({ width, height, data });
}
