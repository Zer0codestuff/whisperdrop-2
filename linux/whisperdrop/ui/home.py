"""Start page: what WhisperDrop does, one card per way in, and the model download when none is installed."""

from __future__ import annotations

from gi.repository import Adw, Gtk

from .. import shortcuts
from ..core import models
from .widgets import Page, clear, label


class HomePage(Page):
    def __init__(self, window):
        super().__init__()
        self.window = window
        self.app = window.app
        header = Adw.HeaderBar(show_title=False)
        self.add_top_bar(header)

        self.banner = Adw.Banner(revealed=False)
        self.banner.connect("button-clicked", lambda *_: self._banner_action())
        self.add_top_bar(self.banner)

        scroller = Gtk.ScrolledWindow(hscrollbar_policy=Gtk.PolicyType.NEVER)
        clamp = Adw.Clamp(maximum_size=760, margin_top=40, margin_bottom=40, margin_start=24, margin_end=24)
        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0, valign=Gtk.Align.CENTER, vexpand=True)
        mark = Gtk.Image(icon_name="io.github.zer0codestuff.WhisperDrop", pixel_size=72, halign=Gtk.Align.START)
        mark.set_margin_bottom(24)
        body.append(mark)
        body.append(label("Drop a recording.", ("hero-title",)))
        body.append(label("Leave with the words.", ("hero-subtitle",)))
        intro = label("Transcribe files and YouTube videos, record notes while you listen, or dictate into any app. "
                      "Everything runs on this computer.", ("dim",), wrap=True)
        intro.set_margin_top(14)
        intro.set_margin_bottom(28)
        body.append(intro)

        self.cards = Gtk.FlowBox(selection_mode=Gtk.SelectionMode.NONE, column_spacing=12, row_spacing=12,
                                 homogeneous=True, min_children_per_line=1, max_children_per_line=3)
        body.append(self.cards)

        self.queue = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6, margin_top=26)
        body.append(self.queue)
        clamp.set_child(body)
        scroller.set_child(clamp)
        self.set_content(scroller)
        self.app.models_changed.connect(lambda: self.refresh())
        self.app.settings.observe(lambda key: self.refresh() if key in ("shortcut", "dictation_enabled", "main_model") else None)
        self.refresh()

    def _card(self, icon: str, title: str, detail: str, hint: str, callback) -> Gtk.Button:
        button = Gtk.Button()
        button.add_css_class("flat")
        button.add_css_class("start-card")
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        image = Gtk.Image(icon_name=icon, pixel_size=24, halign=Gtk.Align.START)
        image.add_css_class("card-icon")
        box.append(image)
        box.append(label(title, ("card-title",)))
        detail_label = label(detail, ("card-detail",), wrap=True)
        detail_label.set_max_width_chars(22)
        detail_label.set_vexpand(True)
        detail_label.set_valign(Gtk.Align.START)
        box.append(detail_label)
        hint_label = label(hint, ("card-hint",), wrap=True)
        hint_label.set_max_width_chars(22)
        box.append(hint_label)
        button.set_child(box)
        button.connect("clicked", lambda *_: callback())
        return button

    def refresh(self) -> None:
        app = self.app
        while (child := self.cards.get_first_child()) is not None:
            self.cards.remove(child)
        settings = app.settings
        key = settings.shortcut
        if shortcuts.hyprland():
            found = shortcuts.hypr_config()
            ready = bool(found and shortcuts.installed_key(found[0]))
        else:
            ready = True
        dictation_hint = (f"Hold {key} and speak" if ready else "Set up the shortcut") if settings.dictation_enabled \
            else "Turn on dictation"
        self.cards.append(self._card("audio-input-microphone-symbolic", "Record a note",
                                     "Lectures, calls and meetings. Text appears a few seconds after it is spoken.",
                                     "New note  ·  Ctrl+N", self.window.new_note))
        self.cards.append(self._card("document-open-symbolic", "Transcribe files",
                                     "Audio or video, or a YouTube link. You can also drop files on this window.",
                                     "Add files  ·  Ctrl+O", self.window.choose_files))
        self.cards.append(self._card("input-keyboard-symbolic", "Dictate anywhere",
                                     "Speak in any app. The words are typed where your cursor is.",
                                     dictation_hint, lambda: app.show_preferences("dictation")))

        # Model banner
        installed = app.downloads.installed()
        model = settings.model
        if app.downloads.active:
            name = models.by_id(app.downloads.active).name
            self.banner.set_title(f"Downloading {name}… {round(app.downloads.progress * 100)}%")
            self.banner.set_button_label("Cancel")
            self.banner.set_revealed(True)
            self._banner = "cancel"
        elif not installed:
            self.banner.set_title(f"Download {model.name} ({model.size_label}) to start. It is needed once, then everything works offline.")
            self.banner.set_button_label("Download")
            self.banner.set_revealed(True)
            self._banner = "download"
        elif model.id not in installed:
            self.banner.set_title(f"{model.name} is selected but not downloaded.")
            self.banner.set_button_label("Models")
            self.banner.set_revealed(True)
            self._banner = "models"
        elif app.downloads.error:
            self.banner.set_title(app.downloads.error)
            self.banner.set_button_label("Models")
            self.banner.set_revealed(True)
            self._banner = "models"
        else:
            self.banner.set_revealed(False)
            self._banner = None

        clear(self.queue)
        queued = app.transcriber.queued
        if queued and not app.transcriber.busy:
            row = Gtk.Box(spacing=12)
            row.append(label(f"{len(queued)} waiting to be transcribed.", ("dim",)))
            start = Gtk.Button(label="Transcribe")
            start.add_css_class("suggested-action")
            start.add_css_class("pill")
            start.connect("clicked", lambda *_: app.transcriber.start())
            row.append(start)
            self.queue.append(row)

    def _banner_action(self) -> None:
        app = self.app
        if self._banner == "download":
            app.downloads.download(app.settings.model)
        elif self._banner == "cancel":
            app.downloads.cancel()
        else:
            app.show_preferences("models")
