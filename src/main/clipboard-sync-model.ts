import { z } from 'zod';

export const stampSchema = z.object({
  counter: z
    .number()
    .int()
    .nonnegative()
    .max(Number.MAX_SAFE_INTEGER - 1000000),
  device: z.string().uuid(),
});
export type Stamp = z.infer<typeof stampSchema>;
export const syncEntrySchema = z.object({
  snippet: z.literal(true).optional(),
  added: stampSchema.optional(),
  deleted: stampSchema.optional(),
  pin: z.object({ stamp: stampSchema, value: z.boolean() }).optional(),
});
export type SyncEntry = z.infer<typeof syncEntrySchema>;
export const manifestSchema = z.object({
  version: z.literal(1),
  snippets: z.literal(true).optional(),
  clear: stampSchema.optional(),
  entries: z.record(z.string().regex(/^[a-f0-9]{64}$/), syncEntrySchema),
  available: z.array(z.string().regex(/^[a-f0-9]{64}$/)).max(400),
});
export type SyncManifest = z.infer<typeof manifestSchema>;
export function compareStamp(a?: Stamp, b?: Stamp): number {
  if (!a) return b ? -1 : 0;
  if (!b) return 1;
  return a.counter - b.counter || a.device.localeCompare(b.device, 'en');
}
export function newest(a?: Stamp, b?: Stamp) {
  return compareStamp(a, b) >= 0 ? a : b;
}
export function liveEntry(entry: SyncEntry, clear?: Stamp) {
  return (
    !!entry.added &&
    compareStamp(entry.added, newest(entry.deleted, entry.snippet ? undefined : clear)) > 0
  );
}
