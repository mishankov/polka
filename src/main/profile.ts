import { createHash } from 'node:crypto';
import { basename, join, resolve } from 'node:path';

export function profilePathFor(options: {
  appData: string;
  packaged: boolean;
  checkout: string;
  override?: string;
}) {
  if (options.override) return resolve(options.override);
  if (options.packaged) return join(options.appData, 'Everything App');
  const checkout = resolve(options.checkout);
  const id = createHash('sha256').update(checkout).digest('hex').slice(0, 12);
  return join(options.appData, 'polka-development', `${basename(checkout)}-${id}`);
}
