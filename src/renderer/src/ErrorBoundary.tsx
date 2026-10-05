import React from 'react';
import { Alert, Button, Group, Stack, Text } from './NativeControls';
export class ErrorBoundary extends React.Component<React.PropsWithChildren, { error?: Error }> {
  state: { error?: Error } = {};
  static getDerivedStateFromError(error: Error) {
    return { error };
  }
  render() {
    if (this.state.error)
      return (
        <Stack p="xl" maw={620} m="auto" mt={80}>
          <Alert color="red" title="Не удалось показать рабочее пространство">
            <Text size="sm">
              Локальные данные сохранены. Перезагрузите интерфейс, чтобы продолжить работу.
            </Text>
            <Text size="xs" c="dimmed" mt="sm">
              {this.state.error.message}
            </Text>
          </Alert>
          <Group>
            <Button
              onClick={() => {
                localStorage.removeItem('lastApp');
                location.reload();
              }}
            >
              Перезагрузить интерфейс
            </Button>
          </Group>
        </Stack>
      );
    return this.props.children;
  }
}
