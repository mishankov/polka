// Run after npm run build: npx tsx scripts/readme-screenshots.ts
// All sample data stays in a disposable profile; no AI connection is used.
import { _electron as electron, type Page } from '@playwright/test';
import { mkdtemp, mkdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import assert from 'node:assert/strict';

async function main() {
  const profile = await mkdtemp(join(tmpdir(), 'everything-readme-'));
  const output = resolve('docs/screenshots');
  await mkdir(output, { recursive: true });
  const app = await electron.launch({
    args: [resolve('.')],
    env: { ...process.env, EVERYTHING_PROFILE: profile },
  });
  const page = await app.firstWindow();
  const errors: string[] = [];
  page.on('pageerror', (error) => errors.push(error.message));
  async function capture(name: string, target: Page = page) {
    await target.evaluate(() => document.fonts.ready);
    await target.mouse.move(0, 0);
    await target.getByRole('tooltip').waitFor({ state: 'hidden' });
    await target.screenshot({
      path: join(output, `${name}.png`),
      animations: 'disabled',
      caret: 'hide',
    });
  }
  try {
    await app.evaluate(({ BrowserWindow }) => {
      BrowserWindow.getAllWindows()[0].setContentSize(1280, 820);
    });
    await page.waitForSelector('.home-page');
    await page.evaluate(() => localStorage.setItem('mantine-color-scheme-value', 'light'));
    await page.reload();
    await page
      .getByRole('textbox', { name: 'Описание нового приложения' })
      .fill(
        'Создай приложение для проектов мастерской: задачи, сроки и доску со статусами «Планы», «В работе», «Готово».',
      );
    await capture('home');

    await page.evaluate(async () => {
      const instance = await window.platform.call('apps.create', {
        name: 'Проекты мастерской',
        icon: '✦',
        description: 'Задачи, сроки и заметки для небольшой мастерской',
        definition: {
          schemaVersion: 1,
          name: 'Проекты мастерской',
          entities: [
            {
              id: 'tasks',
              name: 'Задачи',
              fields: [
                { id: 'title', name: 'Задача', type: 'text', required: true },
                { id: 'due', name: 'Срок', type: 'date' },
                { id: 'owner', name: 'Ответственный', type: 'text' },
                {
                  id: 'status',
                  name: 'Статус',
                  type: 'select',
                  options: ['Планы', 'В работе', 'Готово'],
                },
              ],
            },
          ],
          screens: [
            {
              id: 'board',
              name: 'Доска задач',
              type: 'board',
              entityId: 'tasks',
              config: { groupBy: 'status' },
            },
            { id: 'table', name: 'Все задачи', type: 'table', entityId: 'tasks' },
            { id: 'calendar', name: 'Календарь', type: 'calendar', entityId: 'tasks' },
            { id: 'notes', name: 'Заметки', type: 'text' },
          ],
          actions: [],
          automations: [],
          extensions: [],
          permissions: [],
        },
      });
      await window.platform.call('apps.updateMeta', { appId: instance.id, status: 'running' });
      for (const [title, due, owner, status] of [
        ['Подобрать материалы для стеллажа', '2026-10-05', 'Анна', 'Планы'],
        ['Подготовить эскиз рабочего стола', '2026-10-07', 'Михаил', 'Планы'],
        ['Обновить фотографии изделий', '2026-10-09', 'Анна', 'Планы'],
        ['Собрать настенную полку', '2026-10-03', 'Михаил', 'В работе'],
        ['Согласовать размеры с заказчиком', '2026-10-04', 'Анна', 'В работе'],
        ['Заказать крепёж', '2026-10-01', 'Михаил', 'Готово'],
        ['Разобрать инструменты', '2026-10-01', 'Анна', 'Готово'],
      ]) {
        await window.platform.call('records.upsert', {
          appId: instance.id,
          entityId: 'tasks',
          values: { title, due, owner, status },
        });
      }
      await window.platform.call('docs.create', {
        appId: instance.id,
        name: 'Материалы.txt',
        kind: 'text',
        content:
          'Материалы для настенной полки\n\n• Берёзовая фанера, 18 мм\n• Масло для дерева\n• Скрытые крепления, 2 шт.\n',
      });
      await window.platform.call('docs.create', {
        appId: instance.id,
        name: 'План мастерской.md',
        kind: 'text',
        content:
          '# План мастерской\n\n## На этой неделе\n\n- Собрать настенную полку и проверить крепления.\n- Согласовать размеры рабочего стола.\n- Сфотографировать готовые изделия при дневном свете.\n\n## Идея для следующего проекта\n\nСтеллаж для книг: светлое дерево, открытые полки,\nместо для растений у окна.\n\n## Перед передачей заказчику\n\n1. Проверить размеры и качество поверхности.\n2. Подготовить памятку по уходу за деревом.\n3. Сохранить фотографии готового изделия.\n',
      });
    });
    await page.getByRole('button', { name: 'Проекты мастерской', exact: true }).click();
    await page.getByText('Собрать настенную полку', { exact: true }).waitFor();
    assert.equal(await page.locator('.board-card').count(), 7);
    await capture('project-board');

    await page.getByRole('tab', { name: 'Заметки', exact: true }).click();
    await page.getByRole('tab', { name: /План мастерской\.md/ }).click();
    await page.locator('.cm-content').getByText('# План мастерской', { exact: true }).waitFor();
    await capture('documents');

    assert.deepEqual(errors, []);
    console.log('Saved three README screenshots using sample data in a temporary profile.');
  } finally {
    await app.close();
    await rm(profile, { recursive: true, force: true });
  }
}
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
