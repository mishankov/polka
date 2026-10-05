export interface PlatformAPI {
  call<T = any>(method: string, params?: any): Promise<T>;
  onEvent(callback: (event: { type: string; [key: string]: any }) => void): () => void;
}
declare global {
  interface Window {
    platform: PlatformAPI;
  }
}
