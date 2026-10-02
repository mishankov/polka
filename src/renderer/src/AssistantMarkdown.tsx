import Markdown, { type Components } from 'react-markdown';
import remarkGfm from 'remark-gfm';
import { externalWebUrl } from '../../shared/externalLinks';
import { api, report } from './api';

const components: Components = {
  a: ({ href, children, title }) =>
    href ? (
      <a
        href={href}
        title={title || href}
        onClick={(event) => {
          event.preventDefault();
          api('links.openExternal', { url: href }).catch(report);
        }}
      >
        {children}
      </a>
    ) : (
      <span>{children}</span>
    ),
  // Model output must not silently fetch remote images or local files.
  img: ({ alt }) => <span className="markdown-image-label">{alt || 'Изображение'}</span>,
  table: ({ children }) => (
    <div className="markdown-table" tabIndex={0} role="region" aria-label="Таблица">
      <table>{children}</table>
    </div>
  ),
};
const remarkPlugins = [remarkGfm];

export function AssistantMarkdown({ children }: { children: string }) {
  return (
    <div className="assistant-markdown">
      <Markdown
        remarkPlugins={remarkPlugins}
        components={components}
        skipHtml
        urlTransform={(url) => externalWebUrl(url) || ''}
      >
        {children}
      </Markdown>
    </div>
  );
}
