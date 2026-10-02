import { readFile, access } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { join } from 'node:path';
import { load } from 'js-yaml';
import { releaseArtifactNames } from './release-config.mjs';

/** The uploader and updater must agree on exact asset basenames and bytes. */
export async function verifyReleaseMetadata(pkg, directory) {
  const names = releaseArtifactNames(pkg);
  await Promise.all(names.map((name) => access(join(directory, name))));
  const metadata = load(await readFile(join(directory, 'latest-mac.yml'), 'utf8'));
  if (!metadata || metadata.version !== pkg.version || !Array.isArray(metadata.files))
    throw new Error('Update metadata version/files do not match this release.');
  const binaries = names.filter((name) => name.endsWith('.zip') || name.endsWith('.dmg'));
  if (
    metadata.files.length !== binaries.length ||
    new Set(metadata.files.map((file) => file.url)).size !== binaries.length
  )
    throw new Error('Update metadata must list exactly one ZIP and one DMG.');
  for (const file of metadata.files) {
    if (!binaries.includes(file.url))
      throw new Error(`Update URL does not match uploaded asset: ${file.url}`);
    const hash = createHash('sha512');
    let size = 0;
    for await (const chunk of createReadStream(join(directory, file.url))) {
      size += chunk.length;
      hash.update(chunk);
    }
    if (file.sha512 !== hash.digest('base64') || file.size !== size)
      throw new Error(`Update metadata integrity mismatch: ${file.url}`);
  }
  const zip = metadata.files.find((file) => file.url.endsWith('.zip'));
  if (metadata.path !== zip.url || metadata.sha512 !== zip.sha512)
    throw new Error('Legacy update metadata does not match the ZIP asset.');
  return names;
}
