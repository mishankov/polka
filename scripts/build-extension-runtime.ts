import { mkdir, writeFile } from 'node:fs/promises';
import { buildExtensionRuntime } from '../src/extensions/build-runtime';
async function main() {
  const runtime = await buildExtensionRuntime();
  await mkdir('out/extensions', { recursive: true });
  await writeFile('out/extensions/runtime.js', runtime.script);
  await writeFile('out/extensions/runtime.css', runtime.css);
  console.log('Bundled extension UI runtime and fixed dependencies.');
}
void main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
