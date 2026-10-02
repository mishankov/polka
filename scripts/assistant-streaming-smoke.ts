import { _electron as electron, expect } from '@playwright/test';
import { createServer, type ServerResponse } from 'node:http';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve, join } from 'node:path';
import assert from 'node:assert/strict';

const first = 'Сначала проверю возможности платформы.';
const second = 'Возможности найдены. Проверю описание приложения.';
const partial = 'Всё проверено. ';
const final = `${partial}Можно создать приложение.`;
const repeat = 'Повторная проверка.';

async function main() {
  const profile = await mkdtemp(join(tmpdir(), 'everything-streaming-smoke-'));
  const responses: ServerResponse[] = [];
  const requests: { messages: Record<string, any>[] }[] = [];
  const failures: string[] = [];
  const server = createServer(async (req, res) => {
    try {
      assert.equal(req.url, '/v1/chat/completions');
      assert.equal(req.headers.authorization, 'Bearer mock-only');
      const chunks: Buffer[] = [];
      for await (const chunk of req) chunks.push(Buffer.from(chunk));
      const body = JSON.parse(Buffer.concat(chunks).toString());
      assert.equal(body.stream, true);
      requests.push(body);
      res.writeHead(200, { 'content-type': 'text/event-stream' });
      res.flushHeaders();
      responses.push(res);
    } catch (error) {
      failures.push(String(error));
      res.writeHead(400, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: { message: 'Mock contract failed' } }));
    }
  });
  await new Promise<void>((done) => server.listen(0, '127.0.0.1', done));
  const port = (server.address() as import('node:net').AddressInfo).port;
  let app: Awaited<ReturnType<typeof electron.launch>> | undefined;
  const send = (round: number, delta: Record<string, unknown>) =>
    responses[round].write(`data: ${JSON.stringify({ choices: [{ delta }] })}\n\n`);
  const finish = (round: number, tool?: string) => {
    if (tool)
      send(round, {
        tool_calls: [{ index: 0, id: `call-${round}`, function: { name: tool, arguments: '{}' } }],
      });
    responses[round].end('data: [DONE]\n\n');
  };
  try {
    app = await electron.launch({
      ...(process.env.EVERYTHING_EXECUTABLE
        ? { executablePath: resolve(process.env.EVERYTHING_EXECUTABLE), args: [], cwd: profile }
        : { args: [resolve('.')] }),
      env: { ...process.env, EVERYTHING_PROFILE: profile },
    });
    const page = await app.firstWindow();
    await page.locator('.home-page').waitFor();
    await page.evaluate(
      (endpoint) =>
        window.platform.call('provider.save', {
          type: 'openai',
          endpoint,
          model: 'mock',
          apiKey: 'mock-only',
        }),
      `http://127.0.0.1:${port}/v1`,
    );
    await page.getByRole('button', { name: 'Помощник', exact: true }).click();
    const panel = page.locator('.agent-panel');
    const composer = panel.locator('textarea');
    const committed = panel.locator('.chat-message.assistant:not(.streaming) .assistant-markdown');
    const live = panel.locator('.chat-message.assistant.streaming .assistant-markdown');
    const paragraph = (text: string) =>
      panel
        .locator('.assistant-markdown p')
        .filter({ hasText: new RegExp(`^${text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}$`) });
    const waitRound = (count: number) =>
      expect.poll(() => responses.length, { timeout: 15000 }).toBe(count);
    await composer.fill('Проверь возможности приложения');
    await expect(
      panel.getByRole('button', { name: 'Отправить сообщение', exact: true }),
    ).toBeEnabled();
    await composer.press('Shift+Enter');
    await expect(composer).toHaveValue('Проверь возможности приложения\n');
    await composer.fill('Проверь возможности приложения');
    await composer.dispatchEvent('keydown', { key: 'Enter', code: 'Enter', isComposing: true });
    await composer.dispatchEvent('keydown', { key: 'Enter', code: 'Enter', keyCode: 229 });
    await composer.dispatchEvent('keydown', { key: 'Enter', code: 'Enter', repeat: true });
    await page.waitForTimeout(200);
    assert.equal(responses.length, 0, 'Newlines, composition and held Enter must not send');
    await expect(panel.locator('.chat-message.user')).toHaveCount(0);
    await expect(composer).toHaveValue('Проверь возможности приложения');
    await composer.press('Enter');
    await waitRound(1);
    await expect(panel.getByRole('status')).toHaveText('Жду ответа…');
    send(0, { reasoning_content: 'Private mock reasoning must stay hidden.' });
    await expect(panel.getByRole('status')).toHaveText('Обдумываю задачу…');
    await expect(panel.getByText('Private mock reasoning must stay hidden.')).toHaveCount(0);
    send(0, { content: first });
    await expect(live).toHaveText(first);
    await expect(panel.getByRole('status')).toHaveText('Пишу ответ…');
    await expect(committed).toHaveCount(0);
    finish(0, 'platform_capabilities');
    await waitRound(2);
    await expect(panel.getByRole('status')).toHaveText('Жду ответа…');
    await expect(committed).toHaveText([first]);
    await expect(live).toHaveCount(0);
    send(1, { content: second });
    await expect(live).toHaveText(second);
    await expect(paragraph(first)).toHaveCount(1);
    await expect(paragraph(second)).toHaveCount(1);
    finish(1, 'definition_schema');
    await waitRound(3);
    await expect(committed).toHaveText([first, second]);
    await expect(live).toHaveCount(0);
    send(2, { content: partial });
    await expect(live).toHaveText(partial);
    await expect(paragraph(first)).toHaveCount(1);
    await expect(paragraph(second)).toHaveCount(1);
    assert.equal(responses[2].writableEnded, false, 'Check must happen before provider completion');
    await mkdir('artifacts', { recursive: true });
    await page.screenshot({ path: 'artifacts/assistant-streaming-in-progress.png' });
    send(2, { content: 'Можно создать приложение.' });
    finish(2);
    await expect(committed).toHaveText([first, second, final]);
    await expect(live).toHaveCount(0);
    await expect(paragraph(final)).toHaveCount(1);

    // Equal text in two distinct responses is legitimate and must not be deduplicated by value.
    await composer.fill('Проверь ещё раз');
    await expect(
      panel.getByRole('button', { name: 'Отправить сообщение', exact: true }),
    ).toBeEnabled();
    await composer.press('Meta+Enter');
    await waitRound(4);
    send(3, { content: repeat });
    await expect(live).toHaveText(repeat);
    finish(3, 'platform_capabilities');
    await waitRound(5);
    send(4, { content: repeat });
    await expect(live).toHaveText(repeat);
    await expect(paragraph(repeat)).toHaveCount(2);
    await expect(committed).toHaveText([first, second, final, repeat]);
    finish(4);
    await expect(live).toHaveCount(0);
    await expect(committed).toHaveText([first, second, final, repeat, repeat]);
    await expect(paragraph(repeat)).toHaveCount(2);
    await expect(panel.getByRole('status')).toHaveCount(0);

    // An incomplete tool response should stop clearly and retry from intact conversation history.
    const interruptedPrompt = 'Добавь возможность вставлять картинки из буфера обмена';
    await composer.fill(interruptedPrompt);
    await expect(
      panel.getByRole('button', { name: 'Отправить сообщение', exact: true }),
    ).toBeEnabled();
    await composer.press('Meta+Enter');
    await waitRound(6);
    await expect(panel.getByRole('status')).toHaveText('Жду ответа…');
    send(5, {
      tool_calls: [
        {
          index: 0,
          id: 'incomplete-call',
          function: { name: 'capabilities_search', arguments: '{"query":"clipboard' },
        },
      ],
    });
    await expect(panel.getByRole('status')).toHaveText('Готовлю следующий шаг…');
    responses[5].write(
      `data: ${JSON.stringify({
        choices: [{ delta: {}, finish_reason: 'length' }],
        usage: { prompt_tokens: 321, completion_tokens: 123 },
      })}\n\n`,
    );
    finish(5);
    await expect(
      panel.getByText(
        'Ответ помощника пришёл не полностью. Можно попробовать ещё раз с сохранённых результатов.',
        { exact: true },
      ),
    ).toBeVisible();
    await expect(panel.getByRole('status')).toHaveCount(0);
    const retry = panel.getByRole('button', { name: 'Попробовать ещё раз', exact: true });
    await expect(retry).toBeEnabled();
    await retry.scrollIntoViewIfNeeded();
    await page.screenshot({ path: 'artifacts/assistant-streaming-incomplete.png' });
    await panel.screenshot({ path: 'artifacts/assistant-streaming-incomplete-panel.png' });
    await retry.click();
    await waitRound(7);
    const recovered = requests[6].messages;
    assert.ok(
      recovered.some((message) => message.role === 'user' && message.content === interruptedPrompt),
    );
    for (const callId of ['call-0', 'call-1', 'call-3']) {
      assert.ok(
        recovered.some(
          (message) =>
            message.role === 'assistant' &&
            message.tool_calls?.some((call: any) => call.id === callId),
        ),
        `Missing assistant tool call ${callId}`,
      );
      assert.ok(
        recovered.some((message) => message.role === 'tool' && message.tool_call_id === callId),
        `Missing tool result ${callId}`,
      );
    }
    assert.equal(
      recovered.some((message) =>
        message.tool_calls?.some((call: any) => call.id === 'incomplete-call'),
      ),
      false,
    );
    const retried = 'Продолжил с сохранённых результатов.';
    send(6, { content: retried });
    finish(6);
    await expect(committed.last()).toHaveText(retried);
    await expect(panel.getByRole('status')).toHaveCount(0);
    assert.deepEqual(failures, []);
    await page.screenshot({ path: 'artifacts/assistant-streaming-completed.png' });
    await writeFile(
      'artifacts/assistant-streaming-smoke.json',
      JSON.stringify(
        {
          passed: true,
          requests: responses.length,
          noDuplicateCommittedProse: true,
          currentPartialVisible: true,
          enterSendsAndShiftEnterAddsNewline: true,
          compositionAndRepeatedEnterDoNotSend: true,
          legitimateRepeatedProsePreserved: true,
          progressPhasesVisible: true,
          privateReasoningHidden: true,
          incompleteResponseRetryPreservesHistory: true,
          failures,
        },
        null,
        2,
      ),
    );
    console.log(
      'Assistant streaming smoke passed: gated phase status, private reasoning hidden, atomic text streaming, and incomplete-response retry with preserved history.',
    );
  } finally {
    for (const response of responses) if (!response.writableEnded) response.end('data: [DONE]\n\n');
    await app?.close();
    await new Promise<void>((done) => server.close(() => done()));
    await rm(profile, { recursive: true, force: true });
  }
}
void main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
