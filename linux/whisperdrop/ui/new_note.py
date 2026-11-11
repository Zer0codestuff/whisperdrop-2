"""Starting a note: what to record, in which language, and whether to keep the audio, explained in one place."""

from __future__ import annotations

from gi.repository import Adw, Gtk

from ..audio import capture
from ..core import models
from ..settings import SOURCES
from .widgets import label

SOURCE_HELP = {
    "microphone": "Your microphone only. For a lecture or a meeting in the room.",
    "system": "Sound from other apps only, such as an online lesson or a video.",
    "both": "Both sides of a call. The transcript labels them You and Others.",
}


class NewNoteDialog(Adw.Dialog):
    def __init__(self, app):
        super().__init__(title="New note", content_width=480)
        self.app = app
        settings = app.settings
        view = Adw.ToolbarView()
        view.add_top_bar(Adw.HeaderBar())
        page = Adw.PreferencesPage()

        group = Adw.PreferencesGroup(title="Record", description=None)
        self.sources = Adw.ToggleGroup(homogeneous=True, margin_bottom=6)
        for key, name, icon in (("microphone", "Microphone", "audio-input-microphone-symbolic"),
                                ("system", "System audio", "audio-speakers-symbolic"),
                                ("both", "Both", "system-users-symbolic")):
            self.sources.add(Adw.Toggle(name=key, label=name, icon_name=icon, tooltip=SOURCES[key]))
        self.sources.set_active_name(settings.note_sources)
        self.sources.connect("notify::active-name", lambda *_: self._sources_changed())
        group.add(self.sources)
        self.source_help = label("", ("dim",), wrap=True)
        self.source_help.set_margin_top(4)
        group.add(self.source_help)
        page.add(group)

        details = Adw.PreferencesGroup()
        self.mics = capture.microphones()
        current = settings.microphone
        if current and not any(m.name == current for m in self.mics):
            # A device chosen elsewhere, such as a monitor, stays selectable instead of silently resetting.
            self.mics.append(capture.Device(current, current, current.endswith(".monitor")))
        self.mic_row = Adw.ComboRow(title="Microphone",
                                    model=Gtk.StringList.new(["Default input"] + [m.description for m in self.mics]))
        index = next((i + 1 for i, m in enumerate(self.mics) if m.name == current), 0)
        self.mic_row.set_selected(index)
        details.add(self.mic_row)

        self.codes = [code for code, _ in models.LANGUAGES]
        names = [name for _, name in models.LANGUAGES]
        app_language = settings.spoken_language
        names = [f"{n} (usual)" if c == app_language else n for c, n in zip(self.codes, names)]
        self.language_row = Adw.ComboRow(title="Language", subtitle="For this note only. The usual language is set in Preferences.",
                                         model=Gtk.StringList.new(names))
        self.language_row.set_enable_search(True)
        self.language_row.set_selected(self.codes.index(app_language) if app_language in self.codes else 0)
        self.language_row.connect("notify::selected", lambda *_: self._check_model())
        details.add(self.language_row)

        self.title_row = Adw.EntryRow(title="Name (optional, you can rename it later)")
        details.add(self.title_row)

        self.keep_row = Adw.SwitchRow(title="Keep the recording",
                                      subtitle="Saved as M4A beside the transcript, about 22 MB per hour. "
                                               "When off, the audio is deleted once the text is saved.",
                                      active=settings.keep_note_audio)
        details.add(self.keep_row)
        page.add(details)

        self.problem = label("", ("notice",), wrap=True)
        self.problem.set_visible(False)
        actions = Adw.PreferencesGroup()
        actions.add(self.problem)
        self.start_button = Gtk.Button(label="Start recording", halign=Gtk.Align.CENTER, margin_top=6)
        self.start_button.add_css_class("suggested-action")
        self.start_button.add_css_class("pill")
        self.start_button.set_size_request(220, -1)
        self.start_button.connect("clicked", lambda *_: self._start())
        actions.add(self.start_button)
        page.add(actions)

        view.set_content(page)
        self.set_child(view)
        self.set_default_widget(self.start_button)
        self._sources_changed()

    def _language(self) -> str:
        return self.codes[self.language_row.get_selected()]

    def _sources_changed(self) -> None:
        source = self.sources.get_active_name() or "both"
        self.source_help.set_text(SOURCE_HELP[source])
        self.mic_row.set_visible(source != "system")
        self._check_model()

    def _check_model(self) -> None:
        app = self.app
        language = self._language()
        model = app.settings.model_for("notes", language)
        problem = None
        if model.id not in app.downloads.installed():
            problem = f"Download {model.name} in Preferences, Models first. It is needed once."
        elif not model.supports(language):
            problem = (f"{model.name} does not transcribe {models.language_name(language)}. "
                       "Download Whisper Turbo in Preferences, Models.")
        elif capture.available():
            problem = capture.available()
        self.problem.set_text(problem or "")
        self.problem.set_visible(bool(problem))
        self.start_button.set_sensitive(problem is None)

    def _start(self) -> None:
        app = self.app
        source = self.sources.get_active_name() or "both"
        selected = self.mic_row.get_selected()
        app.settings.set("note_sources", source)
        app.settings.set("microphone", self.mics[selected - 1].name if selected > 0 else None)
        app.settings.set("keep_note_audio", self.keep_row.get_active())
        error = app.recorder.start(source, self._language(), self.keep_row.get_active(), self.title_row.get_text().strip())
        if error:
            self.problem.set_text(error)
            self.problem.set_visible(True)
            return
        self.close()
        if app.window:
            app.window.show_job(None)
