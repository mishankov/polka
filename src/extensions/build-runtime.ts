import { build } from 'esbuild';
import { resolve } from 'node:path';
export async function buildExtensionRuntime(root = process.cwd()) {
  const result = await build({
    entryPoints: [resolve(root, 'src/extensions/runtime-entry.tsx')],
    bundle: true,
    write: false,
    outdir: 'extension-runtime',
    format: 'iife',
    platform: 'browser',
    target: 'es2022',
    jsx: 'automatic',
    minify: true,
    define: { 'process.env.NODE_ENV': '"production"' },
    logLevel: 'silent',
  });
  return {
    script: result.outputFiles.find((f) => f.path.endsWith('.js'))!.text,
    css: result.outputFiles.find((f) => f.path.endsWith('.css'))!.text,
  };
}
