import SwiftUI
import AppKit
import WhisperDropCore

struct WritingEditorView: View {
    @EnvironmentObject private var tools: WritingController
    @EnvironmentObject private var settings: WritingSettings
    @EnvironmentObject private var engine: TextGenerationEngine
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                Rectangle().fill(LivePalette.line).frame(height: 1)
                VStack(alignment: .leading, spacing: 20) {
                    WritingActionControls(controller: tools, settings: settings,
                                          compact: geometry.size.width < 740, stackInstruction: geometry.size.width < 740)
                        .padding(14).modifier(LiveControlSurface())
                    Group {
                        if geometry.size.width < 640 {
                            VStack(spacing: 18) { original; suggestion }
                        } else {
                            HStack(alignment: .top, spacing: 24) { original; suggestion }
                        }
                    }.frame(maxHeight: .infinity)
                    WritingResultControls(controller: tools)
                    WritingStatus(controller: tools, engine: engine)
                }.padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 24)
            }
        }.background(Color.black).tint(LivePalette.green)
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Writing tools").font(.system(size: 17, weight: .semibold))
                Text(tools.contextTitle == "Writing tools" ? "Revise text on this Mac. Review the result before using it." : "Editing \(tools.contextTitle)")
                    .font(.system(size: 11)).foregroundStyle(LivePalette.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("New draft", action: tools.newDraft)
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(LivePalette.secondary)
                .disabled(tools.busy || tools.replacing)
            OpenWritingSettingsButton()
        }.padding(.horizontal, 32).frame(height: 96)
    }

    private var original: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Original").font(.system(size: 12, weight: .medium)).foregroundStyle(LivePalette.secondary)
            TextEditor(text: $tools.source).font(.system(size: 16)).scrollContentBackground(.hidden)
                .padding(12).background(Color.black).overlay(RoundedRectangle(cornerRadius: 10).stroke(LivePalette.line))
                .accessibilityLabel("Original text").disabled(tools.busy)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var suggestion: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Suggestion").font(.system(size: 12, weight: .medium)).foregroundStyle(LivePalette.secondary)
                Spacer()
                if !tools.result.isEmpty { Toggle("Show changes", isOn: $tools.showChanges).toggleStyle(.checkbox).font(.system(size: 11)) }
            }
            ZStack(alignment: .topLeading) {
                Color.black
                if tools.result.isEmpty {
                    Text(tools.busy ? (engine.processingDetail ?? "Revising text…") : "Choose an action to create a suggestion.")
                        .font(.system(size: 13)).foregroundStyle(LivePalette.secondary).padding(16)
                } else if tools.showChanges {
                    ScrollView { WritingDiff(original: tools.source, revised: tools.result).padding(16).frame(maxWidth: .infinity, alignment: .leading) }
                } else {
                    TextEditor(text: $tools.result).font(.system(size: 16)).scrollContentBackground(.hidden)
                        .padding(12).accessibilityLabel("Suggested text")
                }
            }.overlay(RoundedRectangle(cornerRadius: 10).stroke(LivePalette.line))
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WritingActionControls: View {
    @ObservedObject var controller: WritingController
    @ObservedObject var settings: WritingSettings
    var compact = false
    var stackInstruction = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: compact ? 2 : 4), spacing: 8) {
                ForEach(Array(settings.actions.prefix(4))) { action in
                    Button(action.title) {
                        controller.chosenActionID = action.id
                        if action.id != "tone" && action.id != "rewrite" { controller.run(action) }
                    }.buttonStyle(LiveQuietButton())
                        .disabled(controller.busy || !controller.hasSource)
                }
            }
            HStack(spacing: 10) {
                if settings.actions.count > 4 {
                    Menu {
                        ForEach(Array(settings.actions.dropFirst(4))) { action in
                            Button(action.title) { controller.run(action) }
                        }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                        .disabled(controller.busy || !controller.hasSource)
                }
                Picker("Action", selection: $controller.chosenActionID) {
                    ForEach(settings.actions) { action in Text(action.title).tag(action.id) }
                }.labelsHidden().frame(maxWidth: 165)
                if stackInstruction { Spacer(minLength: 0) } else { instructionField }
                if controller.busy {
                    Button("Cancel", action: controller.cancel).buttonStyle(LiveQuietButton())
                } else {
                    Button("Generate") { controller.run() }.buttonStyle(LiveGreenButton()).disabled(!controller.hasSource)
                }
            }
            if stackInstruction { instructionField }
        }
    }
    private var instructionField: some View {
        TextField(controller.chosenActionID == "tone" ? "Tone, e.g. friendly or formal" : "Optional instruction", text: $controller.instruction)
            .textFieldStyle(.roundedBorder).accessibilityLabel("Additional instruction")
    }
}

