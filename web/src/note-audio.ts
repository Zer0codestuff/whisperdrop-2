import { joinAudio, pcm16, wavHeader } from './audio';
import { appendAudioPart, readAudioParts, clearAudioParts, type Entry } from './storage';

// Persist small PCM blocks instead of retaining a whole recording in the JS heap.
export class NoteAudioWriter {
  private parts: Float32Array[] = [];
  private samples = 0;
  private index = 0;
  private writes = Promise.resolve();
  private failed = false;
  private pending = 0;
  constructor(private entry: Entry, private onError: (message: string) => void) {}

  push(audio: Float32Array) {
    if (this.failed) return;
    this.parts.push(audio); this.samples += audio.length;
    if (this.samples >= 5 * 16000) this.flush();
  }
  private flush() {
    if (!this.samples || this.failed) return;
    if (this.pending >= 3) {
      this.failed = true; this.parts = []; this.samples = 0;
      this.onError('Browser storage cannot keep up with note audio. The saved portion and transcript are retained.');
      return;
    }
    const blob = new Blob([pcm16(joinAudio(this.parts))]);
    const index = this.index++;
    this.parts = []; this.samples = 0;
    this.pending++;
    this.writes = this.writes.then(() => appendAudioPart(this.entry.id, index, blob)).catch(() => {
      this.failed = true;
      this.onError('Note audio could not be saved. Export your transcript before closing the page.');
    }).finally(() => { this.pending--; });
  }
  async finish() {
    this.flush(); await this.writes;
    return recoverNoteAudio(this.entry.id);
  }
}

export async function recoverNoteAudio(id: string): Promise<Blob | undefined> {
  const parts = await readAudioParts(id);
  if (!parts.length) return;
  const bytes = parts.reduce((sum, part) => sum + part.size, 0);
  return new Blob([wavHeader(bytes / 2), ...parts], { type: 'audio/wav' });
}

export { clearAudioParts };
