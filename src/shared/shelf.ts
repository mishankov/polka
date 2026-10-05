export type ShelfDestination = 'apps' | 'clipboard' | 'emoji' | 'settings' | 'about';

export interface ShelfPresentation {
  revision: number;
  destination: ShelfDestination;
  visible: boolean;
  focusSearch: boolean;
  searchQuery?: string;
  topInset: number;
  notchWidth: number;
  notchHeight: number;
}
