import { promises as fs } from 'node:fs';
import { basename, join } from 'node:path';
// Only receives paths granted by a native dialog or a real dropped File in preload.
export async function collectDocumentPaths(paths: string[]) {
  if (!Array.isArray(paths) || paths.length > 256 || paths.some((p) => typeof p !== 'string' || !p))
    throw Error('Выберите от 1 до 256 файлов');
  const files: string[] = [],
    errors: { name: string; error: string }[] = [];
  const seen = new Set<string>();
  let inspected = 0,
    totalBytes = 0;
  async function visit(path: string, depth: number) {
    if (++inspected > 2048) throw Error('Слишком много элементов: выберите меньшую папку');
    const stat = await fs.lstat(path);
    if (stat.isSymbolicLink()) {
      errors.push({ name: basename(path), error: 'Символическая ссылка пропущена' });
      return;
    }
    if (stat.isDirectory()) {
      if (depth > 16) {
        errors.push({ name: basename(path), error: 'Папка вложена слишком глубоко' });
        return;
      }
      for (const entry of (await fs.readdir(path)).sort()) {
        if (entry.startsWith('.')) continue;
        await visit(join(path, entry), depth + 1);
      }
    } else if (stat.isFile()) {
      if (stat.size > 32 * 1024 * 1024) {
        errors.push({ name: basename(path), error: 'Файл превышает 32 МБ' });
        return;
      }
      const real = await fs.realpath(path);
      if (!seen.has(real)) {
        if (files.length >= 256) throw Error('В папке больше 256 файлов; выберите меньшую папку');
        totalBytes += stat.size;
        if (totalBytes > 64 * 1024 * 1024)
          throw Error('Выбранные файлы превышают 64 МБ; открывайте их меньшими группами');
        seen.add(real);
        files.push(real);
      }
    }
  }
  for (const path of paths) await visit(path, 0);
  return { files, errors };
}
