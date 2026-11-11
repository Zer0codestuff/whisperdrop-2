"""Core rules, mirrored from the Mac app's WhisperDropCore tests where they exist."""

import json
import sys
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from whisperdrop.core import SAMPLE_RATE, cleanup, models  # noqa: E402
from whisperdrop.core import transcript as tx  # noqa: E402
from whisperdrop.core.audio import (PauseChunker, RollingAudio, SentenceParagraphs, block_rms, read_wav,  # noqa: E402
                                    wav_bytes, windows)
from whisperdrop.core.livetext import LiveText, edit_between  # noqa: E402

W = tx.Word


def words(text: str, start: float = 0.0, step: float = 0.4) -> list[tx.Word]:
    out = []
    for i, token in enumerate(text.split()):
        out.append(W(start + i * step, start + i * step + step * 0.8, " " + token))
    return out


class TranscriptTests(unittest.TestCase):
    def test_time_labels(self):
        self.assertEqual(tx.time_label(65), "01:05")
        self.assertEqual(tx.time_label(3725), "1:02:05")
        self.assertEqual(tx.duration_label(42), "42 s")
        self.assertEqual(tx.duration_label(187), "3 min 7 s")
        self.assertEqual(tx.duration_label(3 * 3600 + 120), "3 h 02 min")

    def test_ends_sentence(self):
        self.assertTrue(tx.ends_sentence("Fine."))
        self.assertTrue(tx.ends_sentence("Davvero?”"))
        self.assertFalse(tx.ends_sentence("e poi.."))
        self.assertFalse(tx.ends_sentence("virgola,"))

    def test_parse_server_joins_word_pieces_and_shifts(self):
        data = {"language": "en", "segments": [{"start": 0.0, "end": 1.0, "text": " Hello world",
                                                 "words": [{"word": " Hel", "start": 0.0, "end": 0.2},
                                                           {"word": "lo", "start": 0.2, "end": 0.4},
                                                           {"word": " world", "start": 0.5, "end": 0.9}]}]}
        result = tx.parse_server(data, offset=10, speaker="you")
        self.assertEqual([w.text for w in result.timed_words], [" Hello", " world"])
        self.assertAlmostEqual(result.timed_words[0].end, 10.4)
        self.assertEqual(result.segments[0].speaker, "you")

    def test_parse_server_without_segments(self):
        result = tx.parse_server(json.dumps({"text": " Ciao a tutti"}))
        self.assertEqual(result.text, "Ciao a tutti")

    def test_paragraphs_group_until_pause_and_speaker_change(self):
        segments = [tx.Segment(0, 0, 2, "Prima frase."), tx.Segment(1, 2.5, 4, "Seconda frase."),
                    tx.Segment(2, 9, 10, "Dopo una pausa."), tx.Segment(3, 10, 11, "Altro.", "others")]
        result = tx.paragraphs(segments)
        self.assertEqual([p.text for p in result], ["Prima frase. Seconda frase.", "Dopo una pausa.", "Altro."])
        self.assertEqual(segments[0].text, "Prima frase.", "inputs are not modified")
        self.assertEqual(len(tx.paragraphs(segments, each_sentence=True)), 4)

    def test_labeled_text(self):
        segments = [tx.Segment(0, 0, 1, "Ciao.", "you"), tx.Segment(1, 1, 2, "Buongiorno.", "others"),
                    tx.Segment(2, 6, 7, "Come va?", "others")]
        self.assertEqual(tx.labeled_text(segments), "You: Ciao.\n\nOthers: Buongiorno.\n\nCome va?")

    def test_subtitles(self):
        segments = [tx.Segment(0, 1.5, 3.25, "Hello.", "you")]
        self.assertEqual(tx.subtitles(segments, vtt=False), "1\n00:00:01,500 --> 00:00:03,250\nHello.\n")
        self.assertIn("<v You>Hello.", tx.subtitles(segments, vtt=True))
        self.assertTrue(tx.subtitles(segments, vtt=True).startswith("WEBVTT"))

    def test_markdown_and_json(self):
        segments = [tx.Segment(0, 61, 62, "Testo.", "others")]
        md = tx.markdown("Lezione", segments, details=["Oggi", ""])
        self.assertIn("# Lezione", md)
        self.assertIn("`01:01` **Others** Testo.", md)
        payload = json.loads(tx.to_json("Lezione", segments, "it", "Parakeet v3", 62))
        self.assertEqual(payload["segments"][0]["speaker"], "others")

    def test_search_ignores_case_and_accents(self):
        segments = [tx.Segment(0, 0, 1, "Perché è così"), tx.Segment(1, 1, 2, "niente")]
        self.assertEqual(tx.search(segments, "perche COSI"), [0])
        self.assertEqual(tx.search(segments, ""), [])

    def test_segment_round_trip(self):
        segment = tx.Segment(3, 1.0, 2.0, "Ciao", "you", [W(1.0, 1.5, " Ciao")])
        self.assertEqual(tx.Segment.from_dict(segment.to_dict()), segment)


