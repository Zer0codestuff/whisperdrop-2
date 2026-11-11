"""whisperdrop [FILES…]                   open the app (and transcribe FILES)
whisperdrop --background                 start hidden, for dictation
whisperdrop transcribe FILE… [options]   transcribe without the window and print or save the text
"""

from __future__ import annotations

import argparse
import sys
import threading
import time
from pathlib import Path


def transcribe_command(argv: list[str]) -> int:
    from . import paths
    from .audio import media
    from .core import models
    from .core import transcript as tx
    from .downloads import Downloads
    from .engine.host import ModelHost
    from .jobs import Transcriber
    from .library import Job, Library
    from .settings import Settings

    parser = argparse.ArgumentParser(prog="whisperdrop transcribe",
                                     description="Transcribe audio or video files, or YouTube links, on this computer.")
    parser.add_argument("inputs", nargs="+", help="files or YouTube links")
    parser.add_argument("-f", "--format", choices=("txt", "md", "srt", "vtt", "json"), default="txt")
    parser.add_argument("-o", "--output", help="folder for one output file per input; prints to stdout when omitted")
    parser.add_argument("-l", "--language", help="spoken language code, or auto")
    parser.add_argument("-m", "--model", choices=[m.id for m in models.CATALOG], help="model id")
    parser.add_argument("--data-dir", help="isolated data folder")
    parser.add_argument("--save", action="store_true", help="also add the transcripts to the app's library")
    options = parser.parse_args(argv)
    if options.data_dir:
        paths.set_data_dir(options.data_dir)
    paths.ensure(paths.data_dir(), paths.work_dir())
    settings = Settings()
    downloads = Downloads(lambda f: f(), lambda: None)
    settings.installed = downloads.installed
    if options.language:
        settings._values["spoken_language"] = options.language
    if options.model:
        settings._values["main_model"] = options.model
        settings._values["task_models"] = {}
    settings._values["auto_transcribe"] = False
    model = settings.model_for("files")
    if model.id not in downloads.installed():
        print(f"{model.name} is not downloaded. Open WhisperDrop, Preferences, Models, or run:\n"
              f"  whisperdrop download {model.id}", file=sys.stderr)
        return 2
    library = Library(settings)
    write_transcripts = library.write_transcripts
    if not options.save:
        # Without --save, nothing touches the library: no history entry and no files in the Transcripts folder.
        library.save = lambda: None  # type: ignore[method-assign]
        library.write_transcripts = lambda job: None  # type: ignore[method-assign]
    host = ModelHost(downloads.location)
    transcriber = Transcriber(library, settings, host, lambda f: f(), lambda job_id: None, downloads.installed)
    jobs: list[Job] = []
    for item in options.inputs:
        if media.youtube_url(item):
            done = threading.Event()
            transcriber.add_youtube(item, lambda added, error: (jobs.extend(added), error and print(error, file=sys.stderr), done.set()))
            done.wait()
        elif Path(item).is_file():
            jobs += transcriber.add_files([item])
        else:
            print(f"Skipping {item}: not a file or a YouTube link.", file=sys.stderr)
    failures = 0
    try:
        for job in jobs:
            started = time.monotonic()
            transcriber._transcribe(job)
            if job.status != "completed":
                failures += 1
                print(f"{job.title}: {job.error}", file=sys.stderr)
                continue
            text = library.export(job, options.format)
            print(f"{job.title}: {tx.duration_label(job.duration)} in {time.monotonic() - started:.1f} s with {job.model_name}",
                  file=sys.stderr)
            if options.output:
                folder = Path(options.output)
                folder.mkdir(parents=True, exist_ok=True)
                target = folder / f"{Path(job.title).name}.{options.format}"
                target.write_text(text)
            else:
                sys.stdout.write(text)
            if options.save:
                write_transcripts(job)
                library.save()
    except KeyboardInterrupt:
        transcriber.cancel()
        failures += 1
    finally:
        host.shutdown()
    return 1 if failures else 0


def download_command(argv: list[str]) -> int:
    from . import paths
    from .core import models
    from .downloads import Downloads

    parser = argparse.ArgumentParser(prog="whisperdrop download", description="Download a speech model.")
    parser.add_argument("model", nargs="?", default=models.DEFAULT_MODEL, choices=[m.id for m in models.CATALOG])
    parser.add_argument("--data-dir")
    options = parser.parse_args(argv)
    if options.data_dir:
        paths.set_data_dir(options.data_dir)
    paths.ensure(paths.models_dir())
    model = models.by_id(options.model)
    finished = threading.Event()
    downloads = Downloads(lambda f: f(), lambda: finished.set() if downloads.active is None else
                          print(f"\r{model.name}: {round(downloads.progress * 100)}%", end="", file=sys.stderr))
    if model.id in downloads.installed():
        print(f"{model.name} is already installed.", file=sys.stderr)
        return 0
    downloads.download(model)
    try:
        while downloads.active:
            time.sleep(0.2)
    except KeyboardInterrupt:
        downloads.cancel()
        return 1
    print(file=sys.stderr)
    if downloads.error:
        print(downloads.error, file=sys.stderr)
        return 1
    print(f"{model.name} installed.", file=sys.stderr)
    return 0


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "transcribe":
        return transcribe_command(sys.argv[2:])
    if len(sys.argv) > 1 and sys.argv[1] == "download":
        return download_command(sys.argv[2:])
    if len(sys.argv) > 1 and sys.argv[1] in ("-h", "--help") :
        print(__doc__.strip())
        print("\nApp options: --background, --data-dir DIR, --verify-dictation CLIP.wav")
        return 0
    from .ui.app import main as app_main

    return app_main(sys.argv)


if __name__ == "__main__":
    sys.exit(main())
