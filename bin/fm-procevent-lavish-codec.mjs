import { realpathSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

export function resolveInstalledToon(lavish) {
  const entry = pathToFileURL(realpathSync(lavish));
  const sdk = import.meta.resolve('axi-sdk-js', entry);
  return createRequire(entry).resolve('@toon-format/toon', { paths: [dirname(fileURLToPath(sdk))] });
}
