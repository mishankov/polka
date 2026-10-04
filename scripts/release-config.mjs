export function releaseArtifactNames(pkg) {
  const base = `${pkg.name}-${pkg.version}-arm64`;
  if (!/^[A-Za-z0-9._-]+$/.test(base))
    throw new Error('Release artifact name must be safe for GitHub.');
  return [
    `${base}.dmg`,
    `${base}.dmg.blockmap`,
    `${base}.zip`,
    `${base}.zip.blockmap`,
    'latest-mac.yml',
  ];
}

export function releaseConfig(pkg, env) {
  const repository = env.RELEASE_REPOSITORY;
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository || ''))
    throw new Error(
      'Set RELEASE_REPOSITORY=owner/repository to the product owner’s GitHub repository.',
    );
  if (!env.CSC_LINK || !env.CSC_KEY_PASSWORD)
    throw new Error(
      'Developer ID certificate and password are required (CSC_LINK, CSC_KEY_PASSWORD).',
    );
  if (
    !(env.APPLE_ID && env.APPLE_APP_SPECIFIC_PASSWORD && env.APPLE_TEAM_ID) &&
    !(env.APPLE_API_KEY && env.APPLE_API_KEY_ID && env.APPLE_API_ISSUER)
  )
    throw new Error('Provide Apple notarization credentials through your secret store.');
  const [owner, repo] = repository.split('/');
  return {
    ...pkg.build,
    forceCodeSigning: true,
    mac: {
      ...pkg.build.mac,
      identity: undefined,
      hardenedRuntime: true,
      notarize: true,
      artifactName: '${name}-${version}-${arch}.${ext}',
    },
    extraMetadata: { release: { repository, signed: true } },
    publish: [{ provider: 'github', owner, repo, releaseType: 'draft' }],
  };
}
