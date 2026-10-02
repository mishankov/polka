export const THEME_COLORS = [
  'dark',
  'gray',
  'red',
  'pink',
  'grape',
  'violet',
  'indigo',
  'blue',
  'cyan',
  'teal',
  'green',
  'lime',
  'yellow',
  'orange',
] as const;
export const THEME_RADII = ['xs', 'sm', 'md', 'lg', 'xl'] as const;
export type FieldType =
  'text' | 'number' | 'boolean' | 'date' | 'select' | 'relation' | 'attachment' | 'json';
export interface FieldDefinition {
  id: string;
  name: string;
  type: FieldType;
  required?: boolean;
  unique?: boolean;
  options?: string[];
  targetEntity?: string;
  default?: unknown;
}
export interface EntityDefinition {
  id: string;
  name: string;
  fields: FieldDefinition[];
}
export interface ScreenDefinition {
  id: string;
  name: string;
  type:
    | 'table'
    | 'form'
    | 'board'
    | 'calendar'
    | 'chart'
    | 'text'
    | 'image'
    | 'converter'
    | 'dashboard'
    | 'custom';
  entityId?: string;
  config?: Record<string, unknown>;
}
export interface ActionDefinition {
  id: string;
  name: string;
  type: string;
  config?: Record<string, unknown>;
  permission?: string;
}
export interface AutomationDefinition {
  id: string;
  name: string;
  trigger: 'interval' | 'clipboard' | 'schedule' | 'event';
  actionId: string;
  enabled?: boolean;
  intervalMs?: number;
  config?: Record<string, unknown>;
}
export interface ExtensionDefinition {
  id: string;
  name: string;
  kind: 'component' | 'handler';
  source: string;
  dependencies?: Record<string, string>;
}
export interface AppDefinition {
  schemaVersion: 1;
  name: string;
  description?: string;
  icon?: string;
  entities: EntityDefinition[];
  screens: ScreenDefinition[];
  actions: ActionDefinition[];
  automations: AutomationDefinition[];
  extensions: ExtensionDefinition[];
  permissions: string[];
  theme?: {
    mode?: 'light' | 'dark' | 'auto';
    primaryColor?: string;
    density?: 'compact' | 'comfortable';
    radius?: string;
  };
  connections?: { id: string; name: string; kind: string }[];
}
export interface AppInstance {
  id: string;
  name: string;
  icon: string;
  description: string;
  status: 'running' | 'stopped' | 'archived';
  favorite: boolean;
  version: number;
  revision: number;
  templateId: string;
  sourceVersion: number;
  createdAt: string;
  updatedAt: string;
  definition: AppDefinition;
}
export interface DataRecord {
  id: string;
  appId: string;
  entityId: string;
  values: Record<string, unknown>;
  createdAt: string;
  updatedAt: string;
}
export interface PlatformAPI {
  openDropped(appId: string, files: File[]): Promise<any>;
  call<T = any>(method: string, params?: any): Promise<T>;
  onEvent(callback: (event: { type: string; [key: string]: any }) => void): () => void;
}
declare global {
  interface Window {
    platform: PlatformAPI;
  }
}
