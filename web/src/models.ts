export const MODELS = [
  {
    id: 'onnx-community/whisper-large-v3-turbo',
    repository: 'onnx-community/whisper-large-v3-turbo',
    revision: '360ebcde2559d60bb474678be3c1de9ef347d01a',
    name: 'Whisper Turbo',
    detail: 'Compact Q4, recommended',
    size: '564 MB',
    bytes: 563479095,
    dtype: { encoder_model: 'q4f16', decoder_model_merged: 'q4f16' },
    requiresF16: true,
  },
  {
    id: 'onnx-community/whisper-base',
    repository: 'onnx-community/whisper-base',
    revision: '1846881b6b3a3024392c1eea3ad983695bc23925',
    name: 'Whisper Base',
    detail: 'Smaller model for limited GPUs',
    size: '206 MB',
    bytes: 206000000,
    dtype: { encoder_model: 'fp32', decoder_model_merged: 'q4' },
    requiresF16: false,
  },
] as const;

export function modelProfile(id: string) {
  const profile = MODELS.find(candidate => candidate.id === id);
  if (!profile) throw new Error('Choose a supported model in Models & storage.');
  return profile;
}
