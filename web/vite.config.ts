import { defineConfig } from 'vite';
export default defineConfig({
  server: { port: 5173, strictPort: true, headers: { 'Cross-Origin-Opener-Policy': 'same-origin', 'Cross-Origin-Embedder-Policy': 'require-corp' } },
  preview: { headers: { 'Cross-Origin-Opener-Policy': 'same-origin', 'Cross-Origin-Embedder-Policy': 'require-corp' } },
  worker: { format: 'es' },
  optimizeDeps: { exclude: ['@huggingface/transformers'] },
});
