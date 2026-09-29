import SwiftUI
import Combine
import WhisperDropCore

/// Contract file. Live recording view shown in the main window detail area while NoteRecorder is active. Reads NoteRecorder from the environment.
/// Laid out as a full reading column (header, transcript, control group) to match ContentView.
struct LiveNoteView: View {
    @EnvironmentObject private var recorder: NoteRecorder
    @State private var confirmDiscard = false
    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(LivePalette.line).frame(height: 1)
            ZStack {
                Color.black
                if recorder.segments.isEmpty { waiting } else { transcript }
            }
            controls.padding(.horizontal, 28).padding(.bottom, 24).padding(.top, 12)
        }
        .background(Color.black)
        .tint(LivePalette.green)
        .confirmationDialog("Discard this note?", isPresented: $confirmDiscard) {
            Button("Discard", role: .destructive) { recorder.discard() }
            Button("Keep recording", role: .cancel) {}
        } message: { Text("The recording and its transcript are deleted.") }
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                TextField(LiveFormat.noteTitle(), text: $recorder.title)
                    .textFieldStyle(.plain).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: LiveNote.symbol(recorder.sources))
                    Text(recorder.sources.label)
                }.font(.system(size: 11)).foregroundStyle(LivePalette.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Circle().fill(stateColor).frame(width: 7, height: 7)
                Text(stateLabel).font(.system(size: 11)).foregroundStyle(isFailed ? Color.red : LivePalette.secondary)
            }
            Text(LiveFormat.clock(recorder.elapsed)).font(.system(size: 17, weight: .medium, design: .monospaced))
                .accessibilityLabel("Elapsed \(LiveFormat.clock(recorder.elapsed))")
        }.padding(.horizontal, 32).frame(height: 96)
    }

    private var waiting: some View {
        VStack(spacing: 16) {
            LiveLevelBars(level: max(recorder.micLevel, recorder.systemLevel), active: recorder.state == .recording, maxHeight: 28)
            Text(recorder.state == .starting ? "Starting…" : "Listening.").font(.system(size: 24, weight: .medium))
            Text(isFailed ? failure : "Text appears here a few seconds after someone speaks.")
                .font(.system(size: 13)).foregroundStyle(isFailed ? Color.red : LivePalette.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 390)
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        Text("Live transcript").font(.system(size: 12, weight: .medium)).foregroundStyle(LivePalette.secondary)
                        Spacer()
                        if recorder.pendingChunks > 1 {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("Catching up… \(recorder.pendingChunks)").monospacedDigit()
                            }.font(.system(size: 11)).foregroundStyle(LivePalette.secondary)
                        }
                    }.padding(.bottom, 8)
                    ForEach(recorder.segments) { segment in
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text(segment.timeLabel).font(.system(size: 11)).monospacedDigit().foregroundStyle(LivePalette.secondary).frame(width: 44, alignment: .leading)
                            if let speaker = segment.speaker {
                                Text(speaker.label).font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(speaker == .you ? LivePalette.green : .white).frame(width: 44, alignment: .leading)
                            }
                            Text(segment.text).font(.system(size: 16)).lineSpacing(7).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }.id(segment.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(36).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: recorder.segments.count) {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 18) {
            if recorder.sources.usesMicrophone { meter("You", recorder.micLevel, LivePalette.green) }
            if recorder.sources.usesMicrophone && recorder.sources.usesSystemAudio {
                Rectangle().fill(LivePalette.line).frame(width: 1, height: 28)
            }
            if recorder.sources.usesSystemAudio { meter("Others", recorder.systemLevel, .white) }
            Spacer(minLength: 0)
            if recorder.state == .finishing {
                ProgressView().controlSize(.small)
                Text("Saving the note…").font(.system(size: 12)).foregroundStyle(LivePalette.secondary)
            } else {
                Button("Discard") { confirmDiscard = true }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(LivePalette.secondary)
                    .disabled(recorder.state != .recording && recorder.state != .starting)
                Button(action: recorder.stop) { Label("Stop and save", systemImage: "stop.fill") }
                    .buttonStyle(LiveGreenButton()).keyboardShortcut(.cancelAction)
                    .disabled(recorder.state != .recording)
            }
        }.padding(16).modifier(LiveControlSurface())
    }

    private func meter(_ label: String, _ level: Float, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10)).foregroundStyle(LivePalette.secondary)
            LiveLevelBars(level: level, active: recorder.state == .recording, color: color, maxHeight: 14)
        }.accessibilityElement().accessibilityLabel("\(label) level")
    }

    private var isFailed: Bool { if case .failed = recorder.state { true } else { false } }
    private var failure: String { if case .failed(let message) = recorder.state { message } else { "" } }
    private var stateColor: Color {
        switch recorder.state {
        case .recording: LivePalette.green
        case .starting, .finishing: LivePalette.green.opacity(0.45)
        case .failed: .red
        case .idle: LivePalette.secondary
        }
    }
    private var stateLabel: String {
        switch recorder.state {
        case .idle: "Stopped"
        case .starting: "Starting"
        case .recording: "Recording"
        case .finishing: "Saving"
        case .failed: "Failed"
        }
    }
}

