import { Unzip, UnzipInflate } from 'fflate';

/** Inflate in 1 KiB input increments and account real output, never trusting ZIP sizes. */
export function boundedUnzip(
  bytes: Uint8Array,
  maxExpanded = 128 * 1024 * 1024,
  onProgress?: (completed: number, total: number) => void,
): Record<string, Uint8Array> {
  const files: Record<string, Uint8Array> = Object.create(null),
    seen = new Set<string>();
  let total = 0,
    completed = 0;
  if (bytes.length < 22 || bytes[0] !== 0x50 || bytes[1] !== 0x4b) throw new Error('Не ZIP-архив');
  let hasEnd = false;
  for (let i = bytes.length - 22; i >= Math.max(0, bytes.length - 65557); i--)
    if (bytes[i] === 0x50 && bytes[i + 1] === 0x4b && bytes[i + 2] === 5 && bytes[i + 3] === 6) {
      const length = bytes[i + 20] + bytes[i + 21] * 256;
      if (i + 22 + length === bytes.length) hasEnd = true;
      break;
    }
  if (!hasEnd) throw new Error('Архив не завершён');
  const unzip = new Unzip((file) => {
    if (seen.has(file.name)) throw new Error('Повторяющиеся пути архива запрещены');
    if (seen.size >= 1000) throw new Error('Слишком много файлов');
    if (
      !/^(manifest\.json|definition\.json|documents\.json|demo-data\.json|data\.json|attachments\.json|attachments\/[a-zA-Z0-9-]+)$/.test(
        file.name,
      )
    )
      throw new Error('Недопустимый путь или исполняемый файл в архиве');
    if (file.originalSize !== undefined && file.originalSize > maxExpanded)
      throw new Error('Пакет превышает лимит распаковки');
    if (![0, 8].includes(file.compression)) throw new Error('Неподдерживаемый метод сжатия');
    seen.add(file.name);
    let size = 0;
    const chunks: Uint8Array[] = [];
    file.ondata = (error, chunk, final) => {
      if (error) throw error;
      size += chunk.length;
      total += chunk.length;
      if (total > maxExpanded) throw new Error('Пакет превышает фактический лимит распаковки');
      chunks.push(chunk);
      if (final) {
        if (file.originalSize !== undefined && size !== file.originalSize)
          throw new Error('Фактический размер файла не совпадает с заголовком');
        const data = new Uint8Array(size);
        let offset = 0;
        for (const part of chunks) {
          data.set(part, offset);
          offset += part.length;
        }
        files[file.name] = data;
        chunks.length = 0;
        completed++;
      }
    };
    file.start();
  });
  unzip.register(UnzipInflate);
  for (let offset = 0; offset < bytes.length; offset += 1024) {
    unzip.push(bytes.subarray(offset, offset + 1024), offset + 1024 >= bytes.length);
    if (offset % (64 * 1024) === 0 || offset + 1024 >= bytes.length)
      onProgress?.(Math.min(offset + 1024, bytes.length), bytes.length);
  }
  if (completed !== seen.size) throw new Error('Архив содержит незавершённый файл');
  return files;
}
