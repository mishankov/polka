import { useEffect, useRef, useState } from 'react';
import {
  ActionIcon,
  Alert,
  Button,
  Checkbox,
  Group,
  Loader,
  Menu,
  Paper,
  ScrollArea,
  Stack,
  Text,
  Textarea,
  Tooltip,
} from '@mantine/core';
import {
  IconArrowUp,
  IconCheck,
  IconHistory,
  IconPlus,
  IconPlayerStop,
  IconX,
} from '@tabler/icons-react';
import { subscribeSelection, type SelectionContext } from './selectionContext';
import { api, perform, report, AnyRecord } from './api';
import { AssistantMarkdown } from './AssistantMarkdown';
function friendlyError(run: AnyRecord) {
  if (run.stopReason)
    return 'Помощник сделал паузу, чтобы запрос не выполнялся слишком долго. Уже выполненные изменения сохранены.';
  if (run.status === 'cancelled') return 'Уже выполненные изменения сохранены.';
  if (run.failureReason === 'incomplete_response')
    return 'Ответ помощника пришёл не полностью. Можно попробовать ещё раз с сохранённых результатов.';
  if (run.failureReason === 'invalid_tool_arguments')
    return 'Помощник не смог подготовить следующий шаг. Можно попробовать ещё раз с сохранённых результатов.';
  if (run.failureReason === 'timeout')
    return 'Не удалось дождаться ответа помощника. Уже выполненные изменения сохранены. Попробуйте немного позже.';
  const error = String(run.error || '');
  if (/429|лимит провайдера/.test(error))
    return 'Сервис помощника временно недоступен. Попробуйте немного позже.';
  if (/ключ|доступ к модели|HTTP 40[0134]|endpoint|конфигурация|Подключите AI/.test(error))
    return 'Не удалось подключить помощника. Проверьте подключение в настройках.';
  return 'Не удалось закончить запрос. Уже выполненные изменения сохранены. Попробуйте ещё раз.';
}
function RunningStatus({ run }: { run: AnyRecord }) {
  const [now, setNow] = useState(Date.now);
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, []);
  const phase = run.progress?.phase;
  const label =
    {
      waiting: 'Жду ответа…',
      thinking: 'Обдумываю задачу…',
      preparing: 'Готовлю следующий шаг…',
      answering: 'Пишу ответ…',
      tool: 'Выполняю шаг…',
    }[String(phase)] || 'Работаю…';
  const startedAt = Date.parse(run.createdAt || run.progress?.startedAt || '');
  const seconds = Number.isFinite(startedAt)
    ? Math.max(0, Math.floor((now - startedAt) / 1000))
    : 0;
  const elapsed =
    seconds < 60 ? `${seconds} сек` : `${Math.floor(seconds / 60)} мин ${seconds % 60} сек`;
  const lastActivity = Date.parse(run.progress?.lastActivityAt || '');
  const quiet =
    ['waiting', 'thinking', 'preparing'].includes(phase) &&
    Number.isFinite(lastActivity) &&
    now - lastActivity >= 30_000;
  return (
    <Stack gap={4}>
      <Group gap="xs">
        <Loader size="xs" />
        <Text size="xs" role="status">
          {label}
        </Text>
        {seconds > 0 && (
          <Text size="xs" c="dimmed">
            {elapsed}
          </Text>
        )}
      </Group>
      {quiet && (
        <Text size="xs" c="dimmed">
          Пока нет новых сообщений. Можно подождать или остановить работу.
        </Text>
      )}
    </Stack>
  );
}
export function Character({ state = 'idle', small = false }: { state?: string; small?: boolean }) {
  return (
    <div
      className={`character ${small ? 'small' : ''} ${state}`}
      aria-label={
        {
          idle: 'Помощник готов',
          running: 'Помощник работает',
          waiting_approval: 'Нужно ваше решение',
          completed: 'Готово',
          failed: 'Ошибка',
        }[state] || state
      }
    >
      <span className="eye left" />
      <span className="eye right" />
      <span className="mouth" />
    </div>
  );
}
export default function AgentPanel({
  app,
  pageId,
  onClose,
  onChanged,
  initialPrompt,
  onPromptUsed,
}: {
  app?: AnyRecord;
  pageId?: string;
  onClose: () => void;
  onChanged: () => void;
  initialPrompt?: string;
  onPromptUsed?: () => void;
}) {
  const [selection, setSelection] = useState<SelectionContext | null>(null);
  const [includeSelection, setIncludeSelection] = useState(false);
  useEffect(() => subscribeSelection(setSelection), []);
  const [message, setMessage] = useState(initialPrompt || '');
  const [runs, setRuns] = useState<AnyRecord[]>([]);
  const [busy, setBusy] = useState(false);
  const [loading, setLoading] = useState(true);
  const [conversationId, setConversationId] = useState<string>();
  const scope = useRef(0);
  const openingWithPrompt = useRef(!!initialPrompt);
  const pendingInitialPrompt = useRef(initialPrompt || '');
  const composer = useRef<HTMLTextAreaElement>(null);
  const storageKey = `assistant.conversation.${app?.id || 'workspace'}`;
  const run = runs.filter((item) => item.conversationId === conversationId).at(-1);
  const activeRun = runs.find((item) => ['running', 'waiting_approval'].includes(item.status));
  const rememberConversation = (id: string) => {
    setConversationId(id);
    localStorage.setItem(storageKey, id);
  };
  const updateRun = (updated: AnyRecord) =>
    setRuns((previous) =>
      previous.some((item) => item.id === updated.id)
        ? previous.map((item) => (item.id === updated.id ? updated : item))
        : [...previous, updated],
    );
  useEffect(() => {
    const requestScope = ++scope.current;
    setRuns([]);
    setConversationId(undefined);
    setLoading(true);
    setBusy(false);
    setIncludeSelection(false);
    setMessage(initialPrompt || '');
    api('agent.history', { appId: app?.id })
      .then((result: any) => {
        if (scope.current !== requestScope) return;
        const history: AnyRecord[] = Array.isArray(result) ? result : result.runs || [];
        setRuns(history);
        const active = history.find((item) =>
          ['running', 'waiting_approval'].includes(item.status),
        );
        rememberConversation(
          active?.conversationId ||
            (openingWithPrompt.current ? crypto.randomUUID() : undefined) ||
            localStorage.getItem(storageKey) ||
            history.at(-1)?.conversationId ||
            crypto.randomUUID(),
        );
        openingWithPrompt.current = false;
      })
      .catch(report)
      .finally(() => {
        if (scope.current === requestScope) setLoading(false);
      });
    return () => {
      scope.current++;
    };
  }, [app?.id]);
  useEffect(() => {
    if (initialPrompt) {
      pendingInitialPrompt.current = initialPrompt;
      if (loading) openingWithPrompt.current = true;
      else if (!activeRun) rememberConversation(crypto.randomUUID());
      setMessage(initialPrompt);
      onPromptUsed?.();
    }
  }, [initialPrompt]);
  useEffect(() => {
    if (loading || !conversationId || !pendingInitialPrompt.current) return;
    if (message !== pendingInitialPrompt.current) return;
    // A home submission sends once, after history has established the conversation.
    // If work is already active, retain the text as a draft rather than queueing it.
    pendingInitialPrompt.current = '';
    if (!activeRun && !busy) void submit();
  }, [loading, conversationId, message, activeRun, busy]);
  useEffect(() => {
    if (!activeRun) return;
    let live = true;
    const id = setInterval(
      () =>
        api('agent.status', { runId: activeRun.id })
          .then((r: any) => {
            if (!live) return;
            updateRun(r);
            if (!['running', 'waiting_approval'].includes(r.status)) {
              onChanged();
            }
          })
          .catch(report),
      1000,
    );
    return () => {
      live = false;
      clearInterval(id);
    };
  }, [activeRun?.id, activeRun?.status]);
  function selectConversation(id: string) {
    rememberConversation(id);
    setMessage('');
    setIncludeSelection(false);
    composer.current?.focus();
  }
  async function submit(continuing?: AnyRecord) {
    const prompt = continuing
      ? 'Продолжи предыдущую задачу с сохранённых результатов. Не создавай заново уже созданное приложение.'
      : message;
    if (!prompt.trim() || busy || loading || activeRun) return;
    const requestScope = scope.current;
    setBusy(true);
    const result = await perform(() =>
      api('agent.run', {
        message: prompt,
        appId: continuing?.appId || app?.id || run?.appId,
        pageId,
        ...(includeSelection && selection ? { selection } : {}),
        conversationId: continuing?.conversationId || conversationId,
      }),
    );
    if (scope.current !== requestScope) return;
    if (result) {
      updateRun(result);
      rememberConversation(result.conversationId);
      if (!continuing) setMessage('');
    }
    setBusy(false);
  }
  const displayed = runs.filter((item) => item.conversationId === conversationId);
  const conversations = Array.from(new Set(runs.map((item) => item.conversationId)))
    .reverse()
    .map((id) => {
      const first = runs.find((item) => item.conversationId === id);
      const title = first?.messages?.find((message: any) => message.role === 'user')?.content;
      return { id, title: typeof title === 'string' ? title : 'Разговор с помощником' };
    });
  return (
    <aside
      className="agent-panel"
      style={{ width: Number(localStorage.getItem('agentPanelWidth')) || 355 }}
      onMouseUp={(e) =>
        localStorage.setItem('agentPanelWidth', String(e.currentTarget.offsetWidth))
      }
    >
      <Group className="panel-heading" justify="space-between">
        <Group gap="sm">
          <Character small state={run?.status} />
          <div>
            <Text fw={600}>Помощник</Text>
            <Text size="xs" c="dimmed">
              {app?.name || 'Рабочее пространство'}
            </Text>
          </div>
        </Group>
        <ActionIcon variant="subtle" aria-label="Закрыть помощника" onClick={onClose}>
          <IconX size={18} />
        </ActionIcon>
      </Group>
      <Group className="conversation-actions" justify="space-between" gap="xs">
        <Tooltip label="Дождитесь завершения работы или остановите помощника" disabled={!activeRun}>
          <span>
            <Button
              size="xs"
              variant="subtle"
              leftSection={<IconPlus size={15} />}
              disabled={busy || loading || !!activeRun}
              onClick={() => selectConversation(crypto.randomUUID())}
            >
              Новый разговор
            </Button>
          </span>
        </Tooltip>
        <Menu position="bottom-end" width={280} withinPortal>
          <Menu.Target>
            <Button
              size="xs"
              variant="subtle"
              leftSection={<IconHistory size={15} />}
              disabled={busy || loading || !!activeRun || !conversations.length}
            >
              История
            </Button>
          </Menu.Target>
          <Menu.Dropdown className="conversation-menu">
            {conversations.map((conversation) => (
              <Menu.Item
                key={conversation.id}
                onClick={() => selectConversation(conversation.id)}
                rightSection={
                  conversation.id === conversationId ? <IconCheck size={14} /> : undefined
                }
              >
                <Text size="sm" lineClamp={2}>
                  {conversation.title.slice(0, 120)}
                </Text>
              </Menu.Item>
            ))}
          </Menu.Dropdown>
        </Menu>
      </Group>
      <ScrollArea key={conversationId} className="conversation" type="auto">
        <Stack gap="lg" p="md">
          {loading && <Loader size="sm" aria-label="Загружаю разговоры" />}
          {!loading && !displayed.length && (
            <Stack gap="xs" mt="xl">
              <Text fw={500}>Что сделаем?</Text>
              <Text c="dimmed" size="sm">
                Опишите инструмент, который нужен вам в работе. Можно начать с одной задачи и
                постепенно добавить остальное.
              </Text>
              <Text c="dimmed" size="xs">
                Помощник работает с открытым приложением.
              </Text>
            </Stack>
          )}
          {displayed.map((r) => (
            <Stack key={r.id} gap="xs">
              {(r.messages || [])
                .slice(
                  Math.max(
                    0,
                    (r.messages || []).findLastIndex((m: any) => m.role === 'user'),
                  ),
                )
                .filter((m: any) => ['user', 'assistant'].includes(m.role) && m.content)
                .map((m: any, i: number) => (
                  <Paper key={i} className={`chat-message ${m.role}`} p="sm">
                    <Text size="xs" c="dimmed" mb={5}>
                      {m.role === 'user' ? 'Вы' : 'Помощник'}
                    </Text>
                    {m.role === 'assistant' ? (
                      <AssistantMarkdown>
                        {typeof m.content === 'string' ? m.content : JSON.stringify(m.content)}
                      </AssistantMarkdown>
                    ) : (
                      <Text size="sm" style={{ whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}>
                        {typeof m.content === 'string' ? m.content : JSON.stringify(m.content)}
                      </Text>
                    )}
                  </Paper>
                ))}
              {r.streamingText && (
                <Paper className="chat-message assistant streaming" p="sm">
                  <Text size="xs" c="dimmed" mb={5}>
                    Помощник
                  </Text>
                  <AssistantMarkdown>{r.streamingText}</AssistantMarkdown>
                </Paper>
              )}
              {r.error && (
                <Alert
                  color={r.stopReason ? 'orange' : 'red'}
                  title={r.stopReason ? 'Можно продолжить' : 'Работа остановлена'}
                >
                  <Text size="sm">{friendlyError(r)}</Text>
                  {(r.stopReason ||
                    ['incomplete_response', 'invalid_tool_arguments'].includes(
                      r.failureReason,
                    )) && (
                    <Button
                      mt="sm"
                      size="xs"
                      variant="default"
                      loading={busy}
                      disabled={displayed.some((item) =>
                        ['running', 'waiting_approval'].includes(item.status),
                      )}
                      onClick={() => submit(r)}
                    >
                      {r.stopReason ? 'Продолжить работу' : 'Попробовать ещё раз'}
                    </Button>
                  )}
                </Alert>
              )}
              {r.status === 'running' && <RunningStatus run={r} />}
              {r.approval && r.status === 'waiting_approval' && (
                <Alert title="Нужно ваше решение" color="orange">
                  <Text size="sm" mb="sm">
                    {r.approval.description}
                  </Text>
                  <Group>
                    <Button
                      size="xs"
                      onClick={() =>
                        perform(() => api('agent.approve', { runId: r.id, approved: true })).then(
                          (v) => v && updateRun(v),
                        )
                      }
                    >
                      Разрешить
                    </Button>
                    <Button
                      size="xs"
                      variant="default"
                      onClick={() =>
                        perform(() => api('agent.approve', { runId: r.id, approved: false })).then(
                          (v) => v && updateRun(v),
                        )
                      }
                    >
                      Отклонить
                    </Button>
                  </Group>
                </Alert>
              )}
              {(r.steps?.length > 0 ||
                r.error ||
                r.usage?.inputTokens + r.usage?.outputTokens > 0) && (
                <details className="agent-details">
                  <summary>Подробности работы</summary>
                  <Stack gap="xs" mt="xs">
                    {r.steps?.map((s: any) => (
                      <Group key={s.id} gap={6} wrap="nowrap" align="flex-start">
                        {s.status === 'failed' ? (
                          <IconX size={13} style={{ flexShrink: 0, marginTop: 3 }} />
                        ) : s.status === 'completed' ? (
                          <IconCheck size={13} style={{ flexShrink: 0, marginTop: 3 }} />
                        ) : (
                          <Loader size={13} />
                        )}
                        <Text size="xs" c={s.status === 'failed' ? 'red' : 'dimmed'}>
                          {s.tool} ·{' '}
                          {s.status === 'completed'
                            ? 'готово'
                            : s.status === 'failed'
                              ? s.error
                              : s.status === 'waiting_approval'
                                ? 'ожидает решения'
                                : 'выполняется'}
                        </Text>
                      </Group>
                    ))}
                    {r.error && <Text size="xs">{r.error}</Text>}
                    {r.usage && r.usage.inputTokens + r.usage.outputTokens > 0 && (
                      <Text c="dimmed" size="xs">
                        Токены за все обращения: {r.usage.inputTokens} входящих ·{' '}
                        {r.usage.outputTokens} исходящих
                      </Text>
                    )}
                  </Stack>
                </details>
              )}
            </Stack>
          ))}
        </Stack>
      </ScrollArea>
      <div className="composer">
        {selection && (
          <Checkbox
            mb="sm"
            size="xs"
            checked={includeSelection}
            onChange={(e) => setIncludeSelection(e.currentTarget.checked)}
            label={`Передать выделение из «${selection.name}» (${selection.text.length} символов)`}
          />
        )}
        <Textarea
          ref={composer}
          variant="unstyled"
          aria-label="Сообщение помощнику"
          placeholder={app ? 'Что изменить в приложении?' : 'Опишите вашу задачу…'}
          autosize
          minRows={3}
          maxRows={8}
          value={message}
          onChange={(e) => setMessage(e.target.value)}
          onKeyDown={(e) => {
            if (
              e.key === 'Enter' &&
              !e.shiftKey &&
              !e.nativeEvent.isComposing &&
              e.keyCode !== 229
            ) {
              e.preventDefault();
              if (!e.repeat) submit();
            }
          }}
        />
        <Group justify="space-between" mt="xs" wrap="nowrap">
          <Text size="xs" c="dimmed">
            Enter — отправить
            <br />
            Shift+Enter — новая строка
          </Text>
          {run?.status === 'running' ? (
            <Button
              size="xs"
              variant="light"
              leftSection={<IconPlayerStop size={14} />}
              onClick={() =>
                perform(() => api('agent.cancel', { runId: run.id })).then((v) => v && updateRun(v))
              }
            >
              Остановить
            </Button>
          ) : (
            <Tooltip label="Отправить">
              <ActionIcon
                size="lg"
                radius="xl"
                variant="filled"
                aria-label="Отправить сообщение"
                loading={busy}
                disabled={!message.trim() || loading || !!activeRun}
                onClick={() => submit()}
              >
                <IconArrowUp size={18} />
              </ActionIcon>
            </Tooltip>
          )}
        </Group>
      </div>
    </aside>
  );
}
