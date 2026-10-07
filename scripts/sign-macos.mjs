import { signAsync } from '@electron/osx-sign';
import { execFileSync } from 'node:child_process';
import { join, resolve } from 'node:path';
import { signingFingerprint } from './signing-certificate.mjs';

export const nativeHelpers = ['clipboard-probe', 'media-probe', 'sync-discovery', 'file-shelf-probe'];

export function helperIdentifier(appId, helper) {
  return `${appId}.${helper}`;
}

export function verifySignedBundle(bundle, appId, fingerprint) {
  fingerprint = signingFingerprint({ POLKA_SIGNING_CERT_SHA1: fingerprint });
  const targets = [
    [bundle, appId],
    ...nativeHelpers.map((helper) => [
      join(bundle, 'Contents/Resources', helper),
      helperIdentifier(appId, helper),
    ]),
  ];
  const requirements = {};
  for (const [path, identifier] of targets) {
    // Verify signer and identifier, not just that a signature exists.
    execFileSync(
      'codesign',
      [
        '--verify',
        '--strict',
        '-R',
        `=identifier ${JSON.stringify(identifier)} and certificate leaf = H"${fingerprint}"`,
        path,
      ],
      { stdio: 'pipe' },
    );
    const details = execFileSync('codesign', ['--display', '-r-', path], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    const requirement = details.match(/^designated => (.+)$/m)?.[1];
    // A hash-based DR would still invalidate permissions after rebuilding.
    if (
      !requirement ||
      /\bcdhash\b/.test(requirement) ||
      !requirement.toUpperCase().includes(fingerprint)
    )
      throw Error(`Unstable designated requirement for ${identifier}.`);
    requirements[identifier] = requirement;
  }
  execFileSync('codesign', ['--verify', '--deep', '--strict', bundle], { stdio: 'pipe' });
  return requirements;
}

/** electron-builder custom signing hook, invoked before DMG/ZIP creation. */
export async function sign(options, packager, env = process.env) {
  const fingerprint = signingFingerprint(env);
  const keychain = env.POLKA_SIGNING_KEYCHAIN;
  if (!keychain) throw Error('Release signing requires an isolated POLKA_SIGNING_KEYCHAIN.');
  const appId = packager.appInfo.id;
  const helpers = new Map(
    nativeHelpers.map((helper) => [
      resolve(options.app, 'Contents/Resources', helper),
      helperIdentifier(appId, helper),
    ]),
  );
  await signAsync({
    ...options,
    identity: fingerprint,
    keychain,
    identityValidation: false, // Self-signed certificates have no Apple trust chain.
    preAutoEntitlements: false,
    preEmbedProvisioningProfile: false,
    optionsForFile(path) {
      const original = options.optionsForFile?.(path) || {};
      const identifier = helpers.get(resolve(path));
      return {
        ...original,
        hardenedRuntime: false,
        timestamp: 'none',
        additionalArguments: [
          ...(original.additionalArguments || []),
          ...(identifier ? ['--identifier', identifier] : []),
        ],
      };
    },
  });
  verifySignedBundle(options.app, appId, fingerprint);
}
