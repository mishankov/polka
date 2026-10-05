export type DeviceActivity = 'active' | 'inactive' | 'unknown' | 'disabled';
export type MediaDevice = 'camera' | 'microphone';
export interface MediaTracking {
  cameraEnabled: boolean;
  microphoneEnabled: boolean;
}
export interface MediaActivity {
  camera: DeviceActivity;
  microphone: DeviceActivity;
}
export interface MediaIndicatorState extends MediaActivity, MediaTracking {
  enabled: boolean;
}
export interface MediaIndicatorPresentation extends MediaActivity {
  notchWidth: number;
  notchHeight: number;
}
export const UNKNOWN_MEDIA: MediaActivity = { camera: 'unknown', microphone: 'unknown' };

export function mediaTrackingFromSettings(settings: Record<string, unknown> = {}): MediaTracking {
  const tracking = settings.mediaIndicatorTracking as Partial<MediaTracking> | null;
  const fallback = settings.mediaIndicatorEnabled !== false;
  return {
    cameraEnabled: typeof tracking?.cameraEnabled === 'boolean' ? tracking.cameraEnabled : fallback,
    microphoneEnabled:
      typeof tracking?.microphoneEnabled === 'boolean' ? tracking.microphoneEnabled : fallback,
  };
}

export function trackedMediaActivity(
  activity: MediaActivity,
  tracking: MediaTracking,
): MediaActivity {
  return {
    camera: tracking.cameraEnabled ? activity.camera : 'disabled',
    microphone: tracking.microphoneEnabled ? activity.microphone : 'disabled',
  };
}

export function parseMediaActivity(value: unknown): MediaActivity {
  const source = value as Record<string, { state?: unknown }> | null;
  const read = (key: string): DeviceActivity => {
    const state = source?.[key]?.state;
    return state === 'active' || state === 'inactive' || state === 'disabled' ? state : 'unknown';
  };
  return { camera: read('camera'), microphone: read('microphone') };
}

export function mediaIndicatorVisible(activity: MediaActivity) {
  return [activity.camera, activity.microphone].some(
    (state) => state === 'active' || state === 'unknown',
  );
}

export function mediaActivityLabel(activity: MediaActivity) {
  const label = (name: string, state: DeviceActivity) =>
    `${name}: ${state === 'active' ? 'используется' : state === 'inactive' ? 'не используется' : state === 'disabled' ? 'отслеживание выключено' : 'статус недоступен'}`;
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
