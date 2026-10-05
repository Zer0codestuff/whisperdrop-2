import './style.css';
import { createIcons, AudioLines, FileAudio, Mic, NotebookPen, FileText, Cpu, ShieldCheck, LockKeyhole, Settings2, CircleAlert, X, HardDriveDownload, Fingerprint, Copy, Download, Square, Trash2, Check, HardDrive, Zap } from 'lucide';
const icons = { AudioLines, FileAudio, Mic, NotebookPen, FileText, Cpu, ShieldCheck, LockKeyhole, Settings2, CircleAlert, X, HardDriveDownload, Fingerprint, Copy, Download, Square, Trash2, Check, HardDrive, Zap };
import { decodeAudio, joinAudio, resample, MicrophoneCapture } from './audio';
import { listEntries, saveEntry, deleteEntry, type Entry } from './storage';
import { MODELS } from './models';
import { NoteAudioWriter, recoverNoteAudio, clearAudioParts } from './note-audio';
import { reserveSession, releaseSession, recoverWhenIdle } from './session-lock';

const LANGUAGES = [['italian','Italian'],['english','English'],['spanish','Spanish'],['french','French'],['german','German'],['portuguese','Portuguese'],['dutch','Dutch'],['japanese','Japanese'],['chinese','Chinese'],['korean','Korean'],['arabic','Arabic'],['hindi','Hindi']];
const app = document.querySelector<HTMLDivElement>('#app')!;
let entries: Entry[] = [];
let current: Entry | undefined;
let view = 'files';
let drawer = false;
let model = localStorage.getItem('wd-model') || MODELS[0].id;
if (!MODELS.some(candidate => candidate.id === model)) model = MODELS[0].id;
let language = localStorage.getItem('wd-language') || 'italian';
if (!LANGUAGES.some(([value]) => value === language)) language = 'italian';
let keepAudio = localStorage.getItem('wd-audio') === 'true';
let modelState = 'unloaded';
let loadedModel = '';
let modelDetail = 'Download once. Run locally.';
let gpuInfo: any;
let busy = false;
let error = '';
let progress = 0;
let downloadFiles = new Map<string, { loaded: number; total: number }>();
let worker = new Worker(new URL('./worker.ts', import.meta.url), { type: 'module' });
let sequence = 0;
const pending = new Map<number, { resolve: (value: any) => void; reject: (reason: Error) => void; partial?: (value: any) => void }>();
let loadPromise: Promise<void> | undefined;
let activeRequest = 0;
let cancelRequested = false;
let fileProgress = '';
let noteFailed = false;
let recording = false;
let recordingStarted = 0;
let capture: MicrophoneCapture | undefined;
let noteAudio: NoteAudioWriter | undefined;
let chunkParts: Float32Array[] = [];
let chunkLength = 0;
let totalSamples = 0;
let noteQueue = Promise.resolve();
let noteQueued = 0;
let recordingTimer: ReturnType<typeof setInterval> | undefined;
let persistenceTimer: ReturnType<typeof setInterval> | undefined;
let wakeLock: any;
let audioURL = '';
const escape = (value: string) => value.replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]!));
const icon = (name: string, cls = '') => `<i data-lucide="${name}" class="${cls}"></i>`;
const time = (value: number) => `${Math.floor(value / 60)}:${Math.floor(value % 60).toString().padStart(2, '0')}`;
const niceDate = (value: number) => new Intl.DateTimeFormat('en', { month:'short', day:'numeric', hour:'numeric', minute:'2-digit' }).format(value);
function rpc(type: string, payload: Record<string, unknown> = {}, partial?: (value: any) => void): Promise<any> {
  const id = ++sequence;
  if (type === 'load' || type === 'transcribe') activeRequest = id;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject, partial });
    const audio = payload.audio as Float32Array | undefined;
    worker.postMessage({ id, type, ...payload }, audio ? [audio.buffer as ArrayBuffer] : []);
  });
}
function connectWorker() {
worker.onmessage = ({ data }) => {
  if (data.type === 'gpu') { gpuInfo = data.info; return; }
  if (data.type === 'download') {
    if (data.status === 'progress') downloadFiles.set(data.file, { loaded: data.loaded, total: data.total });
    const files = [...downloadFiles.values()];
    const total = files.reduce((s, f) => s + f.total, 0);
    const loaded = files.reduce((s, f) => s + f.loaded, 0);
    progress = total ? loaded / total : 0;
    modelDetail = total ? `${Math.round(loaded / 1e6)} / ${Math.round(total / 1e6)} MB` : 'Reading cached model files';
    updateModelStatus(); return;
  }
  if (data.type === 'warming') { modelDetail = data.detail ?? 'Preparing GPU kernels'; updateModelStatus(); return; }
  if (data.type === 'fatal') { failWorker(data.message); return; }
  if (data.type === 'partial') { pending.get(data.id)?.partial?.(data); return; }
  const request = pending.get(data.id);
  if (request) {
    pending.delete(data.id);
    if (data.type === 'error') request.reject(new Error(data.message)); else request.resolve(data);
  }
};
worker.onerror = event => failWorker(event.message || 'The model worker stopped. Reload this page to restart it.');
}
connectWorker();
function failWorker(message: string) {
  for (const request of pending.values()) request.reject(new Error(message));
  pending.clear(); loadedModel = ''; modelState = 'unloaded'; modelDetail = 'Model unavailable';
  if (recording) { error = message; void stopNote(); }
  showError(message);
}
function cancelWork() {
  if (recording) return;
  cancelRequested = true;
  if (modelState === 'loading') {
    worker.terminate(); failWorker('Model loading cancelled. Downloaded files remain cached.');
    worker = new Worker(new URL('./worker.ts', import.meta.url), { type: 'module' }); connectWorker();
  } else worker.postMessage({ type: 'cancel', requestId: activeRequest });
}
function updateModelStatus() {
  for (const element of document.querySelectorAll<HTMLElement>('[data-model-detail]')) element.textContent = modelDetail;
  for (const element of document.querySelectorAll<HTMLProgressElement>('[data-model-progress]')) element.value = progress;
}
function showError(message: string) { error = message; render(); }
function ensureModel(): Promise<void> {
  if (loadPromise) return loadPromise;
  if (loadedModel === model && modelState === 'ready') return Promise.resolve();
  const selected = model;
  loadPromise = loadSelectedModel(selected).finally(() => { loadPromise = undefined; });
  return loadPromise;
}
async function loadSelectedModel(selected: string) {
  modelState = 'loading'; downloadFiles.clear(); progress = 0; modelDetail = 'Connecting to model storage'; render();
  try {
    await navigator.storage?.persist?.();
    const result = await rpc('load', { model: selected });
    loadedModel = selected; modelState = 'ready';
    modelDetail = `${MODELS.find(m => m.id === selected)!.name} on WebGPU`;
    (window as any).__lastModelLoad = result;
  } catch (e) { modelState = 'unloaded'; modelDetail = 'Model could not load'; throw e; }
  finally { render(); void refreshStorage(); }
}
function render() {
  if (audioURL) { URL.revokeObjectURL(audioURL); audioURL = ''; }
  app.innerHTML = `<div class="shell">
    <aside class="sidebar">
      <a class="brand" href="#" aria-label="WhisperDrop home"><span class="brand-mark">${icon('audio-lines')}</span><span>WhisperDrop<span class="brand-sub">Web experiment</span></span></a>
      <nav aria-label="Main navigation">
        <button class="nav-item ${view === 'files' && !current ? 'active' : ''}" data-view="files">${icon('file-audio')}<span>Transcribe files</span></button>
        <button class="nav-item ${view === 'notes' && !current ? 'active' : ''}" data-view="notes">${icon('mic')}<span>Record a note</span>${recording ? '<span class="record-dot"></span>' : ''}</button>
      </nav>
      <div class="library-heading"><span>Your library</span><span>${entries.length}</span></div>
      <div class="library">${entries.length ? entries.map(entry => `<button class="library-item ${current?.id === entry.id ? 'selected' : ''}" data-entry="${entry.id}">${icon(entry.kind === 'note' ? 'notebook-pen' : 'file-text')}<span><strong>${escape(entry.title)}</strong><small>${niceDate(entry.created)}</small></span></button>`).join('') : '<p class="library-empty">Your transcripts will<br>appear here.</p>'}</div>
      <button class="model-card" id="open-models">${icon('cpu')}<span><strong>${modelState === 'ready' ? 'GPU ready' : modelState === 'loading' ? 'Loading model' : 'Models & storage'}</strong><small data-model-detail>${escape(modelDetail)}</small></span><span class="status-dot ${modelState === 'ready' ? 'ready' : ''}"></span></button>
      <div class="privacy">${icon('shield-check')}<span>Audio stays on this device</span></div>
    </aside>
    <main>
      <header class="topbar"><span>${current ? (current.kind === 'note' ? 'Notes' : 'Files') : view === 'notes' ? 'Notes' : 'Files'}</span><div>${busy && !recording && current?.kind !== 'note' || modelState === 'loading' ? '<button class="secondary" id="cancel-work">Cancel</button>' : ''}${entries.length ? `<select class="mobile-library" id="mobile-library" aria-label="Your library"><option value="">Your library</option>${entries.map(e => `<option value="${e.id}" ${current?.id === e.id ? 'selected' : ''}>${escape(e.title)}</option>`).join('')}</select>` : ''}<span class="local-badge">${icon('lock-keyhole')}Local processing</span><button class="icon-button mobile-models" id="mobile-models" aria-label="Models and storage">${icon('settings-2')}</button></div></header>
      ${error ? `<div class="error" role="alert">${icon('circle-alert')}<span>${escape(error)}</span><button class="icon-button" id="dismiss-error" aria-label="Dismiss error">${icon('x')}</button></div>` : ''}
      ${current ? transcriptView() : homeView()}
      <footer><span>WhisperDrop 2, in your browser.</span><button id="footer-models">${icon('zap')}WebGPU ${modelState === 'ready' ? 'active' : 'inference'}</button></footer>
    </main>
    ${drawer ? modelsView() : ''}
    <input type="file" id="file-input" accept="audio/*,video/*,.wav,.mp3,.m4a,.ogg,.flac,.webm,.mp4" hidden multiple>
  </div>`;
  createIcons({ icons });
  bind();
}
function languageSelect() {
  return `<label class="field"><span>Spoken language</span><select id="language" ${busy || recording ? 'disabled' : ''}>${LANGUAGES.map(([value, label]) => `<option value="${value}" ${language === value ? 'selected' : ''}>${label}</option>`).join('')}</select></label>`;
}
function homeView() {
  return `<section class="home"><div class="intro"><h1>${view === 'notes' ? 'Give your thoughts<br>a place to land.' : 'From sound<br>to something written.'}</h1><p>${view === 'notes' ? 'Record a conversation, a lecture, or a thought.<br>Your transcript grows as you speak.' : 'Drop in a file. Get a transcript.<br>Everything happens right here on your device.'}</p></div>
  ${view === 'notes' ? `<div class="record-panel"><div class="record-symbol">${icon('mic')}</div><h2>A new note</h2><p>Keep this page open while recording.</p><div class="record-options">${languageSelect()}<label class="checkbox"><input id="keep-audio" type="checkbox" ${keepAudio ? 'checked' : ''}>Keep audio in library</label></div><button class="primary" id="start-note" ${busy ? 'disabled' : ''}>${icon('mic')}Start recording</button></div>` : `<button class="dropzone" id="pick-file" ${busy ? 'disabled' : ''}><span class="drop-symbol">${icon('file-audio')}</span><h2>Drop your audio here</h2><p>or choose a file</p><span class="file-types">Audio and browser-supported video</span></button><div class="file-options">${languageSelect()}<span class="hint">${icon('hard-drive-download')}The model downloads on first use.</span></div>`}
  <div class="local-explanation">${icon('fingerprint')}<p>Your audio is never uploaded. Models and transcripts are stored in this browser. You can export or remove them at any time.</p></div></section>`;
}
function transcriptView() {
  const entry = current!;
  const canEdit = !busy && !recording && (entry.status === 'saved' || entry.status === 'interrupted');
  const speed = entry.elapsed > 0 ? entry.duration / entry.elapsed : 0;
  return `<section class="transcript-view"><div class="transcript-heading"><div><div class="entry-meta">${entry.kind === 'note' ? 'Recorded note' : 'File transcript'}<span>${niceDate(entry.created)}</span></div><h1 id="entry-title" ${canEdit ? 'contenteditable="plaintext-only"' : ''} spellcheck="false" aria-label="Transcript title">${escape(entry.title)}</h1><div class="entry-stats"><span id="duration">${time(entry.duration)}</span>${speed ? `<span>${speed.toFixed(1)}× real time</span><span>${entry.elapsed.toFixed(1)} s processing</span>` : ''}<span>${MODELS.find(m => m.id === entry.model)?.name ?? 'Whisper'}</span></div></div><div class="transcript-actions">${recording ? `<button class="stop-button" id="stop-note">${icon('square')}Stop & save</button>` : `<button class="secondary" id="copy-text" ${!entry.text ? 'disabled' : ''}>${icon('copy')}Copy</button><div class="export-wrap"><button class="secondary" id="export-text" ${!entry.text ? 'disabled' : ''}>${icon('download')}Export</button><select id="export-format" aria-label="Export format"><option value="txt">TXT</option><option value="srt">SRT</option><option value="json">JSON</option></select></div>`}</div></div>
    ${recording ? `<div class="recording-bar"><span class="record-dot"></span><strong>Recording</strong><span id="record-time">${time((Date.now() - recordingStarted) / 1000)}</span><div class="level-meter"><div id="audio-level"></div></div><span id="queue-status">${noteQueued ? `${noteQueued} chunk${noteQueued === 1 ? '' : 's'} processing` : 'Listening'}</span></div>` : ''}
    ${entry.status === 'transcribing' || modelState === 'loading' ? `<div class="processing-bar" role="status">${icon('audio-lines')}<span>${modelState === 'loading' ? 'Loading model' : 'Transcribing on your GPU'}<small data-model-detail>${modelState === 'loading' ? escape(modelDetail) : escape(fileProgress || 'Preparing audio')}</small></span>${modelState === 'loading' ? '<progress data-model-progress max="1" value="0"></progress>' : ''}</div>` : ''}
    ${entry.warning ? `<div class="recovery">${escape(entry.warning)}</div>` : ''}
    ${entry.status === 'interrupted' ? '<div class="recovery">This session was interrupted. The text saved before the interruption is below.</div>' : ''}
    <article class="transcript-body" id="transcript-text" ${canEdit && entry.text ? 'contenteditable="plaintext-only"' : ''} aria-label="Transcript" spellcheck="true">${entry.text ? entry.text.split('\n\n').map(p => `<p>${escape(p)}</p>`).join('') : `<div class="transcript-empty">${icon('audio-lines')}<p>${recording ? 'Speak naturally.<br>Your first words will appear after the next audio chunk.' : entry.status === 'saved' ? 'No speech was recognized.' : 'Preparing your transcript.'}</p></div>`}</article>
    ${entry.audio ? `<audio controls preload="metadata" src="${audioURL = URL.createObjectURL(entry.audio)}" aria-label="Saved audio"></audio>` : ''}
    ${canEdit ? `<div class="entry-bottom"><span>Saved in this browser. Click the text to edit.</span><button class="text-button danger" id="delete-entry">${icon('trash-2')}Delete</button></div>` : ''}
  </section>`;
}
function modelsView() {
  return `<div class="drawer-backdrop" id="drawer-backdrop"><section class="drawer" role="dialog" aria-modal="true" aria-label="Models and storage"><div class="drawer-title"><h2>Models & storage</h2><button class="icon-button" id="close-models" aria-label="Close settings">${icon('x')}</button></div><p class="drawer-copy">One model for files and notes. It runs on your GPU and stays cached for next time.</p><div class="model-choices">${MODELS.map(m => `<label class="model-choice"><input type="radio" name="model" value="${m.id}" ${model === m.id ? 'checked' : ''} ${busy || recording || modelState === 'loading' ? 'disabled' : ''}><span><strong>${m.name}</strong><small>${m.detail}</small></span><span class="model-size">${m.size}</span></label>`).join('')}</div><div class="model-load-status"><span class="status-dot ${modelState === 'ready' ? 'ready' : ''}"></span><span data-model-detail>${escape(modelDetail)}</span></div>${modelState === 'loading' ? `<progress data-model-progress max="1" value="${progress}"></progress>` : `<button class="primary full-width" id="load-model" ${busy || recording ? 'disabled' : ''}>${icon(modelState === 'ready' ? 'check' : 'download')}${modelState === 'ready' ? 'Model ready' : 'Download & load model'}</button>`}<div class="storage-section"><h3>On this device</h3><div class="storage-row"><span>Browser storage used</span><strong id="storage-used">Checking</strong></div><div class="storage-row"><span>Saved transcripts</span><strong>${entries.length}</strong></div><p>Browser storage can be cleared by your browser. Export anything you want to keep.</p><button class="secondary full-width" id="clear-models" ${busy || recording || modelState === 'loading' ? 'disabled' : ''}>${icon('hard-drive')}Remove cached models</button><button class="text-button full-width" id="unload-model" ${busy || recording || modelState !== 'ready' ? 'disabled' : ''}>Release GPU memory</button></div><div class="gpu-details">${icon('cpu')}<span>${gpuInfo ? escape([gpuInfo.vendor, gpuInfo.architecture, gpuInfo.description].filter(Boolean).join(' ')) || 'Hardware WebGPU adapter' : 'A hardware WebGPU adapter is required.'}</span></div></section></div>`;
}
function bind() {
  app.querySelectorAll<HTMLElement>('[data-view]').forEach(button => button.onclick = () => { if (busy || recording) { current = entries.find(e => e.status === 'recording' || e.status === 'transcribing'); } else { current = undefined; view = button.dataset.view!; } render(); });
  app.querySelectorAll<HTMLElement>('[data-entry]').forEach(button => button.onclick = () => { current = entries.find(e => e.id === button.dataset.entry); render(); });
  const on = (id: string, action: () => void) => { const element = document.getElementById(id); if (element) element.onclick = action; };
  on('open-models', openModels);
  const mobileLibrary = document.querySelector<HTMLSelectElement>('#mobile-library');
  if (mobileLibrary) mobileLibrary.onchange = () => { current = entries.find(e => e.id === mobileLibrary.value); render(); }; on('mobile-models', openModels); on('footer-models', openModels);
  on('close-models', () => { drawer = false; render(); });
  on('drawer-backdrop', () => { drawer = false; render(); });
  app.querySelector('.drawer')?.addEventListener('click', e => e.stopPropagation());
  on('dismiss-error', () => { error = ''; render(); });
  on('pick-file', () => document.getElementById('file-input')?.click());
  const fileInput = document.querySelector<HTMLInputElement>('#file-input')!;
  fileInput.onchange = () => { if (fileInput.files) void importFiles(Array.from(fileInput.files)); };
  const dropzone = document.getElementById('pick-file');
  if (dropzone) {
    dropzone.ondragover = e => { e.preventDefault(); dropzone.classList.add('dragging'); };
    dropzone.ondragleave = () => dropzone.classList.remove('dragging');
    dropzone.ondrop = e => { e.preventDefault(); if (!busy && e.dataTransfer) void importFiles(Array.from(e.dataTransfer.files)); };
  }
  const lang = document.querySelector<HTMLSelectElement>('#language');
  if (lang) lang.onchange = () => { language = lang.value; localStorage.setItem('wd-language', language); };
  const retention = document.querySelector<HTMLInputElement>('#keep-audio');
  if (retention) retention.onchange = () => { keepAudio = retention.checked; localStorage.setItem('wd-audio', String(keepAudio)); };
  app.querySelectorAll<HTMLInputElement>('[name=model]').forEach(input => input.onchange = () => { model = input.value; localStorage.setItem('wd-model', model); modelState = loadedModel === model ? 'ready' : 'unloaded'; modelDetail = 'Download once. Run locally.'; render(); void refreshStorage(); });
  on('load-model', () => { if (modelState !== 'ready') void ensureModel().catch(e => showError(e.message)); });
  on('start-note', () => { void startNote(); });
  on('stop-note', () => { void stopNote(); });
  on('cancel-work', cancelWork);
  on('copy-text', () => { if (current) void navigator.clipboard.writeText(current.text).then(() => { const el = document.getElementById('copy-text'); if (el) el.textContent = 'Copied'; }).catch(e => showError(e.message)); });
  on('export-text', exportCurrent);
  on('delete-entry', () => { if (current && confirm(`Delete "${current.title}" from this browser?`)) void deleteEntry(current.id).then(() => { entries = entries.filter(e => e.id !== current!.id); current = undefined; render(); }); });
  on('unload-model', () => { void releaseModel().catch(e => showError(e.message)); });
  on('clear-models', () => { if (confirm('Remove downloaded models? Your saved transcripts will stay.')) void clearModels(); });
  const title = document.getElementById('entry-title');
  if (title?.isContentEditable) title.onblur = () => { const value = title.textContent?.trim(); if (current && value) { current.title = value; void persist(current); } else if (current) title.textContent = current.title; };
  const text = document.getElementById('transcript-text');
  if (text?.isContentEditable) text.onblur = () => { if (current) { current.text = text.innerText.trim(); void persist(current); } };
}
function openModels() { drawer = true; render(); void refreshStorage(); }
async function refreshStorage() {
  const estimate = await navigator.storage?.estimate?.();
  const element = document.getElementById('storage-used');
  if (element) element.textContent = estimate?.usage ? `${(estimate.usage / 1e6).toFixed(0)} MB` : '0 MB';
}
async function clearModels() {
  try {
    await releaseModel();
    for (const key of await caches.keys()) if (key.includes('transformers')) await caches.delete(key);
    loadedModel = ''; modelState = 'unloaded'; modelDetail = 'Cached models removed'; render(); await refreshStorage();
  } catch (e) { showError((e as Error).message); }
}
async function releaseModel() {
  await rpc('unload');
  worker.terminate();
  worker = new Worker(new URL('./worker.ts', import.meta.url), { type: 'module' }); connectWorker();
  loadedModel = ''; modelState = 'unloaded'; modelDetail = 'Model cached. GPU memory released.'; render();
}
async function persist(entry: Entry) {
  try { await saveEntry(entry); return true; }
  catch { error = 'Browser storage is full or unavailable. Export this transcript before closing the page.'; render(); return false; }
}
function makeEntry(title: string, kind: 'file' | 'note'): Entry {
  const entry: Entry = { id: crypto.randomUUID(), title, kind, created: Date.now(), text: '', segments: [], duration: 0, elapsed: 0, model, language, status: kind === 'note' ? 'recording' : 'transcribing' };
  entries.unshift(entry); current = entry; return entry;
}
async function importFiles(files: File[]) {
  if (busy || recording || !files.length) return;
  busy = true; error = ''; cancelRequested = false; fileProgress = ''; render();
  let importingEntry: Entry | undefined;
  try {
    await reserveSession();
    await ensureModel();
    for (const file of files) {
      if (cancelRequested) throw new Error('Import cancelled. Completed transcripts are saved.');
      if (!file.size) throw new Error('This file is empty.');
      if (file.size > 500 * 1024 * 1024) throw new Error('This experiment accepts files up to 500 MB. Split larger files before importing.');
      const entry = importingEntry = makeEntry(file.name.replace(/\.[^.]+$/, ''), 'file'); render();
      await persist(entry);
      fileProgress = 'Decoding audio';
      const pcm = await decodeAudio(file);
      if (pcm.length > 2 * 60 * 60 * 16000) throw new Error('This browser experiment accepts up to two hours per file. Split longer recordings before importing.');
      entry.duration = pcm.length / 16000; render();
      if (cancelRequested) throw new Error('Import cancelled. Completed transcripts are saved.');
      const result = await rpc('transcribe', { audio: pcm, language: entry.language }, partial => {
        entry.text = partial.text; entry.segments = partial.chunks; entry.elapsed = partial.elapsed;
        fileProgress = `${time(partial.completed)} / ${time(partial.seconds)}`;
        void persist(entry); render();
      });
      entry.text = result.text.trim(); entry.segments = result.chunks ?? []; entry.elapsed = result.elapsed; entry.status = 'saved';
      await persist(entry); render();
      (window as any).__lastTranscription = { ...result, audio: undefined };
    }
  } catch (e) {
    error = (e as Error).message;
    if (importingEntry?.status === 'transcribing') {
      importingEntry.status = 'interrupted'; importingEntry.warning = error; await persist(importingEntry);
    }
  }
  finally { releaseSession(); busy = false; render(); }
}
async function startNote() {
  if (busy || recording) return;
  busy = true; error = ''; cancelRequested = false; noteFailed = false; fileProgress = 'Finishing recorded audio';
  let startingEntry: Entry | undefined;
  try {
    await reserveSession();
    await ensureModel();
    if (cancelRequested) throw new Error('Recording cancelled before the microphone opened.');
    const entry = startingEntry = makeEntry(`Note ${new Intl.DateTimeFormat('en', { month:'short', day:'numeric', hour:'numeric', minute:'2-digit' }).format(Date.now())}`, 'note');
    const sessionKeepAudio = keepAudio;
    entry.keepAudio = sessionKeepAudio;
    await persist(entry);
    noteAudio = sessionKeepAudio ? new NoteAudioWriter(entry, message => { noteFailed = true; entry.warning = message; showError(message); }) : undefined;
    chunkParts = []; chunkLength = 0; totalSamples = 0; noteQueued = 0; noteQueue = Promise.resolve();
    capture = new MicrophoneCapture();
    await capture.start((audio, rate) => {
      const pcm = resample(audio, rate);
      totalSamples += pcm.length;
      noteAudio?.push(pcm);
      chunkParts.push(pcm); chunkLength += pcm.length;
      let sum = 0; for (const value of pcm) sum += value * value;
      const level = Math.sqrt(sum / pcm.length);
      const meter = document.getElementById('audio-level'); if (meter) meter.style.width = `${Math.min(100, level * 600)}%`;
      // Cut near a pause after 12 s; force a cut at 24 s with context overlap.
      if (chunkLength >= 12 * 16000 && (level < 0.006 || chunkLength >= 24 * 16000)) queueNoteChunk(entry);
      if (noteQueued > 12 && recording) { noteFailed = true; entry.warning = 'Capture stopped because transcription fell behind.'; error = 'Recording stopped because transcription fell behind. Waiting for the queued audio to finish.'; void stopNote(); }
    });
    recording = true; busy = false; recordingStarted = Date.now();
    recordingTimer = setInterval(() => {
      entry.duration = totalSamples / 16000;
      const timer = document.getElementById('record-time'); if (timer) timer.textContent = time((Date.now() - recordingStarted) / 1000);
      const duration = document.getElementById('duration'); if (duration) duration.textContent = time(entry.duration);
    }, 1000);
    persistenceTimer = setInterval(() => { void persist(entry); }, 10000);
    try { wakeLock = await (navigator as any).wakeLock?.request('screen'); } catch { /* Recording still works without a wake lock. */ }
    await persist(entry); render();
  } catch (e) {
    await capture?.stop();
    const message = (e as Error).name === 'NotAllowedError' ? 'Microphone access is blocked. Allow it in your browser and macOS privacy settings, then try again.' : (e as Error).message;
    if (startingEntry?.status === 'recording') { startingEntry.status = 'interrupted'; startingEntry.warning = message; await persist(startingEntry); }
    releaseSession(); busy = false; showError(message);
  }
}
function queueNoteChunk(entry: Entry, final = false) {
  if (chunkLength < 1600) return;
  const audio = joinAudio(chunkParts);
  // Whisper resolves the shared audio by timestamped tokens across requests.
  const overlap = final ? 0 : Math.min(32000, audio.length);
  chunkParts = overlap ? [audio.slice(-overlap)] : []; chunkLength = overlap;
  noteQueued++;
  noteQueue = noteQueue.then(async () => {
    try {
      const result = await rpc('transcribe', { audio, language: entry.language, session: entry.id, final });
      // Rebuild from Whisper tokens and acoustic strides, preserving spoken repetitions.
      entry.segments = result.chunks;
      entry.text = result.text.trim();
      entry.elapsed += result.elapsed;
      await persist(entry);
    } catch (e) { noteFailed = true; entry.warning = `A note chunk could not be transcribed: ${(e as Error).message}`; error = entry.warning; await persist(entry); }
    finally { noteQueued--; render(); }
  });
}
async function stopNote() {
  if (!recording) return;
  const entry = entries.find(e => e.status === 'recording')!;
  recording = false; busy = true; clearInterval(recordingTimer); clearInterval(persistenceTimer);
  try {
    await capture?.stop();
    await wakeLock?.release?.().catch(() => {});
    entry.duration = totalSamples / 16000; entry.status = 'transcribing';
    queueNoteChunk(entry, true); render();
    await noteQueue;
    entry.audio = await noteAudio?.finish();
    entry.status = noteFailed ? 'interrupted' : 'saved';
    if (await persist(entry)) await clearAudioParts(entry.id);
  } catch (e) {
    entry.status = 'interrupted'; entry.warning = (e as Error).message;
    error = entry.warning; await persist(entry);
  } finally { releaseSession(); noteAudio = undefined; busy = false; current = entry; render(); }
}
function exportCurrent() {
  if (!current) return;
  const format = document.querySelector<HTMLSelectElement>('#export-format')!.value;
  const srtTime = (seconds: number) => new Date(Math.round(seconds * 1000)).toISOString().slice(11, 23).replace('.', ',');
  const contents = format === 'json' ? JSON.stringify({ ...current, audio: undefined }, null, 2) : format === 'srt' ? current.segments.map((s, i) => `${i + 1}\n${srtTime(s.timestamp[0])} --> ${srtTime(s.timestamp[1] ?? current!.duration)}\n${s.text.trim()}\n`).join('\n') : current.text;
  const url = URL.createObjectURL(new Blob([contents], { type: format === 'json' ? 'application/json' : 'text/plain;charset=utf-8' }));
  const a = document.createElement('a'); a.href = url; a.download = `${current.title.replace(/[/\\:*?"<>|]/g, '_')}.${format}`; a.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
}
window.addEventListener('beforeunload', event => { if (busy || recording) { event.preventDefault(); } });
window.addEventListener('keydown', event => { if (event.key === 'Escape' && drawer) { drawer = false; render(); } });
// Development-only hooks run the exact production worker and file import path, silently.
if (import.meta.env.DEV) (window as any).whisperdrop = { importFiles, decodeAudio, rpc, ensureModel, getState: () => ({ entries, modelState, model, gpuInfo, busy, recording }), setModel: (id: string) => { model = id; modelState = loadedModel === id ? 'ready' : 'unloaded'; }, replayNote: async (pcm: Float32Array, pieceSeconds = 20) => {
  if (busy || recording) throw new Error('A session is already active.');
  busy = true; noteFailed = false; await ensureModel(); const entry = makeEntry('Silent note replay', 'note');
  chunkParts = []; chunkLength = 0; noteQueued = 0; noteQueue = Promise.resolve();
  for (let offset = 0; offset < pcm.length; offset += pieceSeconds * 16000) { chunkParts.push(pcm.slice(offset, offset + pieceSeconds * 16000)); chunkLength = chunkParts.reduce((s, p) => s + p.length, 0); queueNoteChunk(entry, offset + pieceSeconds * 16000 >= pcm.length); }
  await noteQueue; entry.duration = pcm.length / 16000; entry.status = noteFailed ? 'interrupted' : 'saved'; busy = false; await persist(entry); render(); return entry;
} };
(async () => {
  try {
    entries = await listEntries();
    await recoverWhenIdle(async () => { for (const entry of entries) {
      if (entry.status === 'recording' || entry.status === 'transcribing') {
        entry.status = 'interrupted';
        if (entry.keepAudio && !entry.audio) entry.audio = await recoverNoteAudio(entry.id);
        if (await persist(entry)) await clearAudioParts(entry.id);
      }
    } });
  } catch { error = 'Browser storage is unavailable. Transcripts cannot be saved in this session.'; }
  if (!(navigator as any).gpu) error = 'WebGPU is unavailable here. Use a recent Chrome or Edge browser on a device with a supported GPU.';
  render();
})();
