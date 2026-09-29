import SwiftUI

/// Contract file. Content of the MenuBarExtra (window style). Reads AppStore, AppSettings, ModelHost, DictationController and NoteRecorder from the environment.
struct MenuBarContent: View {
    var body: some View { Text("WhisperDrop 2") }
}

/// Menu bar icon reflecting dictation and recording state.
struct MenuBarLabel: View {
    var body: some View { Image(systemName: "waveform") }
}
