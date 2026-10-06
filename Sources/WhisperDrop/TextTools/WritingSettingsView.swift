import SwiftUI
import WhisperDropCore

struct WritingSettingsPane: View {
    @EnvironmentObject private var settings: WritingSettings
    @EnvironmentObject private var tools: WritingController
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Writing").font(.system(size: 22, weight: .medium))
                Text("Use the shortcut on selected text, or revise a transcript. All processing stays on this Mac.")
                    .font(.system(size: 12)).foregroundStyle(LivePalette.secondary)
            }
            HStack {
                Text("Selected text shortcut").font(.system(size: 13))
                Spacer()
                Picker("Selected text shortcut", selection: $settings.shortcut) {
                    Text("Control + Option + D").tag("control-option-d")
                    Text("Command + Shift + D").tag("command-shift-d")
                    Text("Control + Option + Space").tag("control-option-space")
                }.labelsHidden().frame(width: 230)
            }
            if let error = tools.shortcutError { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
            Toggle("Show writing tools after dictation", isOn: $settings.showAfterDictation).toggleStyle(.switch).controlSize(.small)
            Toggle("Summarize notes after saving", isOn: $settings.autoSummarizeNotes).toggleStyle(.switch).controlSize(.small)
            Text("Summaries are saved as separate versions. The original transcript and subtitles keep their words and timestamps.")
                .font(.system(size: 11)).foregroundStyle(LivePalette.secondary)
            Divider()
            HStack {
                Text("Actions").font(.system(size: 14, weight: .medium))
                Spacer()
                Button("Add action") {
                    settings.actions.append(.init(id: UUID().uuidString, title: "Custom action", instruction: "Rewrite clearly while preserving the original meaning."))
                }.buttonStyle(.plain).foregroundStyle(LivePalette.green)
            }
            Text("Edit the names and instructions used by the writing panel, dictation and transcripts.")
                .font(.system(size: 11)).foregroundStyle(LivePalette.secondary)
            ForEach($settings.actions) { $action in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Action name", text: $action.title).textFieldStyle(.roundedBorder)
                        if !TextAction.defaults.contains(where: { $0.id == action.id }) {
                            Button { settings.actions.removeAll { $0.id == action.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain).foregroundStyle(LivePalette.secondary).accessibilityLabel("Remove action")
                        }
                    }
                    TextEditor(text: $action.instruction).font(.system(size: 12)).scrollContentBackground(.hidden)
                        .frame(height: 76).padding(8).background(LivePalette.surface, in: RoundedRectangle(cornerRadius: 7))
                        .accessibilityLabel("Instruction for \(action.title)")
                }
            }
            Button("Restore default actions") { settings.resetActions() }.buttonStyle(.plain).foregroundStyle(LivePalette.secondary)
            Divider()
            Text("Your style").font(.system(size: 14, weight: .medium))
            Text("Preferences for revisions. Wording is remembered only when you choose Remember this wording.")
                .font(.system(size: 11)).foregroundStyle(LivePalette.secondary)
            TextEditor(text: $settings.style).font(.system(size: 12)).scrollContentBackground(.hidden)
                .frame(height: 100).padding(8).background(LivePalette.surface, in: RoundedRectangle(cornerRadius: 7))
                .accessibilityLabel("Writing style preferences")
            ForEach(Array(settings.styleExamples.enumerated()), id: \.offset) { index, text in
                HStack(alignment: .top) {
                    Text(text).font(.system(size: 12)).lineLimit(4).textSelection(.enabled)
                    Spacer()
                    Button { settings.styleExamples.remove(at: index) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).foregroundStyle(LivePalette.secondary).accessibilityLabel("Remove style example")
                }
            }
        }.font(.system(size: 13))
    }
}

struct TextModelsPane: View {
    @EnvironmentObject private var settings: WritingSettings
    @EnvironmentObject private var models: TextModelStore
    @EnvironmentObject private var engine: TextGenerationEngine
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider().padding(.top, 20)
            Text("Text editing").font(.system(size: 17, weight: .medium))
            Text("A separate local model for writing tools, summaries and transcript revisions. Downloads are checked against the published SHA-256.")
                .font(.system(size: 12)).foregroundStyle(LivePalette.secondary)
            HStack {
                Text("Working context").font(.system(size: 13))
                Spacer()
                Picker("Working context", selection: $settings.contextMode) {
                    ForEach(TextContextMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 190)
            }
            Text("Automatic uses up to \(TextContextPolicy.automaticMaximum(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory) / 1024)K on this Mac. Larger contexts use more memory. Long texts are processed in sections, including every section.")
                .font(.system(size: 11)).foregroundStyle(LivePalette.secondary)
            ForEach(models.catalog) { model in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 7) {
                                Text(model.name).font(.system(size: 13, weight: .medium))
                                if settings.modelID == model.id { Text("Selected").font(.system(size: 10)).foregroundStyle(LivePalette.green) }
                            }
                            Text(model.detail).font(.system(size: 11)).foregroundStyle(LivePalette.secondary)
                        }
                        Spacer()
                        if models.isInstalled(model) {
                            Button(settings.modelID == model.id ? "Selected" : "Use") { settings.modelID = model.id }
                                .buttonStyle(LiveQuietButton()).disabled(settings.modelID == model.id)
                        } else if models.downloadingID == model.id {
                            Button("Cancel", action: models.cancelDownload).buttonStyle(LiveQuietButton())
                        } else {
                            Button("Download") { models.download(model) }.buttonStyle(LiveQuietButton()).disabled(models.downloadingID != nil)
                        }
                    }
                    if models.downloadingID == model.id {
                        ProgressView(value: models.progress)
                        Text("Downloading \(Int(models.progress * 100))%") .font(.system(size: 11)).foregroundStyle(LivePalette.secondary)
                    }
                    if !models.isInstalled(model) {
                        Button("Use downloaded file…") { models.chooseFile(for: model) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(LivePalette.secondary)
                    }
                }.padding(14).background(LivePalette.surface, in: RoundedRectangle(cornerRadius: 9))
            }
            if let error = models.error { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
            HStack {
                Text(engine.loadedModelID == nil ? "Loads when you run a writing action. Unloads after five minutes idle." : "Text model loaded · \((engine.loadedContextTokens ?? 0) / 1024)K context · \(engine.memoryMB) MB")
                    .font(.system(size: 11)).foregroundStyle(LivePalette.secondary)
                Spacer()
                if engine.loadedModelID != nil {
                    Button("Unload", action: engine.unload).buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(LivePalette.green)
                        .disabled(engine.isGenerating)
                }
            }
            Text("Small text models can change meaning or miss details. Review their suggestions. Model weights are downloaded separately.")
                .font(.system(size: 11)).foregroundStyle(LivePalette.secondary)
        }.onAppear { models.refresh() }
    }
}
