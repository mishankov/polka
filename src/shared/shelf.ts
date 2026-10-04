export interface ShelfPresentation {
  revision: number;
  destination: 'apps' | 'clipboard';
  visible: boolean;
  focusSearch: boolean;
  topInset: number;
  notchWidth: number;
  notchHeight: number;
}
