import { _electron as electron, expect, type Locator } from '@playwright/test';
import { createServer } from 'node:http';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve, join } from 'node:path';
import assert from 'node:assert/strict';

const markdownReply = [
  '## Возможности помощника',
  '',
  'Могу создавать **приложения** и работать с документами.',
  '',
  '- Создавать документы',
  '- Изменять приложения',
  '',
  'Пример: `document.open`.',
  '',
  '```json',
  '{ "title": "Новый документ" }',
  '```',
  '',
  '| Действие | Результат |',
  '| --- | --- |',
  '| Создать | Документ |',
  '',
  '[Документация](https://example.com/docs)',
  '',
  '[Небезопасная ссылка](javascript:alert%281%29)',
  '',
  '<script>window.MARKDOWN_SCRIPT_EXECUTED = true</script>',
  '<img id="markdown-html-image" src="https://example.com/tracker.png" onerror="window.MARKDOWN_SCRIPT_EXECUTED = true">',
  '',
  '![Изображение без загрузки](https://example.com/remote.png)',
].join('\n');
const userPrompt = 'Что ты можешь сделать? **Оставь разметку пользователя текстом**';
const newSessionPrompt = 'Начнём отдельный разговор';
const newSessionReply = 'Начали новый разговор без предыдущей переписки.';

