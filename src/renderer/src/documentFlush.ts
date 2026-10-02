const writers = new Set<() => Promise<void>>();
export function registerDocumentFlush(write: () => Promise<void>) {
  writers.add(write);
  return () => {
    writers.delete(write);
  };
}
export async function flushDocuments() {
  await Promise.all([...writers].map((write) => write()));
}
