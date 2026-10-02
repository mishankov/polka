import { getQuickJS } from 'quickjs-emscripten';
import { build } from 'esbuild';
import { readFile } from 'node:fs/promises';
import { basename, join } from 'node:path';
import { extensionDependencies, extensionImports } from './dependencies';
export { extensionDependencies } from './dependencies';
export async function compileExtension(
  source: string,
  kind: 'handler' | 'component',
  dependencies: Record<string, string> = {},
) {
  if (typeof source !== 'string' || source.length > 512 * 1024)
    throw Error('Расширение превышает 512 КБ');
  for (const [name, version] of Object.entries(dependencies)) {
    if (extensionDependencies[name] !== version)
      throw Error(`Зависимость ${name}@${version} не входит в эту поставку`);
  }
  const result = await build({
    stdin: { contents: source, loader: 'tsx', sourcefile: 'extension.tsx' },
    write: false,
    logLevel: 'silent',
    bundle: true,
    format: 'iife',
    globalName: 'Extension',
    platform: 'browser',
    target: 'es2022',
    define: {
      'process.env.NODE_ENV': '"production"',
      ...(kind === 'handler' ? { require: 'undefined' } : {}),
    },
    minify: false,
    jsx: 'automatic',
    plugins: [
      {
        name: 'locked-modules',
        setup(b) {
          b.onResolve({ filter: /.*/ }, (args) => {
            if (kind === 'handler' || !extensionImports.has(args.path))
              throw Error(`Импорт ${args.path} запрещён`);
            return { path: args.path, namespace: 'bundled-library' };
          });
          b.onLoad({ filter: /.*/, namespace: 'bundled-library' }, (args) => ({
            contents: `module.exports = globalThis.__extensionModules[${JSON.stringify(args.path)}]`,
            loader: 'js',
          }));
        },
      },
    ],
  });
  const code = result.outputFiles[0].text;
  if (kind === 'handler' && /\brequire\s*\(/.test(code))
    throw Error('Динамические импорты недоступны');
  return code;
}
export async function runHandler(
  code: string,
  input: unknown,
  capability: (method: string, params: any) => Promise<unknown>,
  signal?: AbortSignal,
) {
  const q = await getQuickJS(),
    runtime = q.newRuntime();
  runtime.setMemoryLimit(32 * 1024 * 1024);
  runtime.setMaxStackSize(512 * 1024);
  const deadline = Date.now() + 3000;
  runtime.setInterruptHandler(() => Date.now() > deadline || !!signal?.aborted);
  const context = runtime.newContext();
  // Effect requests are returned as JSON and executed outside the VM, never exposing host objects.
  try {
    const value = context.evalCode(
      `${code}\nJSON.stringify(Extension.default(${JSON.stringify(input ?? null)}));`,
    );
    if (value.error) {
      const e = context.dump(value.error);
      value.error.dispose();
      throw Error(`Расширение: ${e.message || JSON.stringify(e)}`);
    }
    const result = JSON.parse(context.getString(value.value));
    value.value.dispose();
    if (result && Array.isArray(result.operations)) {
      if (result.operations.length > 32) throw Error('Не более 32 операций за вызов');
      const outputs = [];
      for (const op of result.operations) {
        signal?.throwIfAborted();
        outputs.push(await capability(op.method, op.params));
      }
      return { value: result.value, results: outputs };
    }
    return result;
  } finally {
    context.dispose();
    runtime.dispose();
  }
}
let runtimePromise: Promise<{ script: string; css: string }> | undefined;
async function bundledRuntime() {
  if (!runtimePromise)
    runtimePromise = (async () => {
      // Packaged worker lives in out/main; tests run against TypeScript sources.
      const root =
        typeof __dirname === 'string' && basename(__dirname) === 'main'
          ? join(__dirname, '../extensions')
          : join(process.cwd(), 'out/extensions');
      const [script, css] = await Promise.all([
        readFile(join(root, 'runtime.js'), 'utf8'),
        readFile(join(root, 'runtime.css'), 'utf8'),
      ]);
      return { script, css };
    })().catch((error) => {
      runtimePromise = undefined;
      throw Error(`Среда расширений не собрана. Выполните npm run build: ${error.message}`);
    });
  return runtimePromise;
}
export function componentDocument(code: string, runtime: { script: string; css: string }) {
  const boot = `${runtime.script}\n${code}\nwindow.__mountExtension(Extension.default);`;
  return `<!doctype html><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; connect-src 'none'; form-action 'none'; base-uri 'none'; frame-src 'none'; object-src 'none'"><style>${runtime.css.replace(/<\/style/gi, '<\\/style')}\nhtml,body,#root{height:100%;min-height:0}body{margin:0;padding:0;background:var(--workspace-bg);color:var(--ink)}*{box-sizing:border-box}</style><div id="root"></div><script>${boot.replace(/<\/script/gi, '<\\/script')}</script>`;
}
export async function buildComponent(source: string, dependencies: Record<string, string>) {
  const code = await compileExtension(source, 'component', dependencies);
  return { code, html: componentDocument(code, await bundledRuntime()), kind: 'component' };
}
