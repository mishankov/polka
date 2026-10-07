export type ShelfDestination = 'apps' | 'clipboard' | 'emoji' | 'files' | 'settings' | 'about';

export interface ShelfEntry {
  revision: number;
  sessionId: number;
  entryMode: 'fresh' | 'resume';
  destination: ShelfDestination;
  searchQuery?: string;
}

export interface ShelfPresentation extends ShelfEntry {
  visible: boolean;
  focusSearch: boolean;
  topInset: number;
  notchWidth: number;
  notchHeight: number;
}