/// Sidebar control to start a new note with a chosen source. Reads NoteRecorder and AppSettings from the environment.
struct NewNoteButton: View {
    @EnvironmentObject private var recorder: NoteRecorder
    @EnvironmentObject private var settings: AppSettings
    var body: some View {
        let active = LiveNote.isActive(recorder.state)
        Menu {
            ForEach(NoteSources.allCases) { source in
                Button { LiveNote.start(recorder, source) } label: {
                    Label(source.label + (source == settings.noteSources ? " (default)" : ""), systemImage: LiveNote.symbol(source))
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: active ? "record.circle.fill" : "record.circle").foregroundStyle(active ? LivePalette.green : .white)
                Text(active ? "Recording" : "New note")
            }.frame(maxWidth: .infinity)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(LivePalette.line))
        .disabled(active)
        .help(active ? "A note is recording" : "Record a call, lecture or meeting")
    }
}

/// Floating onboarding sheet that walks through the permissions the live features need. Reads Permissions from the environment.
/// Done stores `permissionsOnboardingDone = true` in UserDefaults; Settings, Permissions, "Show setup again" clears it.
struct PermissionsOnboardingView: View {
    @EnvironmentObject private var permissions: Permissions
    @Environment(\.dismiss) private var dismiss
    @AppStorage("permissionsOnboardingDone") private var onboardingDone = false
    private let poll = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("WhisperDrop").font(.system(size: 21, weight: .semibold, design: .rounded))
                Text("2").font(.system(size: 13, weight: .medium)).foregroundStyle(LivePalette.green)
            }
            Text("Dictate into any app, or record a note, on this Mac.").font(.system(size: 24, weight: .medium)).tracking(-0.5)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 18)
            Text("macOS asks for a few permissions. Audio and text never leave this Mac. Skip any of them and allow it later in Settings.")
                .font(.system(size: 13)).foregroundStyle(LivePalette.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 10).padding(.bottom, 18)
            ForEach(Array(Permissions.Kind.allCases.enumerated()), id: \.element) { index, kind in
                if index > 0 { Rectangle().fill(LivePalette.line).frame(height: 1) }
                LivePermissionRow(kind: kind)
            }
            Rectangle().fill(LivePalette.line).frame(height: 1)
            LiveFnHint().padding(.top, 16)
            HStack {
                Text(allSet ? "All set." : "You can change these any time.").font(.system(size: 11)).foregroundStyle(LivePalette.secondary)
                Spacer()
                Button("Done") { onboardingDone = true; dismiss() }
                    .buttonStyle(LiveGreenButton()).keyboardShortcut(.defaultAction)
            }.padding(.top, 22)
        }
        .padding(32).frame(width: 520)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .tint(LivePalette.green)
        .onAppear { permissions.refresh() }
        .onReceive(poll) { _ in permissions.refresh() }
    }
    private var allSet: Bool {
        [.microphone, .accessibility, .inputMonitoring].allSatisfy { permissions.status[$0] == .granted }
    }
}
