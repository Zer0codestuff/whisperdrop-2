const SESSION_LOCK = 'whisperdrop-session';
let release: (() => void) | undefined;

export async function reserveSession() {
  if (!navigator.locks) return;
  await new Promise<void>((resolve, reject) => {
    void navigator.locks.request(SESSION_LOCK, { ifAvailable: true }, async lock => {
      if (!lock) { reject(new Error('A transcription or recording is already running in another WhisperDrop tab.')); return; }
      await new Promise<void>(finish => { release = finish; resolve(); });
    }).catch(reject);
  });
}

export function releaseSession() { release?.(); release = undefined; }

export async function recoverWhenIdle(recover: () => Promise<void>) {
  if (!navigator.locks) { await recover(); return; }
  await navigator.locks.request(SESSION_LOCK, { ifAvailable: true }, async lock => { if (lock) await recover(); });
}
