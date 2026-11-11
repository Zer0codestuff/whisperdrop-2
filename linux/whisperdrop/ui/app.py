"""The GTK application: creates the shared objects once and hands them to the window, the overlay and Preferences."""

from __future__ import annotations

import sys
from pathlib import Path

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, Gio, GLib, Gtk  # noqa: E402

from .. import APP_ID, APP_NAME, VERSION, notes, paths, shortcuts  # noqa: E402
from ..dictation import Dictation  # noqa: E402
from ..downloads import Downloads  # noqa: E402
from ..engine.host import ModelHost  # noqa: E402
from ..jobs import Transcriber  # noqa: E402
from ..library import Library  # noqa: E402
from ..settings import Settings  # noqa: E402


def post(callback) -> None:
    """Runs `callback` on the main thread."""
    def run():
        callback()
        return False
    GLib.idle_add(run)


class Signal:
    """A tiny observer list. The UI connects; models emit on the main thread."""

    def __init__(self):
        self._handlers = []

    def connect(self, handler):
        self._handlers.append(handler)
        return handler

    def disconnect(self, handler):
        if handler in self._handlers:
            self._handlers.remove(handler)

    def emit(self, *args):
        for handler in list(self._handlers):
            handler(*args)


class App(Adw.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.HANDLES_COMMAND_LINE |
                         Gio.ApplicationFlags.HANDLES_OPEN)
        GLib.set_application_name(APP_NAME)
        self.window = None
        self.hud = None
        self.background = False
        self.held = False
        self.library_changed = Signal()   # job id or None
        self.notes_changed = Signal()
        self.dictation_changed = Signal()
        self.host_changed = Signal()
        self.models_changed = Signal()
        self.portal = None
        self.add_main_option("background", 0, GLib.OptionFlags.NONE, GLib.OptionArg.NONE,
                             "Start without opening the window, for dictation", None)
        self.add_main_option("data-dir", 0, GLib.OptionFlags.NONE, GLib.OptionArg.STRING,
                             "Keep every file, saved files included, in this folder", "DIR")
        self.add_main_option("verify-dictation", 0, GLib.OptionFlags.NONE, GLib.OptionArg.STRING,
                             "Dictate a 16 kHz WAV and print the text instead of typing it", "WAV")

    # Startup

    def do_command_line(self, command_line):
        options = command_line.get_options_dict().end().unpack()
        if not self.get_is_remote() and getattr(self, "settings", None) is None:
            if options.get("data-dir"):
                paths.set_data_dir(options["data-dir"])
            self._create()
        files = [f for f in command_line.get_arguments()[1:] if not f.startswith("-")]
        if options.get("verify-dictation"):
            self._verify_dictation(options["verify-dictation"])
            return 0
        if files:
            self.transcriber.add_files([command_line.create_file_for_arg(f).get_path() for f in files])
        if options.get("background") and self.window is None:
            self._hold()
        else:
            self.present()
        return 0

    def do_open(self, files, n_files, hint):
        self.transcriber.add_files([f.get_path() for f in files if f.get_path()])
        self.present()

    def do_startup(self):
        Adw.Application.do_startup(self)
        Adw.StyleManager.get_default().set_color_scheme(Adw.ColorScheme.FORCE_DARK)
        css = Gtk.CssProvider()
        css.load_from_path(str(Path(__file__).with_name("style.css")))
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), css,
                                                  Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        icons = Path(__file__).resolve().parents[2] / "data" / "icons"
        if icons.is_dir():
            Gtk.IconTheme.get_for_display(Gdk.Display.get_default()).add_search_path(str(icons))
        self._actions()

    def _create(self) -> None:
        paths.ensure(paths.data_dir(), paths.models_dir(), paths.work_dir())
        self.settings = Settings()
        self.library = Library(self.settings)
        self.downloads = Downloads(post, self._models_changed)
        self.settings.installed = self.downloads.installed
        self.host = ModelHost(self.downloads.location, lambda: post(lambda: self.host_changed.emit()))
        self.host.residency = self.settings.residency
        self.transcriber = Transcriber(self.library, self.settings, self.host, post,
                                       lambda job_id: self.library_changed.emit(job_id), self.downloads.installed)
        self.recorder = notes.NoteRecorder(self.library, self.settings, self.host, post,
                                           lambda: self.notes_changed.emit(), self._note_saved, self.downloads.installed)
        self.dictation = Dictation(self.settings, self.host, post, self._dictation_changed, self.downloads.installed,
                                   self._dictation_blocked)
        self.settings.observe(self._setting_changed)
        GLib.timeout_add(500, self._tick)
        self._watch_sleep()
        recovered = notes.recover(self.library)
        self._recovered = len(recovered)
        if self.settings.residency == "always":
            self._prewarm()
        self._connect_portal()
        if any(job.status == "queued" and job.kind != "note" for job in self.library.jobs) and self.settings.auto_transcribe:
            self.transcriber.start()

    def _actions(self) -> None:
        def add(name, callback, accels=None, parameter=None):
            action = Gio.SimpleAction.new(name, GLib.VariantType.new(parameter) if parameter else None)
            action.connect("activate", lambda a, p: callback(p) if parameter else callback())
            self.add_action(action)
            if accels:
                self.set_accels_for_action(f"app.{name}", accels)

        add("dictate-press", lambda: self.dictation.press())
        add("dictate-release", lambda: self.dictation.release())
        add("dictate-toggle", lambda: self.dictation.toggle())
        add("dictate-cancel", lambda: self.dictation.cancel())
        add("note-toggle", self._note_toggle)
        add("show", self.present)
        add("preferences", lambda: self.show_preferences(), ["<Control>comma"])
        add("models", lambda: self.show_preferences("models"))
        add("guide", self.show_guide)
        add("about", self.show_about)
        add("quit", self.quit_app, ["<Control>q"])

    def _hold(self) -> None:
        if not self.held:
            self.hold()
            self.held = True

    def present(self) -> None:
        from .window import MainWindow

        if self.window is None:
            self.window = MainWindow(self)
            self.window.connect("close-request", self._on_close)
            if self._recovered:
                self.window.toast(f"{self._recovered} interrupted note{'s' if self._recovered > 1 else ''} recovered.")
                self._recovered = 0
        self.window.present()
        if not self.settings.guide_done:
            GLib.idle_add(lambda: (self.show_guide(), False)[1])

    def _on_close(self, window):
        busy = self.recorder.active or self.transcriber.busy
        if self.settings.run_in_background or busy:
            # Dictation, notes and the queue keep working. The window comes back from the launcher or whisperdrop-ctl.
            self._hold()
            window.set_visible(False)
            if busy:
                self.notify("WhisperDrop is still working", "The window is hidden. Recording and transcription continue.")
            return True
        self.window = None
        return False

    def quit_app(self) -> None:
        if self.recorder.active:
            self.recorder.stop()
            self.notify("Saving the note", "WhisperDrop quits once the note is saved.")
            GLib.timeout_add(500, self._quit_when_saved)
            return
        self._shutdown()

    def _quit_when_saved(self):
        if self.recorder.active:
            return True
        self._shutdown()
        return False

    def _shutdown(self) -> None:
        self.transcriber.cancel()
        self.dictation.cancel()
        self.host.shutdown()
        if self.held:
            self.release()
            self.held = False
        if self.window:
            self.window.destroy()
        self.quit()

    # Callbacks

    def _tick(self):
        self.recorder.tick()
        if self.recorder.state in ("recording", "paused"):
            self.notes_changed.emit()
        return True

    def _models_changed(self) -> None:
        self.models_changed.emit()

    def _setting_changed(self, key: str) -> None:
        if key == "residency":
            self.host.residency = self.settings.residency
            if self.settings.residency == "always":
                self._prewarm()
        if key in ("shortcut",):
            self._connect_portal()

    def _prewarm(self) -> None:
        model = self.settings.model_for("dictation")
        if model.id in self.downloads.installed():
            self.host.prewarm(model)

    def _note_saved(self, job) -> None:
        self.library_changed.emit(job.id)
        if self.window:
            self.window.show_job(job.id)
        if not self.window or not self.window.is_visible():
            self.notify("Note saved", job.title)

    def _note_toggle(self) -> None:
        if self.recorder.active:
            self.recorder.stop()
            return
        self.present()
        self.window.new_note()

    def _dictation_blocked(self) -> str | None:
        if self.recorder.active:
            return "Finish the note before dictating."
        if not self.settings.dictation_enabled:
            return "Dictation is off. Turn it on in Preferences, Dictation."
        return None

    def _dictation_changed(self) -> None:
        from .hud import Hud

        if self.hud is None:
            self.hud = Hud(self)
        self.hud.update()
        self.dictation_changed.emit()

    def _connect_portal(self) -> None:
        if shortcuts.hyprland() or self.portal is not None or not self.settings.dictation_enabled:
            return
        self.portal = shortcuts.PortalShortcut(lambda: post(self.dictation.press), lambda: post(self.dictation.release))
        self.portal.connect(self.settings.shortcut)

    def _watch_sleep(self) -> None:
        """Pauses a recording note before the computer sleeps, including a closed lid. It never resumes alone."""
        try:
            bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
        except GLib.Error:
            return

        def prepare(_bus, _sender, _path, _iface, _signal, params):
            if params.unpack()[0] and self.recorder.state == "recording":
                self.recorder.pause("Recording paused because the computer went to sleep. Resume when you are ready.")

        bus.signal_subscribe("org.freedesktop.login1", "org.freedesktop.login1.Manager", "PrepareForSleep",
                             "/org/freedesktop/login1", None, Gio.DBusSignalFlags.NONE, prepare)
        self._system_bus = bus

    def notify(self, title: str, body: str = "") -> None:
        notification = Gio.Notification.new(title)
        if body:
            notification.set_body(body)
        self.send_notification(None, notification)

    # Windows

    def show_preferences(self, page: str | None = None) -> None:
        from .preferences import Preferences

        self.present()
        dialog = Preferences(self, page)
        dialog.present(self.window)

    def show_guide(self) -> None:
        from .guide import Guide

        if self.window is None:
            self.present()
            return
        Guide(self).present(self.window)

    def show_about(self) -> None:
        about = Adw.AboutDialog(application_name=APP_NAME, version=VERSION, application_icon=APP_ID,
                                developer_name="Gabriele Monni", license_type=Gtk.License.MIT_X11,
                                website="https://github.com/Zer0codestuff/whisperdrop-2",
                                issue_url="https://github.com/Zer0codestuff/whisperdrop-2/issues",
                                comments="Local transcription, notes and dictation. Speech never leaves this computer.")
        about.present(self.window)

    # Verification

    def _verify_dictation(self, wav: str) -> None:
        """Feeds a clip through the real dictation path and prints the result. Nothing is typed."""
        from ..audio.media import decode, load_samples

        target = paths.work_dir() / "verify.wav"
        decode(wav, target)
        self.dictation.replay = load_samples(target)
        self._hold()

        def output(text: str) -> str:
            print(text, flush=True)
            return "verify"

        self.dictation.output = output

        def finish():
            if self.dictation.state == "idle" and self.dictation.recent:
                self._shutdown()
                return False
            if self.dictation.state == "idle" and self.dictation.message and not self.dictation.recent:
                print("FAILED:", self.dictation.message, flush=True)
                self._shutdown()
                return False
            return True

        self.dictation.hands_free = True
        self.dictation.start()
        GLib.timeout_add(200, finish)


def main(argv: list[str] | None = None) -> int:
    app = App()
    return app.run(argv if argv is not None else sys.argv)
