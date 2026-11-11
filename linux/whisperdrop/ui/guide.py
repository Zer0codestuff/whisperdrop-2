"""First-run guide: what the app does, the model and language, the dictation shortcut. Skippable, reopened from Help."""

from __future__ import annotations

from gi.repository import Adw, Gtk

from .. import shortcuts
from ..core import models
from .widgets import label


class Guide(Adw.Dialog):
    def __init__(self, app):
        super().__init__(title="Welcome", content_width=560, content_height=560)
        self.app = app
        view = Adw.ToolbarView()
        view.add_top_bar(Adw.HeaderBar(show_title=False))
        self.carousel = Adw.Carousel(allow_scroll_wheel=False, vexpand=True)
        self.carousel.append(self._page("io.github.zer0codestuff.WhisperDrop", "Speech to text, on this computer.",
                                        "WhisperDrop transcribes with a model that runs locally. Nothing is uploaded, and once "
                                        "the model is downloaded it works offline.", self._features()))
        self.carousel.append(self._page("drive-harddisk-symbolic", "Download the model.",
                                        "Parakeet v3 covers 25 European languages and is fast enough to show words while you "
                                        "speak. It is downloaded once.", self._setup()))
        self.carousel.append(self._page("input-keyboard-symbolic", "Dictate in any app.",
                                        "Put the cursor where the text should go, hold the shortcut and speak. Release it "
                                        "and the words are typed.", self._dictation()))
        self.carousel.append(self._page("object-select-symbolic", "You are ready.",
                                        "Start a note to record a lecture or a call, or drop a recording on the window. "
                                        "Preferences explain every option, and this guide is in the main menu.", None))
        dots = Adw.CarouselIndicatorDots(carousel=self.carousel)
        footer = Gtk.Box(spacing=10, margin_start=24, margin_end=24, margin_bottom=20, margin_top=8)
        footer.append(dots)
        spacer = Gtk.Box(hexpand=True)
        footer.append(spacer)
        self.skip = Gtk.Button(label="Skip")
        self.skip.add_css_class("flat")
        self.skip.connect("clicked", lambda *_: self._done())
        footer.append(self.skip)
        self.back = Gtk.Button(label="Back")
        self.back.connect("clicked", lambda *_: self._go(-1))
        footer.append(self.back)
        self.next = Gtk.Button(label="Next")
        self.next.add_css_class("suggested-action")
        self.next.connect("clicked", lambda *_: self._go(1))
        footer.append(self.next)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        box.append(self.carousel)
        box.append(footer)
        view.set_content(box)
        self.set_child(view)
        self.carousel.connect("page-changed", lambda *_: self._update())
        self._handler = app.models_changed.connect(self._refresh_setup)
        self.connect("closed", lambda *_: (app.models_changed.disconnect(self._handler),
                                           app.settings.set("guide_done", True)))
        self._update()

    def _page(self, icon, title, body, extra) -> Gtk.Widget:
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12, margin_start=36, margin_end=36, margin_top=8,
                      hexpand=True, vexpand=True)
        image = Gtk.Image(icon_name=icon, pixel_size=48, halign=Gtk.Align.START)
        if icon.endswith("-symbolic"):
            image.add_css_class("green")
        box.append(image)
        box.append(label(title, ("guide-title",), wrap=True))
        box.append(label(body, ("guide-body",), wrap=True))
        if extra:
            extra.set_margin_top(10)
            box.append(extra)
        return box

    def _features(self) -> Gtk.Widget:
        group = Adw.PreferencesGroup()
        for icon, title, detail in (
                ("audio-input-microphone-symbolic", "Notes", "Record a lecture, call or meeting. The text builds while you listen."),
                ("document-open-symbolic", "Files and YouTube", "Drop audio or video, or paste a link, and export the transcript."),
                ("input-keyboard-symbolic", "Dictation", "Hold a key, speak, and the words appear where your cursor is.")):
            row = Adw.ActionRow(title=title, subtitle=detail)
            row.add_prefix(Gtk.Image(icon_name=icon))
            group.add(row)
        return group

    def _setup(self) -> Gtk.Widget:
        group = Adw.PreferencesGroup()
        self.model_row = Adw.ActionRow(title=self.app.settings.model.name)
        self.model_suffix = Gtk.Box(valign=Gtk.Align.CENTER, spacing=8)
        self.model_row.add_suffix(self.model_suffix)
        group.add(self.model_row)
        codes = [c for c, _ in models.LANGUAGES]
        language = Adw.ComboRow(title="Spoken language", subtitle="Used for files, dictation and notes.",
                                model=Gtk.StringList.new([n for _, n in models.LANGUAGES]), enable_search=True)
        current = self.app.settings.spoken_language
        language.set_selected(codes.index(current) if current in codes else 0)
        language.connect("notify::selected", lambda r, _p: self.app.settings.set("spoken_language", codes[r.get_selected()]))
        group.add(language)
        self._refresh_setup()
        return group

    def _refresh_setup(self) -> None:
        app = self.app
        model = app.settings.model
        self.model_row.set_subtitle(f"{model.size_label}, downloaded once.")
        child = self.model_suffix.get_first_child()
        while child:
            self.model_suffix.remove(child)
            child = self.model_suffix.get_first_child()
        if app.downloads.active == model.id:
            self.model_suffix.append(Gtk.ProgressBar(fraction=app.downloads.progress, width_request=120,
                                                     valign=Gtk.Align.CENTER))
            self.model_suffix.append(label(f"{round(app.downloads.progress * 100)}%", ("dim",)))
        elif model.id in app.downloads.installed():
            self.model_suffix.append(label("Ready", ("green",)))
        else:
            button = Gtk.Button(label="Download")
            button.add_css_class("suggested-action")
            button.connect("clicked", lambda *_: app.downloads.download(model))
            self.model_suffix.append(button)

    def _dictation(self) -> Gtk.Widget:
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        key = self.app.settings.shortcut
        if shortcuts.hyprland():
            text = (f"On Hyprland, WhisperDrop can add {key} to your configuration for you, after you confirm. "
                    "Open Preferences, Dictation to do it, choose another key, or copy the lines yourself.")
        else:
            text = ("Your desktop may ask you to confirm a key for WhisperDrop. If it does not, add a keyboard shortcut "
                    "in its settings that runs: whisperdrop-ctl dictate toggle")
        box.append(label(text, ("dim",), wrap=True))
        button = Gtk.Button(label="Set up the shortcut", halign=Gtk.Align.START)
        button.add_css_class("pill")
        button.connect("clicked", lambda *_: (self.close(), self.app.show_preferences("dictation")))
        box.append(button)
        return box

    def _go(self, step: int) -> None:
        index = round(self.carousel.get_position()) + step
        if index >= self.carousel.get_n_pages():
            self._done()
            return
        index = max(0, index)
        self.carousel.scroll_to(self.carousel.get_nth_page(index), True)

    def _update(self) -> None:
        index = round(self.carousel.get_position())
        last = index == self.carousel.get_n_pages() - 1
        self.back.set_visible(index > 0)
        self.skip.set_visible(not last)
        self.next.set_label("Start using WhisperDrop" if last else "Next")

    def _done(self) -> None:
        self.app.settings.set("guide_done", True)
        self.close()
