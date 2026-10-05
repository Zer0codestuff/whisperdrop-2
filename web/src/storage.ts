export interface Segment { text: string; timestamp: [number, number | null] }
export interface Entry {
  id: string; title: string; kind: 'file' | 'note'; created: number; text: string;
  segments: Segment[]; duration: number; elapsed: number; model: string; language: string;
  status: 'recording' | 'transcribing' | 'saved' | 'interrupted'; audio?: Blob;
  keepAudio?: boolean; warning?: string;
}
const database = new Promise<IDBDatabase>((resolve, reject) => {
  const request = indexedDB.open('whisperdrop-web', 2);
  request.onupgradeneeded = () => {
    const db = request.result;
    if (!db.objectStoreNames.contains('entries')) db.createObjectStore('entries', { keyPath: 'id' });
    if (!db.objectStoreNames.contains('audioParts')) db.createObjectStore('audioParts', { keyPath: ['entryId', 'index'] });
  };
  request.onsuccess = () => {
    request.result.onversionchange = () => request.result.close();
    resolve(request.result);
  };
  request.onerror = () => reject(request.error);
  request.onblocked = () => reject(new Error('Close other WhisperDrop tabs, then reload to update browser storage.'));
});
export async function saveEntry(entry: Entry) {
  const db = await database;
  return new Promise<void>((resolve, reject) => {
    const tx = db.transaction('entries', 'readwrite'); tx.objectStore('entries').put(entry);
    tx.oncomplete = () => resolve(); tx.onerror = tx.onabort = () => reject(tx.error);
  });
}
export async function listEntries(): Promise<Entry[]> {
  const db = await database;
  return new Promise((resolve, reject) => {
    const request = db.transaction('entries').objectStore('entries').getAll();
    request.onsuccess = () => resolve(request.result.sort((a: Entry, b: Entry) => b.created - a.created));
    request.onerror = () => reject(request.error);
  });
}
export async function deleteEntry(id: string) {
  const db = await database;
  return new Promise<void>((resolve, reject) => {
    const tx = db.transaction(['entries', 'audioParts'], 'readwrite'); tx.objectStore('entries').delete(id);
    tx.objectStore('audioParts').delete(audioRange(id));
    tx.oncomplete = () => resolve(); tx.onerror = tx.onabort = () => reject(tx.error);
  });
}
const audioRange = (id: string) => IDBKeyRange.bound([id, 0], [id, Number.MAX_SAFE_INTEGER]);
export async function appendAudioPart(entryId: string, index: number, audio: Blob) {
  const db = await database;
  return new Promise<void>((resolve, reject) => {
    const tx = db.transaction('audioParts', 'readwrite');
    tx.objectStore('audioParts').put({ entryId, index, audio });
    tx.oncomplete = () => resolve(); tx.onerror = tx.onabort = () => reject(tx.error);
  });
}
export async function readAudioParts(id: string): Promise<Blob[]> {
  const db = await database;
  return new Promise((resolve, reject) => {
    const request = db.transaction('audioParts').objectStore('audioParts').getAll(audioRange(id));
    request.onsuccess = () => resolve(request.result.map(part => part.audio));
    request.onerror = () => reject(request.error);
  });
}
export async function clearAudioParts(id: string) {
  const db = await database;
  return new Promise<void>((resolve, reject) => {
    const tx = db.transaction('audioParts', 'readwrite'); tx.objectStore('audioParts').delete(audioRange(id));
    tx.oncomplete = () => resolve(); tx.onerror = tx.onabort = () => reject(tx.error);
  });
}
