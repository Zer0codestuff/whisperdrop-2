"""Library, settings, multipart parsing and shortcut configuration, on temporary folders."""

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from whisperdrop import paths, shortcuts  # noqa: E402
from whisperdrop.core import transcript as tx  # noqa: E402
from whisperdrop.engine.host import multipart  # noqa: E402
from whisperdrop.engine.parakeet_server import parse_multipart  # noqa: E402


class Isolated(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.root = Path(self.folder.name)
        paths.set_data_dir(self.root)
        from whisperdrop.settings import Settings
        from whisperdrop.library import Library

        self.settings = Settings()
        self.library = Library(self.settings)

    def tearDown(self):
        paths.set_data_dir(None)
        self.folder.cleanup()


class SettingsTests(Isolated):
    def test_persists_and_notifies(self):
        from whisperdrop.settings import Settings

        seen = []
        self.settings.observe(seen.append)
        self.settings.set("shortcut", "F8")
        self.settings.set("shortcut", "F8")
        self.assertEqual(seen, ["shortcut"])
        self.assertEqual(Settings().shortcut, "F8")

    def test_task_model_follows_main_unless_set(self):
        self.settings.set_task_model("files", "turbo")
        self.assertEqual(self.settings.chosen_model("files").id, "turbo")
        self.settings.set_task_model("files", self.settings.main_model)
        self.assertNotIn("files", self.settings.task_models)

    def test_unknown_keys_in_file_are_ignored(self):
        from whisperdrop.settings import Settings

        self.settings.path.write_text(json.dumps({"bogus": 1, "sounds": False}))
        settings = Settings()
        self.assertFalse(settings.sounds)
        with self.assertRaises(AttributeError):
            settings.bogus  # noqa: B018


class LibraryTests(Isolated):
    def job(self, title="Lezione", kind="file"):
        from whisperdrop.library import Job

        job = Job(kind, title, str(self.root / "source.mp3"), status="completed")
        job.segments = [tx.Segment(0, 0, 1, "Primo."), tx.Segment(1, 1, 2, "Secondo.")]
        return job

    def test_writes_transcripts_named_after_title(self):
        job = self.library.add(self.job())
        self.library.write_transcripts(job)
        folder = Path(job.transcript_folder)
        self.assertEqual(folder.name, "Lezione")
        self.assertEqual(sorted(p.suffix for p in folder.iterdir()), [".md", ".srt", ".txt", ".vtt"])
        self.assertEqual((folder / "Lezione.txt").read_text(), "Primo. Secondo.\n")

    def test_same_titles_get_numbers(self):
        first, second = self.library.add(self.job()), self.library.add(self.job())
        self.library.write_transcripts(first)
        self.library.write_transcripts(second)
        self.assertEqual(Path(second.transcript_folder).name, "Lezione 2")

    def test_rename_moves_note_audio_and_transcripts(self):
        audio = self.library.audio_folder / "Nota"
        audio.mkdir(parents=True)
        (audio / "Nota.m4a").write_bytes(b"x")
        job = self.job("Nota", "note")
        job.source = str(audio)
        job.audio_files = [str(audio / "Nota.m4a")]
        self.library.add(job)
        self.library.write_transcripts(job)
        self.library.rename(job.id, "Analisi / 1")
        self.assertEqual(job.title, "Analisi / 1")
        self.assertTrue((self.library.audio_folder / "Analisi 1" / "Analisi 1.m4a").exists())
        self.assertTrue((self.library.transcripts_folder / "Analisi 1" / "Analisi 1.txt").exists())
        self.assertFalse(audio.exists())
        reloaded = json.loads(self.library.path.read_text())["jobs"][0]
        self.assertEqual(reloaded["title"], "Analisi / 1")

    def test_history_survives_reload_and_requeues_interrupted_jobs(self):
        from whisperdrop.library import Job, Library

        job = Job("file", "In corso", "/x.mp3", status="transcribing")
        self.library.add(job)
        again = Library(self.settings)
        self.assertEqual(again.jobs[0].status, "queued")

    def test_unreadable_history_is_kept_aside(self):
        from whisperdrop.library import Library

        self.library.path.write_text("{not json")
        again = Library(self.settings)
        self.assertEqual(again.jobs, [])
        self.assertIsNotNone(again.load_error)
        self.assertTrue(any(p.name.startswith("history-unreadable") for p in self.root.iterdir()))

    def test_move_library_updates_references(self):
        job = self.library.add(self.job())
        self.library.write_transcripts(job)
        target = self.root / "elsewhere"
        target.mkdir()
        new_root = self.library.move_library(target)
        self.assertTrue(Path(job.transcript_folder).is_relative_to(new_root))
        self.assertTrue(Path(job.transcript_folder, "Lezione.txt").exists())

    def test_exports(self):
        job = self.job()
        for fmt in ("txt", "md", "srt", "vtt", "json"):
            self.assertTrue(self.library.export(job, fmt))

    def test_recover_interrupted_note(self):
        from whisperdrop import notes

        leftover = self.library.audio_folder / ".recording-abc"
        leftover.mkdir(parents=True)
        (leftover / "note.json").write_text(json.dumps({"title": "Fisica", "started": 1_700_000_000, "model": "Parakeet v3"}))
        (leftover / "transcript.json").write_text(json.dumps({"segments": [{"id": 0, "start": 0, "end": 1, "text": "Ciao."}],
                                                              "elapsed": 12}))
        with mock.patch("whisperdrop.notes.media.compress", side_effect=lambda s, d: d.write_bytes(b"m4a")):
            from whisperdrop.audio.capture import WavWriter
            import numpy as np

            writer = WavWriter(leftover / "you.wav")
            writer.append(np.zeros(1600, dtype=np.float32))
            writer.close()
            recovered = notes.recover(self.library)
        self.assertEqual(len(recovered), 1)
        self.assertEqual(recovered[0].title, "Fisica (recovered)")
        self.assertFalse(leftover.exists())
        self.assertTrue(Path(recovered[0].audio_files[0]).exists())


class MultipartTests(unittest.TestCase):
    def test_client_and_server_agree(self):
        body, content_type = multipart(b"RIFFdata", {"language": "it", "prompt": "Ciao, mondo"})
        fields, files = parse_multipart(body, content_type)
        self.assertEqual(files["file"], b"RIFFdata")
        self.assertEqual(fields, {"language": "it", "prompt": "Ciao, mondo"})


class ShortcutTests(unittest.TestCase):
    def test_snippets(self):
        lua = shortcuts.hypr_snippet("super + d", True, "ctl")
        self.assertIn('hl.bind("SUPER + D", hl.dsp.exec_cmd("ctl dictate press")', lua)
        self.assertIn("release = true", lua)
        legacy = shortcuts.hypr_snippet("F9", False, "ctl")
        self.assertIn("bind = , F9, exec, ctl dictate press", legacy)
        self.assertIn("bindr = , F9, exec, ctl dictate release", legacy)

    def test_install_replace_and_remove_block_in_config(self):
        with tempfile.TemporaryDirectory() as home:
            hypr = Path(home) / "hypr"
            hypr.mkdir()
            (hypr / "hyprland.lua").write_text("-- main\n")
            bindings = hypr / "bindings.lua"
            original = "-- my bindings\nhl.bind(\"SUPER + Q\", hl.dsp.exec_cmd(\"kitty\"))\n"
            bindings.write_text(original)
            with mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": home}):
                shortcuts.install_hypr("F9")
                self.assertEqual(shortcuts.installed_key(bindings), "F9")
                shortcuts.install_hypr("F8")
                text = bindings.read_text()
                self.assertEqual(text.count(shortcuts.BEGIN), 1)
                self.assertEqual(shortcuts.installed_key(bindings), "F8")
                self.assertEqual((hypr / "bindings.lua.whisperdrop-backup").read_text().count("SUPER + Q"), 1)
                shortcuts.remove_hypr()
                self.assertEqual(bindings.read_text(), original)
                self.assertIsNone(shortcuts.installed_key(bindings))


if __name__ == "__main__":
    unittest.main()
