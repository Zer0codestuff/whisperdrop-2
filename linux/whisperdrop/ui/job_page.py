"""A library item: its transcript with a player and search, or its progress while it is processed."""

from __future__ import annotations

import time
from pathlib import Path

from gi.repository import Adw, Gdk, Gio, GLib, Gtk

from ..audio.player import Player
from ..core import models
from ..core import transcript as tx
from ..library import Job, atomic_write
from .widgets import Page, TranscriptRow, clear, icon_button, label

EXPORTS = (("txt", "Plain text", "Text"), ("md", "Markdown", "Markdown"), ("srt", "SubRip subtitles", "SRT"),
           ("vtt", "WebVTT subtitles", "VTT"), ("json", "JSON with word timings", "JSON"))
KIND_LABELS = {"note": "Note", "youtube": "YouTube", "file": "File"}


class JobPage(Page):
    def __init__(self, window):
        super().__init__()
        self.window = window
        self.app = window.app
        self.job: Job | None = None
        self.shown_key = None
        self.rows: list[TranscriptRow] = []
        self.player: Player | None = None
        self.player_files: tuple[str, ...] = ()
        self.matches: list[int] = []
        self.match_index = 0
        self.playing_row: TranscriptRow | None = None

        header = Adw.HeaderBar(show_title=False)
        self.title_widget = Adw.WindowTitle()  # the page shows an editable title instead
        self.search_button = Gtk.ToggleButton(icon_name="system-search-symbolic", tooltip_text="Find in transcript (Ctrl+F)")
        self.copy_button = icon_button("edit-copy-symbolic", "Copy transcript", self.copy)
        export_menu = Gio.Menu()
        for fmt, name, _ in EXPORTS:
            export_menu.append(f"{name} (.{fmt})", f"page.export::{fmt}")
        self.export_button = Gtk.MenuButton(icon_name="document-save-symbolic", tooltip_text="Export", menu_model=export_menu)
        self.more_button = Gtk.MenuButton(icon_name="view-more-symbolic", tooltip_text="More")
        header.pack_end(self.more_button)
        header.pack_end(self.export_button)
        header.pack_end(self.copy_button)
        header.pack_end(self.search_button)
        self.add_top_bar(header)

        self.search_bar = Gtk.SearchBar()
        search_box = Gtk.Box(spacing=6)
        self.search_entry = Gtk.SearchEntry(placeholder_text="Find in transcript", width_chars=30)
        self.search_entry.connect("search-changed", lambda *_: self._search())
        self.search_entry.connect("activate", lambda *_: self._step_match(1))
        self.search_entry.connect("next-match", lambda *_: self._step_match(1))
        self.search_entry.connect("previous-match", lambda *_: self._step_match(-1))
        search_box.append(self.search_entry)
        self.match_label = label("", ("dim",))
        search_box.append(self.match_label)
        search_box.append(icon_button("go-up-symbolic", "Previous match", lambda: self._step_match(-1)))
        search_box.append(icon_button("go-down-symbolic", "Next match", lambda: self._step_match(1)))
        self.search_bar.set_child(search_box)
        self.search_bar.connect_entry(self.search_entry)
        self.search_button.bind_property("active", self.search_bar, "search-mode-enabled",
                                         1 | 2)  # bidirectional, sync create
        self.add_top_bar(self.search_bar)

        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE)
        self.scroller = Gtk.ScrolledWindow(hscrollbar_policy=Gtk.PolicyType.NEVER, vexpand=True)
        clamp = Adw.Clamp(maximum_size=860, margin_start=28, margin_end=28, margin_top=20, margin_bottom=40)
        self.body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        clamp.set_child(self.body)
        self.scroller.set_child(clamp)
        self.stack.add_named(self.scroller, "transcript")
        self.status = Adw.StatusPage()
        self.stack.add_named(self.status, "status")
        self.set_content(self.stack)

        self.player_bar = self._player_bar()
        self.add_bottom_bar(self.player_bar)

        group = Gio.SimpleActionGroup()
        export = Gio.SimpleAction.new("export", GLib.VariantType.new("s"))
        export.connect("activate", lambda a, p: self.export(p.unpack()))
        group.add_action(export)
        for name, callback in (("retranscribe", self.retranscribe), ("rename", lambda: self.window.rename(self.job.id)),
                               ("reveal", lambda: self.window.reveal(self.job.id)),
                               ("remove", lambda: self.window.remove(self.job.id))):
            action = Gio.SimpleAction.new(name, None)
            action.connect("activate", lambda a, p, callback=callback: callback())
            group.add_action(action)
        self.insert_action_group("page", group)
        keys = Gtk.ShortcutController()
        keys.add_shortcut(Gtk.Shortcut(trigger=Gtk.ShortcutTrigger.parse_string("<Control>space"),
                                       action=Gtk.CallbackAction.new(lambda *_: (self.toggle_play(), True)[1])))
        self.add_controller(keys)
        GLib.timeout_add(250, self._tick)

    # Showing

    def show(self, job: Job) -> None:
        key = (job.id, job.status, job.title, len(job.segments), job.error, job.warning, tuple(job.audio_files))
        same = self.job is not None and self.job.id == job.id
        self.job = job
        self.title_widget.set_title(job.title)
        self.title_widget.set_subtitle(self._meta(job))
        if job.status != "completed":
            self._status(job)
            return
        if key == self.shown_key:
            return
        self.shown_key = key
        self.stack.set_visible_child_name("transcript")
        for widget in (self.copy_button, self.export_button, self.search_button):
            widget.set_sensitive(bool(job.segments))
        self._more_menu(job)
        self._render(job)
        files = self._audio(job)
        if not same or tuple(files) != self.player_files:
            self._close_player()
            self.player_files = tuple(files)
            if files and Player.available():
                self.player = Player(files)
        self.player_bar.set_visible(self.player is not None)
        self._sync_player()
        if self.search_bar.get_search_mode():
            self._search()

    def _meta(self, job: Job) -> str:
        parts = [KIND_LABELS.get(job.kind, ""), time.strftime("%b %d, %Y %H:%M", time.localtime(job.created)).replace(" 0", " "),
                 tx.duration_label(job.duration)]
        if job.status == "completed":
            parts.append(job.model_name or "")
            if job.language and job.language != "auto":
                parts.append(models.language_name(job.language))
        return " · ".join(p for p in parts if p)

    def _audio(self, job: Job) -> list[str]:
        if job.kind == "note":
            return [f for f in job.audio_files if Path(f).exists()]
        if job.kind == "file" and Path(job.source).is_file():
            return [job.source]
        return []

    def _more_menu(self, job: Job) -> None:
        menu = Gio.Menu()
        menu.append("Rename…", "page.rename")
        if self.app.library.folders(job):
            menu.append("Show in Files", "page.reveal")
        if job.kind != "note":
            menu.append("Transcribe Again", "page.retranscribe")
        menu.append("Remove…", "page.remove")
        self.more_button.set_menu_model(menu)

    def _render(self, job: Job) -> None:
        clear(self.body)
        self.rows = []
        self.playing_row = None
        title = Gtk.EditableLabel(text=job.title, tooltip_text="Click to rename")
        title.add_css_class("page-title")
        title.connect("notify::editing", self._title_edited)
        self.body.append(title)
        meta = label(self._meta(job), ("page-meta",))
        meta.set_margin_bottom(14)
        self.body.append(meta)
        for message in (job.warning, job.error):
            if message:
                notice = label(message, ("notice",), wrap=True)
                notice.set_margin_bottom(10)
                self.body.append(notice)
        if not job.segments:
            empty = label("No speech was detected in this recording.", ("dim",))
            empty.set_margin_top(20)
            self.body.append(empty)
            return
        seek = self.seek if self._audio(job) else None
        for paragraph in tx.paragraphs(job.segments, each_sentence=job.sentence_paragraphs):
            row = TranscriptRow(paragraph, seek)
            self.rows.append(row)
            self.body.append(row)

    def _title_edited(self, editable, _param) -> None:
        if editable.get_editing() or not self.job:
            return
        text = editable.get_text().strip()
        if text and text != self.job.title:
            self.window.apply_rename(self.job.id, text)
        else:
            editable.set_text(self.job.title)

    def _status(self, job: Job) -> None:
        key = (job.id, job.status, job.error, self.app.transcriber.busy)
        if job.active and key == getattr(self, "_status_key", None) and getattr(self, "_bar", None):
            self._bar.set_fraction(job.progress)
            self._bar.set_text(f"{round(job.progress * 100)}%")
            return
        self._status_key = key
        self._bar = None
        self.shown_key = None
        self._close_player()
        self.player_bar.set_visible(False)
        for widget in (self.copy_button, self.export_button, self.search_button):
            widget.set_sensitive(False)
        self._more_menu(job)
        self.stack.set_visible_child_name("status")
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12, halign=Gtk.Align.CENTER)
        status = self.status
        if job.active:
            status.set_icon_name("content-loading-symbolic")
            status.set_title(f"{job.status_label}…")
            status.set_description({"downloading": "Downloading the audio from YouTube.",
                                    "converting": "Preparing the audio for the speech model.",
                                    "transcribing": "Transcribing on this computer. You can keep adding recordings."}
                                   .get(job.status, ""))
            bar = Gtk.ProgressBar(fraction=job.progress, show_text=True, width_request=280)
            bar.set_text(f"{round(job.progress * 100)}%")
            self._bar = bar
            box.append(bar)
            stop = Gtk.Button(label="Stop", halign=Gtk.Align.CENTER)
            stop.add_css_class("pill")
            stop.connect("clicked", lambda *_: self.app.transcriber.cancel())
            box.append(stop)
        elif job.status == "queued":
            status.set_icon_name("document-open-recent-symbolic")
            status.set_title("Waiting")
            busy = self.app.transcriber.busy
            status.set_description("Another recording is being transcribed. This one is next in line." if busy else
                                   "Ready to transcribe in " + models.language_name(self.app.settings.spoken_language) + ".")
            if not busy:
                start = Gtk.Button(label="Transcribe", halign=Gtk.Align.CENTER)
                start.add_css_class("suggested-action")
                start.add_css_class("pill")
                start.connect("clicked", lambda *_: self.app.transcriber.start())
                box.append(start)
        else:
            failed = job.status == "failed"
            status.set_icon_name("dialog-error-symbolic" if failed else "media-playback-stop-symbolic")
            status.set_title("Transcription failed" if failed else "Stopped")
            status.set_description(GLib.markup_escape_text(job.error or ""))
            again = Gtk.Button(label="Try Again", halign=Gtk.Align.CENTER)
            again.add_css_class("suggested-action")
            again.add_css_class("pill")
            again.connect("clicked", lambda *_: self.app.transcriber.retry(job.id))
            box.append(again)
        status.set_child(box)

    # Actions

    def copy(self) -> None:
        if self.job:
            Gdk.Display.get_default().get_clipboard().set(self.job.text)
            self.window.toast("Transcript copied.")

    def export(self, fmt: str) -> None:
        if not self.job:
            return
        job = self.job
        dialog = Gtk.FileDialog(title="Export transcript", initial_name=f"{job.title}.{fmt}")
        folder = Path(job.transcript_folder) if job.transcript_folder else self.app.library.transcripts_folder
        if folder.is_dir():
            dialog.set_initial_folder(Gio.File.new_for_path(str(folder)))

        def saved(d, result):
            try:
                file = d.save_finish(result)
            except GLib.Error:
                return
            try:
                atomic_write(Path(file.get_path()), self.app.library.export(job, fmt))
                self.window.toast(f"Exported {Path(file.get_path()).name}.")
            except OSError as error:
                self.window.toast(f"Could not export: {error.strerror}")

        dialog.save(self.window, None, saved)

    def retranscribe(self) -> None:
        if self.job and self.job.kind != "note":
            self.app.transcriber.retry(self.job.id)

    # Search

    def toggle_search(self) -> None:
        if not self.job or self.job.status != "completed":
            return
        self.search_bar.set_search_mode(not self.search_bar.get_search_mode())
        if self.search_bar.get_search_mode():
            self.search_entry.grab_focus()

    def _search(self) -> None:
        query = self.search_entry.get_text().strip().lower()
        terms = query.split()
        self.matches = []
        for index, row in enumerate(self.rows):
            row.highlight(terms)
            hit = bool(terms) and all(t in row.segment.text.lower() for t in terms)
            (row.add_css_class if hit else row.remove_css_class)("match")
            if hit:
                self.matches.append(index)
        self.match_index = 0
        if not terms:
            self.match_label.set_text("")
        elif not self.matches:
            self.match_label.set_text("No matches")
        else:
            self._step_match(0)

    def _step_match(self, step: int) -> None:
        if not self.matches:
            return
        self.match_index = (self.match_index + step) % len(self.matches)
        self.match_label.set_text(f"{self.match_index + 1} of {len(self.matches)}")
        self._scroll_to(self.rows[self.matches[self.match_index]])

    def _scroll_to(self, row: Gtk.Widget) -> None:
        def run():
            ok, point = row.compute_point(self.body, _point(0, 0))
            if ok:
                adjustment = self.scroller.get_vadjustment()
                adjustment.set_value(max(0, point.y - adjustment.get_page_size() / 3))
            return False
        GLib.idle_add(run)

    # Player

    def _player_bar(self) -> Gtk.Widget:
        bar = Gtk.Box(spacing=12)
        bar.add_css_class("control-surface")
        self.play_button = icon_button("media-playback-start-symbolic", "Play (Ctrl+Space)", self.toggle_play,
                                       css=("circular", "suggested-action"))
        bar.append(self.play_button)
        self.position_label = label("00:00", ("dim",))
        bar.append(self.position_label)
        self.scale = Gtk.Scale(orientation=Gtk.Orientation.HORIZONTAL, hexpand=True, draw_value=False)
        self.scale.set_range(0, 1)
        self.scale.connect("change-value", self._scrubbed)
        bar.append(self.scale)
        self.length_label = label("00:00", ("dim",))
        bar.append(self.length_label)
        speeds = Gtk.DropDown.new_from_strings(["1×", "1.25×", "1.5×", "2×"])
        speeds.set_tooltip_text("Playback speed")
        speeds.connect("notify::selected", lambda d, _p: self.player and self.player.set_speed((1, 1.25, 1.5, 2)[d.get_selected()]))
        bar.append(speeds)
        bar.set_visible(False)
        return bar

    def toggle_play(self) -> None:
        if not self.player:
            return
        if self.player.playing:
            self.player.pause()
        else:
            self.player.play()
        self._sync_player()

    def seek(self, seconds: float) -> None:
        if not self.player:
            return
        self.player.play(max(0.0, seconds - 0.3))
        self._sync_player()

    def _scrubbed(self, scale, scroll, value) -> bool:
        if self.player:
            self.player.seek(value)
            self._sync_player()
        return False

    def _close_player(self) -> None:
        if self.player:
            self.player.close()
        self.player = None
        self.player_files = ()

    def _sync_player(self) -> None:
        player = self.player
        if not player:
            return
        playing = player.playing
        self.play_button.set_icon_name("media-playback-pause-symbolic" if playing else "media-playback-start-symbolic")
        self.play_button.set_tooltip_text("Pause (Ctrl+Space)" if playing else "Play (Ctrl+Space)")
        position = player.position
        self.scale.set_range(0, max(1.0, player.length))
        self.scale.set_value(position)
        self.position_label.set_text(tx.time_label(position))
        self.length_label.set_text(tx.time_label(player.length))
        current = None
        if playing or position > 0:
            for row in self.rows:
                if row.segment.start <= position + 0.2:
                    current = row
                else:
                    break
        if current is not self.playing_row:
            if self.playing_row:
                self.playing_row.remove_css_class("playing")
            if current and playing:
                current.add_css_class("playing")
                self._scroll_to(current)
            self.playing_row = current if playing else None

    def _tick(self) -> bool:
        if self.player and self.get_mapped():
            self._sync_player()
        elif self.player and self.player.playing and not self.get_mapped():
            self.player.pause()
        return True


def _point(x: float, y: float):
    from gi.repository import Graphene

    point = Graphene.Point()
    point.x, point.y = x, y
    return point
