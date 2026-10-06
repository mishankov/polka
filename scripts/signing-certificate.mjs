import { spawnSync } from 'node:child_process';
import { randomBytes, X509Certificate } from 'node:crypto';
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { isAbsolute, join } from 'node:path';

// Capture tool output: security/OpenSSL errors must not print secret arguments.
function run(command, args, env = process.env) {
  const result = spawnSync(command, args, { env, encoding: 'utf8' });
  if (result.status !== 0) throw Error(`${command} failed during certificate setup.`);
  return result.stdout;
}

export function signingFingerprint(env) {
  const fingerprint = env.POLKA_SIGNING_CERT_SHA1?.trim();
  if (!/^[A-Fa-f0-9]{40}$/.test(fingerprint || ''))
    throw Error(
      'POLKA_SIGNING_CERT_SHA1 must pin the persistent code-signing certificate (40 hex digits).',
    );
  return fingerprint.toUpperCase();
}

/** Generate once, outside the repository. Releases must never generate a replacement. */
export async function createSigningCertificate(directory) {
  if (!isAbsolute(directory))
    throw Error('Use an absolute path for the certificate backup directory.');
  await mkdir(directory, { mode: 0o700 }); // Refuse to overwrite an existing identity.
  const temporary = await mkdtemp(join(tmpdir(), 'polka-certificate-'));
  try {
    const password = randomBytes(32).toString('base64');
    const key = join(temporary, 'private.pem');
    const certificate = join(directory, 'certificate.pem');
    run('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:3072',
      '-nodes',
      '-sha256',
      '-days',
      '3650',
      '-subj',
      '/CN=Polka Release Signing/O=Polka',
      '-keyout',
      key,
      '-out',
      certificate,
      '-addext',
      'basicConstraints=critical,CA:FALSE',
      '-addext',
      'keyUsage=critical,digitalSignature',
      '-addext',
      'extendedKeyUsage=critical,codeSigning',
    ]);
    const p12 = join(directory, 'identity.p12');
    run(
      'openssl',
      [
        'pkcs12',
        '-export',
        '-inkey',
        key,
        '-in',
        certificate,
        '-out',
        p12,
        '-name',
        'Polka Release Signing',
        '-passout',
        'env:POLKA_SIGNING_PASSWORD',
        // Compatible with macOS security import, including older PKCS#12 readers.
        '-keypbe',
        'PBE-SHA1-3DES',
        '-certpbe',
        'PBE-SHA1-3DES',
        '-macalg',
        'sha1',
      ],
      { ...process.env, POLKA_SIGNING_PASSWORD: password },
    );
    const fingerprint = new X509Certificate(await readFile(certificate)).fingerprint.replaceAll(
      ':',
      '',
    );
    await writeFile(join(directory, 'password.txt'), password, { mode: 0o600 });
    await writeFile(join(directory, 'fingerprint.txt'), fingerprint + '\n', { mode: 0o600 });
    // Exported private material is only readable by the owner.
    await chmod(p12, 0o600);
    return fingerprint;
  } catch (error) {
    await rm(directory, { recursive: true, force: true });
    throw error;
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
}

/** Import into an isolated keychain; leave the user's login keychain and trust settings alone. */
export async function withSigningKeychain(env, work) {
  const fingerprint = signingFingerprint(env);
  if (!env.POLKA_SIGNING_P12 || !env.POLKA_SIGNING_PASSWORD)
    throw Error('POLKA_SIGNING_P12 and POLKA_SIGNING_PASSWORD are required. See docs/macos.md.');
  const directory = await mkdtemp(join(tmpdir(), 'polka-signing-'));
  const keychain = join(directory, 'signing.keychain-db');
  let created = false;
  try {
    const p12 = join(directory, 'identity.p12');
    const bytes = isAbsolute(env.POLKA_SIGNING_P12)
      ? await readFile(env.POLKA_SIGNING_P12)
      : Buffer.from(env.POLKA_SIGNING_P12, 'base64');
    await writeFile(p12, bytes, { mode: 0o600 });
    const pem = run(
      'openssl',
      ['pkcs12', '-in', p12, '-passin', 'env:POLKA_SIGNING_PASSWORD', '-clcerts', '-nokeys'],
      { ...process.env, POLKA_SIGNING_PASSWORD: env.POLKA_SIGNING_PASSWORD },
    );
    const cert = new X509Certificate(pem);
    if (cert.fingerprint.replaceAll(':', '') !== fingerprint)
      throw Error(
        'Signing certificate does not match POLKA_SIGNING_CERT_SHA1. Refusing identity rotation.',
      );
    if (Date.parse(cert.validTo) <= Date.now())
      throw Error('Code-signing certificate has expired.');
    const password = randomBytes(32).toString('base64');
    run('security', ['create-keychain', '-p', password, keychain]);
    created = true;
    run('security', ['set-keychain-settings', '-lut', '21600', keychain]);
    run('security', ['unlock-keychain', '-p', password, keychain]);
    run('security', [
      'import',
      p12,
      '-k',
      keychain,
      '-P',
      env.POLKA_SIGNING_PASSWORD,
      '-T',
      '/usr/bin/codesign',
    ]);
    run('security', [
      'set-key-partition-list',
      '-S',
      'apple-tool:,apple:',
      '-s',
      '-k',
      password,
      keychain,
    ]);
    await rm(p12);
    const {
      POLKA_SIGNING_P12: _p12,
      POLKA_SIGNING_PASSWORD: _password,
      SPARKLE_PRIVATE_KEY: _sparkleKey,
      CSC_LINK: _csc,
      CSC_KEY_PASSWORD: _cscPassword,
      ...publicEnv
    } = env;
    return await work({
      ...publicEnv,
      POLKA_SIGNING_KEYCHAIN: keychain,
      POLKA_SIGNING_CERT_SHA1: fingerprint,
    });
  } finally {
    try {
      if (created) run('security', ['delete-keychain', keychain]);
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  }
}
