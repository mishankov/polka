import { useEffect, useRef, useState } from 'react';
import { Alert, Button, Group, Select, SimpleGrid, Stack, Text } from '@mantine/core';
import { CodeEditor, type CodeLanguage } from '../../components/CodeEditor';
import { api, errorMessage, type AnyRecord } from './api';
export default function FormatConverter({ appId, config }: { appId: string; config?: AnyRecord }) {
  const [operations, setOperations] = useState<AnyRecord[]>([]);
  const [operation, setOperation] = useState(String(config?.operation || 'json.format'));
  const [input, setInput] = useState('');
  const [output, setOutput] = useState<string>();
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);
  const revision = useRef(0);
  const spec = operations.find((item) => item.id === operation);
  useEffect(() => {
    let active = true;
    api('transforms.list')
      .then((items) => {
        if (active) setOperations(items);
      })
      .catch((e) => {
        if (active) setError(errorMessage(e));
      });
    return () => {
      active = false;
      revision.current++;
    };
  }, []);
  function invalidate() {
    revision.current++;
    setOutput(undefined);
    setError('');
    setSaved(false);
  }
  async function run() {
    const current = ++revision.current;
    setBusy(true);
    setError('');
    setOutput(undefined);
    setSaved(false);
    try {
      const value = spec?.input === 'text' ? input : JSON.parse(input);
      const result = await api('transforms.run', { appId, operation, input: value });
      if (revision.current === current)
        setOutput(
          typeof result.output === 'string'
            ? result.output
            : JSON.stringify(result.output, null, 2),
        );
    } catch (e) {
      if (revision.current === current) setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }
  async function save() {
    const current = revision.current;
    setSaving(true);
    try {
      await api('docs.create', {
        appId,
        name: `Результат.${['json', 'xml', 'yaml'].includes(spec?.outputLanguage) ? spec!.outputLanguage : 'txt'}`,
        content: output,
        kind: 'text',
      });
      if (revision.current === current) setSaved(true);
    } catch (e) {
      if (revision.current === current) setError(errorMessage(e));
    } finally {
      setSaving(false);
    }
  }
  return (
    <Stack>
      <Group align="end">
        <Select
          label="Операция"
          value={operation}
          data={operations.map((item) => ({ value: item.id, label: item.name }))}
          searchable
          w={320}
          onChange={(value) => {
            if (value) {
              invalidate();
              setOperation(value);
            }
          }}
        />
        <Button onClick={run} loading={busy} disabled={!spec}>
          Выполнить
        </Button>
      </Group>
      {!spec && operations.length > 0 && (
        <Alert color="orange">
          Эта операция больше не поддерживается. Выберите операцию из списка.
        </Alert>
      )}
      {spec?.warning && <Alert color="yellow">{spec.warning}</Alert>}
      {error && (
        <Alert color="red" title="Не удалось обработать текст" role="alert">
          {error}
        </Alert>
      )}
      <SimpleGrid cols={{ base: 1, md: 2 }}>
        <Stack gap="xs">
          <Text fw={500}>Исходный текст</Text>
          <CodeEditor
            label="Исходный текст"
            value={input}
            onChange={(value) => {
              invalidate();
              setInput(value);
            }}
            language={(spec?.inputLanguage || 'text') as CodeLanguage}
            height="420px"
          />
        </Stack>
        <Stack gap="xs">
          <Text fw={500}>Результат</Text>
          <CodeEditor
            label="Результат"
            value={output ?? ''}
            readOnly
            language={(spec?.outputLanguage || 'text') as CodeLanguage}
            height="420px"
          />
          {output !== undefined && (
            <Group>
              <Button variant="default" onClick={save} loading={saving} disabled={saved}>
                Сохранить новым документом
              </Button>
              {saved && (
                <Text size="sm" role="status">
                  Сохранено во вкладках документов приложения
                </Text>
              )}
            </Group>
          )}
        </Stack>
      </SimpleGrid>
      <Text size="xs" c="dimmed">
        Обработка выполняется локально. Ввод — до 1 МиБ, результат — до 2 МиБ. Base64 и hex
        используют UTF-8; для двоичных данных выберите операции с байтами.
      </Text>
    </Stack>
  );
}
