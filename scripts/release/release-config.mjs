import { sparkleBuilderConfig } from 'electron-sparkle-updater/builder';
import { signingFingerprint } from './signing-certificate.mjs';

export { releasePackage } from './release-version.mjs';

export function releaseArtifactNames(pkg) {
  const base = `${pkg.name}-${pkg.version}-arm64`;
  if (!/^[A-Za-z0-9._-]+$/.test(base))
    throw Error('Release artifact name must be safe for GitHub.');
  return [`${base}.dmg`, `${base}.zip`, 'appcast.xml'];
}

export function releaseConfig(pkg, env, { adHoc = false } = {}) {
  const repository = env.RELEASE_REPOSITORY;
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository || ''))
    throw Error('Set RELEASE_REPOSITORY=owner/repository to the public GitHub release repository.');
  const publicKey = env.SPARKLE_PUBLIC_KEY;
  if (
    !publicKey ||
    !/^[A-Za-z0-9+/]{43}=$/.test(publicKey) ||
    Buffer.from(publicKey, 'base64').length !== 32
  )
    throw Error('SPARKLE_PUBLIC_KEY must be the base64 Ed25519 public key from generate_keys.');
  if (!adHoc) signingFingerprint(env);
  const feedUrl = `https://github.com/${repository}/releases/latest/download/appcast.xml`;
  const sparkle = sparkleBuilderConfig({
    feedUrl,
    publicEdKey: publicKey,
    localizations: ['en', 'ru'],
    deltaHistory: 0,
    scheduledCheckIntervalSeconds: 6 * 60 * 60,
  });
  return {
    ...pkg.build,
    buildVersion: pkg.version,
    forceCodeSigning: !adHoc,
    npmRebuild: false, // The N-API bridge is built explicitly for the target Electron version.
    files: [
      ...(pkg.build.files || []).filter(
        (file) => file !== '!**/node_modules/electron-sparkle-updater/native/**',
      ),
      ...sparkle.files,
      '!**/node_modules/electron-sparkle-updater/native/src/**',
      '!**/node_modules/electron-sparkle-updater/native/scripts/**',
      '!**/node_modules/electron-sparkle-updater/native/patches/**',
    ],
    extraFiles: [...(pkg.build.extraFiles || []), ...sparkle.extraFiles],
    asarUnpack: [...(pkg.build.asarUnpack || []), ...sparkle.asarUnpack],
    dmg: { ...pkg.build.dmg, ...sparkle.dmg },
    mac: {
      ...pkg.build.mac,
      // Enter builder's custom signing hook without Apple certificate discovery.
      // The hook always signs with the pinned certificate; fixtures omit the hook.
      identity: '-',
      sign: adHoc ? undefined : './scripts/release/sign-macos.mjs',
      hardenedRuntime: false,
      notarize: false,
      artifactName: '${name}-${version}-${arch}.${ext}',
      extendInfo: {
        ...pkg.build.mac.extendInfo,
        ...sparkle.mac.extendInfo,
        SUEnableAutomaticChecks: true,
        SUAutomaticallyUpdate: false,
        SUAllowsAutomaticUpdates: false,
        SUEnableSystemProfiling: false,
        SUVerifyUpdateBeforeExtraction: true,
      },
    },
    extraMetadata: {
      version: pkg.version,
      release: { repository, updater: 'sparkle', feedUrl, publicKey },
    },
    publish: null,
  };
}