struct WritingStatus: View {
    @ObservedObject var controller: WritingController
    @ObservedObject var engine: TextGenerationEngine
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = controller.error {
                Text(error).font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 7) {
                if controller.busy { ProgressView().controlSize(.small) }
                else { Circle().fill(LivePalette.green).frame(width: 5, height: 5) }
                Text(controller.busy ? (engine.processingDetail ?? "Revising text…") : "\(controller.model.name) · Local processing")
                    .font(.system(size: 11)).foregroundStyle(LivePalette.secondary)
                Spacer(minLength: 0)
            }
        }
    }
}

struct WritingResultControls: View {
    @ObservedObject var controller: WritingController
    var body: some View {
        HStack(spacing: 12) {
            if !controller.result.isEmpty {
                Button("Copy", action: controller.copyResult).buttonStyle(LiveQuietButton())
                Button("Export…", action: controller.exportResult).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(LivePalette.secondary)
                Menu {
                    Button("Remember this wording", action: controller.rememberWording)
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                    .help("Save this wording as an approved style example")
                Spacer(minLength: 0)
                if controller.canSave {
                    Button("Save version", action: controller.saveVersion).buttonStyle(LiveGreenButton()).keyboardShortcut(.defaultAction)
                } else if controller.saved {
                    Label("Saved", systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(LivePalette.green)
                } else if controller.canReplace {
                    Button("Replace", action: controller.replace).buttonStyle(LiveGreenButton()).keyboardShortcut(.defaultAction)
                        .disabled(controller.replacing)
                }
            }
        }
    }
}

struct WritingDiff: View {
    let original: String
    let revised: String
    var body: some View {
        Text(attributed).font(.system(size: 16)).lineSpacing(6).textSelection(.enabled)
    }
    private var attributed: AttributedString {
        guard original.count + revised.count < 24_000 else { return AttributedString(revised) }
        var value = AttributedString()
        for part in TextDiff.parts(original: original, revised: revised) {
            var piece = AttributedString(part.text)
            switch part.kind {
            case .inserted: piece.foregroundColor = LivePalette.green
            case .removed: piece.foregroundColor = .red.opacity(0.8); piece.strikethroughStyle = .single
            case .unchanged: break
            }
            value += piece
        }
        return value
    }
}

struct WritingPanelView: View {
    @ObservedObject var controller: WritingController
    @ObservedObject var settings: WritingSettings
    @ObservedObject var engine: TextGenerationEngine
    let resize: (CGFloat) -> Void
    @State private var showOriginal = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(controller.contextTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 8)
                OpenModelsButton(defaults: controller.defaults) { Image(systemName: "square.stack.3d.up") }
                    .buttonStyle(.plain).foregroundStyle(LivePalette.secondary).help("Choose the text model in Settings, Models")
                Button(action: controller.dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(LivePalette.secondary).accessibilityLabel("Keep original and close")
            }
            if controller.source.isEmpty {
                TextEditor(text: $controller.source).font(.system(size: 14)).scrollContentBackground(.hidden)
                    .frame(height: 80).padding(8).background(Color.black, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Text to revise")
            } else if controller.result.isEmpty {
                Text(controller.source).font(.system(size: 14)).lineSpacing(4).lineLimit(4)
                    .foregroundStyle(.white.opacity(0.85)).textSelection(.enabled)
            }
            if controller.result.isEmpty {
                WritingActionControls(controller: controller, settings: settings, compact: true)
            } else {
                HStack {
                    Text("Suggestion").font(.system(size: 11)).foregroundStyle(LivePalette.secondary)
                    Spacer()
                    Toggle("Changes", isOn: $controller.showChanges).toggleStyle(.checkbox).font(.system(size: 11))
                }
                Group {
                    if controller.showChanges {
                        ScrollView { WritingDiff(original: controller.source, revised: controller.result).padding(12).frame(maxWidth: .infinity, alignment: .leading) }
                    } else {
                        TextEditor(text: $controller.result).font(.system(size: 14)).scrollContentBackground(.hidden).padding(8)
                            .accessibilityLabel("Suggested text")
                    }
                }.frame(height: 210).background(Color.black, in: RoundedRectangle(cornerRadius: 9))
                WritingResultControls(controller: controller)
                HStack {
                    Button("Try another action") { controller.result = "" }.buttonStyle(.plain).foregroundStyle(LivePalette.secondary)
                    Spacer()
                    Button("Keep original", action: controller.dismiss).buttonStyle(.plain).foregroundStyle(LivePalette.secondary)
                }.font(.system(size: 11))
                if !controller.canReplace && !controller.canSave && !controller.saved {
                    Text("Copy the result to use it. The source editor did not provide a verified replacement target.")
                        .font(.system(size: 11)).foregroundStyle(LivePalette.secondary)
                }
            }
            WritingStatus(controller: controller, engine: engine)
        }.padding(20).frame(width: 500).modifier(LiveControlSurface(radius: 20))
            .padding(4).preferredColorScheme(.dark).tint(LivePalette.green)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { geometry in
                Color.clear.onAppear { resize(geometry.size.height) }.onChange(of: geometry.size.height) { resize(geometry.size.height) }
            })
    }
}

