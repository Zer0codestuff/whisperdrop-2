import AppKit
import SwiftUI
import Combine

/// Contract file. Small floating, non-activating panel near the bottom of the active screen.
@MainActor
final class DictationHUD {
    private let controller: DictationController
    private var panel: HUDPanel?
    private var subscription: AnyCancellable?
    private var hideTask: Task<Void, Never>?
    private var shown = false
    /// Transparent host; the visible pill is centered inside and animates its own width.
    private static let size = NSSize(width: 340, height: 52)

    init(controller: DictationController) {
        self.controller = controller
        // @Published emits in willSet on the main actor, so use the delivered value, not controller.state.
        subscription = controller.$state.removeDuplicates().sink { [weak self] state in
            MainActor.assumeIsolated { self?.apply(state) }
        }
    }

    /// Shows or hides the panel to match the controller state. Called by the controller on every state change.
    func update() { apply(controller.state) }

    private func apply(_ state: DictationController.State) {
        hideTask?.cancel()
        hideTask = nil
        switch state {
        case .idle:
            hide()
        case .listening, .transcribing:
            show()
        case .failed:
            show()
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled else { return }
                self?.hide()
            }
        }
    }

    private func show() {
        if shown, panel?.isVisible == true { return }
        shown = true
        // Stay on the screen that had the mouse when dictation started.
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = Self.size
        // Pill is 36 pt tall and centered, so its bottom edge sits 28 pt above the Dock.
        let target = NSRect(x: (visible.midX - size.width / 2).rounded(), y: visible.minY + 28 - (size.height - 36) / 2,
                            width: size.width, height: size.height)
        var panel = self.panel ?? makePanel()
        present(panel, at: target)
        if !panel.isVisible {
            // A panel kept across sleep can ignore orderFront; rebuild once.
            panel.close()
            panel = makePanel()
            present(panel, at: target)
        }
    }

    private func present(_ panel: HUDPanel, at target: NSRect) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let wasVisible = panel.isVisible && panel.alphaValue > 0.01
        if !wasVisible {
            panel.alphaValue = 0
            panel.setFrame(reduceMotion ? target : target.offsetBy(dx: 0, dy: -8), display: false)
        }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(target, display: true)
        }
    }

    private func hide() {
        guard shown, let panel else { return }
        shown = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                if self?.shown == false { panel.orderOut(nil) }
            }
        }
    }

    private func makePanel() -> HUDPanel {
        let panel = HUDPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        let host = NSHostingView(rootView: HUDView(controller: controller))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = host
        self.panel = panel
        return panel
    }
}

private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct HUDView: View {
    @ObservedObject var controller: DictationController
    var body: some View {
        let failure: String? = if case .failed(let message) = controller.state { message } else { nil }
        let listening = if case .listening = controller.state { true } else { false }
        let transcribing = controller.state == .transcribing
        HStack(spacing: 10) {
            if failure != nil {
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 13)).foregroundStyle(.red)
            } else {
                LiveLevelBars(level: listening ? controller.level : 0, active: listening)
            }
            Text(failure ?? label).font(.system(size: 12, weight: .medium)).lineLimit(1).minimumScaleFactor(0.85)
                .foregroundStyle(failure == nil ? Color.white : Color.red)
                .contentTransition(.opacity)
            Spacer(minLength: 0)
            if listening {
                Text("esc").font(.system(size: 11)).foregroundStyle(LivePalette.secondary).transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .frame(width: failure == nil ? 220 : 300, height: 36)
        .background(Color.black, in: Capsule())
        .overlay(alignment: .bottom) {
            if transcribing { SweepBar().padding(.horizontal, 18).padding(.bottom, 3).transition(.opacity) }
        }
        .overlay(Capsule().strokeBorder(LivePalette.line))
        .clipShape(Capsule())
        .animation(.easeOut(duration: 0.16), value: failure == nil)
        .animation(.easeInOut(duration: 0.12), value: label)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .combine)
    }
    private var label: String {
        switch controller.state {
        case .listening(let handsFree): handsFree ? "Hands-free" : "Listening"
        case .transcribing: "Transcribing"
        case .idle: "Done"
        case .failed(let message): message
        }
    }
}

/// Indeterminate 2 pt green segment; static with Reduce Motion.
private struct SweepBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geo in
            if reduceMotion {
                Capsule().fill(LivePalette.green).frame(height: 2)
            } else {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
                    let width = geo.size.width * 0.4
                    Capsule().fill(LivePalette.green).frame(width: width, height: 2)
                        .offset(x: -width + (geo.size.width + width) * t)
                }
            }
        }.frame(height: 2).clipped()
    }
}
