import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { request } from 'node:http';
import { gzipSync, gunzipSync } from 'node:zlib';
import { createStaticServer } from '../server.mjs';

function get(port, path, headers = {}, method = 'GET') {
  return new Promise((resolve, reject) => {
    const req = request({ hostname: '127.0.0.1', port, path, headers, method }, response => {
      const chunks = [];
      response.on('data', chunk => chunks.push(chunk));
      response.on('end', () => resolve({ status: response.statusCode, headers: response.headers, body: Buffer.concat(chunks) }));
    });
    req.on('error', reject); req.end();
  });
}

test('production server preserves isolation, WASM MIME and cache rules while negotiating compression', async t => {
  const root = await mkdtemp(join(tmpdir(), 'whisperdrop-web-'));
  await mkdir(join(root, 'assets'));
  const wasm = Buffer.from([0, 97, 115, 109, 1, 0, 0, 0]);
  await Promise.all([
    writeFile(join(root, 'index.html'), '<!doctype html><title>WhisperDrop</title>'),
    writeFile(join(root, 'assets/runtime-12345678.wasm'), wasm),
    writeFile(join(root, 'assets/runtime-12345678.wasm.gz'), gzipSync(wasm)),
  ]);
  const server = createStaticServer(root);
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => { await new Promise(resolve => server.close(resolve)); await rm(root, { recursive: true }); });
  const port = server.address().port;
  const home = await get(port, '/');
  assert.equal(home.status, 200);
  assert.equal(home.headers['cross-origin-opener-policy'], 'same-origin');
  assert.equal(home.headers['cross-origin-embedder-policy'], 'require-corp');
  assert.equal(home.headers['cache-control'], 'no-cache');
  const compressed = await get(port, '/assets/runtime-12345678.wasm', { 'Accept-Encoding': 'gzip' });
  assert.equal(compressed.headers['content-type'], 'application/wasm');
  assert.equal(compressed.headers['content-encoding'], 'gzip');
  assert.match(compressed.headers['cache-control'], /immutable/);
  assert.equal(compressed.headers.vary, 'Accept-Encoding');
  assert.deepEqual(gunzipSync(compressed.body), wasm);
  const plain = await get(port, '/assets/runtime-12345678.wasm', { 'Accept-Encoding': 'br;q=0, gzip;q=0' });
  assert.equal(plain.headers['content-encoding'], undefined);
  assert.deepEqual(plain.body, wasm);
  const head = await get(port, '/assets/runtime-12345678.wasm', {}, 'HEAD');
  assert.equal(head.body.length, 0);
  assert.equal(Number(head.headers['content-length']), wasm.length);
  assert.equal((await get(port, '/healthz')).body.toString(), 'ok');
  for (const path of ['/%2e%2e/package.json', '/.env', '/%00', '/%ZZ', '/assets/missing.js']) {
    assert.ok([400, 404].includes((await get(port, path)).status), path);
  }
  assert.equal((await get(port, '/', {}, 'POST')).status, 405);
});
