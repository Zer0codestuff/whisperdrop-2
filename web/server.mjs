import { createServer } from 'node:http';
import { createReadStream } from 'node:fs';
import { stat } from 'node:fs/promises';
import { extname, resolve, sep } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { pipeline } from 'node:stream/promises';

const types = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.wasm': 'application/wasm',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
};

function accepts(header, encoding) {
  const entries = String(header ?? '').split(',').map(value => value.trim().split(';'));
  const entry = entries.find(([name]) => name === encoding) ?? entries.find(([name]) => name === '*');
  if (!entry) return false;
  const quality = entry.slice(1).find(value => value.trim().startsWith('q='));
  return !quality || Number(quality.trim().slice(2)) > 0;
}

export function createStaticServer(directory = fileURLToPath(new URL('./dist/', import.meta.url))) {
  const root = resolve(directory);
  return createServer(async (request, response) => {
    response.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
    response.setHeader('Cross-Origin-Embedder-Policy', 'require-corp');
    response.setHeader('Cross-Origin-Resource-Policy', 'same-origin');
    response.setHeader('X-Content-Type-Options', 'nosniff');
    response.setHeader('Cache-Control', 'no-cache');
    const fail = (status, message) => {
      response.writeHead(status, { 'Content-Type': 'text/plain; charset=utf-8' });
      response.end(request.method === 'HEAD' ? undefined : message);
    };
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      response.setHeader('Allow', 'GET, HEAD');
      return fail(405, 'Method not allowed.');
    }
    let pathname;
    try { pathname = decodeURIComponent((request.url ?? '/').split('?')[0]); }
    catch { return fail(400, 'Invalid path.'); }
    if (pathname === '/healthz') {
      response.setHeader('Cache-Control', 'no-store');
      return fail(200, 'ok');
    }
    if (!pathname.startsWith('/') || pathname.includes('\\') || pathname.includes('\0') || pathname.split('/').some(part => part.startsWith('.'))) {
      return fail(404, 'Not found.');
    }
    const file = resolve(root, `.${pathname === '/' ? '/index.html' : pathname}`);
    if (!file.startsWith(root + sep)) return fail(404, 'Not found.');
    try {
      let info = await stat(file);
      if (!info.isFile()) return fail(404, 'Not found.');
      let representation = file;
      response.setHeader('Vary', 'Accept-Encoding');
      for (const encoding of ['br', 'gzip']) {
        if (!accepts(request.headers['accept-encoding'], encoding)) continue;
        const compressed = file + (encoding === 'br' ? '.br' : '.gz');
        const compressedInfo = await stat(compressed).catch(() => null);
        if (!compressedInfo?.isFile()) continue;
        representation = compressed; info = compressedInfo;
        response.setHeader('Content-Encoding', encoding);
        break;
      }
      if (/^\/assets\/.+-[\w-]{8,}\./.test(pathname)) {
        response.setHeader('Cache-Control', 'public, max-age=31536000, immutable');
      }
      response.writeHead(200, { 'Content-Type': types[extname(file)] ?? 'application/octet-stream', 'Content-Length': info.size });
      if (request.method === 'HEAD') return response.end();
      await pipeline(createReadStream(representation), response);
    } catch (error) {
      if (response.headersSent) response.destroy();
      else fail(error.code === 'ENOENT' || error.code === 'ENOTDIR' ? 404 : 500, 'File unavailable.');
    }
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const port = Number(process.env.PORT ?? 3000);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('PORT must be a valid TCP port.');
  const server = createStaticServer();
  server.listen(port, '0.0.0.0', () => console.log(`WhisperDrop Web listening on port ${port}`));
  for (const signal of ['SIGTERM', 'SIGINT']) process.once(signal, () => {
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(1), 10000).unref();
  });
}
