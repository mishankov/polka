export type ShelfDestination = 'apps' | 'clipboard' | 'settings' | 'about';

export interface ShelfPresentation {
  revision: number;
  destination: ShelfDestination;
  visible: boolean;
  focusSearch: boolean;
  topInset: number;
  notchWidth: number;
  notchHeight: number;
}
