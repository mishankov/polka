import { readFile, stat } from 'node:fs/promises';
import { createPublicKey, verify } from 'node:crypto';
import { join } from 'node:path';
import { XMLBuilder, XMLParser, XMLValidator } from 'fast-xml-parser';
import { releaseArtifactNames } from './release-config.mjs';
export { readReleaseNotes } from './release-notes.mjs';

export function appcastXml(pkg, repository, signature, size, date = new Date()) {
  const zip = releaseArtifactNames(pkg).find((name) => name.endsWith('.zip'));
  const builder = new XMLBuilder({ ignoreAttributes: false, format: true });
  return (
    '<?xml version="1.0" encoding="utf-8"?>\n' +
    builder.build({
      rss: {
        '@_version': '2.0',
        '@_xmlns:sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle',
        channel: {
          title: `${pkg.build.productName} updates`,
          link: `https://github.com/${repository}/releases`,
          item: {
            title: `${pkg.build.productName} ${pkg.version}`,
            pubDate: date.toUTCString(),
            'sparkle:version': pkg.version,
            'sparkle:shortVersionString': pkg.version,
            'sparkle:minimumSystemVersion': pkg.build.mac.minimumSystemVersion,
            ...(pkg.releaseNotes ? { description: JSON.stringify(pkg.releaseNotes) } : {}),
            enclosure: {
              '@_url': `https://github.com/${repository}/releases/download/${encodeURIComponent(pkg.releaseTag || `v${pkg.version}`)}/${zip}`,
              '@_length': String(size),
              '@_type': 'application/octet-stream',
              '@_sparkle:edSignature': signature,
            },
          },
        },
      },
    })
  );
}

/** Authenticate the exact ZIP bytes against the public key embedded in this release. */
export async function verifyReleaseMetadata(pkg, directory, repository, publicKey) {
  const names = releaseArtifactNames(pkg);
  await Promise.all(names.map((name) => stat(join(directory, name))));
  const xml = await readFile(join(directory, 'appcast.xml'), 'utf8');
  if (XMLValidator.validate(xml) !== true) throw Error('Invalid appcast XML.');
  const parsed = new XMLParser({ ignoreAttributes: false, parseTagValue: false }).parse(xml);
  const item = parsed?.rss?.channel?.item;
  if (pkg.releaseNotes && item?.description !== JSON.stringify(pkg.releaseNotes))
    throw Error('Appcast release notes do not match this release.');
  if (
    !item ||
    Array.isArray(item) ||
    item['sparkle:version'] !== pkg.version ||
    item['sparkle:shortVersionString'] !== pkg.version ||
    item['sparkle:minimumSystemVersion'] !== pkg.build.mac.minimumSystemVersion
  )
    throw Error('Appcast version or minimum system version does not match this release.');
  const zip = names.find((name) => name.endsWith('.zip'));
  const enclosure = item.enclosure;
  const expectedUrl = `https://github.com/${repository}/releases/download/${encodeURIComponent(pkg.releaseTag || `v${pkg.version}`)}/${zip}`;
  if (!enclosure || enclosure['@_url'] !== expectedUrl)
    throw Error('Appcast URL does not match the uploaded ZIP asset.');
  const bytes = await readFile(join(directory, zip));
  if (String(bytes.length) !== enclosure['@_length']) throw Error('Appcast ZIP size mismatch.');
  const signature = enclosure['@_sparkle:edSignature'];
  if (typeof signature !== 'string' || !/^[A-Za-z0-9+/]{86}==$/.test(signature))
    throw Error('Missing or invalid Ed25519 update signature.');
  const key = createPublicKey({
    key: Buffer.concat([
      Buffer.from('302a300506032b6570032100', 'hex'),
      Buffer.from(publicKey, 'base64'),
    ]),
    format: 'der',
    type: 'spki',
  });
  if (!verify(null, bytes, key, Buffer.from(signature, 'base64')))
    throw Error('Update signature does not match the ZIP bytes and embedded public key.');
  return names;
}
