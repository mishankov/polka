import { _electron as electron, expect } from '@playwright/test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
async function main() {
  if (process.env.ELECTRON_RENDERER_URL) {
    const response = await fetch(process.env.ELECTRON_RENDERER_URL, {
      signal: AbortSignal.timeout(5000),
    });
    assert(response.ok, 'Development renderer must be running');
  }
  const profile = await mkdtemp(join(tmpdir(), 'everything-formats-'));
  const app = await electron.launch({
    ...(process.env.EVERYTHING_EXECUTABLE
      ? { executablePath: process.env.EVERYTHING_EXECUTABLE, args: [] }
      : { args: [resolve('.')] }),
    env: { ...process.env, EVERYTHING_PROFILE: profile },
  });
  const shell = await app.firstWindow();
  const errors: string[] = [];
  shell.on('pageerror', (error) => errors.push(error.message));
  try {
    await shell.waitForSelector('.home-page');
    const instance = await shell.evaluate(() =>
      window.platform.call('apps.create', {
        definition: {
          schemaVersion: 1,
          name: 'Форматы QA',
          entities: [],
          actions: [],
          automations: [],
          permissions: [],
          screens: [
            { id: 'formats', name: 'Форматы', type: 'converter' },
            { id: 'custom', name: 'Код', type: 'custom', config: { extensionId: 'editor' } },
            { id: 'docs', name: 'Документы', type: 'text' },
          ],
          extensions: [
            {
              id: 'editor',
              name: 'Editor',
              kind: 'component',
              source: `import {useState} from 'react'; import {CodeEditor} from '@everything/ui'; export default function Screen({sdk}) {const [value,setValue]=useState('name: test');const [output,setOutput]=useState('');return <div style={{padding:16}}><CodeEditor label="YAML приложения" value={value} onChange={setValue} language="yaml"/><button onClick={async()=>setOutput((await sdk.call('transforms.run',{operation:'yaml.json',input:value})).output)}>Проверить SDK</button><pre>{output}</pre></div>;}`,
            },
          ],
        },
      }),
    );
    await shell.getByRole('button', { name: 'Форматы QA', exact: true }).click();
    const input = shell.locator('.cm-content[aria-label="Исходный текст"]');
    const output = shell.locator('.cm-content[aria-label="Результат"]');
    await input.fill('{"name":"Привет","n":42}');
    assert((await input.locator('span').count()) > 0, 'JSON syntax highlighting');
    await shell.getByRole('button', { name: 'Выполнить', exact: true }).click();
    await expect(output).toContainText('"n": 42');
    assert.equal(await output.getAttribute('contenteditable'), 'false');
    await input.fill('{bad');
    await shell.getByRole('button', { name: 'Выполнить', exact: true }).click();
    await shell.getByRole('alert').filter({ hasText: 'Не удалось обработать текст' }).waitFor();
    assert.equal(await input.innerText(), '{bad');
    await expect(output).toHaveText('');
    await shell.getByRole('combobox', { name: 'Операция', exact: true }).click();
    await shell.getByRole('option', { name: 'YAML → JSON', exact: true }).click();
    await input.fill('name: Привет\nvalues: [1, true]');
    await shell.getByRole('button', { name: 'Выполнить', exact: true }).click();
    await expect(output).toContainText('"Привет"');
    await shell.getByRole('button', { name: 'Сохранить новым документом', exact: true }).click();
    await shell.getByRole('status').filter({ hasText: 'Сохранено' }).waitFor();
    const docs = await shell.evaluate(
      (id) => window.platform.call('docs.list', { appId: id }),
      instance.id,
    );
    assert.equal(docs.length, 1);
    assert.equal(JSON.parse(docs[0].content).name, 'Привет');
    await mkdir('artifacts', { recursive: true });
    await shell.screenshot({ path: 'artifacts/formats-converter.png' });
    const opened = app.context().waitForEvent('page');
    await shell.getByRole('tab', { name: 'Код', exact: true }).click();
    const view = await opened;
    view.on('pageerror', (error) => errors.push(error.message));
    const code = view.locator('.cm-content[aria-label="YAML приложения"]');
    await code.waitFor();
    await code.fill('title: редактор\nactive: true');
    assert((await code.locator('span').count()) > 0, 'YAML syntax highlighting in sandbox');
    await view.getByRole('button', { name: 'Проверить SDK', exact: true }).click();
    await expect(view.locator('pre')).toContainText('"active": true');
    await view.screenshot({ path: 'artifacts/formats-code-editor.png' });
    await shell.getByRole('tab', { name: 'Документы', exact: true }).click();
    await shell.locator('.cm-content[aria-label="Текст документа"]').waitFor();
    assert.deepEqual(errors, []);
    console.log(
      'Formats smoke passed: highlighted code input, format errors preserve input, JSON/YAML conversion, document save, sandboxed CodeEditor and SDK.',
    );
  } finally {
    await app.close();
    await rm(profile, { recursive: true, force: true });
  }
}
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
