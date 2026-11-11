"""Small shared widgets."""

from __future__ import annotations

import time

from gi.repository import Adw, GLib, Gtk, Pango

from ..core import transcript as tx

KIND_ICONS = {"note": "audio-input-microphone-symbolic", "youtube": "video-x-generic-symbolic",
              "file": "audio-x-generic-symbolic"}


def label(text: str = "", css: tuple[str, ...] = (), wrap: bool = False, xalign: float = 0.0, selectable=False,
          markup=False) -> Gtk.Label:
    widget = Gtk.Label(xalign=xalign, wrap=wrap, selectable=selectable)
    if markup:
        widget.set_markup(text)
    else:
        widget.set_text(text)
    if wrap:
        widget.set_wrap_mode(Pango.WrapMode.WORD_CHAR)
    for name in css:
        widget.add_css_class(name)
    return widget


def icon_button(icon: str, tooltip: str, callback=None, css: tuple[str, ...] = ("flat",)) -> Gtk.Button:
    button = Gtk.Button(icon_name=icon, tooltip_text=tooltip)
    button.update_property([Gtk.AccessibleProperty.LABEL], [tooltip])
    for name in css:
        button.add_css_class(name)
    if callback:
        button.connect("clicked", lambda *_: callback())
    return button


def clear(box: Gtk.Box) -> None:
    child = box.get_first_child()
    while child:
        following = child.get_next_sibling()
        box.remove(child)
        child = following


def when(created: float) -> str:
    now = time.localtime()
    then = time.localtime(created)
    if then.tm_year == now.tm_year and then.tm_yday == now.tm_yday:
        return time.strftime("%H:%M", then)
    if then.tm_year == now.tm_year:
        return time.strftime("%b %d", then).replace(" 0", " ")
    return time.strftime("%b %d, %Y", then).replace(" 0", " ")


def group_name(created: float) -> str:
    now = time.time()
    today = time.mktime(time.localtime(now)[:3] + (0, 0, 0, 0, 0, -1))
    if created >= today:
        return "Today"
    if created >= today - 86400:
        return "Yesterday"
    if created >= today - 6 * 86400:
        return "Previous 7 days"
    if created >= today - 29 * 86400:
        return "Previous 30 days"
    return time.strftime("%B %Y", time.localtime(created))


class LevelBars(Gtk.Box):
    """Five bars that light up with the input level."""

    def __init__(self, others: bool = False, height: int = 18):
        super().__init__(orientation=Gtk.Orientation.HORIZONTAL, spacing=3, valign=Gtk.Align.CENTER)
        self.bars = []
        for index in range(5):
            bar = Gtk.Box(height_request=int(height * (0.45 + 0.55 * (1 - abs(index - 2) / 2))), valign=Gtk.Align.CENTER)
            bar.add_css_class("level-bar")
            if others:
                bar.add_css_class("others")
            self.append(bar)
            self.bars.append(bar)

    def set_level(self, value: float) -> None:
        lit = round(max(0.0, min(1.0, value)) * 5)
        for index, bar in enumerate(self.bars):
            (bar.add_css_class if index < lit else bar.remove_css_class)("on")


class TranscriptRow(Gtk.Box):
    """One reading paragraph: a time button that seeks the player, an optional speaker, and selectable text."""

    def __init__(self, segment: tx.Segment, on_seek=None, live: bool = False):
        super().__init__(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        self.segment = segment
        self.add_css_class("transcript-row")
        stamp = Gtk.Button(label="Live" if live else segment.time_label, valign=Gtk.Align.START)
        stamp.add_css_class("flat")
        stamp.add_css_class("timestamp")
        stamp.set_size_request(54, -1)
        if on_seek and not live:
            stamp.set_tooltip_text("Play from here")
            stamp.connect("clicked", lambda *_: on_seek(segment.start))
        else:
            stamp.set_sensitive(not live)
            stamp.set_can_focus(False)
        self.append(stamp)
        if segment.speaker:
            speaker = label(tx.SPEAKER_LABELS.get(segment.speaker, segment.speaker), ("speaker", segment.speaker))
            speaker.set_valign(Gtk.Align.START)
            speaker.set_margin_top(4)
            speaker.set_size_request(50, -1)
            self.append(speaker)
        self.text = label(segment.text, ("transcript-text",) + (("live",) if live else ()), wrap=True,
                          selectable=not live)
        self.text.set_hexpand(True)
        self.append(self.text)

    def highlight(self, query_terms: list[str]) -> None:
        if not query_terms:
            self.text.set_text(self.segment.text)
            return
        text = self.segment.text
        lower = text.lower()
        spans = []
        for term in query_terms:
            start = 0
            while term and (found := lower.find(term, start)) >= 0:
                spans.append((found, found + len(term)))
                start = found + len(term)
        if not spans:
            self.text.set_text(text)
            return
        spans.sort()
        out, position = [], 0
        for start, end in spans:
            if start < position:
                continue
            out.append(GLib.markup_escape_text(text[position:start]))
            out.append(f"<span background='#2bd66b' foreground='#000000'>{GLib.markup_escape_text(text[start:end])}</span>")
            position = end
        out.append(GLib.markup_escape_text(text[position:]))
        self.text.set_markup("".join(out))


def confirm(parent, heading: str, body: str, action: str, callback, destructive: bool = True) -> None:
    dialog = Adw.AlertDialog(heading=heading, body=body)
    dialog.add_response("cancel", "Cancel")
    dialog.add_response("ok", action)
    dialog.set_response_appearance("ok", Adw.ResponseAppearance.DESTRUCTIVE if destructive else Adw.ResponseAppearance.SUGGESTED)
    dialog.set_default_response("cancel")
    dialog.connect("response", lambda d, response: callback() if response == "ok" else None)
    dialog.present(parent)


class Page(Gtk.Box):
    """A content page with header bars. Adw.ToolbarView is final, so pages wrap one."""

    def __init__(self):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self.view = Adw.ToolbarView(vexpand=True, hexpand=True)
        self.append(self.view)

    def add_top_bar(self, widget):
        self.view.add_top_bar(widget)

    def add_bottom_bar(self, widget):
        self.view.add_bottom_bar(widget)

    def set_content(self, widget):
        self.view.set_content(widget)
