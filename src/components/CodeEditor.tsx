import { useMemo } from 'react';
import CodeMirror, { EditorView, type ReactCodeMirrorProps } from '@uiw/react-codemirror';
import { useComputedColorScheme } from '@mantine/core';
import { json } from '@codemirror/lang-json';
import { xml } from '@codemirror/lang-xml';
import { yaml } from '@codemirror/lang-yaml';
export type CodeLanguage = 'text' | 'json' | 'xml' | 'yaml' | 'base64' | 'hex';
export interface CodeEditorProps {
  value: string;
  onChange?: (value: string) => void;
  language?: CodeLanguage;
  label?: string;
  readOnly?: boolean;
  height?: string;
  minHeight?: string;
  onUpdate?: ReactCodeMirrorProps['onUpdate'];
}
export function documentLanguage(name = ''): CodeLanguage {
  const extension = name.split('.').pop()?.toLowerCase();
  return extension === 'json'
    ? 'json'
    : extension === 'xml'
      ? 'xml'
      : extension === 'yaml' || extension === 'yml'
        ? 'yaml'
        : 'text';
}
/** Controlled code input, bundled for both shell documents and sandboxed user screens. */
export function CodeEditor({
  value,
  onChange,
  language = 'text',
  label = 'Код',
  readOnly = false,
  height = '320px',
  minHeight,
  onUpdate,
}: CodeEditorProps) {
  const scheme = useComputedColorScheme('light');
  const extensions = useMemo(
    () => [
      EditorView.contentAttributes.of({ 'aria-label': label }),
      ...(language === 'json'
        ? [json()]
        : language === 'xml'
          ? [xml()]
          : language === 'yaml'
            ? [yaml()]
            : []),
    ],
    [language, label],
  );
  return (
    <CodeMirror
      value={value}
      onChange={onChange}
      onUpdate={onUpdate}
      extensions={extensions}
      theme={scheme}
      height={height}
      minHeight={minHeight}
      readOnly={readOnly}
      editable={!readOnly}
      basicSetup={{ lineNumbers: true, foldGutter: true, highlightActiveLine: !readOnly }}
    />
  );
}
