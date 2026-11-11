"""Main window: the library on the left, the selected transcript, the recording note or the start page on the right."""

from __future__ import annotations

from pathlib import Path

from gi.repository import Adw, Gdk, Gio, GLib, Gtk

from .. import shortcuts
from ..audio import media
from ..core import models
from ..core import transcript as tx
from ..library import Job
from .widgets import KIND_ICONS, group_name, icon_button, label, when


class MainWindow(Adw.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title="WhisperDrop", default_width=1180, default_height=780)
        self.set_size_request(380, 480)
        self.app = app
        self.selected: str | None = None
        self.query = ""
        self.rows: dict[str, Gtk.ListBoxRow] = {}

        self.toasts = Adw.ToastOverlay()
        self.split = Adw.NavigationSplitView(min_sidebar_width=300, max_sidebar_width=340, sidebar_width_fraction=0.27)
        self.toasts.set_child(self.split)
        self.set_content(self.toasts)

        self.split.set_sidebar(self._sidebar())
        self.content = Adw.NavigationPage(title="WhisperDrop", tag="content")
        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE, transition_duration=120)
        self.content.set_child(self.stack)
        self.split.set_content(self.content)

        from .home import HomePage
        from .job_page import JobPage
        from .note_page import NotePage

        self.home = HomePage(self)
        self.job_page = JobPage(self)
        self.note_page = NotePage(self)
        self.stack.add_named(self.home, "home")
        self.stack.add_named(self.job_page, "job")
        self.stack.add_named(self.note_page, "note")

        breakpoint = Adw.Breakpoint.new(Adw.BreakpointCondition.parse("max-width: 720sp"))
        breakpoint.add_setter(self.split, "collapsed", True)
        self.add_breakpoint(breakpoint)

        drop = Gtk.DropTarget.new(Gdk.FileList, Gdk.DragAction.COPY)
        drop.connect("drop", self._dropped)
        self.add_controller(drop)
        keys = Gtk.EventControllerKey()
        keys.connect("key-pressed", self._key)
        self.add_controller(keys)
        self._window_actions()

        app.library_changed.connect(self._library_changed)
        app.notes_changed.connect(self._notes_changed)
        app.host_changed.connect(self._update_status)
        app.models_changed.connect(self._update_status)
        app.dictation_changed.connect(self._update_status)
        app.settings.observe(lambda key: self._update_status())
        self.connect("destroy", lambda *_: self._disconnect())
        self.rebuild()
        self._update_status()
        self._route()
        if app.library.load_error:
            GLib.idle_add(lambda: (self.toast(app.library.load_error, 8), False)[1])

    def _disconnect(self) -> None:
        self.app.library_changed.disconnect(self._library_changed)
        self.app.notes_changed.disconnect(self._notes_changed)

    # Sidebar

    def _sidebar(self) -> Adw.NavigationPage:
        page = Adw.NavigationPage(title="Library", tag="sidebar")
        view = Adw.ToolbarView()
        view.add_css_class("sidebar-pane")
        header = Adw.HeaderBar()
        title = Gtk.Box(spacing=4)
        title.append(label("WhisperDrop", ("wordmark",)))
        header.set_title_widget(title)
        menu = Gio.Menu()
        section = Gio.Menu()
        section.append("Preferences", "app.preferences")
        section.append("Models", "app.models")
        menu.append_section(None, section)
        help_section = Gio.Menu()
        help_section.append("Show the Guide", "app.guide")
        help_section.append("Keyboard Shortcuts", "win.shortcuts")
        help_section.append("About WhisperDrop", "app.about")
        menu.append_section(None, help_section)
        quit_section = Gio.Menu()
        quit_section.append("Quit", "app.quit")
        menu.append_section(None, quit_section)
        header.pack_end(Gtk.MenuButton(icon_name="open-menu-symbolic", menu_model=menu, tooltip_text="Main menu",
                                       primary=True))
        view.add_top_bar(header)

        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        actions = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, margin_start=12, margin_end=12, margin_top=6)
        self.note_button = Gtk.Button()
        self.note_button.add_css_class("suggested-action")
        self.note_button.add_css_class("big-action")
        self.note_button.set_tooltip_text("Record a lecture, call or meeting (Ctrl+N)")
        self.note_button_content = Adw.ButtonContent(icon_name="media-record-symbolic", label="New note")
        self.note_button.set_child(self.note_button_content)
        self.note_button.connect("clicked", lambda *_: self.note_clicked())
        actions.append(self.note_button)
        row = Gtk.Box(spacing=8, homogeneous=True)
        add = Gtk.Button(child=Adw.ButtonContent(icon_name="list-add-symbolic", label="Add files"),
                         tooltip_text="Transcribe audio or video files (Ctrl+O)")
        add.add_css_class("quiet-action")
        add.connect("clicked", lambda *_: self.choose_files())
        link = Gtk.Button(child=Adw.ButtonContent(icon_name="insert-link-symbolic", label="YouTube"),
                          tooltip_text="Transcribe a YouTube video or playlist (Ctrl+L)")
        link.add_css_class("quiet-action")
        link.connect("clicked", lambda *_: self.ask_link())
        row.append(add)
        row.append(link)
        actions.append(row)
        body.append(actions)

        self.search = Gtk.SearchEntry(placeholder_text="Search transcripts", margin_start=12, margin_end=12, margin_top=6)
        self.search.connect("search-changed", self._search_changed)
        body.append(self.search)

        self.list = Gtk.ListBox(selection_mode=Gtk.SelectionMode.SINGLE)
        self.list.add_css_class("navigation-sidebar")
        self.list.set_header_func(self._header)
        self.list.connect("row-selected", self._row_selected)
        self.list.set_placeholder(self._placeholder())
        scroller = Gtk.ScrolledWindow(vexpand=True, hscrollbar_policy=Gtk.PolicyType.NEVER, child=self.list)
        body.append(scroller)
        view.set_content(body)

        footer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4, margin_start=16, margin_end=12,
                         margin_top=8, margin_bottom=10)
        status = Gtk.Box(spacing=8)
        self.status_dot = Gtk.Box(valign=Gtk.Align.CENTER)
        self.status_dot.add_css_class("status-dot")
        status.append(self.status_dot)
        self.status_label = label("", ("status-line",))
        self.status_label.set_ellipsize(3)
        self.status_label.set_hexpand(True)
        status.append(self.status_label)
        models_button = icon_button("emblem-system-symbolic", "Models and memory", lambda: self.app.show_preferences("models"))
        status.append(models_button)
        footer.append(status)
        self.dictation_hint = Gtk.Button(halign=Gtk.Align.START)
        self.dictation_hint.add_css_class("flat")
        self.dictation_hint.add_css_class("status-line")
        self.dictation_hint.connect("clicked", lambda *_: self.app.show_preferences("dictation"))
        footer.append(self.dictation_hint)
        footer.append(label("Speech stays on this computer", ("status-line",)))
        view.add_bottom_bar(footer)
        page.set_child(view)
        return page

    def _placeholder(self) -> Gtk.Widget:
        self.placeholder = label("Transcripts and notes will appear here.", ("dim",), wrap=True, xalign=0.5)
        self.placeholder.set_max_width_chars(26)
        self.placeholder.set_margin_top(24)
        self.placeholder.set_margin_start(18)
        self.placeholder.set_margin_end(18)
        return self.placeholder

    def _header(self, row, before):
        name = getattr(row, "group", None)
        if before is None or getattr(before, "group", None) != name:
            row.set_header(label(name, ("group-header",)))
        else:
            row.set_header(None)

    def _make_row(self, job: Job) -> Gtk.ListBoxRow:
        row = Gtk.ListBoxRow()
        row.job_id = job.id
        row.group = "Recording now" if job.id == "__live__" else group_name(job.created)
        box = Gtk.Box(spacing=10, margin_top=8, margin_bottom=8, margin_start=8, margin_end=8)
        icon = Gtk.Image(icon_name=KIND_ICONS.get(job.kind, "audio-x-generic-symbolic"), valign=Gtk.Align.START,
                         margin_top=2)
        icon.add_css_class("row-icon")
        box.append(icon)
        text = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3, hexpand=True)
        title = label(job.title, ("row-title",))
        title.set_ellipsize(3)
        text.append(title)
        subtitle = label(self._subtitle(job), ("row-subtitle",) + (("failed",) if job.status == "failed" else ()))
        subtitle.set_ellipsize(3)
        text.append(subtitle)
        progress = Gtk.ProgressBar(fraction=job.progress, visible=job.active)
        progress.add_css_class("row-progress")
        text.append(progress)
        box.append(text)
        row.set_child(box)
        row.parts = (title, subtitle, progress)
        menu = Gtk.GestureClick(button=3)
        menu.connect("pressed", lambda g, n, x, y, job_id=job.id, row=row: self._row_menu(job_id, row, x, y))
        row.add_controller(menu)
        return row

    def _subtitle(self, job: Job) -> str:
        if job.status == "completed":
            parts = [when(job.created), tx.duration_label(job.duration)]
            if job.kind == "note":
                parts.insert(0, "Note")
            return " · ".join(p for p in parts if p)
        if job.active:
            return f"{job.status_label} {round(job.progress * 100)}%" if job.progress else job.status_label + "…"
        return job.status_label

    def _update_row(self, job: Job) -> None:
        row = self.rows.get(job.id)
        if not row:
            return
        title, subtitle, progress = row.parts
        title.set_text(job.title)
        subtitle.set_text(self._subtitle(job))
        (subtitle.add_css_class if job.status == "failed" else subtitle.remove_css_class)("failed")
        progress.set_visible(job.active)
        progress.set_fraction(job.progress)

    def _visible_jobs(self) -> list[Job]:
        jobs = self.app.library.jobs
        if not self.query:
            return jobs
        terms = self.query.lower().split()
        return [j for j in jobs if all(t in (j.title + " " + j.text).lower() for t in terms)]

    def rebuild(self) -> None:
        selected = self.selected
        self.list.handler_block_by_func(self._row_selected)
        clear_list(self.list)
        self.rows = {}
        if self.app.recorder.active:
            live = Job("note", self.app.recorder.title or "Recording…", "", id="__live__")
            live.status = "transcribing"
            row = self._make_row(live)
            row.parts[1].set_text("Recording now")
            self.rows[live.id] = row
            self.list.append(row)
        for job in self._visible_jobs():
            row = self._make_row(job)
            self.rows[job.id] = row
            self.list.append(row)
        self.placeholder.set_text("No transcripts match your search." if self.query else
                                  "Transcripts and notes will appear here.")
        if selected in self.rows:
            self.list.select_row(self.rows[selected])
        self.list.handler_unblock_by_func(self._row_selected)

    def _search_changed(self, entry):
        self.query = entry.get_text().strip()
        self.rebuild()

    def _row_selected(self, listbox, row):
        if row is None:
            return
        if row.job_id == "__live__":
            self.selected = None
            self.stack.set_visible_child_name("note")
            self.split.set_show_content(True)
            return
        self.show_job(row.job_id)

    def _row_menu(self, job_id: str, row, x, y) -> None:
        job = self.app.library.get(job_id)
        if not job:
            return
        menu = Gio.Menu()
        if job.status in ("failed", "cancelled"):
            menu.append("Try again", f"win.retry::{job_id}")
        menu.append("Rename…", f"win.rename::{job_id}")
        if self.app.library.folders(job):
            menu.append("Show in Files", f"win.reveal::{job_id}")
        menu.append("Remove…", f"win.remove::{job_id}")
        popover = Gtk.PopoverMenu(menu_model=menu, has_arrow=False)
        popover.set_parent(row)
        rect = Gdk.Rectangle()
        rect.x, rect.y, rect.width, rect.height = int(x), int(y), 1, 1
        popover.set_pointing_to(rect)
        popover.popup()

    # Routing

    def show_job(self, job_id: str | None) -> None:
        self.selected = job_id
        if job_id and job_id in self.rows and self.list.get_selected_row() is not self.rows[job_id]:
            self.list.handler_block_by_func(self._row_selected)
            self.list.select_row(self.rows[job_id])
            self.list.handler_unblock_by_func(self._row_selected)
        self._route()
        if job_id:
            self.split.set_show_content(True)

    def show_home(self) -> None:
        self.selected = None
        self.list.unselect_all()
        self._route()

    def _route(self) -> None:
        job = self.app.library.get(self.selected)
        if self.app.recorder.active and not job:
            self.stack.set_visible_child_name("note")
            self.content.set_title(self.app.recorder.title or "Recording")
        elif job:
            self.job_page.show(job)
            self.stack.set_visible_child_name("job")
            self.content.set_title(job.title)
        else:
            self.stack.set_visible_child_name("home")
            self.content.set_title("WhisperDrop")
            self.home.refresh()

    def _library_changed(self, job_id) -> None:
        job = self.app.library.get(job_id) if job_id else None
        if job and job.id in self.rows and not self.query:
            self._update_row(job)
        else:
            self.rebuild()
        if job_id is None or job_id == self.selected:
            current = self.app.library.get(self.selected)
            if current:
                self.job_page.show(current)
            elif self.selected:
                self.selected = None
                self._route()
        if self.stack.get_visible_child_name() == "home":
            self.home.refresh()

    def _notes_changed(self) -> None:
        recorder = self.app.recorder
        active = recorder.active
        has_live = "__live__" in self.rows
        if active != has_live:
            self.rebuild()
            if active:
                self.selected = None
                self._route()
        elif active:
            title, subtitle, _ = self.rows["__live__"].parts
            title.set_text(recorder.title or "Recording…")
            subtitle.set_text({"paused": "Paused", "finishing": "Saving…"}.get(recorder.state, "Recording now"))
        self.note_page.update()
        self.note_button_content.set_label({"recording": "Recording…", "paused": "Paused", "starting": "Starting…",
                                            "finishing": "Saving…"}.get(recorder.state, "New note"))
        self.note_button_content.set_icon_name("media-record-symbolic")
        self._update_status()

    def note_clicked(self) -> None:
        if self.app.recorder.active:
            self.show_job(None)
            return
        self.new_note()

    def new_note(self) -> None:
        from .new_note import NewNoteDialog

        if self.app.recorder.active:
            self.show_job(None)
            return
        NewNoteDialog(self.app).present(self)

    # Status

    def _update_status(self, *args) -> None:
        app = self.app
        host = app.host
        model = app.settings.model_for("dictation")
        installed = app.downloads.installed()
        for name in ("ready", "loading", "failed", "recording"):
            self.status_dot.remove_css_class(name)
        if app.downloads.active:
            text, css = f"Downloading {models.by_id(app.downloads.active).name} {round(app.downloads.progress * 100)}%", "loading"
        elif not installed:
            text, css = "No speech model yet. Download one to start.", "failed"
        elif host.state == "failed":
            text, css = host.message or "The model stopped.", "failed"
        elif host.state in ("ready", "busy") and host.loaded:
            text, css = f"{host.loaded.name} ready", "ready"
        elif host.state == "loading":
            text, css = f"Loading {host.loaded.name if host.loaded else model.name}…", "loading"
        else:
            text, css = f"{model.name} · loads when needed", ""
        if css:
            self.status_dot.add_css_class(css)
        self.status_label.set_text(text)
        self.status_label.set_tooltip_text(text)
        self.dictation_hint.set_label(dictation_hint(app))

    # Adding

    def choose_files(self) -> None:
        dialog = Gtk.FileDialog(title="Choose recordings to transcribe")
        media_filter = Gtk.FileFilter(name="Audio and video")
        for extension in sorted(media.EXTENSIONS):
            media_filter.add_suffix(extension)
        filters = Gio.ListStore.new(Gtk.FileFilter)
        filters.append(media_filter)
        dialog.set_filters(filters)
        dialog.open_multiple(self, None, self._files_chosen)

    def _files_chosen(self, dialog, result):
        try:
            files = dialog.open_multiple_finish(result)
        except GLib.Error:
            return
        self.add_files([files.get_item(i).get_path() for i in range(files.get_n_items())])

    def add_files(self, files: list[str]) -> None:
        usable = [f for f in files if f and Path(f).is_file()]
        if not usable:
            self.toast("Those files cannot be transcribed.")
            return
        skipped = [f for f in usable if not media.is_media(f)]
        added = self.app.transcriber.add_files(usable)
        if added:
            self.show_job(added[0].id)
            if not self.app.settings.auto_transcribe:
                self.toast(f"{len(added)} added. Press Transcribe to start.")
        if skipped:
            self.toast(f"{len(skipped)} file{'s' if len(skipped) > 1 else ''} may not be audio or video. "
                       "WhisperDrop will try anyway.")

    def _dropped(self, target, value, x, y) -> bool:
        files = [f.get_path() for f in value.get_files() if f.get_path()]
        self.add_files(files)
        return True

    def ask_link(self, initial: str = "") -> None:
        dialog = Adw.AlertDialog(heading="Transcribe from YouTube",
                                 body="Paste a video or playlist link. The audio is downloaded, then transcribed on this computer.")
        entry = Gtk.Entry(placeholder_text="https://www.youtube.com/watch?v=…", text=initial, activates_default=True)
        dialog.set_extra_child(entry)
        dialog.add_response("cancel", "Cancel")
        dialog.add_response("add", "Transcribe")
        dialog.set_response_appearance("add", Adw.ResponseAppearance.SUGGESTED)
        dialog.set_default_response("add")
        dialog.set_response_enabled("add", bool(media.youtube_url(initial)))
        entry.connect("changed", lambda e: dialog.set_response_enabled("add", bool(media.youtube_url(e.get_text()))))
        dialog.connect("response", lambda d, r: self.add_link(entry.get_text()) if r == "add" else None)
        dialog.present(self)
        entry.grab_focus()

    def add_link(self, text: str) -> None:
        url = media.youtube_url(text)
        if not url:
            self.toast("That is not a YouTube link.")
            return
        self.toast("Reading the link…")

        def done(jobs, error):
            if error:
                self.toast(error, 6)
            elif jobs:
                self.show_job(jobs[0].id)
                if len(jobs) > 1:
                    self.toast(f"{len(jobs)} videos added from the playlist.")

        self.app.transcriber.add_youtube(url, done)

    def _key(self, controller, keyval, keycode, state) -> bool:
        if state & Gdk.ModifierType.CONTROL_MASK and keyval in (Gdk.KEY_v, Gdk.KEY_V):
            focus = self.get_focus()
            if isinstance(focus, (Gtk.Text, Gtk.TextView, Gtk.Entry)):
                return False
            clipboard = self.get_clipboard()

            def pasted(clip, result):
                try:
                    text = clip.read_text_finish(result) or ""
                except GLib.Error:
                    return
                if media.youtube_url(text):
                    self.ask_link(text.strip())

            clipboard.read_text_async(None, pasted)
            return False
        return False

    def _window_actions(self) -> None:
        def add(name, callback, accels=None, parameter=None):
            action = Gio.SimpleAction.new(name, GLib.VariantType.new(parameter) if parameter else None)
            action.connect("activate", lambda a, p: callback(p.unpack()) if parameter else callback())
            self.add_action(action)
            if accels:
                self.app.set_accels_for_action(f"win.{name}", accels)

        add("add-files", self.choose_files, ["<Control>o"])
        add("add-link", self.ask_link, ["<Control>l"])
        add("new-note", self.new_note, ["<Control>n"])
        add("find", lambda: self.job_page.toggle_search() if self.stack.get_visible_child_name() == "job"
            else self.search.grab_focus(), ["<Control>f"])
        add("search-library", self.search.grab_focus, ["<Control><Shift>f"])
        add("shortcuts", self.show_shortcuts, ["<Control>question"])
        add("retry", lambda job_id: self.app.transcriber.retry(job_id), parameter="s")
        add("rename", lambda job_id: self.rename(job_id), parameter="s")
        add("reveal", lambda job_id: self.reveal(job_id), parameter="s")
        add("remove", lambda job_id: self.remove(job_id), parameter="s")

    # Item actions

    def rename(self, job_id: str) -> None:
        job = self.app.library.get(job_id)
        if not job:
            return
        dialog = Adw.AlertDialog(heading="Rename", body="Folders and files saved for this item are renamed too.")
        entry = Gtk.Entry(text=job.title, activates_default=True)
        dialog.set_extra_child(entry)
        dialog.add_response("cancel", "Cancel")
        dialog.add_response("rename", "Rename")
        dialog.set_response_appearance("rename", Adw.ResponseAppearance.SUGGESTED)
        dialog.set_default_response("rename")
        entry.connect("changed", lambda e: dialog.set_response_enabled("rename", bool(e.get_text().strip())))
        dialog.connect("response", lambda d, r: self.apply_rename(job_id, entry.get_text()) if r == "rename" else None)
        dialog.present(self)

    def apply_rename(self, job_id: str, title: str) -> None:
        try:
            self.app.library.rename(job_id, title)
        except ValueError as error:
            self.toast(str(error))
        self._library_changed(job_id)

    def reveal(self, job_id: str) -> None:
        job = self.app.library.get(job_id)
        folders = self.app.library.folders(job) if job else []
        if not folders:
            self.toast("No saved files for this item.")
            return
        target = folders[-1]
        launcher = Gtk.FileLauncher.new(Gio.File.new_for_path(str(target)))
        launcher.open_containing_folder(self, None, None) if target.is_file() else launcher.launch(self, None, None)

    def remove(self, job_id: str) -> None:
        job = self.app.library.get(job_id)
        if not job:
            return
        if job.active:
            self.toast("Stop transcription before removing this item.")
            return
        has_files = bool(self.app.library.folders(job))
        dialog = Adw.AlertDialog(heading=f"Remove “{job.title}”?",
                                 body="It disappears from the library." + (
                                     " Its saved transcript and audio can stay in your folder or go to the Trash."
                                     if has_files else ""))
        dialog.add_response("cancel", "Cancel")
        if has_files:
            dialog.add_response("keep", "Keep Files")
            dialog.add_response("trash", "Move Files to Trash")
            dialog.set_response_appearance("trash", Adw.ResponseAppearance.DESTRUCTIVE)
        else:
            dialog.add_response("keep", "Remove")
            dialog.set_response_appearance("keep", Adw.ResponseAppearance.DESTRUCTIVE)
        dialog.set_default_response("cancel")

        def respond(d, response):
            if response in ("keep", "trash"):
                self.app.library.remove(job_id, delete_files=response == "trash")
                if self.selected == job_id:
                    self.selected = None
                self.rebuild()
                self._route()

        dialog.connect("response", respond)
        dialog.present(self)

    def show_shortcuts(self) -> None:
        if not hasattr(Adw, "ShortcutsDialog"):  # libadwaita before 1.8
            rows = "\n".join(f"{title}: {keys}" for title, keys in (
                ("New note", "Ctrl+N"), ("Add files", "Ctrl+O"), ("Transcribe a YouTube link", "Ctrl+L"),
                ("Find in transcript", "Ctrl+F"), ("Search the library", "Ctrl+Shift+F"), ("Play or pause", "Ctrl+Space"),
                ("Preferences", "Ctrl+,"), ("Quit", "Ctrl+Q")))
            alert = Adw.AlertDialog(heading="Keyboard Shortcuts", body=rows)
            alert.add_response("close", "Close")
            alert.present(self)
            return
        dialog = Adw.ShortcutsDialog()
        section = Adw.ShortcutsSection(title="General")
        for title, accel in (("New note", "<Control>n"), ("Add files", "<Control>o"), ("Transcribe a YouTube link", "<Control>l"),
                             ("Paste a YouTube link", "<Control>v"), ("Find in transcript", "<Control>f"),
                             ("Search the library", "<Control><Shift>f"), ("Preferences", "<Control>comma"),
                             ("Quit", "<Control>q")):
            section.add(Adw.ShortcutsItem(title=title, accelerator=accel))
        dialog.add(section)
        player = Adw.ShortcutsSection(title="Player")
        player.add(Adw.ShortcutsItem(title="Play or pause", accelerator="<Control>space"))
        dialog.add(player)
        dialog.present(self)

    def toast(self, text: str, timeout: int = 3) -> None:
        self.toasts.add_toast(Adw.Toast(title=GLib.markup_escape_text(text), timeout=timeout))


def clear_list(listbox: Gtk.ListBox) -> None:
    row = listbox.get_row_at_index(0)
    while row:
        listbox.remove(row)
        row = listbox.get_row_at_index(0)


def dictation_hint(app) -> str:
    settings = app.settings
    if not settings.dictation_enabled:
        return "Dictation is off"
    state = app.dictation.state
    if state == "listening":
        return "Listening… release to type"
    if state == "transcribing":
        return "Transcribing dictation…"
    key = settings.shortcut
    if shortcuts.hyprland():
        found = shortcuts.hypr_config()
        if not found or not shortcuts.installed_key(found[0]):
            return "Set up the dictation shortcut"
    verb = {"toggle": "Press"}.get(settings.dictation_mode, "Hold")
    return f"{verb} {key} to dictate in any app"
