"""The recording note: live transcript, levels, and Pause, Resume, Stop and save, Discard."""

from __future__ import annotations

from gi.repository import Adw, GLib, Gtk

from ..core import models
from ..core import transcript as tx
from ..settings import SOURCES
from .widgets import LevelBars, Page, TranscriptRow, clear, confirm, label

PLACEHOLDER = "Untitled note · click to name it"
STATE_LABELS = {"starting": "Starting", "recording": "Recording", "paused": "Paused", "finishing": "Saving"}


class NotePage(Page):
    def __init__(self, window):
        super().__init__()
        self.window = window
        self.app = window.app
        self.recorder = window.app.recorder
        self.shown = (-1, "")
        self.following = True

        header = Adw.HeaderBar(show_title=False)
        self.add_top_bar(header)

        top = Gtk.Box(spacing=16, margin_start=28, margin_end=28, margin_top=4, margin_bottom=12)
        titles = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4, hexpand=True)
        self.title = Gtk.EditableLabel(tooltip_text="Click to name this note")
        self.title.add_css_class("page-title")
        self.title.connect("notify::editing", self._title_edited)
        titles.append(self.title)
        self.meta = label("", ("page-meta",))
        titles.append(self.meta)
        top.append(titles)
        state = Gtk.Box(spacing=8, valign=Gtk.Align.CENTER)
        self.dot = Gtk.Box(valign=Gtk.Align.CENTER)
        self.dot.add_css_class("status-dot")
        state.append(self.dot)
        self.state_label = label("", ("dim",))
        state.append(self.state_label)
        top.append(state)
        self.clock = label("00:00", ("clock",))
        self.clock.set_valign(Gtk.Align.CENTER)
        top.append(self.clock)
        self.add_top_bar(top)

        self.notice = label("", ("notice",), wrap=True)
        self.notice.set_margin_start(28)
        self.notice.set_margin_end(28)
        self.notice.set_margin_bottom(8)
        self.add_top_bar(self.notice)

        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE)
        waiting = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14, valign=Gtk.Align.CENTER, halign=Gtk.Align.CENTER)
        self.waiting_level = LevelBars(height=30)
        self.waiting_level.set_halign(Gtk.Align.CENTER)
        waiting.append(self.waiting_level)
        self.waiting_title = label("Listening.", ("hero-title",), xalign=0.5)
        waiting.append(self.waiting_title)
        self.waiting_detail = label("", ("dim",), wrap=True, xalign=0.5)
        self.waiting_detail.set_max_width_chars(52)
        waiting.append(self.waiting_detail)
        self.stack.add_named(waiting, "waiting")

        overlay = Gtk.Overlay()
        self.scroller = Gtk.ScrolledWindow(hscrollbar_policy=Gtk.PolicyType.NEVER, vexpand=True)
        clamp = Adw.Clamp(maximum_size=860, margin_start=28, margin_end=28, margin_top=8, margin_bottom=30)
        self.body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.live_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        column = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        column.append(self.body)
        column.append(self.live_box)
        clamp.set_child(column)
        self.scroller.set_child(clamp)
        overlay.set_child(self.scroller)
        self.latest = Gtk.Button(child=Adw.ButtonContent(icon_name="go-bottom-symbolic", label="Latest"),
                                 halign=Gtk.Align.END, valign=Gtk.Align.END, margin_end=24, margin_bottom=16, visible=False)
        self.latest.add_css_class("pill")
        self.latest.connect("clicked", lambda *_: self._follow(True))
        overlay.add_overlay(self.latest)
        adjustment = self.scroller.get_vadjustment()
        adjustment.connect("value-changed", self._scrolled)
        adjustment.connect("changed", lambda *_: self._stick())
        self.stack.add_named(overlay, "transcript")
        self.set_content(self.stack)

        controls = Gtk.Box(spacing=16)
        controls.add_css_class("control-surface")
        self.you = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
        self.you.append(label("You", ("row-subtitle",)))
        self.you_level = LevelBars()
        self.you.append(self.you_level)
        controls.append(self.you)
        self.others = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
        self.others.append(label("Others", ("row-subtitle",)))
        self.others_level = LevelBars(others=True)
        self.others.append(self.others_level)
        controls.append(self.others)
        self.lag_label = label("", ("row-subtitle",))
        self.lag_label.set_hexpand(True)
        controls.append(self.lag_label)
        self.saving = Gtk.Spinner(spinning=True, visible=False)
        controls.append(self.saving)
        self.discard = Gtk.Button(label="Discard", tooltip_text="Delete this recording and its transcript")
        self.discard.add_css_class("flat")
        self.discard.connect("clicked", lambda *_: confirm(self.window, "Discard this note?",
                                                           "The recording and its transcript are deleted.", "Discard",
                                                           self.recorder.discard))
        controls.append(self.discard)
        self.pause = Gtk.Button()
        self.pause_content = Adw.ButtonContent(icon_name="media-playback-pause-symbolic", label="Pause")
        self.pause.set_child(self.pause_content)
        self.pause.add_css_class("pill")
        self.pause.connect("clicked", lambda *_: self._pause_clicked())
        controls.append(self.pause)
        self.stop = Gtk.Button(child=Adw.ButtonContent(icon_name="media-playback-stop-symbolic", label="Stop and save"))
        self.stop.add_css_class("suggested-action")
        self.stop.add_css_class("pill")
        self.stop.connect("clicked", lambda *_: self.recorder.stop())
        controls.append(self.stop)
        self.add_bottom_bar(controls)

    def _pause_clicked(self) -> None:
        if self.recorder.state == "paused":
            self.recorder.resume()
        else:
            self.recorder.pause()

    def _title_edited(self, editable, _param) -> None:
        if editable.get_editing():
            if editable.get_text() == PLACEHOLDER:
                editable.set_text("")
            return
        text = editable.get_text().strip()
        self.recorder.set_title("" if text == PLACEHOLDER else text)
        if not text:
            editable.set_text(PLACEHOLDER)
        self.window.rebuild()

    def _scrolled(self, adjustment) -> None:
        bottom = adjustment.get_upper() - adjustment.get_page_size()
        self.following = adjustment.get_value() >= bottom - 80
        self.latest.set_visible(not self.following)

    def _stick(self) -> None:
        if self.following:
            adjustment = self.scroller.get_vadjustment()
            adjustment.set_value(adjustment.get_upper() - adjustment.get_page_size())

    def _follow(self, value: bool) -> None:
        self.following = value
        self._stick()
        self.latest.set_visible(False)

    def update(self) -> None:
        recorder = self.recorder
        if not recorder.active:
            self.shown = (-1, "")
            clear(self.body)
            clear(self.live_box)
            return
        if not self.title.get_editing():
            self.title.set_text(recorder.title or PLACEHOLDER)
        model = recorder.model.name if recorder.model else ""
        self.meta.set_text(" · ".join(p for p in (SOURCES.get(recorder.sources, ""), models.language_name(recorder.language),
                                                  model, "keeps audio" if recorder.keep_audio else "audio not kept") if p))
        state = recorder.state
        self.state_label.set_text(STATE_LABELS.get(state, ""))
        for css in ("recording", "loading"):
            self.dot.remove_css_class(css)
        self.dot.add_css_class("recording" if state == "recording" else "loading")
        self.clock.set_text(tx.time_label(recorder.elapsed))
        notice = "\n".join(m for m in (recorder.pause_reason, recorder.warning) if m)
        self.notice.set_text(notice)
        self.notice.set_visible(bool(notice))
        uses_mic = recorder.sources in ("microphone", "both")
        uses_system = recorder.sources in ("system", "both")
        self.you.set_visible(uses_mic)
        self.others.set_visible(uses_system)
        self.you_level.set_level(recorder.levels.get("microphone", 0) if state == "recording" else 0)
        self.others_level.set_level(recorder.levels.get("system", 0) if state == "recording" else 0)
        self.lag_label.set_text("Catching up…" if recorder.lag > 20 else "")
        finishing = state == "finishing"
        self.saving.set_visible(finishing)
        for widget in (self.discard, self.pause, self.stop):
            widget.set_visible(not finishing)
        self.pause.set_sensitive(state in ("recording", "paused"))
        self.pause_content.set_label("Resume" if state == "paused" else "Pause")
        self.pause_content.set_icon_name("media-record-symbolic" if state == "paused" else "media-playback-pause-symbolic")
        self.pause.set_tooltip_text("Continue recording this note" if state == "paused" else
                                    "Stop recording for now. The note stays open.")
        if finishing:
            self.lag_label.set_text("Transcribing the last words and saving…")

        segments = recorder.segments
        preview = recorder.preview
        if not segments and not preview:
            self.stack.set_visible_child_name("waiting")
            self.waiting_level.set_level(max(recorder.levels.values()) if state == "recording" else 0)
            self.waiting_title.set_text({"starting": "Starting…", "paused": "Paused."}.get(state, "Listening."))
            if state == "paused":
                detail = "Nothing is recorded until you resume."
            elif recorder.streaming:
                detail = "Text appears a few seconds after it is spoken, one sentence per paragraph."
            else:
                detail = "Text appears after a pause, or after about half a minute of continuous speech."
            self.waiting_detail.set_text(detail)
            return
        self.stack.set_visible_child_name("transcript")
        key = (len(segments), segments[-1].text if segments else "")
        if key != self.shown:
            self.shown = key
            paragraphs = tx.paragraphs(segments, each_sentence=recorder.streaming)
            existing = []
            child = self.body.get_first_child()
            while child:
                existing.append(child)
                child = child.get_next_sibling()
            # Earlier sentences never change; only rebuild from the first paragraph that differs.
            keep = 0
            while keep < min(len(existing), len(paragraphs)) and existing[keep].segment.text == paragraphs[keep].text \
                    and existing[keep].segment.speaker == paragraphs[keep].speaker:
                keep += 1
            for widget in existing[keep:]:
                self.body.remove(widget)
            for paragraph in paragraphs[keep:]:
                self.body.append(TranscriptRow(paragraph))
        clear(self.live_box)
        for speaker, text in preview:
            self.live_box.append(TranscriptRow(tx.Segment(0, 0, 0, text, speaker), live=True))
        GLib.idle_add(lambda: (self._stick(), False)[1])
