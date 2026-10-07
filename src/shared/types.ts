export interface PlatformAPI {
  filePaths(files: File[]): string[];
  startFileDrag(ids: string[]): void;
  call<T = any>(method: string, params?: any): Promise<T>;
  onEvent(callback: (event: { type: string; [key: string]: any }) => void): () => void;
}
declare global {
  interface Window {
    platform: PlatformAPI;
  }
}
