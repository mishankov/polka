import type { ClipboardClip, ClipboardState } from '../../shared/clipboard';
import type { TextTransformation } from '../../shared/clipboard-actions';

export interface ClipboardContext {
  destination: 'clipboard' | 'snippets';
  query: string;
  selected?: string;
  previewId?: string;
  transformation?: TextTransformation;
  editor?: { clip?: ClipboardClip; name: string; content: string };
  scrollTop: number;
  previewScrollTop: number;
  // Last rendered data lets a restored preview commit without a list/loading flash.
  // Refresh remains authoritative; paste readiness is always rechecked on entry.
  state?: ClipboardState;
}

export interface EmojiContext {
  destination: 'emoji';
  query: string;
  selected?: string;
  category: string;
  tone: string;
  columns: number;
  scrollTop: number;
}

export type BuiltinContext = ClipboardContext | EmojiContext;