class CleanupTests(unittest.TestCase):
    def test_removes_silence_hallucinations_and_annotations(self):
        segments = [tx.Segment(0, 0, 1, "Thank you."), tx.Segment(1, 1, 2, "[Music]"),
                    tx.Segment(2, 2, 3, "Sottotitoli a cura di QTSS"), tx.Segment(3, 3, 4, "La lezione inizia (applause) ora.")]
        self.assertEqual([s.text for s in cleanup.clean(segments)], ["La lezione inizia ora."])

    def test_keeps_real_thank_you_when_asked(self):
        self.assertEqual(len(cleanup.clean([tx.Segment(0, 0, 1, "Thank you.")], preserve_short_closings=True)), 1)

    def test_drops_neighbor_repeats_and_loops(self):
        segments = [tx.Segment(0, 0, 1, "Oggi parliamo di algebra."), tx.Segment(1, 1, 2, "Oggi parliamo di algebra"),
                    tx.Segment(2, 2, 3, "no no no no no no")]
        self.assertEqual([s.text for s in cleanup.clean(segments)], ["Oggi parliamo di algebra."])

    def test_keeps_ordinary_grazie(self):
        self.assertEqual(len(cleanup.clean([tx.Segment(0, 0, 1, "Grazie.")])), 1)

    def test_dictation_lowercases_pause_capital(self):
        result = tx.ServerTranscription([tx.Segment(0, 0, 1, "I went to"), tx.Segment(1, 1, 2, "The store.")], "en")
        self.assertEqual(cleanup.dictation_text(result), "I went to the store.")

    def test_dictation_keeps_names_and_german(self):
        result = tx.ServerTranscription([tx.Segment(0, 0, 1, "Ho parlato con"), tx.Segment(1, 1, 2, "Gabriele.")], "it")
        self.assertEqual(cleanup.dictation_text(result, vocabulary="Gabriele"), "Ho parlato con Gabriele.")
        german = tx.ServerTranscription([tx.Segment(0, 0, 1, "Ich sehe"), tx.Segment(1, 1, 2, "Haus.")], "de")
        self.assertEqual(cleanup.dictation_text(german), "Ich sehe Haus.")

    def test_dictation_drops_credit_lines(self):
        result = tx.ServerTranscription([tx.Segment(0, 0, 1, "Subtitles by the Amara.org community")], "en")
        self.assertIsNone(cleanup.dictation_text(result))

    def test_repetition(self):
        loop = " ".join(["the cat sat down"] * 8)
        self.assertGreater(cleanup.repetition_score(loop), 0)
        self.assertEqual(cleanup.repetition_score("a normal sentence " * 2), 0)
        self.assertTrue(cleanup.dictation_loops("ciao ciao ciao ciao ciao"))
        self.assertTrue(cleanup.dictation_prefers("I went home", "I went home home home home home"))

    def test_merge_drops_echo(self):
        you = [tx.Segment(0, 0, 3, "We will meet on Monday at ten", "you")]
        others = [tx.Segment(1, 0.2, 3.1, "We will meet on Monday at ten.", "others"),
                  tx.Segment(2, 4, 5, "Great.", "others")]
        merged = cleanup.merge(you, others)
        self.assertEqual([s.speaker for s in merged], ["others", "others"])
        self.assertEqual([s.id for s in merged], [0, 1])


class LiveTextTests(unittest.TestCase):
    def test_settles_words_followed_by_six_seconds(self):
        live = LiveText()
        heard = words("uno due tre quattro cinque sei sette otto nove dieci", step=1.0)
        live.accept(heard, (0.0, 10.0))
        self.assertEqual(live.settled_text, "uno due tre quattro")
        self.assertTrue(live.text.endswith("dieci"))
        self.assertGreater(live.settled_until, 3.8)

    def test_window_starts_ten_seconds_before_boundary_and_caps_at_thirty(self):
        live = LiveText()
        live.accept(words(" ".join(f"w{i}" for i in range(40)), step=1.0), (0.0, 40.0))
        span = live.window(0.0, 100.0)
        self.assertAlmostEqual(span[0], live.settled_until - 10.0)
        self.assertAlmostEqual(span[1] - span[0], 30.0)

    def test_refound_boundary_does_not_repeat_or_drop(self):
        live = LiveText()
        first = words("questa è una prova di testo che continua ancora molto", step=1.0)
        live.accept(first, (0.0, 11.0))
        settled = live.settled_text
        # The next request re-hears the same words with slightly moved times.
        again = [W(w.start + 0.05, w.end + 0.05, w.text) for w in first] + words("e finisce qui", start=11.0, step=1.0)
        live.accept(again, (0.0, 20.0))
        text = live.settled_text
        self.assertTrue(text.startswith(settled))
        self.assertEqual(text.split().count("prova"), 1)

    def test_silence_moves_boundary_and_final_settles_everything(self):
        live = LiveText()
        live.accept([], (0.0, 12.0))
        self.assertAlmostEqual(live.settled_until, 6.0)
        live.accept(words("ultima frase", start=6.5), (0.0, 8.0), final=True)
        self.assertEqual(live.settled_text, "ultima frase")
        self.assertEqual(live.pending, [])

    def test_take_settled_hands_out_each_word_once(self):
        live = LiveText()
        live.accept(words("a b c d e f g h i j k l m n o p", step=1.0), (0.0, 16.0))
        first = live.take_settled()
        self.assertEqual(live.take_settled(), [])
        self.assertLessEqual(len(live.settled), 3)
        self.assertTrue(first)

    def test_edit_between(self):
        edit = edit_between("ciao a tutti", "ciao amici")
        self.assertEqual((edit.delete, edit.insert), (6, "mici"))


