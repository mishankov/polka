/** Shared by the dependency-free release preflight and the macOS packager. */
export function releaseVersion(tag) {
  const version = tag.replace(/^v/, '');
  if (
    !/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/.test(
      version,
    )
  )
    throw Error('RELEASE_TAG must be a semantic version with an optional v prefix.');
  return version;
}

/** Keep bundle version, archive names and feed URL aligned with the selected release tag. */
export function releasePackage(pkg, env) {
  const tag = env.RELEASE_TAG || `v${pkg.version}`;
  return { ...pkg, version: releaseVersion(tag), releaseTag: tag };
}