struct OpenWritingSettingsButton: View {
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsView.tabKey) private var tab = SettingsView.Tab.general.rawValue
    var body: some View {
        Button("Writing settings…") { tab = SettingsView.Tab.writing.rawValue; NSApp.activate(ignoringOtherApps: true); openSettings() }
            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(LivePalette.secondary)
    }
}

struct OpenWritingEditorButton: View {
    @ObservedObject var controller: WritingController
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Open writing tools") {
            controller.openEditor(); openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true)
        }
    }
}

private final class WritingPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

@MainActor
final class WritingPanelController {
    private weak var controller: WritingController?
    private var panel: WritingPanel?
    private var anchor = NSRect.zero
    private var height: CGFloat = 280
    private var clickMonitor: Any?
    init(controller: WritingController) { self.controller = controller }

    func show(selection: NSRect?) {
        if let selection {
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            anchor = NSRect(x: selection.minX, y: primaryHeight - selection.maxY, width: selection.width, height: selection.height)
        } else {
            let pointer = NSEvent.mouseLocation
            anchor = NSRect(x: pointer.x - 12, y: pointer.y - 10, width: 24, height: 20)
        }
        let panel = makePanel()
        place(); panel.orderFrontRegardless(); panel.makeKey()
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.controller?.dismiss() }
            }
        }
    }

    func hide() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil; panel?.orderOut(nil)
    }

    private func makePanel() -> WritingPanel {
        if let panel { return panel }
        let panel = WritingPanel(contentRect: NSRect(x: 0, y: 0, width: 508, height: height),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true; panel.level = .popUpMenu
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
        panel.hidesOnDeactivate = false; panel.becomesKeyOnlyIfNeeded = true; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.onCancel = { [weak self] in self?.controller?.dismiss() }
        if let controller {
            let hosting = NSHostingView(rootView: WritingPanelView(controller: controller, settings: controller.settings,
                                                                 engine: controller.engine) { [weak self] height in
                guard let self, height > 0, abs(height - self.height) > 0.5 else { return }
                self.height = height; if self.panel?.isVisible == true { self.place() }
            })
            hosting.sizingOptions = []; panel.contentView = hosting
        }
        self.panel = panel
        return panel
    }

    private func place() {
        guard let panel else { return }
        let area = (NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main)?.visibleFrame ?? panel.frame
        let x = min(max(anchor.minX, area.minX + 8), area.maxX - 508 - 8)
        var y = anchor.minY - 8 - height
        if y < area.minY + 8 { y = anchor.maxY + 8 }
        y = min(max(y, area.minY + 8), area.maxY - height - 8)
        panel.setFrame(NSRect(x: x, y: y, width: 508, height: min(height, area.height - 16)), display: true)
        panel.invalidateShadow()
    }
}
