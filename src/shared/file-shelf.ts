export interface ShelfFile {
  id: string;
  name: string;
  path: string;
  icon: string;
  available: boolean;
  directory: boolean;
}
export interface FileShelfState {
  items: ShelfFile[];
  error: string;
}
export const MAX_SHELF_FILES = 200;
