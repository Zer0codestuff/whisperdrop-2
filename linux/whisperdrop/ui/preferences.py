"""Preferences: General, Models, Dictation and Notes. Every setting says what it changes."""

from __future__ import annotations

from pathlib import Path

from gi.repository import Adw, Gdk, Gio, GLib, Gtk

from .. import insert, shortcuts
from ..audio import capture
from ..core import models
from ..engine.host import RESIDENCY_LABELS
from ..settings import INSERT_METHODS, MODES, SOURCES, TASKS
from .widgets import label


def combo(title: str, subtitle: str, options: dict[str, str], current: str, on_change) -> Adw.ComboRow:
    keys = list(options)
    row = Adw.ComboRow(title=title, subtitle=subtitle, model=Gtk.StringList.new(list(options.values())))
    row.set_selected(keys.index(current) if current in keys else 0)
    row.connect("notify::selected", lambda r, _p: on_change(keys[r.get_selected()]))
    return row


def switch(title: str, subtitle: str, active: bool, on_change) -> Adw.SwitchRow:
    row = Adw.SwitchRow(title=title, subtitle=subtitle, active=active)
    row.connect("notify::active", lambda r, _p: on_change(r.get_active()))
    return row


class Preferences(Adw.PreferencesDialog):
    def __init__(self, app, page: str | None = None):
        super().__init__(title="Preferences", search_enabled=True)
        self.app = app
        self.settings = app.settings
        self.add(self._general())
        self.models_page = self._models()
        self.add(self.models_page)
        self.add(self._dictation())
        self.add(self._notes())
        if page:
            self.set_visible_page_name(page)
        self._models_handler = app.models_changed.connect(self._refresh_models)
        self._host_handler = app.host_changed.connect(self._refresh_status)
        self.connect("closed", lambda *_: (app.models_changed.disconnect(self._models_handler),
                                           app.host_changed.disconnect(self._host_handler)))

    def _set(self, key):
        return lambda value: self.settings.set(key, value)

    # General

    def _general(self) -> Adw.PreferencesPage:
        page = Adw.PreferencesPage(title="General", icon_name="preferences-system-symbolic", name="general")
        speech = Adw.PreferencesGroup(title="Speech")
        codes = [c for c, _ in models.LANGUAGES]
        language = Adw.ComboRow(title="Spoken language",
                                subtitle="Used for files, dictation and notes. Automatic detection can pick the wrong "
                                         "language for short or mixed speech.",
                                model=Gtk.StringList.new([n for _, n in models.LANGUAGES]), enable_search=True)
        language.set_selected(codes.index(self.settings.spoken_language) if self.settings.spoken_language in codes else 0)
        language.connect("notify::selected", lambda r, _p: self.settings.set("spoken_language", codes[r.get_selected()]))
        speech.add(language)
        speech.add(switch("Boost quiet audio", "Raises quiet speech for the model when the background is calm. "
                          "Saved recordings are never changed.", self.settings.boost_quiet_audio, self._set("boost_quiet_audio")))
        page.add(speech)

        files = Adw.PreferencesGroup(title="Files")
        files.add(switch("Start transcribing right away", "Added files and links begin at once. When off, they wait "
                         "until you press Transcribe.", self.settings.auto_transcribe, self._set("auto_transcribe")))
        self.folder_row = Adw.ActionRow(title="Saved files", subtitle=str(self.app.library.root))
        self.folder_row.set_subtitle_selectable(True)
        show = Gtk.Button(label="Open", valign=Gtk.Align.CENTER)
        show.connect("clicked", lambda *_: self._open_folder())
        change = Gtk.Button(label="Move…", valign=Gtk.Align.CENTER, tooltip_text="Move Audio and Transcripts to another folder")
        change.connect("clicked", lambda *_: self._move_library())
        self.folder_row.add_suffix(show)
        self.folder_row.add_suffix(change)
        files.add(self.folder_row)
        page.add(files)

        system = Adw.PreferencesGroup(title="Running in the background")
        system.add(switch("Keep running when the window closes", "Dictation keeps working. Open the window again "
                          "from your app launcher.", self.settings.run_in_background, self._set("run_in_background")))
        autostart = Path(GLib.get_user_config_dir()) / "autostart" / "io.github.zer0codestuff.WhisperDrop.desktop"
        system.add(switch("Start at login", "Starts hidden, so dictation is ready after you sign in.",
                          autostart.exists(), lambda on: self._autostart(autostart, on)))
        page.add(system)

        help_group = Adw.PreferencesGroup()
        guide = Adw.ButtonRow(title="Show the guide again", start_icon_name="help-about-symbolic")
        guide.connect("activated", lambda *_: (self.close(), self.app.show_guide()))
        help_group.add(guide)
        page.add(help_group)
        return page

    def _open_folder(self) -> None:
        folder = self.app.library.root
        folder.mkdir(parents=True, exist_ok=True)
        Gtk.FileLauncher.new(Gio.File.new_for_path(str(folder))).launch(self.app.window, None, None)

    def _move_library(self) -> None:
        app = self.app
        if app.recorder.active or app.transcriber.busy:
            self.add_toast(Adw.Toast(title="Wait until recording and transcription finish."))
            return
        dialog = Gtk.FileDialog(title="Choose where to keep the WhisperDrop folder")

        def chosen(d, result):
            try:
                folder = d.select_folder_finish(result)
            except GLib.Error:
                return
            try:
                root = app.library.move_library(Path(folder.get_path()))
                self.folder_row.set_subtitle(str(root))
                self.add_toast(Adw.Toast(title="Saved files moved."))
                app.library_changed.emit(None)
            except (OSError, ValueError) as error:
                self.add_toast(Adw.Toast(title=GLib.markup_escape_text(str(error)), timeout=6))

        dialog.select_folder(app.window, None, chosen)

    def _autostart(self, path: Path, on: bool) -> None:
        if on:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("[Desktop Entry]\nType=Application\nName=WhisperDrop\nExec=whisperdrop --background\n"
                            "Icon=io.github.zer0codestuff.WhisperDrop\nX-GNOME-Autostart-enabled=true\nNoDisplay=true\n")
        else:
            path.unlink(missing_ok=True)

    # Models

    def _models(self) -> Adw.PreferencesPage:
        page = Adw.PreferencesPage(title="Models", icon_name="drive-harddisk-symbolic", name="models")
        status = Adw.PreferencesGroup(title="Memory")
        self.status_row = Adw.ActionRow(title="", subtitle="")
        self.load_button = Gtk.Button(valign=Gtk.Align.CENTER)
        self.load_button.connect("clicked", lambda *_: self._load_or_unload())
        self.status_row.add_suffix(self.load_button)
        status.add(self.status_row)
        status.add(combo("Unload the model", "Frees memory when idle. Keep model ready makes dictation instant.",
                         RESIDENCY_LABELS, self.settings.residency, self._set("residency")))
        page.add(status)

        self.recommended = Adw.PreferencesGroup(title="Speech model",
                                                description="One model serves dictation, notes and files. Downloads are "
                                                            "checked before they are installed.")
        page.add(self.recommended)
        self.legacy = Adw.PreferencesGroup(title="Whisper (more languages)",
                                           description="For languages Parakeet does not cover, or to try a different model. "
                                                       "Uses the graphics card through Vulkan when available.")
        page.add(self.legacy)
        self.tasks = Adw.PreferencesGroup(title="Advanced",
                                          description="Give a task its own model. Switching between two models reloads "
                                                      "the speech model, which takes a few seconds.")
        page.add(self.tasks)
        self.model_rows: dict[str, Adw.ActionRow] = {}
        self.task_rows: list[Adw.ComboRow] = []
        self._refresh_models()
        return page

    def _refresh_status(self) -> None:
        host = self.app.host
        model = self.settings.model_for("dictation")
        if host.state in ("ready", "busy") and host.loaded:
            title, detail, action = "Ready", f"{host.loaded.name} is in memory.", "Unload now"
        elif host.state == "loading":
            title, detail, action = "Loading", f"Starting {host.loaded.name if host.loaded else model.name}.", "Unload now"
        elif host.state == "failed":
            title, detail, action = "Stopped", host.message, "Load now"
        else:
            title, detail, action = "Not loaded", "Loads on the first dictation, note or file.", "Load now"
        self.status_row.set_title(title)
        self.status_row.set_subtitle(GLib.markup_escape_text(detail or ""))
        self.load_button.set_label(action)
        self.load_button.set_sensitive(model.id in self.app.downloads.installed() and host.state != "busy")

    def _load_or_unload(self) -> None:
        host = self.app.host
        if host.state in ("ready", "loading"):
            host.unload()
        else:
            host.prewarm(self.settings.model_for("dictation"))

    def _refresh_models(self) -> None:
        downloads = self.app.downloads
        installed = downloads.installed()
        for model in models.CATALOG:
            group = self.legacy if model.legacy else self.recommended
            row = self.model_rows.get(model.id)
            if row is None:
                row = Adw.ActionRow(title=model.name)
                row.suffix = Gtk.Box(spacing=8, valign=Gtk.Align.CENTER)
                row.add_suffix(row.suffix)
                row.check = Gtk.CheckButton(valign=Gtk.Align.CENTER)
                if self.model_rows:
                    row.check.set_group(next(iter(self.model_rows.values())).check)
                row.check.connect("toggled", lambda b, m=model: b.get_active() and self._use(m))
                row.add_prefix(row.check)
                row.set_activatable_widget(row.check)
                group.add(row)
                self.model_rows[model.id] = row
            row.set_subtitle(f"{model.detail} {model.size_label}.")
            is_installed = model.id in installed
            row.check.set_sensitive(is_installed)
            if self.settings.main_model == model.id and not row.check.get_active():
                row.check.set_active(True)
            child = row.suffix.get_first_child()
            while child:
                row.suffix.remove(child)
                child = row.suffix.get_first_child()
            if downloads.active == model.id:
                bar = Gtk.ProgressBar(fraction=downloads.progress, width_request=120, valign=Gtk.Align.CENTER)
                row.suffix.append(bar)
                cancel = Gtk.Button(label="Cancel")
                cancel.connect("clicked", lambda *_: downloads.cancel())
                row.suffix.append(cancel)
            elif is_installed:
                if self.settings.main_model == model.id:
                    row.suffix.append(label("In use", ("green",)))
                delete = Gtk.Button(icon_name="user-trash-symbolic", tooltip_text=f"Delete {model.name}")
                delete.add_css_class("flat")
                delete.connect("clicked", lambda *_, m=model: self._delete(m))
                delete.set_sensitive(self.app.host.state != "busy")
                row.suffix.append(delete)
            else:
                get = Gtk.Button(label="Download")
                get.set_sensitive(downloads.active is None)
                get.connect("clicked", lambda *_, m=model: downloads.download(m))
                row.suffix.append(get)
            if model.engine == "whisper" and not self._whisper_ready():
                row.set_subtitle(f"{model.detail} {model.size_label}. Needs whisper-server: run install.sh --with-whisper.")
        if downloads.error:
            self.add_toast(Adw.Toast(title=GLib.markup_escape_text(downloads.error), timeout=6))
            downloads.error = None
        for row in self.task_rows:
            self.tasks.remove(row)
        self.task_rows = []
        options = {"": f"Main model ({self.settings.model.name})"}
        options.update({m.id: m.name for m in models.CATALOG if m.id in installed and m.id != self.settings.main_model})
        for task, name in TASKS.items():
            current = self.settings.task_models.get(task, "")
            if current and current not in options:
                options[current] = f"{models.by_id(current).name} (not downloaded)"
            row = combo(name, "", options, current, lambda value, task=task: self.settings.set_task_model(task, value or None))
            self.tasks.add(row)
            self.task_rows.append(row)
        self._refresh_status()

    def _whisper_ready(self) -> bool:
        from .. import paths

        return paths.tool("whisper-server") is not None

    def _use(self, model: models.Model) -> None:
        if model.id in self.app.downloads.installed() and self.settings.main_model != model.id:
            self.settings.set("main_model", model.id)
            self._refresh_models()
            if self.settings.residency == "always":
                self.app.host.prewarm(model)

    def _delete(self, model: models.Model) -> None:
        if self.app.host.loaded and self.app.host.loaded.id == model.id:
            self.app.host.unload()
        self.app.downloads.delete(model)

    # Dictation

    def _dictation(self) -> Adw.PreferencesPage:
        page = Adw.PreferencesPage(title="Dictation", icon_name="audio-input-microphone-symbolic", name="dictation")
        main = Adw.PreferencesGroup(description="Speak in any app. The words are typed where your cursor is.")
        main.add(switch("Dictation", "Listen for the shortcut while WhisperDrop runs.", self.settings.dictation_enabled,
                        self._set("dictation_enabled")))
        page.add(main)

        self.shortcut_group = Adw.PreferencesGroup(title="Shortcut")
        keys = list(dict.fromkeys([self.settings.shortcut, *shortcuts.SUGGESTED_KEYS]))
        self.key_row = Adw.ComboRow(title="Key", subtitle="A single key such as F9 works best: you hold it while you speak.",
                                    model=Gtk.StringList.new(keys))
        self.key_row.set_selected(0)
        self.key_row.keys = keys
        self.key_row.connect("notify::selected", lambda r, _p: self._key_changed(r.keys[r.get_selected()]))
        self.shortcut_group.add(self.key_row)
        self.shortcut_group.add(combo("How it works", "", MODES, self.settings.dictation_mode, self._set("dictation_mode")))
        self.setup_row = Adw.ActionRow()
        self.setup_row.set_subtitle_selectable(True)
        self.setup_button = Gtk.Button(valign=Gtk.Align.CENTER)
        self.setup_button.connect("clicked", lambda *_: self._setup_shortcut())
        self.setup_row.add_suffix(self.setup_button)
        self.shortcut_group.add(self.setup_row)
        self.snippet = label("", ("shortcut-snippet",), wrap=True, selectable=True)
        self.snippet.set_margin_top(8)
        self.shortcut_group.add(self.snippet)
        page.add(self.shortcut_group)
        self._refresh_shortcut()

        typing = Adw.PreferencesGroup(title="Typing")
        method = combo("Typing method", insert.describe(self.settings.insert_method), INSERT_METHODS,
                       self.settings.insert_method, lambda value: (self.settings.set("insert_method", value),
                                                                    self._typing_hint(method)))
        typing.add(method)
        self.typing_problem = label("", ("notice",), wrap=True)
        typing.add(self.typing_problem)
        self._typing_hint(method)
        typing.add(switch("Show words while you speak", "With Parakeet v3, the overlay shows the newest words. "
                          "The text is typed when you finish.", self.settings.dictation_live_words,
                          self._set("dictation_live_words")))
        typing.add(switch("Sounds", "A short tone when listening starts and ends.", self.settings.sounds,
                          self._set("sounds")))
        page.add(typing)

        words = Adw.PreferencesGroup(title="Words and names",
                                     description="Whisper models use this list as a spelling hint. Parakeet v3 ignores it.")
        vocabulary = Adw.EntryRow(title="Names, brands and terms, separated by commas", text=self.settings.vocabulary)
        vocabulary.connect("changed", lambda r: self.settings.set("vocabulary", r.get_text()))
        words.add(vocabulary)
        page.add(words)

        try_group = Adw.PreferencesGroup(title="Try it",
                                         description="Click in this box, then hold the shortcut and speak.")
        test = Gtk.TextView(wrap_mode=Gtk.WrapMode.WORD_CHAR, height_request=70, top_margin=8, bottom_margin=8,
                            left_margin=10, right_margin=10)
        test.add_css_class("card")
        try_group.add(test)
        page.add(try_group)
        return page

    def _typing_hint(self, row) -> None:
        method = self.settings.insert_method
        row.set_subtitle(insert.describe(method) + (" (chosen automatically)" if method == "auto" else ""))
        problem = insert.missing(method)
        self.typing_problem.set_text(problem or "")
        self.typing_problem.set_visible(bool(problem))

    def _key_changed(self, key: str) -> None:
        self.settings.set("shortcut", key)
        self._refresh_shortcut()

    def _refresh_shortcut(self) -> None:
        key = self.settings.shortcut
        if shortcuts.hyprland():
            found = shortcuts.hypr_config()
            installed = shortcuts.installed_key(found[0]) if found else None
            conflict = shortcuts.hypr_conflict(key)
            if not found:
                self.setup_row.set_title("Hyprland configuration not found")
                self.setup_row.set_subtitle("Add the lines below to your Hyprland configuration.")
                self.setup_button.set_visible(False)
            elif installed and installed.replace(" ", "").upper() == key.replace(" ", "").upper():
                self.setup_row.set_title(f"Ready: hold {key} in any app")
                self.setup_row.set_subtitle(f"Set up in {found[0]}.")
                self.setup_button.set_label("Remove")
                self.setup_button.set_visible(True)
            else:
                self.setup_row.set_title("Add the shortcut to Hyprland" if not installed else f"Update the shortcut to {key}")
                detail = f"WhisperDrop adds two lines to {found[0]} and keeps a backup. Hyprland reloads it by itself."
                if conflict:
                    detail = f"{key} already does: {conflict}. Choose another key, or replace it. " + detail
                self.setup_row.set_subtitle(GLib.markup_escape_text(detail))
                self.setup_button.set_label("Add")
                self.setup_button.set_visible(True)
                self.setup_button.add_css_class("suggested-action")
            lua = found[1] if found else True
            self.snippet.set_text(shortcuts.hypr_snippet(key, lua).strip())
        else:
            portal = self.app.portal.status if self.app.portal else "Not connected"
            self.setup_row.set_title("Desktop shortcut")
            self.setup_row.set_subtitle(GLib.markup_escape_text(
                f"Global shortcut portal: {portal}. If your desktop does not ask for a key, add a custom keyboard "
                "shortcut in its settings that runs the command below."))
            self.setup_button.set_label("Copy command")
            self.setup_button.set_visible(True)
            self.snippet.set_text(f"{shortcuts.ctl_command()} dictate toggle")

    def _setup_shortcut(self) -> None:
        if not shortcuts.hyprland():
            Gdk.Display.get_default().get_clipboard().set(f"{shortcuts.ctl_command()} dictate toggle")
            self.add_toast(Adw.Toast(title="Command copied."))
            return
        found = shortcuts.hypr_config()
        if not found:
            return
        installed = shortcuts.installed_key(found[0])
        key = self.settings.shortcut
        if installed and installed.replace(" ", "").upper() == key.replace(" ", "").upper():
            shortcuts.remove_hypr()
            self.add_toast(Adw.Toast(title="Shortcut removed from your Hyprland configuration."))
            self._refresh_shortcut()
            self.app.dictation_changed.emit()
            return
        dialog = Adw.AlertDialog(heading=f"Add {key} to Hyprland?",
                                 body=f"These lines are added to {found[0]}. A backup is saved next to it as "
                                      f"{found[0].name}.whisperdrop-backup.")
        dialog.set_extra_child(label(shortcuts.hypr_snippet(key, found[1]).strip(), ("shortcut-snippet",), wrap=True,
                                     selectable=True))
        dialog.add_response("cancel", "Cancel")
        dialog.add_response("add", "Add")
        dialog.set_response_appearance("add", Adw.ResponseAppearance.SUGGESTED)

        def respond(d, response):
            if response != "add":
                return
            try:
                path = shortcuts.install_hypr(key)
                self.add_toast(Adw.Toast(title=f"Added to {path.name}. Hold {key} and speak."))
            except OSError as error:
                self.add_toast(Adw.Toast(title=GLib.markup_escape_text(str(error))))
            self._refresh_shortcut()
            self.app.dictation_changed.emit()

        dialog.connect("response", respond)
        dialog.present(self)

    # Notes

    def _notes(self) -> Adw.PreferencesPage:
        page = Adw.PreferencesPage(title="Notes", icon_name="accessories-text-editor-symbolic", name="notes")
        group = Adw.PreferencesGroup(description="Record a lecture, call or meeting. The transcript builds while you record. "
                                                 "These are the starting choices; New note lets you change them each time.")
        group.add(combo("Record", "You is the microphone. Others is sound from other apps.", SOURCES,
                        self.settings.note_sources, self._set("note_sources")))
        mics = capture.microphones()
        names = {"": "Default input"}
        names.update({m.name: m.description for m in mics})
        group.add(combo("Microphone", "Also used for dictation.", names, self.settings.microphone or "",
                        lambda value: self.settings.set("microphone", value or None)))
        group.add(switch("Keep the recording", "Saves an M4A file beside the transcript, about 22 MB per hour.",
                         self.settings.keep_note_audio, self._set("keep_note_audio")))
        group.add(switch("Show words before they settle", "With Parakeet v3, the newest words appear in grey a few "
                         "seconds before they join the transcript.", self.settings.note_live_text,
                         self._set("note_live_text")))
        page.add(group)
        words = Adw.PreferencesGroup(title="Words and names", description="Whisper models use this list for notes. "
                                                                           "Parakeet v3 ignores it.")
        vocabulary = Adw.EntryRow(title="Subject terms, separated by commas", text=self.settings.note_vocabulary)
        vocabulary.connect("changed", lambda r: self.settings.set("note_vocabulary", r.get_text()))
        words.add(vocabulary)
        page.add(words)
        return page
