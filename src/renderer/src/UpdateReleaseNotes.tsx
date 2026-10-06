import { useState } from 'react';
import type { ReleaseNotes } from '../../shared/updates';
import { Button, Group, Text } from './NativeControls';

export default function UpdateReleaseNotes({ notes }: { notes?: ReleaseNotes }) {
  const [language, setLanguage] = useState<'ru' | 'en'>('ru');
  return (
    <div className="update-release-notes">
      <Group gap="xs" className="update-release-notes-header">
        <Text size="sm" fw={550}>
          Что нового
        </Text>
        <div role="group" aria-label="Язык примечаний к выпуску">
          <Button
            variant="subtle"
            aria-pressed={language === 'ru'}
            onClick={() => setLanguage('ru')}
          >
            Русский
          </Button>
          <Button
            variant="subtle"
            aria-pressed={language === 'en'}
            onClick={() => setLanguage('en')}
          >
            English
          </Button>
        </div>
      </Group>
      <div className="update-release-notes-body" lang={language} tabIndex={0}>
        {notes?.[language] ||
          (language === 'ru'
            ? 'Для этого выпуска примечания не опубликованы.'
            : 'Release notes have not been published for this version.')}
      </div>
    </div>
  );
}
