# WhisperDrop for Linux

Transcribe recordings and YouTube videos, record notes while you listen, and dictate into any app. Speech is processed on your computer. Nothing is uploaded.

It is WhisperDrop 2 for Mac rebuilt for Linux with GTK 4 and libadwaita, with the same models and the same rules for notes and dictation. Saved files use the same folder layout as on the Mac; the two apps keep separate libraries.

## Install

You need Python 3.11 or later with GTK 4, libadwaita 1.7 or later, FFmpeg and PipeWire. On Arch and Omarchy:

```bash
sudo pacman -S --needed python-gobject gtk4 libadwaita ffmpeg pipewire wl-clipboard wtype yt-dlp gtk4-layer-shell
git clone https://github.com/Zer0codestuff/whisperdrop-2.git
cd whisperdrop-2/linux
./install.sh --download
```

On Debian 13 or Ubuntu 25.04 and later: `sudo apt install python3-gi python3-venv gir1.2-adw-1 ffmpeg pipewire-bin wl-clipboard wtype yt-dlp`. On Fedora: `sudo dnf install python3-gobject gtk4 libadwaita ffmpeg pipewire-utils wl-clipboard wtype yt-dlp gtk4-layer-shell`.

`install.sh` works in your home folder only:
- It copies the app to `~/.local/share/whisperdrop/app`.
- It creates a private Python environment with numpy and sherpa-onnx.
- It adds `whisperdrop` and `whisperdrop-ctl` to `~/.local/bin`, plus a launcher entry and icons.
- `--download` also fetches Parakeet v3 (671 MB).
- `--with-whisper` also builds whisper.cpp, for the Whisper models and the languages Parakeet does not cover. It uses your graphics card through Vulkan when the Vulkan headers and `glslc` are installed.

`./uninstall.sh` removes the app. Your models and library stay unless you add `--purge`. Saved transcripts and recordings are never removed.

## Use it

**Files and YouTube.** Choose **Add files**, drop files on the window, or choose **YouTube** and paste a video or playlist link. Pasting a YouTube link anywhere in the window works too. Transcription starts right away. Each transcript shows timestamps; click one to hear that moment. Find words with Ctrl+F. Export as text, Markdown, SRT, VTT or JSON with word timings.

**Notes.** Choose **New note**, pick what to record, and start:
- **Microphone**: you, or a lecture in the room.
- **System audio**: other apps, such as an online lesson.
- **Both**: a call, labeled You and Others.

With Parakeet v3, text appears a few seconds after it is spoken, one sentence per paragraph. **Pause** stops recording without closing the note. Click the title to rename it, during the recording or later. When **Keep the recording** is on, the audio is saved as M4A beside the transcript, about 22 MB per hour.

A note pauses when the computer goes to sleep or the lid closes, and waits for you to resume it. If the app or the computer stops during a note, the next launch recovers the recording and the transcript up to that point.

**Dictation.** Hold **F9**, speak, and release: the words are typed where your cursor is. A quick tap starts hands-free mode, and the next press stops it. While you speak, a small overlay at the bottom of the screen shows what was heard. **Preferences, Dictation** sets up the shortcut:
- **Hyprland and Omarchy**: WhisperDrop shows two lines for your Hyprland configuration and adds them to `bindings.lua` (or `hyprland.conf`) when you confirm, keeping a backup.
- **GNOME and KDE**: the desktop asks you to confirm a shortcut through its global shortcuts portal.
- **Other desktops**: add a keyboard shortcut that runs `whisperdrop-ctl dictate toggle`.

Typing uses `wtype` on Hyprland, Sway and KDE, `ydotool` on GNOME (its service must run), and `xdotool` on X11. Without one of these, the text is copied and you paste it with Ctrl+V.

WhisperDrop keeps running when you close the window, so dictation stays ready. **Start at login** in Preferences starts it hidden.

### From a terminal

```bash
whisperdrop transcribe lecture.mp3 -f srt -o subtitles/        # one SRT per input; prints to stdout without -o
whisperdrop transcribe "https://www.youtube.com/watch?v=…" -l en
whisperdrop download turbo                                     # or any id from Preferences, Models
whisperdrop-ctl dictate toggle                                 # also press, release, cancel; note toggle; show
```

`transcribe` leaves the library untouched unless you add `--save`.

## Models

| Model | Download | Notes |
| --- | ---: | --- |
| Parakeet v3, recommended | 671 MB | 25 European languages, detected automatically. Runs on the CPU through sherpa-onnx. A 3-minute Italian recording took 9.5 s on an 8-core Intel i7-11700, model loading included. |
| Whisper Tiny, Base, Small, Medium | 32 to 539 MB | Every language. Needs `install.sh --with-whisper`. |
| Whisper Turbo, Turbo Q8 | 574, 874 MB | Every language; best choice for languages Parakeet does not cover. |

Downloads are verified against their SHA-256 checksums. When your language is not covered by the chosen model, an installed Whisper model is used automatically. **Preferences, Models, Advanced** can give dictation, notes or files their own model.

## Where things are

- `~/Documents/WhisperDrop/Audio` and `Transcripts`: kept recordings and TXT, SRT, VTT and Markdown transcripts, in folders named after each item. **Preferences, General, Saved files** moves them.
- `~/.local/share/whisperdrop`: models, the library (`history.json`), the engine log and temporary audio.
- `~/.config/whisperdrop/settings.json`: preferences.

`whisperdrop --data-dir DIR` keeps everything, saved files included, in another folder.

## Limits

- Parakeet decodes windows of up to 35 seconds cut at pauses. A window that mixes several languages can lose a passage; set the spoken language when you know it.
- Wayland lets an app neither grab keys nor type into others by itself, so dictation relies on the shortcut setup and typing tools above.
- The overlay needs `gtk4-layer-shell`. GNOME does not support it; there you see a notification instead.
- Recordings are not cleaned or denoised. Quiet speech is raised for the model only.

## Development

```bash
cd linux
python3 -m venv --system-site-packages .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python -m unittest discover -s tests
WHISPERDROP_VENV=.venv ./bin/whisperdrop --data-dir /tmp/whisperdrop-test
```

See [AGENTS.md](AGENTS.md) for the architecture and how the app was checked.
