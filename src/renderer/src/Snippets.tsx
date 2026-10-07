import ClipboardHistory from './ClipboardHistory';
import type { ClipboardContext } from './shelf-context';

export default function Snippets({
  onBack,
  initialQuery,
  initialContext,
  sourceClipId,
  onContextChange,
}: {
  onBack: () => void;
  initialQuery?: string;
  initialContext?: ClipboardContext;
  sourceClipId?: string;
  onContextChange: (context: ClipboardContext) => void;
}) {
  return (
    <ClipboardHistory
      snippets
      onBack={onBack}
      initialQuery={initialQuery}
      initialContext={initialContext}
      initialSourceClipId={sourceClipId}
      onContextChange={onContextChange}
    />
  );
}
