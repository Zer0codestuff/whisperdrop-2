import { readdir, readFile, writeFile } from 'node:fs/promises';
import { join, extname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { brotliCompressSync, gzipSync, constants } from 'node:zlib';

async function compress(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) { await compress(path); continue; }
    if (!['.html', '.js', '.css', '.wasm', '.json', '.svg'].includes(extname(path))) continue;
    const data = await readFile(path);
    if (data.length < 1024) continue;
    const brotli = brotliCompressSync(data, { params: { [constants.BROTLI_PARAM_QUALITY]: 5 } });
    const gzip = gzipSync(data, { level: 9 });
    await Promise.all([writeFile(path + '.br', brotli), writeFile(path + '.gz', gzip)]);
  }
}

await compress(fileURLToPath(new URL('../dist/', import.meta.url)));
