export type DeviceActivity = 'active' | 'inactive' | 'unknown';
export interface MediaActivity {
  camera: DeviceActivity;
  microphone: DeviceActivity;
}
export interface MediaIndicatorState extends MediaActivity {
  enabled: boolean;
}
export interface MediaIndicatorPresentation extends MediaActivity {
  notchWidth: number;
  notchHeight: number;
}
export const UNKNOWN_MEDIA: MediaActivity = { camera: 'unknown', microphone: 'unknown' };

export function parseMediaActivity(value: unknown): MediaActivity {
  const source = value as Record<string, { state?: unknown }> | null;
  const read = (key: string): DeviceActivity => {
    const state = source?.[key]?.state;
    return state === 'active' || state === 'inactive' ? state : 'unknown';
  };
  return { camera: read('camera'), microphone: read('microphone') };
}

export function mediaIndicatorVisible(activity: MediaActivity) {
  return activity.camera !== 'inactive' || activity.microphone !== 'inactive';
}

export function mediaActivityLabel(activity: MediaActivity) {
  const label = (name: string, state: DeviceActivity) =>
    `${name}: ${state === 'active' ? 'используется' : state === 'inactive' ? 'не используется' : 'статус недоступен'}`;
  return `${label('Камера', activity.camera)}. ${label('Микрофон', activity.microphone)}.`;
}

declare global {
  interface Window {
    mediaIndicator: {
      getState(): Promise<MediaIndicatorPresentation>;
      onChange(callback: (state: MediaIndicatorPresentation) => void): () => void;
    };
  }
}