async function main() {
  const profile = await mkdtemp(join(tmpdir(), 'everything-provider-smoke-'));
  const requests: any[] = [];
  const failures: string[] = [];
  const server = createServer(async (req, res) => {
    try {
      assert.match(String(req.headers['user-agent']), /^everything-app\//);
      assert.equal(req.headers.authorization, 'Bearer mock-only');
      if (req.url === '/v1/models') {
        res.setHeader('content-type', 'application/json');
        res.end(JSON.stringify({ data: [{ id: 'deepseek-v4-flash' }] }));
        return;
      }
      assert.equal(req.url, '/v1/chat/completions');
      const chunks: Buffer[] = [];
      for await (const chunk of req) chunks.push(Buffer.from(chunk));
      const body = JSON.parse(Buffer.concat(chunks).toString());
      assert.equal(body.model, 'deepseek-v4-flash');
      assert.equal(body.max_tokens, 8192);
      assert(!('max_completion_tokens' in body));
      const probe = body.tools.some((t: any) => t.function.name === 'connection_probe');
      if (!probe) assert(body.tools.some((t: any) => t.function.name === 'platform_capabilities'));
      const assistants = body.messages.filter((m: any) => m.role === 'assistant');
      const latestUser = body.messages.findLast((m: any) => m.role === 'user')?.content;
      const newSession = latestUser === newSessionPrompt;
      if (newSession) {
        assert.deepEqual(
          body.messages.filter((m: any) => m.role !== 'system'),
          [{ role: 'user', content: newSessionPrompt }],
          'A new conversation must not send earlier messages or tool results',
        );
      }
      for (const assistant of assistants) {
        assert.equal(typeof assistant.content, 'string');
        assert.equal(typeof assistant.reasoning_content, 'string');
      }
      for (const message of body.messages.filter((m: any) => m.role === 'tool'))
        assert(
          assistants.some((m: any) =>
            m.tool_calls?.some((c: any) => c.id === message.tool_call_id),
          ),
        );
      requests.push({
        probe,
        newSession,
        assistants: assistants.length,
        toolResults: body.messages.filter((m: any) => m.role === 'tool').length,
      });
      const delta = newSession
        ? { content: newSessionReply, reasoning_content: 'PRIVATE_PROTOCOL_FIXTURE' }
        : probe || !assistants.length
          ? {
              reasoning_content: 'PRIVATE_PROTOCOL_FIXTURE',
              tool_calls: [
                {
                  index: 0,
                  id: 'probe-call',
                  function: {
                    name: probe ? 'connection_probe' : 'capabilities_search',
                    arguments: JSON.stringify(probe ? { ok: true } : { query: 'documents' }),
                  },
                },
              ],
            }
          : {
              content: assistants.length > 1 ? 'Контекст разговора сохранён.' : markdownReply,
              reasoning_content: 'PRIVATE_PROTOCOL_FIXTURE',
            };
      if (probe) assert.equal(body.tool_choice, 'auto');
      res.setHeader('content-type', 'text/event-stream');
      res.end(
        `data: ${JSON.stringify({ choices: [{ delta }], usage: { prompt_tokens: !probe && !assistants.length ? 46884 : 100, completion_tokens: !probe && !assistants.length ? 5012 : 20 } })}\n\ndata: [DONE]\n\n`,
      );
    } catch (error) {
      failures.push(String(error));
      res.writeHead(400, { 'content-type': 'application/json' });
      res.end(
        JSON.stringify({
          error: { type: 'invalid_request_error', message: 'Mock contract failed' },
        }),
      );
    }
  });
  await new Promise<void>((done) => server.listen(0, '127.0.0.1', done));
  const port = (server.address() as import('node:net').AddressInfo).port;
  const app = await electron.launch({
    ...(process.env.EVERYTHING_EXECUTABLE
      ? { executablePath: resolve(process.env.EVERYTHING_EXECUTABLE), args: [], cwd: profile }
      : { args: [resolve('.')] }),
    env: { ...process.env, EVERYTHING_PROFILE: profile },
  });
  try {
    await app.evaluate(({ shell }) => {
      (globalThis as any).openedMarkdownUrls = [];
      shell.openExternal = async (url) => {
        (globalThis as any).openedMarkdownUrls.push(url);
      };
    });
    const page = await app.firstWindow();
    await page.locator('.home-page').waitFor();
    await page.evaluate(async (endpoint) => {
      await window.platform.call('provider.save', {
        type: 'openai',
        endpoint,
        model: 'deepseek-v4-flash',
        apiKey: 'mock-only',
      });
      await window.platform.call('provider.models');
      const probe: any = await window.platform.call('provider.test');
      if (!probe.ok) throw Error('Connection probe failed');
    }, `http://127.0.0.1:${port}/v1`);
    await mkdir('artifacts', { recursive: true });
    const checkComposerFocus = async (container: Locator, name: string) => {
      for (const theme of ['light', 'dark'] as const) {
        await page.emulateMedia({ colorScheme: theme });
        const textarea = container.locator('textarea');
        await textarea.evaluate((element) => element.blur());
        const unfocusedBorder = await container.evaluate(
          (element) => getComputedStyle(element).borderColor,
        );
        await textarea.focus();
        const focusedBorder = await container.evaluate(
          (element) => getComputedStyle(element).borderColor,
        );
        assert.notEqual(focusedBorder, unfocusedBorder, `${name}: outer border should show focus`);
        const inputStyle = await textarea.evaluate((element) => {
          const style = getComputedStyle(element);
          return {
            borderWidth: style.borderWidth,
            borderColor: style.borderColor,
            borderStyle: style.borderStyle,
            outlineStyle: style.outlineStyle,
            boxShadow: style.boxShadow,
          };
        });
        assert.ok(
          inputStyle.borderWidth === '0px' ||
            inputStyle.borderStyle === 'none' ||
            inputStyle.borderColor === 'rgba(0, 0, 0, 0)',
          `${name}: textarea should have no inner border: ${JSON.stringify(inputStyle)}`,
        );
        assert.equal(inputStyle.outlineStyle, 'none');
        assert.equal(inputStyle.boxShadow, 'none');
        await container.screenshot({ path: `artifacts/${name}-focus-${theme}.png` });
      }
      await page.emulateMedia({ colorScheme: 'light' });
    };
    await checkComposerFocus(page.locator('.home-composer'), 'home-composer');
    const homeComposer = page.locator('.home-prompt textarea');
    await homeComposer.fill(userPrompt);
    await homeComposer.press('Shift+Enter');
    await expect(homeComposer).toHaveValue(`${userPrompt}\n`);
    await homeComposer.fill(userPrompt);
    await homeComposer.dispatchEvent('keydown', { key: 'Enter', code: 'Enter', isComposing: true });
    await homeComposer.dispatchEvent('keydown', { key: 'Enter', code: 'Enter', keyCode: 229 });
    await homeComposer.dispatchEvent('keydown', { key: 'Enter', code: 'Enter', repeat: true });
    await page.waitForTimeout(200);
    await expect(page.locator('.agent-panel')).toHaveCount(0);
    assert.equal(requests.filter((request) => !request.probe).length, 0);
    await homeComposer.press('Enter');
    const panel = page.locator('.agent-panel');
    // Home submission opens the assistant and sends the draft once without another Enter.
    const composer = panel.locator('textarea');
    await composer.waitFor();
    const markdown = panel.locator('.chat-message.assistant .assistant-markdown').first();
    await expect(markdown.locator('h2')).toHaveText('Возможности помощника', {
      timeout: 15000,
    });
    await expect(composer).toHaveValue('');
    await expect(panel.locator('.chat-message.user')).toHaveCount(1);
    await checkComposerFocus(panel.locator('.composer'), 'assistant-composer');
    await expect(markdown.locator('strong')).toHaveText('приложения');
    await expect(markdown.locator('ul > li')).toHaveText([
      'Создавать документы',
      'Изменять приложения',
    ]);
    await expect(markdown.locator('p > code')).toHaveText('document.open');
    await expect(markdown.locator('pre > code')).toContainText('{ "title": "Новый документ" }');
    await expect(markdown.locator('table th')).toHaveText(['Действие', 'Результат']);
    await expect(markdown.locator('table td')).toHaveText(['Создать', 'Документ']);
    await expect(markdown.getByRole('link', { name: 'Документация', exact: true })).toHaveAttribute(
      'href',
      'https://example.com/docs',
    );
    await expect(markdown.locator('a[href^="javascript:"]')).toHaveCount(0);
    await expect(markdown.locator('script, img, #markdown-html-image')).toHaveCount(0);
    assert.equal(await page.evaluate(() => (window as any).MARKDOWN_SCRIPT_EXECUTED), undefined);
    await markdown.getByRole('link', { name: 'Документация', exact: true }).click();
    assert.deepEqual(await app.evaluate(() => (globalThis as any).openedMarkdownUrls), [
      'https://example.com/docs',
    ]);
    for (const url of [
      'javascript:alert(1)',
      'file:///tmp/test',
      'https://user:secret@example.com',
    ]) {
      assert.equal(
        await page.evaluate(async (url) => {
          try {
            await window.platform.call('links.openExternal', { url });
            return false;
          } catch {
            return true;
          }
        }, url),
        true,
      );
    }
    const userMessage = panel.locator('.chat-message.user').first();
    await expect(userMessage).toContainText(userPrompt);
    await expect(userMessage.locator('strong, .assistant-markdown')).toHaveCount(0);
    const workDetails = panel.locator('.agent-details').first();
    const toolStep = workDetails.getByText(/capabilities_search/);
    const tokenUsage = workDetails.getByText(/Токены за все обращения:/);
    await expect(workDetails.locator('summary')).toHaveText('Подробности работы');
    await expect(toolStep).toBeHidden();
    await expect(tokenUsage).toBeHidden();
    await workDetails.locator('summary').click();
    await expect(toolStep).toBeVisible();
    await expect(tokenUsage).toBeVisible();
    await workDetails.locator('summary').click();
    await expect(toolStep).toBeHidden();
    await expect(tokenUsage).toBeHidden();
    await mkdir('artifacts', { recursive: true });
    await page.screenshot({ path: 'artifacts/assistant-markdown-light.png' });
    await page.emulateMedia({ colorScheme: 'dark' });
    await page.screenshot({ path: 'artifacts/assistant-markdown-dark.png' });
    await page.emulateMedia({ colorScheme: 'light' });
    await composer.fill('Продолжим');
    await composer.press('Meta+Enter');
    await expect(panel.getByText('Контекст разговора сохранён.', { exact: true })).toBeVisible({
      timeout: 15000,
    });
    assert(!(await page.locator('body').innerText()).includes('PRIVATE_PROTOCOL_FIXTURE'));
    assert.deepEqual(failures, []);
    assert(requests.some((r) => r.toolResults > 0 && r.assistants > 1));
    await panel.getByRole('button', { name: 'Новый разговор', exact: true }).click();
    await expect(panel.locator('.chat-message')).toHaveCount(0);
    await expect(composer).toHaveValue('');
    await panel.getByRole('button', { name: 'Закрыть помощника', exact: true }).click();
    await page.getByRole('button', { name: 'Помощник', exact: true }).click();
    await expect(panel.locator('.chat-message')).toHaveCount(0);
    await composer.fill(newSessionPrompt);
    await composer.press('Meta+Enter');
    await expect(panel.getByText(newSessionReply, { exact: true })).toBeVisible({
      timeout: 15000,
    });
    await expect(panel.locator('.chat-message.user')).toHaveCount(1);
    await expect(panel.locator('.chat-message.user')).toContainText(newSessionPrompt);
    await expect(panel.getByText('Контекст разговора сохранён.', { exact: true })).toHaveCount(0);
    assert(requests.some((r) => r.newSession));
    await panel.getByRole('button', { name: 'История', exact: true }).click();
    await page.getByRole('menuitem').filter({ hasText: userPrompt }).click();
    await expect(panel.getByText('Контекст разговора сохранён.', { exact: true })).toBeVisible();
    await expect(panel.getByText(newSessionReply, { exact: true })).toHaveCount(0);
    await panel.getByRole('button', { name: 'Закрыть помощника', exact: true }).click();
    await page.getByRole('button', { name: 'Помощник', exact: true }).click();
    await expect(panel.getByText('Контекст разговора сохранён.', { exact: true })).toBeVisible();
    await expect(panel.getByText(newSessionReply, { exact: true })).toHaveCount(0);
    await panel.getByRole('button', { name: 'История', exact: true }).click();
    await page.getByRole('menuitem').filter({ hasText: newSessionPrompt }).click();
    await expect(panel.getByText(newSessionReply, { exact: true })).toBeVisible();
    await expect(page.locator('[role="menu"]')).toHaveCount(0);
    await page.screenshot({ path: 'artifacts/assistant-new-conversation.png' });
    const limitedRun: any = await page.evaluate(() =>
      window.platform.call('agent.run', { message: 'Проверь возможности', maxTokens: 1000 }),
    );
    await expect
      .poll(async () => {
        const run: any = await page.evaluate(
          (runId) => window.platform.call('agent.status', { runId }),
          limitedRun.id,
        );
        return run.stopReason;
      })
      .toBe('token_budget');
    await panel.getByRole('button', { name: 'Закрыть помощника', exact: true }).click();
    await page.getByRole('button', { name: 'Помощник', exact: true }).click();
    await panel.getByRole('button', { name: 'История', exact: true }).click();
    await page.getByRole('menuitem').filter({ hasText: 'Проверь возможности' }).click();
    await expect(panel.getByText('Можно продолжить', { exact: true })).toBeVisible();
    await expect(
      panel.getByText(
        'Помощник сделал паузу, чтобы запрос не выполнялся слишком долго. Уже выполненные изменения сохранены.',
        { exact: true },
      ),
    ).toBeVisible();
    const budgetDetails = panel.locator('.agent-details').last();
    const technicalReason = budgetDetails.getByText(/Достигнут лимит.*токенов за запрос/);
    await expect(technicalReason).toContainText(/1\s?000/);
    await expect(technicalReason).toBeHidden();
    await expect(budgetDetails.getByText(/capabilities_search/)).toBeHidden();
    await expect(budgetDetails.getByText(/Токены за все обращения:/)).toBeHidden();
    await budgetDetails.locator('summary').click();
    await expect(technicalReason).toBeVisible();
    await expect(budgetDetails.getByText(/capabilities_search/)).toBeVisible();
    await expect(budgetDetails.getByText(/Токены за все обращения:/)).toBeVisible();
    await budgetDetails.locator('summary').click();
    await expect(technicalReason).toBeHidden();
    await page.screenshot({ path: 'artifacts/agent-budget-pause.png' });
    await panel.getByRole('button', { name: 'Продолжить работу', exact: true }).click();
    await expect
      .poll(async () => {
        const runs: any = await page.evaluate(() => window.platform.call('agent.history'));
        const last = runs.at(-1);
        return last?.id !== limitedRun.id && last?.conversationId === limitedRun.conversationId
          ? last.status
          : undefined;
      })
      .toBe('completed');
    assert.deepEqual(failures, []);
    await mkdir('artifacts', { recursive: true });
    await page.screenshot({ path: 'artifacts/provider-mock-smoke.png' });
    await writeFile(
      'artifacts/provider-mock-smoke.json',
      JSON.stringify(
        {
          passed: true,
          markdownRendered: true,
          homeEnterSendsOnce: true,
          singleComposerFocusBorderBothThemes: true,
          homeShiftEnterAddsNewline: true,
          homeCompositionAndRepeatedEnterDoNotSubmit: true,
          assistantModifierEnterStillSends: true,
          budgetRecovery: true,
          technicalDetailsCollapsed: true,
          newConversationIsolated: true,
          conversationHistoryRestored: true,
          selectedConversationPersists: true,
          requests,
          failures,
        },
        null,
        2,
      ),
    );
    console.log(
      'Provider desktop smoke passed: connection probe, tool loop above 40k tokens, friendly budget pause and continuation, collapsed technical details, safe assistant Markdown, plain user text, continued conversation, isolated new conversations, conversation history and selection persistence, private protocol metadata.',
    );
  } finally {
    await app.close();
    await new Promise<void>((done) => server.close(() => done()));
    await rm(profile, { recursive: true, force: true });
  }
}
void main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