class AudioTests(unittest.TestCase):
    def test_wav_round_trip(self):
        samples = (np.sin(np.linspace(0, 100, 16000)) * 0.5).astype(np.float32)
        decoded, rate = read_wav(wav_bytes(samples))
        self.assertEqual(rate, SAMPLE_RATE)
        self.assertLess(float(np.max(np.abs(decoded - samples))), 1e-3)

    def test_short_audio_is_one_window(self):
        self.assertEqual(windows(np.zeros(SAMPLE_RATE * 20, dtype=np.float32)), [(0, SAMPLE_RATE * 20)])

    def test_long_audio_cuts_in_the_quiet_part_of_the_band(self):
        loud = np.full(SAMPLE_RATE * 90, 0.2, dtype=np.float32)
        loud[SAMPLE_RATE * 27:SAMPLE_RATE * 28] = 0.0  # a one-second pause at 27 s
        spans = windows(loud)
        self.assertEqual(spans[0][0], 0)
        self.assertTrue(27 * SAMPLE_RATE <= spans[0][1] <= 28 * SAMPLE_RATE)
        for (a, b), (c, d) in zip(spans, spans[1:]):
            self.assertEqual(b, c)
        self.assertEqual(spans[-1][1], loud.size)
        self.assertTrue(all((b - a) <= 35 * SAMPLE_RATE for a, b in spans))

    def test_block_rms_pads_last_block(self):
        self.assertEqual(block_rms(np.ones(801, dtype=np.float32)).size, 2)

    def test_rolling_audio_discards_old_samples(self):
        rolling = RollingAudio()
        rolling.append(np.arange(SAMPLE_RATE * 4, dtype=np.float32))
        rolling.discard(2.0)
        self.assertAlmostEqual(rolling.start, 2.0)
        self.assertAlmostEqual(rolling.end, 4.0)
        start, piece = rolling.audio(1.0, 3.0)
        self.assertAlmostEqual(start, 2.0)
        self.assertEqual(piece.size, SAMPLE_RATE)

    def test_sentence_paragraphs(self):
        paragraphs = SentenceParagraphs("you")
        paragraphs.append(words("Prima frase. Seconda"))
        self.assertEqual([s.text for s in paragraphs.segments], ["Prima frase.", "Seconda"])
        paragraphs.append(words("parte."))
        self.assertEqual(len(paragraphs.closed), 2)

    def test_sentence_reopens_when_next_word_is_lowercase(self):
        paragraphs = SentenceParagraphs()
        paragraphs.append(words("Visitate il sito LibriVox."))
        paragraphs.append(words("org. Registrazione di Filippo."))
        self.assertEqual([s.text for s in paragraphs.segments],
                         ["Visitate il sito LibriVox. org.", "Registrazione di Filippo."])

    def test_pause_chunker_cuts_at_pause_after_eight_seconds(self):
        chunker = PauseChunker()
        audio = np.full(SAMPLE_RATE * 12, 0.2, dtype=np.float32)
        audio[SAMPLE_RATE * 9:SAMPLE_RATE * 10] = 0.0
        chunks = chunker.append(audio)
        self.assertEqual(len(chunks), 1)
        self.assertTrue(9.0 <= chunks[0][1].size / SAMPLE_RATE <= 10.0)
        tail = chunker.flush()
        self.assertAlmostEqual(chunks[0][1].size / SAMPLE_RATE + tail[1].size / SAMPLE_RATE, 12.0)


class ModelTests(unittest.TestCase):
    def test_parakeet_falls_back_to_installed_whisper_for_other_languages(self):
        parakeet = models.by_id("parakeet-v3")
        self.assertIs(models.resolved(parakeet, "it", {"turbo"}), parakeet)
        self.assertEqual(models.resolved(parakeet, "ja", {"base", "turbo"}).id, "turbo")
        self.assertIs(models.resolved(parakeet, "ja", set()), parakeet)

    def test_catalog_hashes_and_sizes(self):
        for model in models.CATALOG:
            for file in model.files:
                self.assertEqual(len(file.sha256), 64)
                self.assertGreater(file.size, 0)
                self.assertTrue(file.url.startswith("https://huggingface.co/"))

    def test_initial_language(self):
        self.assertEqual(models.initial_language("it_IT.UTF-8"), "it")
        self.assertEqual(models.initial_language("xx_YY"), "auto")


if __name__ == "__main__":
    unittest.main()
