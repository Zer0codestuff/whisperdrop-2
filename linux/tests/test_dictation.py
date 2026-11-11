"""Dictation press and release semantics, with a fake model and a replayed clip instead of the microphone."""

import sys
import time
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from whisperdrop.core import transcript as tx  # noqa: E402
from whisperdrop.dictation import Dictation  # noqa: E402


class FakeSettings:
    dictation_mode = "hold-or-tap"
    spoken_language = "it"
    dictation_live_words = False
    vocabulary = ""
    insert_method = "clipboard"
    microphone = None

    def model_for(self, task):
        from whisperdrop.core import models
        return models.by_id("parakeet-v3")


class FakeHost:
    def __init__(self, text="Ciao a tutti."):
        self.text = text
        self.calls = 0

    def prewarm(self, model):
        pass

    def transcribe(self, samples, model, language, **kwargs):
        self.calls += 1
        return tx.ServerTranscription([tx.Segment(0, 0, 1, self.text)], language)


def speech(seconds=2.0):
    t = np.arange(int(16000 * seconds)) / 16000
    return (0.2 * np.sin(2 * np.pi * 220 * t)).astype(np.float32)


class DictationTests(unittest.TestCase):
    def make(self, clip):
        self.typed = []
        self.host = FakeHost()
        dictation = Dictation(FakeSettings(), self.host, lambda f: f(), lambda: None, lambda: {"parakeet-v3"})
        dictation.replay = clip
        dictation.output = lambda text: (self.typed.append(text), "test")[1]
        return dictation

    def wait_idle(self, dictation, limit=5.0):
        end = time.time() + limit
        while dictation.state != "idle" and time.time() < end:
            time.sleep(0.05)

    def test_hold_and_release_inserts_text(self):
        dictation = self.make(speech(3))
        dictation.press()
        self.assertEqual(dictation.state, "listening")
        time.sleep(0.6)
        dictation.release()
        self.assertIn(dictation.state, ("transcribing", "idle"))
        self.wait_idle(dictation)
        self.assertEqual(self.typed, ["Ciao a tutti."])
        self.assertEqual(dictation.recent, ["Ciao a tutti."])

    def test_quick_tap_switches_to_hands_free_and_next_press_stops(self):
        dictation = self.make(speech(5))
        dictation.press()
        dictation.release()
        self.assertTrue(dictation.hands_free)
        self.assertEqual(dictation.state, "listening")
        time.sleep(0.5)
        dictation.press()
        self.wait_idle(dictation)
        self.assertEqual(len(self.typed), 1)

    def test_silence_types_nothing(self):
        dictation = self.make(np.zeros(16000 * 2, dtype=np.float32))
        dictation.press()
        time.sleep(0.6)
        dictation.release()
        self.wait_idle(dictation)
        self.assertEqual(self.typed, [])
        self.assertEqual(self.host.calls, 0)
        self.assertEqual(dictation.message, "No speech was heard.")

    def test_cancel_discards(self):
        dictation = self.make(speech(3))
        dictation.press()
        time.sleep(0.4)
        dictation.cancel()
        self.assertEqual(dictation.state, "idle")
        time.sleep(0.3)
        self.assertEqual(self.typed, [])

    def test_blocked_start_explains_why(self):
        dictation = self.make(speech(1))
        dictation.can_start = lambda: "Finish the note before dictating."
        dictation.press()
        self.assertEqual(dictation.state, "idle")
        self.assertEqual(dictation.message, "Finish the note before dictating.")


if __name__ == "__main__":
    unittest.main()
