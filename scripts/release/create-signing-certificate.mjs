import { createSigningCertificate } from './signing-certificate.mjs';

const directory = process.argv[2];
if (!directory)
  throw Error(
    'Usage: node scripts/release/create-signing-certificate.mjs /absolute/secure/backup/directory',
  );
const fingerprint = await createSigningCertificate(directory);
console.log(`Persistent signing identity created in ${directory}.`);
console.log(`Certificate SHA-1 (public): ${fingerprint}`);
console.log('Back up this directory securely. Reuse this certificate for every release.');
