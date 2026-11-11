"""Speech models and languages."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class ModelFile:
    name: str
    url: str
    size: int
    sha256: str


@dataclass(frozen=True)
class Model:
    id: str
    name: str
    detail: str
    engine: str  # "parakeet" or "whisper"
    files: tuple[ModelFile, ...]
    languages: frozenset[str] | None = None  # None covers every language
    legacy: bool = False

    @property
    def size(self) -> int:
        return sum(f.size for f in self.files)

    @property
    def size_label(self) -> str:
        return size_label(self.size)

    @property
    def uses_prompt(self) -> bool:
        return self.engine == "whisper"

    @property
    def streams(self) -> bool:
        """Fast enough to show words while you speak."""
        return self.engine == "parakeet"

    def supports(self, language: str) -> bool:
        return language == "auto" or self.languages is None or language in self.languages


def size_label(size: int) -> str:
    if size >= 1_000_000_000:
        return f"{size / 1_000_000_000:.1f} GB"
    return f"{round(size / 1_000_000)} MB"


PARAKEET_LANGUAGES = frozenset({"bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
                                "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk"})

# NVIDIA Parakeet TDT 0.6B v3 exported for sherpa-onnx, int8. The revision is pinned.
_PARAKEET = "https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/resolve/ed5d745623472f97cfc2e6c2916ee248798fc5a8/"
_WHISPER = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"


def _whisper(id: str, name: str, detail: str, filename: str, size: int, sha256: str) -> Model:
    return Model(id, name, detail, "whisper", (ModelFile(filename, _WHISPER + filename, size, sha256),), None, True)


CATALOG: tuple[Model, ...] = (
    Model("parakeet-v3", "Parakeet v3",
          "Recommended. Fast enough to show words while you speak. 25 European languages, detected automatically.",
          "parakeet", (
              ModelFile("tokens.txt", _PARAKEET + "tokens.txt", 93939,
                        "d58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d"),
              ModelFile("decoder.int8.onnx", _PARAKEET + "decoder.int8.onnx", 11845274,
                        "0222a86147299d4dee90edf95b6d13827edb42ad8b7c9cf0b2582f030937c0b5"),
              ModelFile("joiner.int8.onnx", _PARAKEET + "joiner.int8.onnx", 6355277,
                        "cbd02f3696e9944970111fb439d9c3fd365a80374565f13f2b9c7007d253fc98"),
              ModelFile("encoder.int8.onnx", _PARAKEET + "encoder.int8.onnx", 652282294,
                        "1afbe69c1ffdabee94755f42e4daf1d93549131a3da11356bda84fcef0f2c479"),
          ), PARAKEET_LANGUAGES),
    _whisper("tiny", "Whisper Tiny", "Smallest download. For clear, simple speech.", "ggml-tiny-q5_1.bin", 32152673,
             "818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7"),
    _whisper("base", "Whisper Base", "Lightweight for everyday recordings.", "ggml-base-q5_1.bin", 59707625,
             "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898"),
    _whisper("small", "Whisper Small", "More detail, with a modest memory footprint.", "ggml-small-q5_1.bin", 190085487,
             "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb"),
    _whisper("medium", "Whisper Medium", "For difficult recordings. Slower than Turbo.", "ggml-medium-q5_0.bin", 539212467,
             "19fea4b380c3a618ec4723c3eef2eb785ffba0d0538cf43f8f235e7b3b34220f"),
    _whisper("turbo", "Whisper Turbo", "Covers every language. Best for languages Parakeet does not cover.",
             "ggml-large-v3-turbo-q5_0.bin", 574041195,
             "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"),
    _whisper("turbo-q8", "Whisper Turbo Q8", "Higher precision, with a larger download.", "ggml-large-v3-turbo-q8_0.bin",
             874188075, "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1"),
)

DEFAULT_MODEL = "parakeet-v3"
FALLBACK_ORDER = ("turbo", "turbo-q8", "medium", "small", "base", "tiny")


def by_id(model_id: str | None) -> Model:
    for model in CATALOG:
        if model.id == model_id:
            return model
    return CATALOG[0]


def resolved(chosen: Model, language: str, installed: set[str]) -> Model:
    """`chosen`, or the first installed Whisper model that covers `language` when `chosen` does not."""
    if chosen.supports(language):
        return chosen
    for model_id in FALLBACK_ORDER:
        if model_id in installed:
            return by_id(model_id)
    return chosen


LANGUAGES: tuple[tuple[str, str], ...] = (
    ("auto", "Detect automatically"), ("en", "English"), ("it", "Italian"), ("es", "Spanish"), ("fr", "French"),
    ("de", "German"), ("pt", "Portuguese"), ("nl", "Dutch"), ("pl", "Polish"), ("uk", "Ukrainian"), ("ru", "Russian"),
    ("sv", "Swedish"), ("da", "Danish"), ("fi", "Finnish"), ("cs", "Czech"), ("sk", "Slovak"), ("ro", "Romanian"),
    ("hu", "Hungarian"), ("el", "Greek"), ("bg", "Bulgarian"), ("hr", "Croatian"), ("sl", "Slovenian"),
    ("et", "Estonian"), ("lv", "Latvian"), ("lt", "Lithuanian"), ("mt", "Maltese"), ("tr", "Turkish"),
    ("ar", "Arabic"), ("he", "Hebrew"), ("hi", "Hindi"), ("ja", "Japanese"), ("zh", "Chinese"), ("ko", "Korean"),
    ("vi", "Vietnamese"), ("id", "Indonesian"), ("th", "Thai"), ("no", "Norwegian"), ("ca", "Catalan"),
)


def language_name(code: str) -> str:
    for value, name in LANGUAGES:
        if value == code:
            return name
    return code


def initial_language(locale: str | None) -> str:
    code = (locale or "").split("_")[0].split(".")[0].lower()
    return code if any(value == code for value, _ in LANGUAGES[1:]) else "auto"
